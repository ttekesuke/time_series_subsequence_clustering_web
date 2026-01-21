# ------------------------------------------------------------
# polyphonic_cluster_manager.jl
#   Port of Rails `PolyphonicClusterManager` (f2da)
#
# This manager performs incremental subsequence clustering for polyphonic
# (set-like) data points.
#
# Rails reference:
#   app/models/polyphonic_cluster_manager.rb
#   app/models/time_series_cluster_manager.rb
#
# Performance policy:
# - Avoid `Any` for the hot path and rollback journal.
# - Only JSON-facing helper outputs use `Any` (Dict for Genie/JSON).
# ------------------------------------------------------------

module PolyphonicClusterManager

using ..PolyphonicConfig

# Types

"""A single polyphonic value (a set). Order is irrelevant."""
const PolySet = Vector{Float64}

"""A subsequence (length == window_size)."""
const PolySeq = Vector{PolySet}

"""Cluster node."""
mutable struct PolyClusterNode
  si::Vector{Int}                     # start indices (0-based)
  cc::Dict{Int,PolyClusterNode}       # child clusters
  as::PolySeq                         # representative sequence
end

"""Rollback snapshot (typed)."""
struct PolySnapshot
  tasks::Vector{Tuple{Vector{Int},Int}}
  cluster_id_counter::Int
  updated_dist_ids::Dict{Int,Set{Int}}
  updated_quant_ids::Dict{Int,Set{Int}}
end

abstract type PolyJournalEntry end

struct PJDataPush <: PolyJournalEntry end

struct PJSiPush <: PolyJournalEntry
  node::PolyClusterNode
end

struct PJAsUpdate <: PolyJournalEntry
  node::PolyClusterNode
  old_as::PolySeq
end

struct PJCcAdd <: PolyJournalEntry
  parent_cc::Dict{Int,PolyClusterNode}
  key::Int
end

struct PJRootAdd <: PolyJournalEntry
  key::Int
end

struct PJHashSetKeyDist <: PolyJournalEntry
  window_size::Int
  old_value::Union{Nothing,Dict{Tuple{Int,Int},Float64}}
end

struct PJHashSetKeyQty <: PolyJournalEntry
  window_size::Int
  old_value::Union{Nothing,Dict{Int,Float64}}
end

struct PJHashSetKeyComp <: PolyJournalEntry
  window_size::Int
  old_value::Union{Nothing,Dict{Int,Float64}}
end

struct PJCacheWriteDist <: PolyJournalEntry
  cache::Dict{Tuple{Int,Int},Float64}
  key::Tuple{Int,Int}
  old_value::Union{Nothing,Float64}
end

struct PJCacheWriteQty <: PolyJournalEntry
  cache::Dict{Int,Float64}
  key::Int
  old_value::Union{Nothing,Float64}
end

struct PJCacheWriteComp <: PolyJournalEntry
  cache::Dict{Int,Float64}
  key::Int
  old_value::Union{Nothing,Float64}
end

"""Main manager."""
mutable struct Manager
  data::Vector{PolySet}
  merge_threshold_ratio::Float64
  min_window_size::Int
  calculate_distance_when_added_subsequence_to_cluster::Bool

  value_min::Float64
  value_max::Float64
  value_width::Float64
  max_set_size::Int

  clusters::Dict{Int,PolyClusterNode}
  cluster_id_counter::Int
  tasks::Vector{Tuple{Vector{Int},Int}}

  updated_cluster_ids_per_window_for_calculate_distance::Dict{Int,Set{Int}}
  updated_cluster_ids_per_window_for_calculate_quantities::Dict{Int,Set{Int}}

  cluster_distance_cache::Dict{Int,Dict{Tuple{Int,Int},Float64}}
  cluster_quantity_cache::Dict{Int,Dict{Int,Float64}}
  cluster_complexity_cache::Dict{Int,Dict{Int,Float64}}

  recording_mode::Bool
  journal::Vector{PolyJournalEntry}
  snapshot_state::Union{Nothing,PolySnapshot}
end

# Constructors

"""Deep-copy a PolySeq."""
deep_copy_seq(seq::PolySeq)::PolySeq = [copy(s) for s in seq]

"""Ensure a PolySet is non-nil and compact."""
normalize_set(x::PolySet)::PolySet = x

"""Create manager. `data` must be Vector{Vector{Float64}}."""
function Manager(
  data::Vector{PolySet},
  merge_threshold_ratio::Real,
  min_window_size::Int;
  value_min::Real = 0.0,
  value_max::Real = 1.0,
  max_set_size::Int = last(PolyphonicConfig.CHORD_SIZE_RANGE),
)
  mtr = float(merge_threshold_ratio)

  vmin = float(value_min)
  vmax = float(value_max)
  vwidth = abs(vmax - vmin)
  if vwidth <= 0.0
    vwidth = 1.0
  end

  mss = Int(max_set_size)
  if mss <= 0
    mss = 1
  end

  # seed representative = first subsequence (Ruby fix)
  seed_as =
    if length(data) >= min_window_size
      deep_copy_seq(data[1:min_window_size])
    else
      [Float64[] for _ in 1:min_window_size]
    end

  clusters = Dict{Int,PolyClusterNode}(0 => PolyClusterNode([0], Dict{Int,PolyClusterNode}(), seed_as))

  updated_dist = Dict{Int,Set{Int}}(min_window_size => Set([0]))
  updated_qty  = Dict{Int,Set{Int}}(min_window_size => Set([0]))

  dist_cache = Dict{Int,Dict{Tuple{Int,Int},Float64}}(min_window_size => Dict{Tuple{Int,Int},Float64}())
  qty_cache  = Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}())
  comp_cache = Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}())

  return Manager(
    data,
    mtr,
    min_window_size,
    false, # calculate_distance_when_added_subsequence_to_cluster (Polyphonic == false)
    vmin,
    vmax,
    vwidth,
    mss,
    clusters,
    1,
    Tuple{Vector{Int},Int}[],
    updated_dist,
    updated_qty,
    dist_cache,
    qty_cache,
    comp_cache,
    false,
    PolyJournalEntry[],
    nothing
  )
end

# Distance functions (Rails 1:1)

"""Clamp to [0,1]."""
clamp01(x::Float64)::Float64 = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)

"""min_avg_distance(a,b)

Rails:
  - scalar/array both supported; Julia version uses PolySet everywhere.
  - if one is empty and the other isn't => 1.0
  - pitch distance uses symmetric min-average
  - pitch normalized by value_width
  - count normalized by max_set_size
"""
function min_avg_distance(mgr::Manager, a::PolySet, b::PolySet)::Float64
  isempty(a) && isempty(b) && return 0.0
  (isempty(a) || isempty(b)) && return 1.0

  # a_avg = avg_x min_y |x-y|
  a_sum = 0.0
  for x in a
    best = Inf
    for y in b
      d = abs(x - y)
      best = d < best ? d : best
    end
    a_sum += best
  end
  a_avg = a_sum / float(length(a))

  # b_avg = avg_y min_x |y-x|
  b_sum = 0.0
  for y in b
    best = Inf
    for x in a
      d = abs(y - x)
      best = d < best ? d : best
    end
    b_sum += best
  end
  b_avg = b_sum / float(length(b))

  pitch_dist = (a_avg + b_avg) / 2.0
  pitch_norm = clamp01(pitch_dist / mgr.value_width)

  count_dist = abs(length(a) - length(b))
  count_norm = clamp01(float(count_dist) / float(mgr.max_set_size))

  if count_norm <= 0.0
    return pitch_norm
  else
    return (pitch_norm + count_norm) / 2.0
  end
end

"""Per-step distance used for cluster-internal complexity."""
step_distance(mgr::Manager, a::PolySet, b::PolySet)::Float64 = min_avg_distance(mgr, a, b)

"""Squared Euclidean distance between two sequences.

Rails:
  sum_i (min_avg_distance(setA_i, setB_i)^2)
"""
function squared_euclidean_distance(mgr::Manager, seq_a::PolySeq, seq_b::PolySeq)::Float64
  len = min(length(seq_a), length(seq_b))
  s = 0.0
  @inbounds for i in 1:len
    d = min_avg_distance(mgr, seq_a[i], seq_b[i])
    s += d * d
  end
  return s
end

"""Euclidean distance between two sequences."""
euclidean_distance(mgr::Manager, seq_a::PolySeq, seq_b::PolySeq)::Float64 = sqrt(squared_euclidean_distance(mgr, seq_a, seq_b))

# Representative sequence

"""average_sequences(sequences)

Rails semantics:
  - If all sets at timestep t have the same count, sort each and average by index.
  - Otherwise pick the latest (sequences[end][t]).
"""
function average_sequences(mgr::Manager, sequences::Vector{PolySeq})::PolySeq
  length(sequences) == 1 && return deep_copy_seq(sequences[1])

  len = length(sequences[1])
  # Assume consistent lengths as Rails does.
  result = PolySeq(undef, len)

  for t in 1:len
    # collect sets at t
    sets_at_t = PolySet[]
    for seq in sequences
      push!(sets_at_t, seq[t])
    end

    first_count = length(sets_at_t[1])
    all_same = true
    for s in sets_at_t
      if length(s) != first_count
        all_same = false
        break
      end
    end

    if all_same
      # average index-wise on sorted sets
      sorted_sets = [sort(copy(s)) for s in sets_at_t]
      avg_set = zeros(Float64, first_count)
      for s in sorted_sets
        @inbounds for i in 1:first_count
          avg_set[i] += s[i]
        end
      end
      @inbounds for i in 1:first_count
        avg_set[i] /= float(length(sorted_sets))
      end
      result[t] = avg_set
    else
      # latest representative
      result[t] = copy(sequences[end][t])
    end
  end

  return result
end

# Vector mean & max-distance estimation (polyphonic override)

"""Simple squared euclidean between two sets treated as vectors.

Rails:
  - compare first min(lenA,lenB) elements by squared diff
  - plus length difference penalty: |lenA-lenB| * value_width^2
"""
function simple_squared_euclidean(mgr::Manager, vec_a::PolySet, vec_b::PolySet)::Float64
  isempty(vec_a) && isempty(vec_b) && return 0.0

  len = min(length(vec_a), length(vec_b))
  s = 0.0
  @inbounds for i in 1:len
    d = vec_a[i] - vec_b[i]
    s += d * d
  end

  s += float(abs(length(vec_a) - length(vec_b))) * (mgr.value_width^2)
  return s
end

"""Mean vector with ragged lengths.

Rails:
  - max_dim = max length
  - per-index mean ignoring missing dims
"""
function calculate_vector_mean(vectors::Vector{PolySet})::PolySet
  length(vectors) <= 1 && return copy(vectors[1])

  max_dim = 1
  for v in vectors
    max_dim = max(max_dim, length(v))
  end
  max_dim = max_dim <= 0 ? 1 : max_dim

  sums = zeros(Float64, max_dim)
  cnts = zeros(Int, max_dim)

  for v in vectors
    @inbounds for (i, val) in enumerate(v)
      sums[i] += val
      cnts[i] += 1
    end
  end

  out = zeros(Float64, max_dim)
  @inbounds for i in 1:max_dim
    c = cnts[i]
    out[i] = c > 0 ? (sums[i] / float(c)) : 0.0
  end
  return out
end

# Public APIs

function process_data!(mgr::Manager)
  for i in 1:length(mgr.data)
    data_index = i - 1
    if data_index <= mgr.min_window_size - 1
      continue
    end
    clustering_subsequences_incremental!(mgr, data_index)
  end
end

function add_data_point_permanently!(mgr::Manager, val::PolySet)
  push!(mgr.data, val)
  clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
end

"""Update caches after permanent append.

Identical to scalar TimeSeriesClusterManager, but uses polyphonic distances.
"""
function update_caches_permanently!(mgr::Manager, quadratic_integer_array::Vector{Int})
  # Avoid Dict{String,Any} transforms: traverse typed nodes and update caches.
  clusters_each = Dict{Int,Dict{Int,PolyClusterNode}}()
  stack = Vector{Tuple{Int,Int,PolyClusterNode}}()
  sizehint!(stack, length(mgr.clusters))
  for (cid, cl) in mgr.clusters
    push!(stack, (mgr.min_window_size, cid, cl))
  end

  while !isempty(stack)
    (window_size, cluster_id, node) = pop!(stack)
    same_ws = get!(clusters_each, window_size, Dict{Int,PolyClusterNode}())
    same_ws[cluster_id] = node
    for (child_id, child) in node.cc
      push!(stack, (window_size + 1, child_id, child))
    end
  end

  for (window_size, same_ws) in clusters_each
    all_ids = collect(keys(same_ws))

    cache = get!(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    for i in 1:length(all_ids)
      cid1 = all_ids[i]
      node1 = same_ws[cid1]
      for j in (i+1):length(all_ids)
        cid2 = all_ids[j]
        node2 = same_ws[cid2]
        key = cid1 < cid2 ? (cid1, cid2) : (cid2, cid1)
        cache[key] = euclidean_distance(mgr, node1.as, node2.as)
      end
    end

    q_cache = get!(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get!(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())

    for (cid, node) in same_ws
      length(node.si) <= 1 && continue

      q = 1.0
      @inbounds for s in node.si
        idx = s + 1
        if 1 <= idx <= length(quadratic_integer_array)
          q *= quadratic_integer_array[idx]
        end
      end
      q_cache[cid] = q
      c_cache[cid] = calculate_cluster_complexity(mgr, node)
    end
  end

  # reset updated ids (Rails behavior)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
end

# Cluster complexity

# Typed overloads used in the hot path (avoid Dict{String,Any} allocations)
@inline function calculate_cluster_complexity(mgr::Manager, seq::PolySeq)::Float64
  length(seq) < 2 && return 0.0
  total = 0.0
  @inbounds for i in 1:(length(seq)-1)
    total += step_distance(mgr, seq[i], seq[i+1])
  end
  return total / float(length(seq)-1)
end

@inline calculate_cluster_complexity(mgr::Manager, node::PolyClusterNode)::Float64 = calculate_cluster_complexity(mgr, node.as)

# JSON-facing overload (kept for Rails-compatible Dict payloads)
function calculate_cluster_complexity(mgr::Manager, cluster::Dict{String,Any})::Float64
  seq = cluster["as"]
  if !(seq isa AbstractVector)
    return 0.0
  end
  if length(seq) < 2
    return 0.0
  end
  total = 0.0
  for i in 1:(length(seq)-1)
    total += step_distance(mgr, seq[i], seq[i+1])
  end
  return total / float(length(seq)-1)
end

# Transform helpers for JSON

function transform_clusters(clusters::Dict{Int,PolyClusterNode}, min_window_size::Int)
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

function clusters_to_timeline(clusters::Dict{Int,PolyClusterNode}, min_window_size::Int)
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

# Internal helpers

function add_updated_id!(target::Dict{Int,Set{Int}}, window_size::Int, cluster_id::Int)
  s = get!(target, window_size, Set{Int}())
  push!(s, cluster_id)
  return nothing
end

function deep_dup_sets(d::Dict{Int,Set{Int}})
  Dict(k => Set(v) for (k, v) in d)
end

function dig_cluster_by_keys(clusters::Dict{Int,PolyClusterNode}, keys::Vector{Int})::Union{Nothing,PolyClusterNode}
  isempty(keys) && return nothing
  current_dict = clusters
  current_node::Union{Nothing,PolyClusterNode} = nothing
  for key in keys
    node = get(current_dict, key, nothing)
    node === nothing && return nothing
    current_node = node
    current_dict = node.cc
  end
  return current_node
end

# Rollback journal

function start_transaction!(mgr::Manager)
  mgr.recording_mode = true
  empty!(mgr.journal)

  # Rails uses shallow dup. We copy only the key vectors to keep rollback safe
  # without the overhead of a full deepcopy on every simulation.
  snapshot_tasks = Tuple{Vector{Int},Int}[(copy(t[1]), t[2]) for t in mgr.tasks]

  mgr.snapshot_state = PolySnapshot(
    snapshot_tasks,
    mgr.cluster_id_counter,
    deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_distance),
    deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_quantities),
  )
end

function reset_updated_ids_for_simulation!(mgr::Manager)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
end

record!(mgr::Manager, entry::PolyJournalEntry) = (mgr.recording_mode ? push!(mgr.journal, entry) : nothing)

function rollback!(mgr::Manager)
  for entry in reverse(mgr.journal)
    if entry isa PJDataPush
      pop!(mgr.data)

    elseif entry isa PJSiPush
      pop!(entry.node.si)

    elseif entry isa PJAsUpdate
      entry.node.as = entry.old_as

    elseif entry isa PJCcAdd
      delete!(entry.parent_cc, entry.key)

    elseif entry isa PJRootAdd
      delete!(mgr.clusters, entry.key)

    elseif entry isa PJHashSetKeyDist
      if entry.old_value === nothing
        delete!(mgr.cluster_distance_cache, entry.window_size)
      else
        mgr.cluster_distance_cache[entry.window_size] = entry.old_value
      end

    elseif entry isa PJHashSetKeyQty
      if entry.old_value === nothing
        delete!(mgr.cluster_quantity_cache, entry.window_size)
      else
        mgr.cluster_quantity_cache[entry.window_size] = entry.old_value
      end

    elseif entry isa PJHashSetKeyComp
      if entry.old_value === nothing
        delete!(mgr.cluster_complexity_cache, entry.window_size)
      else
        mgr.cluster_complexity_cache[entry.window_size] = entry.old_value
      end

    elseif entry isa PJCacheWriteDist
      if entry.old_value === nothing
        delete!(entry.cache, entry.key)
      else
        entry.cache[entry.key] = entry.old_value
      end

    elseif entry isa PJCacheWriteQty
      if entry.old_value === nothing
        delete!(entry.cache, entry.key)
      else
        entry.cache[entry.key] = entry.old_value
      end

    elseif entry isa PJCacheWriteComp
      if entry.old_value === nothing
        delete!(entry.cache, entry.key)
      else
        entry.cache[entry.key] = entry.old_value
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
  empty!(mgr.journal)
  mgr.snapshot_state = nothing
end

# Simulation with rollback

function simulate_add_and_calculate(mgr::Manager, candidate::PolySet, quadratic_integer_array::Vector{Int})
  start_transaction!(mgr)
  reset_updated_ids_for_simulation!(mgr)

  # NOTE: This function is on the hottest path (called for every candidate).
  # Avoid JSON-facing transforms (Dict{String,Any}) here; we traverse typed nodes directly.

  # Collect clusters by window size (typed)
  @inline function _collect_clusters_each()
    clusters_each = Dict{Int,Dict{Int,PolyClusterNode}}()
    stack = Vector{Tuple{Int,Int,PolyClusterNode}}()
    sizehint!(stack, length(mgr.clusters))
    for (cid, cl) in mgr.clusters
      push!(stack, (mgr.min_window_size, cid, cl))
    end

    while !isempty(stack)
      (depth, cluster_id, node) = pop!(stack)
      same_ws = get!(clusters_each, depth, Dict{Int,PolyClusterNode}())
      same_ws[cluster_id] = node
      for (child_id, child_cluster) in node.cc
        push!(stack, (depth + 1, child_id, child_cluster))
      end
    end
    return clusters_each
  end

  try
    push!(mgr.data, candidate)
    record!(mgr, PJDataPush())

    clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
    clusters_each = _collect_clusters_each()

    sum_distances = 0.0
    sum_quantities = 0.0
    sum_complexities = 0.0

    for (window_size, same_ws) in clusters_each
      all_ids = collect(keys(same_ws))
      updated_ids = collect(get(mgr.updated_cluster_ids_per_window_for_calculate_distance, window_size, Set{Int}()))

      cache_old = get(mgr.cluster_distance_cache, window_size, nothing)
      cache = get!(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
      if cache_old === nothing
        record!(mgr, PJHashSetKeyDist(window_size, nothing))
      end

      # Distances cache (only for updated clusters)
      for cid1 in updated_ids
        node1 = get(same_ws, cid1, nothing)
        node1 === nothing && continue
        @inbounds for cid2 in all_ids
          cid1 == cid2 && continue
          key = cid1 < cid2 ? (cid1, cid2) : (cid2, cid1)
          node2 = same_ws[cid2]
          dist = euclidean_distance(mgr, node1.as, node2.as)
          old_val = haskey(cache, key) ? cache[key] : nothing
          cache[key] = dist
          record!(mgr, PJCacheWriteDist(cache, key, old_val))
        end
      end

      if !isempty(cache)
        sum_distances += (sum(values(cache)) / float(window_size))
      end

      updated_quant_ids = collect(get(mgr.updated_cluster_ids_per_window_for_calculate_quantities, window_size, Set{Int}()))

      q_old = get(mgr.cluster_quantity_cache, window_size, nothing)
      q_cache = get!(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
      if q_old === nothing
        record!(mgr, PJHashSetKeyQty(window_size, nothing))
      end

      c_old = get(mgr.cluster_complexity_cache, window_size, nothing)
      c_cache = get!(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())
      if c_old === nothing
        record!(mgr, PJHashSetKeyComp(window_size, nothing))
      end

      # Quantity / complexity cache (only for updated clusters)
      for cid in updated_quant_ids
        node = get(same_ws, cid, nothing)
        node === nothing && continue
        length(node.si) > 1 || continue

        q = 1.0
        @inbounds for s in node.si
          idx = s + 1
          if 1 <= idx <= length(quadratic_integer_array)
            q *= quadratic_integer_array[idx]
          end
        end

        old_q = haskey(q_cache, cid) ? q_cache[cid] : nothing
        q_cache[cid] = q
        record!(mgr, PJCacheWriteQty(q_cache, cid, old_q))

        comp = calculate_cluster_complexity(mgr, node)
        old_c = haskey(c_cache, cid) ? c_cache[cid] : nothing
        c_cache[cid] = comp
        record!(mgr, PJCacheWriteComp(c_cache, cid, old_c))
      end

      if !isempty(q_cache)
        sum_quantities += sum(values(q_cache))
      end
      if !isempty(c_cache)
        sum_complexities += sum(values(c_cache))
      end
    end

    return (sum_distances, sum_quantities, sum_complexities)
  finally
    rollback!(mgr)
  end
end

# Incremental clustering core (polyphonic override)

function clustering_subsequences_incremental!(mgr::Manager, data_index::Int)
  current_slice = mgr.data[1:(data_index+1)]
  centroid = calculate_vector_mean(current_slice)

  max_dist_sq = 0.0
  for point in current_slice
    d2 = simple_squared_euclidean(mgr, point, centroid)
    max_dist_sq = d2 > max_dist_sq ? d2 : max_dist_sq
  end

  max_distance = sqrt(max_dist_sq) * 2.0

  current_tasks = copy(mgr.tasks)
  empty!(mgr.tasks)

  for task in current_tasks
    keys_to_parent = copy(task[1])
    length0 = task[2]
    parent = dig_cluster_by_keys(mgr.clusters, keys_to_parent)
    parent === nothing && continue

    new_length = length0 + 1
    latest_start = data_index - new_length + 1
    latest_start < 0 && continue

    latest_seq = mgr.data[(latest_start+1):(latest_start+new_length)]
    valid_si = [s for s in parent.si if (s + new_length <= data_index + 1) && (s != latest_start)]
    isempty(valid_si) && continue

    if !isempty(parent.cc)
      process_existing_clusters!(mgr, parent, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    else
      process_new_clusters!(mgr, parent, valid_si, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    end
  end

  process_root_clusters!(mgr, data_index, max_distance)
end

function process_existing_clusters!(
  mgr::Manager,
  parent::PolyClusterNode,
  latest_seq::PolySeq,
  max_distance::Float64,
  latest_start::Int,
  new_length::Int,
  keys_to_parent::Vector{Int}
)
  best_cluster_id = -1
  best_child::Union{Nothing,PolyClusterNode} = nothing
  min_distance = Inf

  for (cluster_id, child) in parent.cc
    # prefer representative sequence (as)
    distance = euclidean_distance(mgr, child.as, latest_seq)

    if distance < min_distance || (distance == min_distance && (best_cluster_id < 0 || cluster_id < best_cluster_id))
      min_distance = distance
      best_child = child
      best_cluster_id = cluster_id
    end
  end

  ratio = max_distance == 0.0 ? 0.0 : (min_distance / max_distance)

  if best_child !== nothing && ratio <= mgr.merge_threshold_ratio
    push!(best_child.si, latest_start)
    record!(mgr, PJSiPush(best_child))

    old_as = deep_copy_seq(best_child.as)
    starts = best_child.si
    sequences = [mgr.data[(s+1):(s+new_length)] for s in starts]
    best_child.as = average_sequences(mgr, sequences)
    record!(mgr, PJAsUpdate(best_child, old_as))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_quantities, new_length, best_cluster_id)
    if mgr.calculate_distance_when_added_subsequence_to_cluster
      add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, best_cluster_id)
    end

    push!(mgr.tasks, (vcat(copy(keys_to_parent), [best_cluster_id]), new_length))
  else
    new_cluster = PolyClusterNode([latest_start], Dict{Int,PolyClusterNode}(), deep_copy_seq(latest_seq))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJCcAdd(parent.cc, mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end
end

function process_new_clusters!(
  mgr::Manager,
  parent::PolyClusterNode,
  valid_si::Vector{Int},
  latest_seq::PolySeq,
  max_distance::Float64,
  latest_start::Int,
  new_length::Int,
  keys_to_parent::Vector{Int}
)
  valid_group = Int[]
  invalid_group = Int[]

  for s in valid_si
    seq = mgr.data[(s+1):(s+new_length)]
    distance = euclidean_distance(mgr, seq, latest_seq)
    ratio = max_distance == 0.0 ? 0.0 : (distance / max_distance)
    if ratio <= mgr.merge_threshold_ratio
      push!(valid_group, s)
    else
      push!(invalid_group, s)
    end
  end

  if !isempty(valid_group)
    starts = vcat(valid_group, [latest_start])
    sequences = [mgr.data[(s+1):(s+new_length)] for s in starts]
    new_cluster = PolyClusterNode(starts, Dict{Int,PolyClusterNode}(), average_sequences(mgr, sequences))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJCcAdd(parent.cc, mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    push!(mgr.tasks, (vcat(copy(keys_to_parent), [mgr.cluster_id_counter]), new_length))
    mgr.cluster_id_counter += 1
  else
    new_cluster = PolyClusterNode([latest_start], Dict{Int,PolyClusterNode}(), deep_copy_seq(latest_seq))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJCcAdd(parent.cc, mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end

  for s in invalid_group
    seq = deep_copy_seq(mgr.data[(s+1):(s+new_length)])
    new_cluster = PolyClusterNode([s], Dict{Int,PolyClusterNode}(), seq)
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJCcAdd(parent.cc, mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end
end

function process_root_clusters!(mgr::Manager, data_index::Int, max_distance::Float64)
  latest_start = data_index - 1
  latest_start < 0 && return
  latest_seq = mgr.data[(latest_start+1):(latest_start+mgr.min_window_size)]

  best_cluster_id = -1
  best_cluster::Union{Nothing,PolyClusterNode} = nothing
  min_distance = Inf

  for (cluster_id, cluster) in mgr.clusters
    if latest_start in cluster.si
      continue
    end

    compare_seq = cluster.as
    distance = euclidean_distance(mgr, compare_seq, latest_seq)
    if distance < min_distance || (distance == min_distance && (best_cluster_id < 0 || cluster_id < best_cluster_id))
      min_distance = distance
      best_cluster = cluster
      best_cluster_id = cluster_id
    end
  end

  ratio = max_distance == 0.0 ? 0.0 : (min_distance / max_distance)

  if best_cluster !== nothing && ratio <= mgr.merge_threshold_ratio
    push!(best_cluster.si, latest_start)
    record!(mgr, PJSiPush(best_cluster))

    old_as = deep_copy_seq(best_cluster.as)
    sequences = [mgr.data[(s+1):(s+mgr.min_window_size)] for s in best_cluster.si]
    best_cluster.as = average_sequences(mgr, sequences)
    record!(mgr, PJAsUpdate(best_cluster, old_as))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_quantities, mgr.min_window_size, best_cluster_id)
    if mgr.calculate_distance_when_added_subsequence_to_cluster
      add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, mgr.min_window_size, best_cluster_id)
    end

    push!(mgr.tasks, ([best_cluster_id], mgr.min_window_size))
  else
    new_cluster = PolyClusterNode([latest_start], Dict{Int,PolyClusterNode}(), deep_copy_seq(latest_seq))
    mgr.clusters[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJRootAdd(mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, mgr.min_window_size, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end
end


# Rails-compatible wrapper APIs
#
# Rails version exposes non-bang method names and instance-style calls.
# The Julia port uses bang-suffixed functions for mutation.
# These wrappers restore Rails-like names so higher-level ports (e.g.
# MultiStreamManager / generate_polyphonic) can call stable APIs.

process_data(mgr::Manager) = process_data!(mgr)

add_data_point_permanently(mgr::Manager, val::PolySet) = add_data_point_permanently!(mgr, val)

update_caches_permanently(mgr::Manager, q_array::Vector{Int}) = update_caches_permanently!(mgr, q_array)

# Instance-style helper wrappers (argument order parity with Rails)
transform_clusters(mgr::Manager, clusters::Dict{Int,PolyClusterNode}, min_window_size::Int) =
  transform_clusters(clusters, min_window_size)

clusters_to_timeline(mgr::Manager, clusters::Dict{Int,PolyClusterNode}, min_window_size::Int) =
  clusters_to_timeline(clusters, min_window_size)

end # module
