# ------------------------------------------------------------
# time_series_cluster_manager.jl
#   Port of app/models/time_series_cluster_manager.rb (Rails)
#   - incremental subsequence clustering
#   - rollback-based simulation (for generate candidate scoring)
# ------------------------------------------------------------

# A single cluster node (nested tree)
mutable struct ClusterNode
  si::Vector{Int}                 # start indices
  cc::Dict{Int,ClusterNode}       # child clusters
  as::Vector{Float64}             # average sequence (representative)
end

mutable struct TimeSeriesClusterManager
  data::Vector{Int}
  merge_threshold_ratio::Float64
  min_window_size::Int
  calculate_distance_when_added_subsequence_to_cluster::Bool

  # ------------------------------------------------------------
  # scale behavior
  #   :global_halves ... analyse用（全体分布から lower/upper を作る）
  #   :range_fixed   ... generate用（range_max-range_min で固定）
  # ------------------------------------------------------------
  scale_mode::Symbol
  range_min::Int
  range_max::Int

  clusters::Dict{Int,ClusterNode}
  cluster_id_counter::Int
  tasks::Vector{Tuple{Vector{Int},Int}}

  updated_cluster_ids_per_window_for_calculate_distance::Dict{Int,Set{Int}}
  updated_cluster_ids_per_window_for_calculate_quantities::Dict{Int,Set{Int}}

  cluster_distance_cache::Dict{Int,Dict{Tuple{Int,Int},Float64}}
  cluster_quantity_cache::Dict{Int,Dict{Int,Float64}}
  cluster_complexity_cache::Dict{Int,Dict{Int,Float64}}

  # rollback journal
  recording_mode::Bool
  journal::Vector{Any}
  snapshot_state::Union{Nothing,NamedTuple}
end

# ---------------------------
# ctor
# ---------------------------
function TimeSeriesClusterManager(
  data::Vector{Int},
  merge_threshold_ratio::Real,
  min_window_size::Int,
  calculate_distance_when_added_subsequence_to_cluster::Bool;
  scale_mode::Symbol = :global_halves,
  range_min::Int = 0,
  range_max::Int = 24
)
  mtr = float(merge_threshold_ratio)
  seed_as =
    if length(data) >= min_window_size
      Float64.(data[1:min_window_size])
    else
      fill(0.0, min_window_size)
    end

  clusters = Dict{Int,ClusterNode}(0 => ClusterNode([0], Dict{Int,ClusterNode}(), seed_as))

  updated_dist = Dict{Int,Set{Int}}(min_window_size => Set([0]))
  updated_qty  = Dict{Int,Set{Int}}(min_window_size => Set([0]))

  dist_cache = Dict{Int,Dict{Tuple{Int,Int},Float64}}(min_window_size => Dict{Tuple{Int,Int},Float64}())
  qty_cache  = Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}())
  comp_cache = Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}())

  return TimeSeriesClusterManager(
    data,
    mtr,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster,
    scale_mode,
    range_min,
    range_max,
    clusters,
    1,                         # next id
    Tuple{Vector{Int},Int}[],  # tasks
    updated_dist,
    updated_qty,
    dist_cache,
    qty_cache,
    comp_cache,
    false,
    Any[],
    nothing
  )
end

# ---------------------------
# scale helpers
# ---------------------------

"""
max_distance_for_length

距離の正規化用スケールを「部分列長 len」に合わせて返す。

- analyse（:global_halves）:
    delta = |upper_half_average - lower_half_average|
    scale = delta * sqrt(len)

- generate（:range_fixed）:
    delta = |range_max - range_min|
    scale = delta * sqrt(len)

※ユークリッド距離は長さに対して sqrt(len) スケールするため、この形が自然。
"""
function max_distance_for_length(mgr::TimeSeriesClusterManager, len::Int)::Float64
  len <= 0 && return 0.0

  if mgr.scale_mode == :range_fixed
    delta = abs(mgr.range_max - mgr.range_min)
    return float(delta) * sqrt(float(len))
  end

  # :global_halves (analyse)
  isempty(mgr.data) && return 0.0

  # グローバルの平均・上下代表
  data_mean = mean_value(mgr.data)
  lower = [x for x in mgr.data if x <= data_mean]
  upper = [x for x in mgr.data if x >= data_mean]

  lower_half_average = mean_value(lower)
  upper_half_average = mean_value(upper)

  delta = abs(upper_half_average - lower_half_average)
  return delta * sqrt(float(len))
end

# ---------------------------
# public APIs
# ---------------------------
function process_data!(mgr::TimeSeriesClusterManager)
  for (i, _) in enumerate(mgr.data)
    data_index = i - 1 # Rails is 0-based in cluster indices
    if data_index <= mgr.min_window_size - 1
      continue
    end
    clustering_subsequences_incremental!(mgr, data_index)
  end
end

function add_data_point_permanently!(mgr::TimeSeriesClusterManager, val::Int)
  push!(mgr.data, val)
  clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
end

# full cache update (used after each permanent append in generate)
function update_caches_permanently!(mgr::TimeSeriesClusterManager, quadratic_integer_array::Vector{Int})
  clusters_each = transform_clusters(mgr.clusters, mgr.min_window_size)

  for (window_size, same_ws) in clusters_each
    all_ids = collect(keys(same_ws))

    # ----------------------------------------------------------
    # Distance cache
    #   - Seed full cache only when this window_size cache is empty
    #   - Otherwise update only updated clusters (incremental)
    # ----------------------------------------------------------
    cache = get!(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    updated_ids_set = get(mgr.updated_cluster_ids_per_window_for_calculate_distance, window_size, nothing)

    if isempty(cache)
      # First-time (or reset) seeding: compute all pairs once.
      for i in 1:length(all_ids)
        cid1 = all_ids[i]
        for j in (i+1):length(all_ids)
          cid2 = all_ids[j]
          as1 = same_ws[cid1]["as"]
          as2 = same_ws[cid2]["as"]
          key = cid1 < cid2 ? (cid1, cid2) : (cid2, cid1)
          cache[key] = euclidean_distance(as1, as2)
        end
      end
    elseif updated_ids_set !== nothing && !isempty(updated_ids_set)
      # Incremental update: only clusters whose representative subsequence changed / was created.
      for cid1 in updated_ids_set
        cluster1 = get(same_ws, cid1, nothing)
        cluster1 === nothing && continue
        as1 = cluster1["as"]
        @inbounds for cid2 in all_ids
          cid1 == cid2 && continue
          as2 = same_ws[cid2]["as"]
          key = cid1 < cid2 ? (cid1, cid2) : (cid2, cid1)
          cache[key] = euclidean_distance(as1, as2)
        end
      end
    end

    # ----------------------------------------------------------
    # Quantity / complexity cache
    #   - Seed full cache only when this window_size cache is empty
    #   - Otherwise update only updated clusters (incremental)
    # ----------------------------------------------------------
    q_cache = get!(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get!(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())
    updated_quant_set = get(mgr.updated_cluster_ids_per_window_for_calculate_quantities, window_size, nothing)

    if isempty(q_cache) || isempty(c_cache)
      for (cid, cluster) in same_ws
        si = cluster["si"]
        length(si) <= 1 && continue

        q = 1.0
        for s in si
          idx = s[1] + 1
          if 1 <= idx <= length(quadratic_integer_array)
            q *= quadratic_integer_array[idx]
          end
        end
        q_cache[cid] = q
        c_cache[cid] = calculate_cluster_complexity(cluster)
      end
    elseif updated_quant_set !== nothing && !isempty(updated_quant_set)
      for cid in updated_quant_set
        cluster = get(same_ws, cid, nothing)
        cluster === nothing && continue
        si = cluster["si"]
        length(si) > 1 || continue

        q = 1.0
        for s in si
          idx = s[1] + 1
          if 1 <= idx <= length(quadratic_integer_array)
            q *= quadratic_integer_array[idx]
          end
        end
        q_cache[cid] = q
        c_cache[cid] = calculate_cluster_complexity(cluster)
      end
    end
  end

  # consume deltas
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
  return nothing
end

# --- simulation with rollback ---
function simulate_add_and_calculate(mgr::TimeSeriesClusterManager, candidate::Int, quadratic_integer_array::Vector{Int})
  start_transaction!(mgr)
  reset_updated_ids_for_simulation!(mgr)

  try
    push!(mgr.data, candidate)
    record_action!(mgr, :data_push)

    clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
    clusters_each = transform_clusters(mgr.clusters, mgr.min_window_size)

    sum_distances = 0.0
    sum_quantities = 0.0
    sum_complexities = 0.0

    for (window_size, same_ws) in clusters_each
      all_ids = collect(keys(same_ws))
      updated_ids = collect(get(mgr.updated_cluster_ids_per_window_for_calculate_distance, window_size, Set{Int}()))

      cache = get!(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
      for cid1 in updated_ids
        for cid2 in all_ids
          cid1 == cid2 && continue
          key = cid1 < cid2 ? (cid1, cid2) : (cid2, cid1)
          as1 = same_ws[cid1]["as"]
          as2 = same_ws[cid2]["as"]
          dist = euclidean_distance(as1, as2)
          old_val = get(cache, key, nothing)
          cache[key] = dist
          record_action!(mgr, :cache_write, cache, key, old_val)
        end
      end
      # identical to Rails: sum(cache.values) / window_size
      if !isempty(cache)
        sum_distances += (sum(values(cache)) / float(window_size))
      end

      updated_quant_ids = collect(get(mgr.updated_cluster_ids_per_window_for_calculate_quantities, window_size, Set{Int}()))
      q_cache = get!(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
      c_cache = get!(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())

      for cid in updated_quant_ids
        haskey(same_ws, cid) || continue
        cluster = same_ws[cid]
        si = cluster["si"]
        length(si) > 1 || continue

        q = 1.0
        for s in si
          idx = s[1] + 1
          if 1 <= idx <= length(quadratic_integer_array)
            q *= quadratic_integer_array[idx]
          end
        end
        old_q = get(q_cache, cid, nothing)
        q_cache[cid] = q
        record_action!(mgr, :cache_write, q_cache, cid, old_q)

        comp = calculate_cluster_complexity(cluster)
        old_c = get(c_cache, cid, nothing)
        c_cache[cid] = comp
        record_action!(mgr, :cache_write, c_cache, cid, old_c)
      end

      if !isempty(q_cache);  sum_quantities += sum(values(q_cache)); end
      if !isempty(c_cache);  sum_complexities += sum(values(c_cache)); end
    end

    return (sum_distances, sum_quantities, sum_complexities)
  finally
    rollback!(mgr)
  end
end

# --- complexity ---
function calculate_cluster_complexity(cluster::Dict{String,Any})::Float64
  seq = cluster["as"]
  if !(seq isa AbstractVector)
    return 0.0
  end
  if length(seq) < 2
    return 0.0
  end
  total = 0.0
  for i in 1:(length(seq)-1)
    total += step_distance(seq[i], seq[i+1])
  end
  return total / float(length(seq)-1)
end

step_distance(a::Real, b::Real)::Float64 = abs(float(a) - float(b))

# ---------------------------
# transform for frontend
# ---------------------------
function transform_clusters(clusters::Dict{Int,ClusterNode}, min_window_size::Int)
  clusters_each = Dict{Int,Dict{Int,Dict{String,Any}}}()
  stack = [(min_window_size, cid, cl) for (cid, cl) in clusters]

  while !isempty(stack)
    (depth, cluster_id, current) = pop!(stack)
    sequences = [[s, s + depth - 1] for s in current.si]
    same_ws = get!(clusters_each, depth, Dict{Int,Dict{String,Any}}())
    same_ws[cluster_id] = Dict("si" => sequences, "as" => current.as)

    for (child_id, child_cluster) in current.cc
      push!(stack, (depth + 1, child_id, child_cluster))
    end
  end

  return clusters_each
end

function clusters_to_timeline(clusters::Dict{Int,ClusterNode}, min_window_size::Int)
  result = Vector{Dict{String,Any}}()
  stack = [(min_window_size, cid, cl) for (cid, cl) in clusters]

  while !isempty(stack)
    (window_size, cluster_id, current) = pop!(stack)

    if !isempty(current.si)
      push!(result, Dict(
        "window_size" => window_size,
        "cluster_id"  => string(cluster_id),
        "indices"     => sort(copy(current.si))
      ))
    end

    for (child_id, child_cluster) in current.cc
      push!(stack, (window_size + 1, child_id, child_cluster))
    end
  end

  return result
end

# ---------------------------
# helpers
# ---------------------------
function add_updated_id!(target::Dict{Int,Set{Int}}, window_size::Int, cluster_id::Int)
  s = get!(target, window_size, Set{Int}())
  push!(s, cluster_id)
  return nothing
end

function euclidean_distance(a::AbstractVector{<:Real}, b::AbstractVector{<:Real})::Float64
  s = 0.0
  @inbounds for i in 1:length(a)
    d = float(a[i]) - float(b[i])
    s += d * d
  end
  return sqrt(s)
end

# deep copy for sets (rollback snapshot)
function deep_dup_sets(d::Dict{Int,Set{Int}})
  Dict(k => Set(v) for (k, v) in d)
end

# ---------------------------
# rollback journal
# ---------------------------
function start_transaction!(mgr::TimeSeriesClusterManager)
  mgr.recording_mode = true
  mgr.journal = Any[]
  mgr.snapshot_state = (
    tasks = deepcopy(mgr.tasks),
    cluster_id_counter = mgr.cluster_id_counter,
    updated_dist_ids = deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_distance),
    updated_quant_ids = deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_quantities),
  )
end

function reset_updated_ids_for_simulation!(mgr::TimeSeriesClusterManager)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
end

function record_action!(mgr::TimeSeriesClusterManager, type::Symbol, target=nothing, key=nothing, old_value=nothing)
  mgr.recording_mode || return
  push!(mgr.journal, (type=type, target=target, key=key, old_value=old_value))
end

function rollback!(mgr::TimeSeriesClusterManager)
  # reverse journal actions
  for entry in reverse(mgr.journal)
    t = entry.type
    if t == :data_push
      pop!(mgr.data)
    elseif t == :si_push
      pop!(entry.target.si)
    elseif t == :as_update
      entry.target.as = entry.old_value
    elseif t == :cc_add
      delete!(entry.target, entry.key)
    elseif t == :root_add
      delete!(mgr.clusters, entry.key)
    elseif t == :cache_write || t == :hash_set_key
      if entry.old_value === nothing
        delete!(entry.target, entry.key)
      else
        entry.target[entry.key] = entry.old_value
      end
    end
  end

  if mgr.snapshot_state !== nothing
    mgr.tasks = mgr.snapshot_state.tasks
    mgr.cluster_id_counter = mgr.snapshot_state.cluster_id_counter
    mgr.updated_cluster_ids_per_window_for_calculate_distance = mgr.snapshot_state.updated_dist_ids
    mgr.updated_cluster_ids_per_window_for_calculate_quantities = mgr.snapshot_state.updated_quant_ids
  end

  mgr.recording_mode = false
  mgr.journal = Any[]
  mgr.snapshot_state = nothing
end

# ---------------------------
# incremental clustering core
# ---------------------------
function clustering_subsequences_incremental!(mgr::TimeSeriesClusterManager, data_index::Int)
  # mean calc uses current data up to data_index inclusive (0-based)
  prefix = mgr.data[1:(data_index+1)]
  data_mean = mean_value(prefix)

  # NOTE:
  # 以前はここで max_distance_between_lower_and_upper を
  # (data_index+1) の長さで作っていましたが、
  # クラスタ判定では「new_length」「min_window_size」など
  # 部分列長ごとに正規化すべきです。
  #
  # したがって、ここでは max_distance を固定計算せず、
  # 各 window_size(new_length) ごとに max_distance_for_length を使います。

  current_tasks = deepcopy(mgr.tasks)
  empty!(mgr.tasks)

  # extend tasks (length >= min_window_size)
  for task in current_tasks
    keys_to_parent = deepcopy(task[1])
    length0 = task[2]
    parent = dig_cluster_by_keys(mgr.clusters, keys_to_parent)
    parent === nothing && continue

    new_length = length0 + 1
    latest_start = data_index - new_length + 1
    latest_seq = Float64.(mgr.data[(latest_start+1):(latest_start+new_length)])

    valid_si = [s for s in parent.si if (s + new_length <= data_index + 1) && (s != latest_start)]
    isempty(valid_si) && continue

    # ★new_lengthに合わせた scale を使う
    max_distance = max_distance_for_length(mgr, new_length)

    if !isempty(parent.cc)
      process_existing_clusters!(mgr, parent, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    else
      process_new_clusters!(mgr, parent, valid_si, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    end
  end

  # update root clusters (window=min_window_size)
  root_max_distance = max_distance_for_length(mgr, mgr.min_window_size)
  process_root_clusters!(mgr, data_index, root_max_distance)
end

function process_existing_clusters!(
  mgr::TimeSeriesClusterManager,
  parent::ClusterNode,
  latest_seq::Vector{Float64},
  max_distance::Float64,
  latest_start::Int,
  new_length::Int,
  keys_to_parent::Vector{Int}
)
  best_cluster_id = nothing
  best_child = nothing
  min_distance = Inf

  for (cluster_id, child) in parent.cc
    # compare by representative sequence
    distance = euclidean_distance(child.as, latest_seq)
    if distance < min_distance || (distance == min_distance && (best_cluster_id === nothing || cluster_id < best_cluster_id))
      min_distance = distance
      best_cluster_id = cluster_id
      best_child = child
    end
  end

  ratio = max_distance == 0.0 ? 0.0 : (min_distance / max_distance)

  if best_child !== nothing && ratio <= mgr.merge_threshold_ratio
    if !(latest_start in best_child.si)
      push!(best_child.si, latest_start)
      record_action!(mgr, :si_push, best_child)

      old_as = copy(best_child.as)
      starts = best_child.si
      sequences = [mgr.data[(s+1):(s+new_length)] for s in starts]
      best_child.as = average_sequences(sequences)
      record_action!(mgr, :as_update, best_child, nothing, old_as)

      add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_quantities, new_length, best_cluster_id)
      if mgr.calculate_distance_when_added_subsequence_to_cluster
        add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, best_cluster_id)
      end
    end

    push!(mgr.tasks, (vcat(copy(keys_to_parent), [best_cluster_id]), new_length))
  else
    # create new child cluster
    new_cluster = ClusterNode([latest_start], Dict{Int,ClusterNode}(), copy(latest_seq))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record_action!(mgr, :cc_add, parent.cc, mgr.cluster_id_counter)

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end
end

function process_new_clusters!(
  mgr::TimeSeriesClusterManager,
  parent::ClusterNode,
  valid_si::Vector{Int},
  latest_seq::Vector{Float64},
  max_distance::Float64,
  latest_start::Int,
  new_length::Int,
  keys_to_parent::Vector{Int}
)
  valid_group = Int[]
  invalid_group = Int[]

  for s in valid_si
    seq = Float64.(mgr.data[(s+1):(s+new_length)])
    distance = euclidean_distance(seq, latest_seq)
    ratio = max_distance == 0.0 ? 0.0 : (distance / max_distance)
    if ratio <= mgr.merge_threshold_ratio
      push!(valid_group, s)
    else
      push!(invalid_group, s)
    end
  end

  # --- 1) valid_group があるならまとめてクラスタ化（task も入れる） ---
  if !isempty(valid_group)
    starts = vcat(valid_group, [latest_start])
    sequences = [mgr.data[(s+1):(s+new_length)] for s in starts]
    new_cluster = ClusterNode(starts, Dict{Int,ClusterNode}(), average_sequences(sequences))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record_action!(mgr, :cc_add, parent.cc, mgr.cluster_id_counter)

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    push!(mgr.tasks, (vcat(copy(keys_to_parent), [mgr.cluster_id_counter]), new_length))
    mgr.cluster_id_counter += 1

  # --- 2) valid_group が無いなら latest_start を単独クラスタ化 ---
  else
    new_cluster = ClusterNode([latest_start], Dict{Int,ClusterNode}(), copy(latest_seq))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record_action!(mgr, :cc_add, parent.cc, mgr.cluster_id_counter)

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end

  # --- 3) ここが重要：invalid_group を全部 “待ち受けクラスタ” として追加する ---
  for s in invalid_group
    seq = Float64.(mgr.data[(s+1):(s+new_length)])
    new_cluster = ClusterNode([s], Dict{Int,ClusterNode}(), seq)
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record_action!(mgr, :cc_add, parent.cc, mgr.cluster_id_counter)

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end
end

function process_root_clusters!(mgr::TimeSeriesClusterManager, data_index::Int, max_distance::Float64)
  latest_start = data_index - 1
  if latest_start < 0
    return
  end
  latest_seq = Float64.(mgr.data[(latest_start+1):(latest_start+mgr.min_window_size)])

  best_cluster_id = nothing
  best_cluster = nothing
  min_distance = Inf

  for (cluster_id, cluster) in mgr.clusters
    if latest_start in cluster.si
      continue
    end

    compare_seq = cluster.as
    distance = euclidean_distance(compare_seq, latest_seq)
    if distance < min_distance || (distance == min_distance && (best_cluster_id === nothing || cluster_id < best_cluster_id))
      min_distance = distance
      best_cluster = cluster
      best_cluster_id = cluster_id
    end
  end

  ratio = max_distance == 0.0 ? 0.0 : (min_distance / max_distance)

  if best_cluster !== nothing && ratio <= mgr.merge_threshold_ratio
    if !(latest_start in best_cluster.si)
      push!(best_cluster.si, latest_start)
      record_action!(mgr, :si_push, best_cluster)

      old_as = copy(best_cluster.as)
      starts = best_cluster.si
      sequences = [mgr.data[(s+1):(s+mgr.min_window_size)] for s in starts]
      best_cluster.as = average_sequences(sequences)
      record_action!(mgr, :as_update, best_cluster, nothing, old_as)

      add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_quantities, mgr.min_window_size, best_cluster_id)
      if mgr.calculate_distance_when_added_subsequence_to_cluster
        add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, mgr.min_window_size, best_cluster_id)
      end
    end
    push!(mgr.tasks, ([best_cluster_id], mgr.min_window_size))
  else
    new_cluster = ClusterNode([latest_start], Dict{Int,ClusterNode}(), Float64.(mgr.data[(latest_start+1):(latest_start+mgr.min_window_size)]))
    mgr.clusters[mgr.cluster_id_counter] = new_cluster
    record_action!(mgr, :root_add, nothing, mgr.cluster_id_counter)

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, mgr.min_window_size, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end
end

function average_sequences(sequences::Vector{<:AbstractVector{<:Real}})
  if length(sequences) == 1
    return Float64.(sequences[1])
  end
  len = length(sequences[1])
  acc = fill(0.0, len)
  for seq in sequences
    @inbounds for i in 1:len
      acc[i] += float(seq[i])
    end
  end
  @inbounds for i in 1:len
    acc[i] /= float(length(sequences))
  end
  return acc
end

function dig_cluster_by_keys(clusters::Dict{Int,ClusterNode}, keys::Vector{Int})
  current = clusters
  node = nothing
  for (idx, key) in enumerate(keys)
    haskey(current, key) || return nothing
    node = current[key]
    if idx < length(keys)
      current = node.cc
    end
  end
  return node
end

# ---------------------------
# JSON export
# ---------------------------
function cluster_to_dict(node::ClusterNode)
  Dict(
    "si" => sort(copy(node.si)),
    "as" => node.as,
    "cc" => Dict(string(cid) => cluster_to_dict(child) for (cid, child) in node.cc)
  )
end

function clusters_to_dict(clusters::Dict{Int,ClusterNode})
  Dict(string(cid) => cluster_to_dict(cl) for (cid, cl) in clusters)
end
