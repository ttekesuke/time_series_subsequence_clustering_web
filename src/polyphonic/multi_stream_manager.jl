# ------------------------------------------------------------
# multi_stream_manager.jl
#   Port of Rails `MultiStreamManager` (f2da)
#
# Rails reference:
#   app/models/multi_stream_manager.rb
#
# Performance policy:
# - Avoid `Any` in core data structures.
# - Use typed containers and cost matrices.
# - `PolySet` is used for all values (including scalars as singleton sets).
#
# IMPORTANT:
# This file defines only the manager itself. The `generate_polyphonic`
# endpoint/controller glue is implemented in a later stage.
# ------------------------------------------------------------

module MultiStreamManager

using ..PolyphonicConfig
using ..PolyphonicClusterManager

# ============================================================
# Types
# ============================================================

"""Per-candidate complexity cost (0..1) per stream."""
struct PerCandidateCost
  raw_complexity::Float64
  complexity01::Float64
end

"""Precalculated costs for active streams."""
struct StreamCosts
  # Rails: { stream_id => { candidate_value => {raw_complexity, complexity01} } }
  # This port restricts keys to scalar candidate values (Float64), which is sufficient for all
  # non-note dimensions used by generate_polyphonic.
  per_stream::Dict{Int,Dict{Float64,PerCandidateCost}}
end

"""Absolute pitch set (e.g., MIDI notes)."""
const AbsPitchSet = Vector{Int}


"""Individual mapping score per stream."""
struct IndividualScore
  stream_id::Int
  dist::Float64
  complexity01::Float64
end

"""Aggregated mapping metric."""
struct MappingMetric
  individual_scores::Vector{IndividualScore}
  avg_distance01::Float64
  avg_complexity01::Float64
end

"""Stream strength entry for reporting."""
struct StreamStrengthEntry
  active::Bool
  presence_avg::Float64
  presence_count::Int
  last_value::PolyphonicClusterManager.PolySet
end

"""Stream container (equivalent to Rails StreamContainer struct)."""
mutable struct StreamContainer
  id::Int
  manager::PolyphonicClusterManager.Manager
  last_value::PolyphonicClusterManager.PolySet
  last_abs_pitch::Union{Nothing,AbsPitchSet}
  strength::Float64
  presence_sum::Float64
  presence_count::Int
  presence_avg::Float64
end

"""Lifecycle plan container."""
struct LifecyclePlan
  deactivate_ids::Vector{Int}
  revive_ids::Vector{Int}
  fork_pairs::Vector{Tuple{Int,Int}}   # (source_id, new_id)
  active_ids::Vector{Int}
end

"""Main multi-stream manager."""
mutable struct Manager
  merge_threshold_ratio::Float64
  min_window_size::Int
  use_complexity_mapping::Bool
  track_presence::Bool

  history_matrix::Vector{Vector{PolyphonicClusterManager.PolySet}}  # steps x streams

  next_stream_id::Int
  stream_pool::Vector{StreamContainer}
  containers_by_id::Dict{Int,StreamContainer}

  active_ids::Vector{Int}
  inactive_ids::Vector{Int}

  max_simultaneous_notes::Int

  value_min::Float64
  value_max::Float64
  value_width::Float64
  fixed_value_range::Bool

  pending_absolute_bases::Union{Nothing,Vector{Int}}
end

# ============================================================
# Constructors
# ============================================================

"""Normalize a scalar (Float64) into PolySet."""
@inline function to_polyset(v::Real)::PolyphonicClusterManager.PolySet
  return Float64[float(v)]
end

"""Normalize PolySet (copy to detach)."""
@inline function to_polyset(v::PolyphonicClusterManager.PolySet)::PolyphonicClusterManager.PolySet
  return copy(v)
end

"""Normalize input history matrix to a padded matrix of PolySet."""
function normalize_history_matrix(history_matrix_raw)::Vector{Vector{PolyphonicClusterManager.PolySet}}
  rows_raw = history_matrix_raw === nothing ? [] : collect(history_matrix_raw)

  max_cols = 1
  for row in rows_raw
    try
      max_cols = max(max_cols, length(row))
    catch
      # if row is not a collection, treat as single element
      max_cols = max(max_cols, 1)
    end
  end

  # detect if any element is vector-like
  has_array_value = false
  for row in rows_raw
    for v in row
      if v isa AbstractVector
        has_array_value = true
        break
      end
    end
    has_array_value && break
  end

  default_value = Float64[0.0]  # scalar also represented as singleton set

  out = Vector{Vector{PolyphonicClusterManager.PolySet}}(undef, length(rows_raw))
  for (i, row) in enumerate(rows_raw)
    rr = Vector{PolyphonicClusterManager.PolySet}(undef, max_cols)
    for j in 1:max_cols
      v = (j <= length(row)) ? row[j] : nothing
      if v === nothing
        rr[j] = copy(default_value)
      elseif v isa AbstractVector
        rr[j] = Float64[float(x) for x in v]
      else
        rr[j] = Float64[float(v)]
      end
    end
    out[i] = rr
  end

  return out
end

"""Infer numeric range from history matrix."""
function infer_value_range_from_history!(m::Manager)::Nothing
  vals = Float64[]
  for row in m.history_matrix
    for v in row
      append!(vals, v)
    end
  end

  if isempty(vals)
    m.value_min = 0.0
    m.value_max = 1.0
  else
    m.value_min = minimum(vals)
    m.value_max = maximum(vals)
  end

  m.value_width = abs(m.value_max - m.value_min)
  if m.value_width <= 0.0
    m.value_width = 1.0
  end

  return nothing
end

"""Update numeric range based on candidates (if range is not fixed)."""
function update_value_range_from_candidates!(m::Manager, candidate_values::Vector{PolyphonicClusterManager.PolySet})::Nothing
  vals = Float64[]
  for v in candidate_values
    append!(vals, v)
  end
  isempty(vals) && return nothing

  cmin = minimum(vals)
  cmax = maximum(vals)

  m.value_min = min(m.value_min, cmin)
  m.value_max = max(m.value_max, cmax)

  m.value_width = abs(m.value_max - m.value_min)
  if m.value_width <= 0.0
    m.value_width = 1.0
  end

  return nothing
end

"""Create a new PolyphonicClusterManager for a stream with given series."""
function build_stream_manager(
  series::Vector{PolyphonicClusterManager.PolySet},
  merge_threshold_ratio::Float64,
  min_window_size::Int;
  value_min::Float64,
  value_max::Float64,
  max_set_size::Int
)::PolyphonicClusterManager.Manager
  mgr = PolyphonicClusterManager.Manager(
    series,
    merge_threshold_ratio,
    min_window_size;
    value_min=value_min,
    value_max=value_max,
    max_set_size=max_set_size,
  )
  try
    PolyphonicClusterManager.process_data(mgr)
  catch
    # noop
  end
  return mgr
end

"""Build initial streams from history."""
function build_initial_streams_from_history!(m::Manager)::Nothing
  steps = length(m.history_matrix)
  stream_count = steps > 0 ? length(m.history_matrix[1]) : 1
  stream_count = max(stream_count, 1)

  for s_idx in 1:stream_count
    series = Vector{PolyphonicClusterManager.PolySet}(undef, steps)
    for t in 1:steps
      series[t] = copy(m.history_matrix[t][s_idx])
    end

    id = m.next_stream_id
    m.next_stream_id += 1

    mgr = build_stream_manager(
      series,
      m.merge_threshold_ratio,
      m.min_window_size;
      value_min=m.value_min,
      value_max=m.value_max,
      max_set_size=m.max_simultaneous_notes,
    )

    pres_sum = 0.0
    pres_cnt = 0
    pres_avg = 0.0

    if m.track_presence
      for v in series
        if length(v) == 1
          vv = clamp(v[1], 0.0, 1.0)
          pres_sum += vv
          pres_cnt += 1
        end
      end
      pres_avg = pres_cnt > 0 ? clamp(pres_sum / pres_cnt, 0.0, 1.0) : clamp(series[end][1], 0.0, 1.0)
    end

    container = StreamContainer(
      id,
      mgr,
      copy(series[end]),
      nothing,
      0.0,
      pres_sum,
      pres_cnt,
      pres_avg,
    )

    push!(m.stream_pool, container)
    m.containers_by_id[id] = container
    push!(m.active_ids, id)
  end

  return nothing
end

"""Create a new multi-stream manager."""
function Manager(
  history_matrix_raw,
  merge_threshold_ratio::Real,
  min_window_size::Int;
  use_complexity_mapping::Bool=true,
  value_range::Union{Nothing,AbstractVector{<:Real}}=nothing,
  max_set_size::Int=last(PolyphonicConfig.CHORD_SIZE_RANGE),
  track_presence::Bool=false
)::Manager
  mtr = float(merge_threshold_ratio)
  mws = Int(min_window_size)

  hm = normalize_history_matrix(history_matrix_raw)

  max_set = Int(max_set_size)
  max_set = max(max_set, 1)

  mgr = Manager(
    mtr,
    mws,
    Bool(use_complexity_mapping),
    Bool(track_presence),
    hm,
    1,
    StreamContainer[],
    Dict{Int,StreamContainer}(),
    Int[],
    Int[],
    max_set,
    0.0,
    1.0,
    1.0,
    false,
    nothing,
  )

  infer_value_range_from_history!(mgr)

  if value_range !== nothing
    vmin = float(minimum(value_range))
    vmax = float(maximum(value_range))
    width = abs(vmax - vmin)
    width = width <= 0.0 ? 1.0 : width

    mgr.value_min = vmin
    mgr.value_max = vmax
    mgr.value_width = width
    mgr.fixed_value_range = true
  else
    mgr.fixed_value_range = false
  end

  build_initial_streams_from_history!(mgr)
  return mgr
end

# ============================================================
# Active stream control
# ============================================================

"""Ensure stream ids up to max_id exist."""
function ensure_stream_id_max!(m::Manager, max_id::Int)::Nothing
  max_id <= 0 && return nothing
  while m.next_stream_id <= max_id
    add_new_stream_with_id!(m, m.next_stream_id)
    m.next_stream_id += 1
  end
  return nothing
end

"""Ensure at least n streams exist."""
function ensure_stream_count_min!(m::Manager, n::Int)::Nothing
  n = max(n, 1)
  if length(m.stream_pool) < n
    ensure_stream_id_max!(m, n)
  end
  return nothing
end

"""Create a new stream with given id (seeded)."""
function add_new_stream_with_id!(m::Manager, id::Int)::Nothing
  haskey(m.containers_by_id, id) && return nothing

  len = length(m.history_matrix)
  len = max(len, 1)

  seed = Float64[m.value_min]
  series = [copy(seed) for _ in 1:len]

  smgr = build_stream_manager(
    series,
    m.merge_threshold_ratio,
    m.min_window_size;
    value_min=m.value_min,
    value_max=m.value_max,
    max_set_size=m.max_simultaneous_notes,
  )

  container = StreamContainer(
    id,
    smgr,
    copy(seed),
    nothing,
    0.0,
    0.0,
    0,
    0.0,
  )

  push!(m.stream_pool, container)
  m.containers_by_id[id] = container

  # default active
  if !(id in m.active_ids)
    push!(m.active_ids, id)
  end

  return nothing
end

"""Revive stream ids (inactive -> active)."""
function revive_stream_ids!(m::Manager, ids::Vector{Int})::Nothing
  for id in ids
    if id in m.inactive_ids
      filter!(x -> x != id, m.inactive_ids)
      if !(id in m.active_ids)
        push!(m.active_ids, id)
      end
    end
  end
  return nothing
end

"""Deactivate stream ids (active -> inactive)."""
function deactivate_stream_ids!(m::Manager, ids::Vector{Int})::Nothing
  for id in ids
    if id in m.active_ids
      filter!(x -> x != id, m.active_ids)
      if !(id in m.inactive_ids)
        push!(m.inactive_ids, id)
      end
    end
  end
  return nothing
end

"""Fork a stream (deep-clone its manager and state)."""
function fork_stream_from_id!(m::Manager, source_id::Int, new_id::Int)::Nothing
  haskey(m.containers_by_id, new_id) && return nothing
  ensure_stream_id_max!(m, source_id)

  src = get(m.containers_by_id, source_id, nothing)
  if src === nothing
    add_new_stream_with_id!(m, new_id)
    return nothing
  end

  new_mgr = deepcopy(src.manager)

  new_container = StreamContainer(
    new_id,
    new_mgr,
    copy(src.last_value),
    src.last_abs_pitch === nothing ? nothing : copy(src.last_abs_pitch),
    0.0,
    src.presence_sum,
    src.presence_count,
    src.presence_avg,
  )

  push!(m.stream_pool, new_container)
  m.containers_by_id[new_id] = new_container

  if !(new_id in m.active_ids)
    push!(m.active_ids, new_id)
  end

  return nothing
end

"""Set active stream ids (controller can set per-step)."""
function set_active_stream_ids!(m::Manager, ids_raw)::Nothing
  ids = unique([Int(x) for x in ids_raw])
  if isempty(ids)
    if !isempty(m.active_ids)
      ids = [m.active_ids[1]]
    else
      ids = [1]
    end
  end

  ensure_stream_id_max!(m, maximum(ids))

  # revive if needed
  revive_stream_ids!(m, intersect(ids, m.inactive_ids))

  m.active_ids = ids
  return nothing
end

"""Return active stream containers matching n streams."""
function active_stream_containers(m::Manager, n::Int)::Vector{StreamContainer}
  n = max(Int(n), 1)

  if isempty(m.active_ids)
    ensure_stream_count_min!(m, n)
    m.active_ids = [c.id for c in m.stream_pool[1:min(n, length(m.stream_pool))]]
  end

  # adjust size
  if length(m.active_ids) < n
    ensure_stream_count_min!(m, n)
    extra = Int[]
    for c in m.stream_pool
      if !(c.id in m.active_ids) && !(c.id in m.inactive_ids)
        push!(extra, c.id)
      end
      length(extra) >= (n - length(m.active_ids)) && break
    end
    append!(m.active_ids, extra)
  elseif length(m.active_ids) > n
    m.active_ids = m.active_ids[1:n]
  end

  out = StreamContainer[]
  for id in m.active_ids
    c = get(m.containers_by_id, id, nothing)
    c === nothing && continue
    push!(out, c)
  end
  return out
end

"""Return inactive stream containers."""
function inactive_stream_containers(m::Manager)::Vector{StreamContainer}
  out = StreamContainer[]
  for id in m.inactive_ids
    c = get(m.containers_by_id, id, nothing)
    c === nothing && continue
    push!(out, c)
  end
  return out
end

# ============================================================
# Stream strength / presence
# ============================================================

"""Update stream strength (vol average) for track_presence=true dimension."""
function update_stream_strength!(m::Manager, stream_id::Int, volume_value::Real)::Nothing
  m.track_presence || return nothing
  container = get(m.containers_by_id, stream_id, nothing)
  container === nothing && return nothing

  vv = clamp(float(volume_value), 0.0, 1.0)
  container.presence_sum += vv
  container.presence_count += 1

  if container.presence_count > 0
    container.presence_avg = clamp(container.presence_sum / container.presence_count, 0.0, 1.0)
  else
    container.presence_avg = vv
  end

  return nothing
end

"""Get stream strength (presence_avg)."""
function get_stream_strength(m::Manager, stream_id::Int)::Float64
  container = get(m.containers_by_id, stream_id, nothing)
  container === nothing && return 0.0
  return clamp(container.presence_avg, 0.0, 1.0)
end

"""Internal: presence value for stream id (fallback if not tracking presence)."""
function presence_of_id(m::Manager, id::Int)::Float64
  c = get(m.containers_by_id, id, nothing)
  c === nothing && return 0.0
  if m.track_presence
    return clamp(c.presence_avg, 0.0, 1.0)
  else
    # fallback: use last scalar value if singleton
    return length(c.last_value) == 1 ? clamp(c.last_value[1], 0.0, 1.0) : 0.0
  end
end

"""Streams sorted by strength."""
function streams_sorted_by_strength(m::Manager; ascending::Bool=false)::Vector{StreamContainer}
  if ascending
    return sort(m.stream_pool, by=c -> c.presence_avg)
  else
    return sort(m.stream_pool, by=c -> -c.presence_avg)
  end
end

"""Generate centered target values (Rails generate_centered_targets)."""
function generate_centered_targets(n::Int, center::Real, spread::Real)::Vector{Float64}
  n = max(n, 0)
  n == 0 && return Float64[]
  if n == 1
    return Float64[clamp(float(center), 0.0, 1.0)]
  end

  c = clamp(float(center), 0.0, 1.0)
  s = clamp(float(spread), 0.0, 1.0)

  half_width = s / 2.0
  start_val = clamp(c - half_width, 0.0, 1.0)
  end_val   = clamp(c + half_width, 0.0, 1.0)

  targets = Vector{Float64}(undef, n)
  for i in 0:(n-1)
    t = float(i) / float(n - 1)
    targets[i+1] = clamp(start_val + (end_val - start_val) * t, 0.0, 1.0)
  end

  return targets
end

"""Select streams by strength target (Rails select_streams_by_strength_target)."""
function select_streams_by_strength_target(m::Manager, target::Real, count::Int; spread::Real=0.0)
  count <= 0 && return Tuple{Int,Float64}[]

  t = clamp(float(target), 0.0, 1.0)
  s = clamp(float(spread), 0.0, 1.0)

  target_values = generate_centered_targets(count, t, s)

  available = [(c.id, float(c.presence_avg)) for c in m.stream_pool]
  selected = Tuple{Int,Float64}[]

  for tv in target_values
    best_id = 0
    best_strength = 0.0
    best_dist = Inf

    for (id, strength) in available
      already = any(x -> x[1] == id, selected)
      already && continue
      d = abs(strength - tv)
      if d < best_dist
        best_dist = d
        best_id = id
        best_strength = strength
      end
    end

    if best_id != 0
      push!(selected, (best_id, best_strength))
    end
  end

  return selected
end

# ============================================================
# Lifecycle planning / applying
# ============================================================

"""Build stream lifecycle plan (Rails build_stream_lifecycle_plan)."""
function build_stream_lifecycle_plan(m::Manager, desired_count::Int; target::Real, spread::Real)
  dc = max(Int(desired_count), 1)

  current_active = [c.id for c in active_stream_containers(m, dc)]
  cur_n = length(current_active)

  t = clamp(float(target), 0.0, 1.0)
  s = clamp(float(spread), 0.0, 1.0)

  plan = LifecyclePlan(Int[], Int[], Tuple{Int,Int}[], copy(current_active))

  # decrease
  if dc < cur_n
    k = cur_n - dc
    delete_targets = generate_centered_targets(k, t, s)
    active_with_strength = [(id, presence_of_id(m, id)) for id in current_active]

    deactivate_ids = Int[]
    for tv in delete_targets
      best_id = 0
      best_dist = Inf
      for (id, strength) in active_with_strength
        (id in deactivate_ids) && continue
        d = abs(strength - tv)
        if d < best_dist
          best_dist = d
          best_id = id
        end
      end
      best_id != 0 && push!(deactivate_ids, best_id)
    end

    active_ids = setdiff(current_active, deactivate_ids)
    return LifecyclePlan(deactivate_ids, Int[], Tuple{Int,Int}[], active_ids)
  end

  # increase
  if dc > cur_n
    k = dc - cur_n

    revive_ids = Int[]

    # revive from inactive
    if !isempty(m.inactive_ids)
      inactive_with_strength = [(id, presence_of_id(m, id)) for id in m.inactive_ids]
      revive_count = min(k, length(inactive_with_strength))
      revive_targets = generate_centered_targets(revive_count, t, s)

      for tv in revive_targets
        best_id = 0
        best_dist = Inf
        for (id, strength) in inactive_with_strength
          (id in revive_ids) && continue
          d = abs(strength - tv)
          if d < best_dist
            best_dist = d
            best_id = id
          end
        end
        best_id != 0 && push!(revive_ids, best_id)
      end

      k -= length(revive_ids)
    end

    active_ids = vcat(current_active, revive_ids)

    fork_pairs = Tuple{Int,Int}[]
    if k > 0
      active_with_strength = [(id, presence_of_id(m, id)) for id in current_active]
      fork_targets = generate_centered_targets(k, t, s)

      for tv in fork_targets
        # duplicates allowed
        best_id = 0
        best_dist = Inf
        for (id, strength) in active_with_strength
          d = abs(strength - tv)
          if d < best_dist
            best_dist = d
            best_id = id
          end
        end

        if best_id != 0
          new_id = m.next_stream_id
          m.next_stream_id += 1
          push!(fork_pairs, (best_id, new_id))
        end
      end

      active_ids = vcat(active_ids, [p[2] for p in fork_pairs])
    end

    return LifecyclePlan(Int[], revive_ids, fork_pairs, active_ids)
  end

  # unchanged
  return plan
end

"""Apply lifecycle plan to manager (Rails apply_stream_lifecycle_plan!)."""
function apply_stream_lifecycle_plan!(m::Manager, plan::LifecyclePlan)::Nothing
  deactivate_stream_ids!(m, plan.deactivate_ids)
  revive_stream_ids!(m, plan.revive_ids)

  for (src, nid) in plan.fork_pairs
    fork_stream_from_id!(m, src, nid)
  end

  # ensure next id > max new
  if !isempty(plan.fork_pairs)
    max_new = maximum([p[2] for p in plan.fork_pairs])
    m.next_stream_id = max(m.next_stream_id, max_new + 1)
  end

  if !isempty(plan.active_ids)
    set_active_stream_ids!(m, plan.active_ids)
  end

  return nothing
end

# ============================================================
# Pre-calc complexity costs
# ============================================================

"""Precalculate complexity costs for active streams and candidates."""
function precalculate_costs(
  m::Manager,
  candidate_values_raw,
  q_array::Vector{Int},
  n_raw::Union{Nothing,Int}=nothing
)::StreamCosts
  # normalize candidates to PolySet
  candidate_values = PolyphonicClusterManager.PolySet[]
  for v in candidate_values_raw
    if v isa AbstractVector
      push!(candidate_values, Float64[float(x) for x in v])
    else
      push!(candidate_values, Float64[float(v)])
    end
  end

  if !m.fixed_value_range
    update_value_range_from_candidates!(m, candidate_values)
  end

  n = n_raw === nothing ? length(m.active_ids) : Int(n_raw)
  n = max(n, 1)
  actives = active_stream_containers(m, n)

  per_stream = Dict{Int,Dict{Float64,PerCandidateCost}}()

  for c in actives
    # Rails stores costs per candidate VALUE (not by index).
    per_value = Dict{Float64,PerCandidateCost}()
    raw_list = Float64[]

    for v in candidate_values
      # This manager only supports scalar candidates; values are stored as 1-element sets.
      key = isempty(v) ? 0.0 : v[1]
      dist, _qty, comp = safe_simulate_add_and_calculate(c.manager, v, q_array)
      raw = finite_number(comp) ? comp : (finite_number(dist) ? dist : 0.0)
      push!(raw_list, raw)
      per_value[key] = PerCandidateCost(raw, 0.0)
    end

    min_r = isempty(raw_list) ? 0.0 : minimum(raw_list)
    max_r = isempty(raw_list) ? 0.0 : maximum(raw_list)
    span = abs(max_r - min_r)
    span = span <= 0.0 ? 1.0 : span

    # normalize to 0..1
    for v in candidate_values
      key = isempty(v) ? 0.0 : v[1]
      pc = get(per_value, key, nothing)
      if pc === nothing
        per_value[key] = PerCandidateCost(0.0, 0.5)
      else
        c01 = clamp((pc.raw_complexity - min_r) / span, 0.0, 1.0)
        per_value[key] = PerCandidateCost(pc.raw_complexity, c01)
      end
    end

    per_stream[c.id] = per_value
  end

  return StreamCosts(per_stream)
end

# ============================================================
# Mapping + scoring
# ============================================================

"""Hungarian algorithm for min assignment (Rails hungarian_min_assignment)."""
function hungarian_min_assignment(cost::Vector{Vector{Float64}})::Vector{Int}
  n = length(cost)
  n <= 0 && return Int[]

  u = fill(0.0, n + 1)
  v = fill(0.0, n + 1)
  p = fill(0, n + 1)
  way = fill(0, n + 1)

  for i in 1:n
    p[1] = i
    j0 = 1
    minv = fill(Inf, n + 1)
    used = fill(false, n + 1)

    while true
      used[j0] = true
      i0 = p[j0]
      delta = Inf
      j1 = 1

      for j in 2:(n+1)
        used[j] && continue
        cur = cost[i0][j-1] - u[i0] - v[j]
        if cur < minv[j]
          minv[j] = cur
          way[j] = j0
        end
        if minv[j] < delta
          delta = minv[j]
          j1 = j
        end
      end

      for j in 1:(n+1)
        if used[j]
          u[p[j]] += delta
          v[j] -= delta
        else
          minv[j] -= delta
        end
      end

      j0 = j1
      p[j0] == 0 && break
    end

    while true
      j1 = way[j0]
      p[j0] = p[j1]
      j0 = j1
      j0 == 1 && break
    end
  end

  assignment = fill(0, n)
  for j in 2:(n+1)
    assignment[p[j]] = j - 1
  end

  return assignment
end

"""Set-distance normalized to 0..1 (Rails set_distance01)."""
function set_distance01(a_raw, b_raw; width::Real, max_count::Int)::Float64
  # Fast path for the hot loop: avoid allocations and broadcasting.
  # Rails behavior:
  # - both empty => 0.0
  # - one empty  => 1.0
  # - pitch distance uses symmetric min-average
  # - normalized by width
  # - count penalty blended only when sizes differ

  w = float(width)
  w = w <= 0.0 ? 1.0 : w
  mc = max(Int(max_count), 1)

  # Normalize inputs as "vector-like" without materializing new arrays
  a_is_vec = a_raw isa AbstractVector
  b_is_vec = b_raw isa AbstractVector

  a_len = a_is_vec ? length(a_raw) : 1
  b_len = b_is_vec ? length(b_raw) : 1

  # Empty checks
  if a_is_vec && a_len == 0 && b_is_vec && b_len == 0
    return 0.0
  end
  if (a_is_vec && a_len == 0) || (b_is_vec && b_len == 0)
    return 1.0
  end

  # We cannot close over vector/scalar state cleanly; use two explicit loops.
  a_sum = 0.0
  for i in 1:a_len
    x = a_is_vec ? float(a_raw[i]) : float(a_raw)
    best = Inf
    @inbounds for j in 1:b_len
      y = b_is_vec ? float(b_raw[j]) : float(b_raw)
      d = abs(x - y)
      best = d < best ? d : best
    end
    a_sum += best
  end
  a_avg = a_sum / float(a_len)

  b_sum = 0.0
  for j in 1:b_len
    y = b_is_vec ? float(b_raw[j]) : float(b_raw)
    best = Inf
    @inbounds for i in 1:a_len
      x = a_is_vec ? float(a_raw[i]) : float(a_raw)
      d = abs(y - x)
      best = d < best ? d : best
    end
    b_sum += best
  end
  b_avg = b_sum / float(b_len)

  pitch_dist = (a_avg + b_avg) / 2.0
  pitch_norm = clamp(pitch_dist / w, 0.0, 1.0)

  count_norm = clamp(abs(a_len - b_len) / float(mc), 0.0, 1.0)

  if count_norm <= 0.0
    return pitch_norm
  end

  return clamp((pitch_norm + count_norm) / 2.0, 0.0, 1.0)
end

"""Resolve mapping and compute score (Rails resolve_mapping_and_score)."""
function resolve_mapping_and_score(
  m::Manager,
  cand_set_raw,
  stream_costs::Union{Nothing,StreamCosts};
  absolute_bases::Union{Nothing,Vector{Int}}=nothing,
  active_note_counts::Union{Nothing,Vector{Int}}=nothing,
  active_total_notes::Union{Nothing,Int}=nothing,
  distance_weight::Union{Nothing,Real}=nothing,
  complexity_weight::Union{Nothing,Real}=nothing
)
  # normalize candidates
  cand_set = PolyphonicClusterManager.PolySet[]
  for v in cand_set_raw
    if v isa AbstractVector
      push!(cand_set, Float64[float(x) for x in v])
    else
      push!(cand_set, Float64[float(v)])
    end
  end

  n = length(cand_set)
  n = max(n, 1)

  if absolute_bases !== nothing
    m.pending_absolute_bases = copy(absolute_bases)
  end

  dw::Float64 = 0.0

  cw::Float64 = 0.0

  if distance_weight === nothing || complexity_weight === nothing
    if m.use_complexity_mapping
      dw = 0.0
      cw = 1.0
    else
      dw = 1.0
      cw = 0.0
    end
  else
    dw = clamp(float(distance_weight), 0.0, 1.0)
    cw = clamp(float(complexity_weight), 0.0, 1.0)
  end

  actives = active_stream_containers(m, n)

  cost_matrix = [fill(0.0, n) for _ in 1:n]
  dist_matrix = [fill(0.0, n) for _ in 1:n]
  comp_matrix = [fill(0.0, n) for _ in 1:n]

  abs_width = 1.0
  if absolute_bases !== nothing
    bases = [float(x) for x in absolute_bases]
    pc_width = abs(float(last(PolyphonicConfig.NOTE_RANGE)) - float(first(PolyphonicConfig.NOTE_RANGE)))
    pc_width = pc_width <= 0.0 ? 1.0 : pc_width
    abs_width = abs(maximum(bases) - minimum(bases)) + pc_width
    abs_width = abs_width <= 0.0 ? 1.0 : abs_width
  end

  # build matrices
  for (i, stream) in enumerate(actives)
    for j in 1:n
      v = cand_set[j]

      dist01::Float64 = 0.0
      if absolute_bases !== nothing
        base = absolute_bases[i]
        # Rails: pc.to_i (truncate) % STEPS_PER_OCTAVE
        abs_candidate = [base + (trunc(Int, pc) % PolyphonicConfig.STEPS_PER_OCTAVE) for pc in v]

        last_abs = stream.last_abs_pitch
        if last_abs === nothing
          last = stream.last_value
          # Rails: pc.to_i (truncate)
          last_abs = [base + (trunc(Int, pc) % PolyphonicConfig.STEPS_PER_OCTAVE) for pc in last]
        end

        pitch_dist01 = set_distance01(abs_candidate, last_abs; width=abs_width, max_count=m.max_simultaneous_notes)

        count01 = active_note_counts === nothing ? 0.0 : clamp(active_note_counts[i] / m.max_simultaneous_notes, 0.0, 1.0)
        dist01 = clamp((pitch_dist01 + count01) / 2.0, 0.0, 1.0)
      else
        last = stream.last_value

        # Rails behavior:
        # - if both are scalar => raw(|v-last|)/value_width
        # - if either is Array => set_distance01
        # In this Julia port, scalar values are stored as 1-element vectors,
        # so we must mirror the scalar branch explicitly.
        if length(v) == 1 && length(last) == 1
          raw = abs(v[1] - last[1])
          dist01 = clamp(raw / m.value_width, 0.0, 1.0)
        else
          dist01 = set_distance01(v, last; width=m.value_width, max_count=m.max_simultaneous_notes)
        end
      end

      comp01::Float64 = 0.5
      if stream_costs === nothing
        comp01 = 0.5
      else
        dict = get(stream_costs.per_stream, stream.id, nothing)
        if dict === nothing
          comp01 = 0.5
        else
          # Rails: lookup by candidate VALUE
          key = isempty(v) ? 0.0 : v[1]
          pc = get(dict, key, nothing)
          comp01 = pc === nothing ? 0.5 : pc.complexity01
        end
      end

      dist_matrix[i][j] = dist01
      comp_matrix[i][j] = comp01
      # Rails behavior is effectively deterministic when costs tie because
      # candidates are enumerated in a stable order (and the assignment solver
      # tends to pick the first min it encounters).
      #
      # In Julia, floating-point ties can lead to different (yet equivalent)
      # assignments depending on numerical path. To match Rails more closely,
      # we apply an extremely small, index-based tie-breaker that prefers
      # smaller candidate indices (j) and then smaller stream indices (i).
      base_cost = (dw * dist01) + (cw * comp01)
      tie_eps = 1e-9 * (float(j) + float(i) * 1e-3)
      cost_matrix[i][j] = base_cost + tie_eps
    end
  end

  assignment = hungarian_min_assignment(cost_matrix)

  ordered = Vector{PolyphonicClusterManager.PolySet}(undef, n)

  individual_scores = Vector{IndividualScore}()
  total_dist = 0.0
  total_comp = 0.0

  for (i, stream) in enumerate(actives)
    j = assignment[i]
    v = cand_set[j]
    ordered[i] = v

    total_dist += dist_matrix[i][j]
    total_comp += comp_matrix[i][j]

    push!(individual_scores, IndividualScore(stream.id, dist_matrix[i][j], comp_matrix[i][j]))
  end

  avg_dist = clamp(total_dist / n, 0.0, 1.0)
  avg_comp = clamp(total_comp / n, 0.0, 1.0)

  metric = MappingMetric(individual_scores, avg_dist, avg_comp)

  return ordered, metric
end

# ============================================================
# Commit
# ============================================================

"""Add a data point permanently (safe)."""
function safe_add_data_point!(mgr::PolyphonicClusterManager.Manager, value::PolyphonicClusterManager.PolySet)::Nothing
  try
    PolyphonicClusterManager.add_data_point_permanently(mgr, value)
  catch
    # fallback: push
    push!(mgr.data, value)
  end
  return nothing
end

"""Simulate add and calculate (safe)."""
function safe_simulate_add_and_calculate(mgr::PolyphonicClusterManager.Manager, value::PolyphonicClusterManager.PolySet, q_array::Vector{Int})
  try
    return PolyphonicClusterManager.simulate_add_and_calculate(mgr, value, q_array)
  catch
    return 0.0, 0.0, 0.0
  end
end

"""Finite number check."""
@inline finite_number(x)::Bool = (x isa Real) && isfinite(float(x))

"""Commit state (Rails commit_state)."""
function commit_state!(
  m::Manager,
  best_chord_raw,
  q_array::Vector{Int};
  strength_params=nothing,
  absolute_bases::Union{Nothing,Vector{Int}}=nothing
)::Bool
  # normalize chord
  best_chord = PolyphonicClusterManager.PolySet[]
  for v in best_chord_raw
    if v isa AbstractVector
      push!(best_chord, Float64[float(x) for x in v])
    else
      push!(best_chord, Float64[float(v)])
    end
  end

  n = max(length(best_chord), 1)

  if absolute_bases !== nothing
    m.pending_absolute_bases = copy(absolute_bases)
  end

  actives = active_stream_containers(m, n)

  for (i, stream) in enumerate(actives)
    v = best_chord[i]

    safe_add_data_point!(stream.manager, v)
    stream.last_value = copy(v)

    if m.pending_absolute_bases !== nothing
      base = m.pending_absolute_bases[i]
      # Rails: pc.to_i (truncate)
      stream.last_abs_pitch = [base + (trunc(Int, pc) % PolyphonicConfig.STEPS_PER_OCTAVE) for pc in v]
    end

    if m.track_presence && length(v) == 1
      vv = clamp(v[1], 0.0, 1.0)
      stream.presence_sum += vv
      stream.presence_count += 1
      stream.presence_avg = stream.presence_count > 0 ? clamp(stream.presence_sum / stream.presence_count, 0.0, 1.0) : vv
    end
  end

  return true
end

"""Update caches permanently for all streams."""
function update_caches_permanently!(m::Manager, q_array::Vector{Int})::Nothing
  for c in m.stream_pool
    try
      PolyphonicClusterManager.update_caches_permanently(c.manager, q_array)
    catch
      # noop
    end
  end
  m.pending_absolute_bases = nothing
  return nothing
end

"""Stream strengths report (Rails stream_strengths_report)."""
function stream_strengths_report(m::Manager)::Dict{Int,StreamStrengthEntry}
  report = Dict{Int,StreamStrengthEntry}()
  for container in m.stream_pool
    report[container.id] = StreamStrengthEntry(
      container.id in m.active_ids,
      container.presence_avg,
      container.presence_count,
      container.last_value,
    )
  end
  return report
end

end # module
