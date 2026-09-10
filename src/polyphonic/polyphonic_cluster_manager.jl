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

using ..Config

# Types

"""A single polyphonic value (a set). Order is irrelevant."""
const PolySet = Vector{Float64}

"""A subsequence (length == window_size)."""
const PolySeq = Vector{PolySet}

const RECENCY_MEMORY_SPAN::Float64 = 64.0

"""Cluster node."""
mutable struct PolyClusterNode
  si::Vector{Int}                     # start indices (0-based)
  cc::Dict{Int,PolyClusterNode}       # child clusters
  as::PolySeq                         # representative sequence
end

"""Complexity metrics of the interval series derived from a cluster's starts."""
struct OccurrenceIntervalMetrics
  distance::Float64
  quantity::Float64
  complexity::Float64
  prediction::Float64
  ready::Bool
end

OccurrenceIntervalMetrics(
  distance::Real,
  quantity::Real,
  complexity::Real,
  ready::Bool,
) = OccurrenceIntervalMetrics(
  float(distance),
  float(quantity),
  float(complexity),
  NaN,
  ready,
)

struct PredictiveSuccessor
  value::PolySet
  mass::Float64
end

struct PredictiveDistribution
  successors::Vector{PredictiveSuccessor}
  peak_likelihood::Float64
  ready::Bool
end

"""Base metrics plus the second-order occurrence-interval metrics."""
struct ExtendedClusterMetrics
  distance::Float64
  quantity::Float64
  complexity::Float64
  occurrence_intervals::OccurrenceIntervalMetrics
end

const EMPTY_OCCURRENCE_INTERVAL_METRICS =
  OccurrenceIntervalMetrics(0.0, 0.0, 0.0, false)
const EMPTY_PREDICTIVE_DISTRIBUTION =
  PredictiveDistribution(PredictiveSuccessor[], 0.0, false)

abstract type AbstractClusterManager end

"""Incremental second-order manager for one base cluster's occurrence gaps."""
mutable struct OccurrenceIntervalState
  source_occurrence_count::Int
  scale::Float64
  manager::Union{Nothing,AbstractClusterManager}
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
mutable struct Manager <: AbstractClusterManager
  data::Vector{PolySet}
  merge_threshold_ratio::Float64
  min_window_size::Int
  calculate_distance_when_added_subsequence_to_cluster::Bool
  use_streamwise_surface_average::Bool
  stream_axis_offset::Float64
  stream_axis_capacity::Int

  value_min::Float64
  value_max::Float64
  value_width::Float64
  max_set_size::Int
  point_distance_mode::Symbol
  point_axis_ranges::Vector{Float64}

  scale_mode::Symbol
  contextual_min_width::Float64

  clusters::Dict{Int,PolyClusterNode}
  cluster_id_counter::Int
  tasks::Vector{Tuple{Vector{Int},Int}}

  updated_cluster_ids_per_window_for_calculate_distance::Dict{Int,Set{Int}}
  updated_cluster_ids_per_window_for_calculate_quantities::Dict{Int,Set{Int}}

  cluster_distance_cache::Dict{Int,Dict{Tuple{Int,Int},Float64}}
  cluster_quantity_cache::Dict{Int,Dict{Int,Float64}}
  cluster_complexity_cache::Dict{Int,Dict{Int,Float64}}

  recency::Float64
  enable_occurrence_intervals::Bool
  occurrence_interval_states::IdDict{PolyClusterNode,OccurrenceIntervalState}

  recording_mode::Bool
  journal::Vector{PolyJournalEntry}
  snapshot_state::Union{Nothing,PolySnapshot}
end

# Constructors

"""Deep-copy a PolySeq."""
deep_copy_seq(seq::PolySeq)::PolySeq = [copy(s) for s in seq]

"""Ensure a PolySet is non-nil and compact."""
normalize_set(x::PolySet)::PolySet = x

@inline function _new_cluster_node(starts::Vector{Int}, as::PolySeq)::PolyClusterNode
  return PolyClusterNode(starts, Dict{Int,PolyClusterNode}(), as)
end

"""Create manager. `data` must be Vector{Vector{Float64}}."""
function Manager(
  data::Vector{PolySet},
  merge_threshold_ratio::Real,
  min_window_size::Int,
  calculate_distance_when_added_subsequence_to_cluster::Bool = false;
  use_streamwise_surface_average::Bool = false,
  stream_axis_offset::Real = Config.UNIT_MIN,
  stream_axis_capacity::Union{Nothing,Int} = nothing,
  value_min::Real = Config.UNIT_MIN,
  value_max::Real = Config.UNIT_MAX,
  max_set_size::Int = last(Config.CHORD_SIZE_RANGE),
  point_distance_mode::Symbol = :set,
  point_axis_ranges::Vector{Float64} = Float64[],
  recency::Real = 0.0,
  enable_occurrence_intervals::Bool = true,
  scale_mode::Symbol = :range_fixed,
  contextual_min_width::Real = Config.DEFAULT_CONTEXTUAL_MIN_WIDTH,
  range_min::Real = Config.DEFAULT_RANGE_MIN,
  range_max::Real = Config.DEFAULT_RANGE_MAX,
)
  mtr = float(merge_threshold_ratio)

  vmin = scale_mode == :range_fixed ? float(range_min) : float(value_min)
  vmax = scale_mode == :range_fixed ? float(range_max) : float(value_max)
  vwidth = abs(vmax - vmin)
  if vwidth <= 0.0
    vwidth = 1.0
  end

  mss = Int(max_set_size)
  if mss <= 0
    mss = 1
  end
  axis_capacity = stream_axis_capacity === nothing ? mss : max(Int(stream_axis_capacity), 1)

  # A root represents the first real min-window subsequence.  Short inputs
  # have no such subsequence and therefore start with an empty tree.
  has_root = length(data) >= min_window_size
  clusters = Dict{Int,PolyClusterNode}()
  if has_root
    seed_as = deep_copy_seq(data[1:min_window_size])
    clusters[0] = PolyClusterNode([0], Dict{Int,PolyClusterNode}(), seed_as)
  end

  updated_dist = has_root ? Dict{Int,Set{Int}}(min_window_size => Set([0])) : Dict{Int,Set{Int}}()
  updated_qty  = has_root ? Dict{Int,Set{Int}}(min_window_size => Set([0])) : Dict{Int,Set{Int}}()

  dist_cache = has_root ? Dict{Int,Dict{Tuple{Int,Int},Float64}}(min_window_size => Dict{Tuple{Int,Int},Float64}()) : Dict{Int,Dict{Tuple{Int,Int},Float64}}()
  qty_cache  = has_root ? Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}()) : Dict{Int,Dict{Int,Float64}}()
  comp_cache = has_root ? Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}()) : Dict{Int,Dict{Int,Float64}}()
  cluster_id_counter = has_root ? 1 : 0

  return Manager(
    data,
    mtr,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster,
    Bool(use_streamwise_surface_average),
    float(stream_axis_offset),
    axis_capacity,
    vmin,
    vmax,
    vwidth,
    mss,
    point_distance_mode,
    copy(point_axis_ranges),
    scale_mode,
    float(contextual_min_width),
    clusters,
    cluster_id_counter,
    Tuple{Vector{Int},Int}[],
    updated_dist,
    updated_qty,
    dist_cache,
    qty_cache,
    comp_cache,
    clamp(float(recency), 0.0, 1.0),
    Bool(enable_occurrence_intervals),
    IdDict{PolyClusterNode,OccurrenceIntervalState}(),
    false,
    PolyJournalEntry[],
    nothing
  )
end

function _initialize_root_cluster_if_ready!(mgr::Manager)::Bool
  !isempty(mgr.clusters) && return false
  length(mgr.data) >= mgr.min_window_size || return false
  seed_as = deep_copy_seq(mgr.data[1:mgr.min_window_size])
  mgr.clusters[0] = PolyClusterNode([0], Dict{Int,PolyClusterNode}(), seed_as)
  mgr.cluster_id_counter = max(mgr.cluster_id_counter, 1)
  mgr.updated_cluster_ids_per_window_for_calculate_distance[mgr.min_window_size] = Set([0])
  mgr.updated_cluster_ids_per_window_for_calculate_quantities[mgr.min_window_size] = Set([0])
  get!(mgr.cluster_distance_cache, mgr.min_window_size, Dict{Tuple{Int,Int},Float64}())
  get!(mgr.cluster_quantity_cache, mgr.min_window_size, Dict{Int,Float64}())
  get!(mgr.cluster_complexity_cache, mgr.min_window_size, Dict{Int,Float64}())
  return true
end

# Distance functions (Rails 1:1)

"""Clamp to [0,1]."""
clamp01(x::Float64)::Float64 = x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x)

"""Distance between sparse streamwise rows, matched strictly by identity-axis slot."""
function streamwise_surface_distance01(mgr::Manager, a::PolySet, b::PolySet)::Float64
  isempty(a) && isempty(b) && return 0.0

  function decode_row(row::PolySet)::Dict{Int,Float64}
    decoded = Dict{Int,Float64}()
    for encoded in row
      slot, raw = _decode_streamwise_value(mgr, encoded)
      haskey(decoded, slot) && error("Duplicate encoded stream slot $(slot) in global row.")
      decoded[slot] = raw
    end
    return decoded
  end

  a_by_slot = decode_row(a)
  b_by_slot = decode_row(b)
  slots = union(Set(keys(a_by_slot)), Set(keys(b_by_slot)))
  isempty(slots) && return 0.0

  raw_width = abs(mgr.stream_axis_offset) - 1.0
  raw_width = raw_width <= 0.0 ? 1.0 : raw_width
  distance_sum = 0.0
  for slot in slots
    if haskey(a_by_slot, slot) && haskey(b_by_slot, slot)
      distance_sum += clamp01(abs(a_by_slot[slot] - b_by_slot[slot]) / raw_width)
    else
      distance_sum += 1.0
    end
  end
  return clamp01(distance_sum / float(length(slots)))
end

"""min_avg_distance(a,b)

Rails:
  - scalar/array both supported; Julia version uses PolySet everywhere.
  - if one is empty and the other isn't => 1.0
  - pitch distance uses symmetric min-average
  - pitch normalized by value_width
  - count normalized by max_set_size

Streamwise global rows are sparse identity-keyed surfaces and therefore use
slot-matched distance rather than nearest encoded-value matching.
"""
function min_avg_distance(mgr::Manager, a::PolySet, b::PolySet)::Float64
  if mgr.point_distance_mode == :ordered_vector
    return ordered_vector_distance01(mgr, a, b)
  end
  if mgr.use_streamwise_surface_average
    return streamwise_surface_distance01(mgr, a, b)
  end

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

"""Ordered vector distance normalized to 0..1-ish.

Used when a single timestep is a fixed feature vector, e.g. [note, vol01],
rather than an unordered pitch set/chord.
"""
function ordered_vector_distance01(mgr::Manager, a::PolySet, b::PolySet)::Float64
  isempty(a) && isempty(b) && return 0.0

  dims = max(length(a), length(b), length(mgr.point_axis_ranges), 1)
  s = 0.0
  @inbounds for i in 1:dims
    av = i <= length(a) ? a[i] : 0.0
    bv = i <= length(b) ? b[i] : 0.0
    width = if i <= length(mgr.point_axis_ranges)
      abs(mgr.point_axis_ranges[i])
    else
      mgr.value_width
    end
    width = width <= 0.0 ? 1.0 : width
    d = (av - bv) / width
    s += d * d
  end
  return clamp01(sqrt(s) / sqrt(float(dims)))
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

Rails semantics for ordinary 1D/stream use:
  - If all sets at timestep t have the same count, sort each and average by index.
  - Otherwise pick the latest (sequences[end][t]).

For forced global polyphonic streams, `use_streamwise_surface_average=true` decodes the
synthetic stream axis and averages each timestep/stream cell independently.
"""
@inline function _decode_streamwise_value(mgr::Manager, encoded::Float64)::Tuple{Int,Float64}
  offset = mgr.stream_axis_offset
  if offset <= 0.0
    return (1, encoded)
  end

  slot = floor(Int, (encoded - mgr.value_min) / offset) + 1
  1 <= slot <= mgr.stream_axis_capacity || error(
    "Encoded stream slot $(slot) is outside configured axis capacity 1:$(mgr.stream_axis_capacity) for value $(encoded).",
  )
  raw = encoded - float(slot - 1) * offset
  return (slot, raw)
end

function _average_streamwise_surface_sequences(mgr::Manager, sequences::Vector{PolySeq})::PolySeq
  len = length(sequences[1])
  result = PolySeq(undef, len)

  for t in 1:len
    sums = zeros(Float64, mgr.stream_axis_capacity)
    counts = zeros(Int, mgr.stream_axis_capacity)

    for seq in sequences
      for encoded in seq[t]
        slot, raw = _decode_streamwise_value(mgr, encoded)
        sums[slot] += raw
        counts[slot] += 1
      end
    end

    avg_set = Float64[]
    sizehint!(avg_set, mgr.stream_axis_capacity)
    for slot in 1:mgr.stream_axis_capacity
      counts[slot] <= 0 && continue
      avg_raw = sums[slot] / float(counts[slot])
      push!(avg_set, avg_raw + float(slot - 1) * mgr.stream_axis_offset)
    end
    result[t] = avg_set
  end

  return result
end

function average_sequences(mgr::Manager, sequences::Vector{PolySeq})::PolySeq
  length(sequences) == 1 && return deep_copy_seq(sequences[1])
  mgr.use_streamwise_surface_average && return _average_streamwise_surface_sequences(mgr, sequences)

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
      if mgr.point_distance_mode == :ordered_vector
        avg_set = zeros(Float64, first_count)
        for s in sets_at_t
          @inbounds for i in 1:first_count
            avg_set[i] += s[i]
          end
        end
        @inbounds for i in 1:first_count
          avg_set[i] /= float(length(sets_at_t))
        end
        result[t] = avg_set
        continue
      end

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
  _initialize_root_cluster_if_ready!(mgr)
  isempty(mgr.clusters) && return nothing
  for i in 1:length(mgr.data)
    data_index = i - 1
    if data_index <= mgr.min_window_size - 1
      continue
    end
    clustering_subsequences_incremental!(mgr, data_index)
  end
  return nothing
end

function add_data_point_permanently!(mgr::Manager, val::PolySet)
  push!(mgr.data, val)
  length(mgr.data) < mgr.min_window_size && return nothing
  _initialize_root_cluster_if_ready!(mgr) && return nothing
  clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
  return nothing
end

"""Update caches after permanent append.

Identical to scalar TimeSeriesClusterManager, but uses polyphonic distances.
"""
@inline cluster_quantity_score(cluster_size::Int, window_size::Int)::Float64 = float(cluster_size * window_size)

@inline function recency_curve(x::Real)::Float64
  r = clamp(float(x), 0.0, 1.0)
  return r * r * (3.0 - 2.0 * r)
end

@inline function recency_weight(mgr::Manager, now_index::Int, start_index::Int)::Float64
  r = recency_curve(mgr.recency)
  r <= 0.0 && return 1.0
  age = max(now_index - start_index, 0)
  span = exp((1.0 - r) * log(RECENCY_MEMORY_SPAN))
  return (1.0 - r) + (r * exp(-float(age) / span))
end

@inline function cluster_last_occurrence(node::PolyClusterNode)::Int
  isempty(node.si) && return 0
  return maximum(node.si)
end

@inline function cluster_recency_weight(mgr::Manager, node::PolyClusterNode, now_index::Int)::Float64
  return recency_weight(mgr, now_index, cluster_last_occurrence(node))
end

function recent_quantity_score(mgr::Manager, node::PolyClusterNode, window_size::Int, now_index::Int)::Float64
  total = 0.0
  @inbounds for s in node.si
    total += recency_weight(mgr, now_index, s)
  end
  return total * float(window_size)
end

function weighted_distance_score(
  mgr::Manager,
  cache::Dict{Tuple{Int,Int},Float64},
  same_ws::Dict{Int,PolyClusterNode},
  now_index::Int
)::Float64
  weighted = 0.0
  weight_sum = 0.0
  for (key, dist) in cache
    n1 = get(same_ws, key[1], nothing)
    n2 = get(same_ws, key[2], nothing)
    (n1 === nothing || n2 === nothing) && continue
    w = sqrt(cluster_recency_weight(mgr, n1, now_index) * cluster_recency_weight(mgr, n2, now_index))
    weighted += float(dist) * w
    weight_sum += w
  end
  return weight_sum > 0.0 ? (weighted / weight_sum) : 0.0
end

function weighted_quantity_score(mgr::Manager, same_ws::Dict{Int,PolyClusterNode}, window_size::Int, now_index::Int)::Float64
  total = 0.0
  for (_, node) in same_ws
    length(node.si) <= 1 && continue
    total += recent_quantity_score(mgr, node, window_size, now_index)
  end
  return total
end

function weighted_complexity_score(
  mgr::Manager,
  c_cache::Dict{Int,Float64},
  same_ws::Dict{Int,PolyClusterNode},
  now_index::Int
)::Float64
  weighted = 0.0
  weight_sum = 0.0
  for (cid, comp) in c_cache
    node = get(same_ws, cid, nothing)
    node === nothing && continue
    w = cluster_recency_weight(mgr, node, now_index)
    weighted += float(comp) * w
    weight_sum += w
  end
  return weight_sum > 0.0 ? (weighted / weight_sum) : 0.0
end

function update_caches_permanently!(mgr::Manager)
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

    # ----------------------------------------------------------
    # Distance cache (incremental)
    # ----------------------------------------------------------
    cache = get!(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    updated_ids_set = get(mgr.updated_cluster_ids_per_window_for_calculate_distance, window_size, nothing)

    if isempty(cache)
      # First-time seeding: compute all pairs once.
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
    elseif updated_ids_set !== nothing && !isempty(updated_ids_set)
      # Incremental update: only clusters whose "as" changed / was created.
      for cid1 in updated_ids_set
        node1 = get(same_ws, cid1, nothing)
        node1 === nothing && continue
        @inbounds for cid2 in all_ids
          cid1 == cid2 && continue
          node2 = same_ws[cid2]
          key = cid1 < cid2 ? (cid1, cid2) : (cid2, cid1)
          cache[key] = euclidean_distance(mgr, node1.as, node2.as)
        end
      end
    end

    # ----------------------------------------------------------
    # Quantity / complexity cache (incremental)
    # ----------------------------------------------------------
    q_cache = get!(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get!(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())
    updated_quant_set = get(mgr.updated_cluster_ids_per_window_for_calculate_quantities, window_size, nothing)

    if isempty(q_cache) || isempty(c_cache)
      for (cid, node) in same_ws
        length(node.si) <= 1 && continue

        q = cluster_quantity_score(length(node.si), window_size)
        q_cache[cid] = q
        c_cache[cid] = calculate_cluster_complexity(mgr, node)
      end
    elseif updated_quant_set !== nothing && !isempty(updated_quant_set)
      for cid in updated_quant_set
        node = get(same_ws, cid, nothing)
        node === nothing && continue
        length(node.si) > 1 || continue

        q = cluster_quantity_score(length(node.si), window_size)
        q_cache[cid] = q
        c_cache[cid] = calculate_cluster_complexity(mgr, node)
      end
    end
  end

  if mgr.enable_occurrence_intervals
    now_index = length(mgr.data) - 1
    for (_, node) in _selected_latest_occurrence_targets(clusters_each, now_index)
      _sync_occurrence_interval_state!(mgr, node)
    end
  end

  # reset updated ids (Rails behavior)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
  return nothing
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

  # Use an explicit stack (and avoid relying on the global `stack` function name)
  _stack = Vector{Tuple{Int,Int,PolyClusterNode}}()
  sizehint!(_stack, length(clusters))
  for (cid, cl) in clusters
    push!(_stack, (min_window_size, cid, cl))
  end

  while !isempty(_stack)
    (depth, cluster_id, current) = pop!(_stack)
    sequences = [[s, s + depth - 1] for s in current.si]
    same_ws = get!(clusters_each, depth, Dict{Int,Dict{String,Any}}())
    same_ws[cluster_id] = Dict("si" => sequences, "as" => current.as)

    for (child_id, child_cluster) in current.cc
      push!(_stack, (depth + 1, child_id, child_cluster))
    end
  end

  return clusters_each
end

function clusters_to_timeline(clusters::Dict{Int,PolyClusterNode}, min_window_size::Int)
  result = Vector{Dict{String,Any}}()

  _stack = Vector{Tuple{Int,Int,PolyClusterNode}}()
  sizehint!(_stack, length(clusters))
  for (cid, cl) in clusters
    push!(_stack, (min_window_size, cid, cl))
  end

  while !isempty(_stack)
    (window_size, cluster_id, current) = pop!(_stack)
    if !isempty(current.si)
      push!(result, Dict(
        "window_size" => window_size,
        "cluster_id"  => string(cluster_id),
        "indices"     => sort(copy(current.si))
      ))
    end
    for (child_id, child_cluster) in current.cc
      push!(_stack, (window_size + 1, child_id, child_cluster))
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

function collect_clusters_each(mgr::Manager)::Dict{Int,Dict{Int,PolyClusterNode}}
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

@inline function predictive_gaussian_similarity(distance::Real, bandwidth::Real)::Float64
  sigma = max(abs(float(bandwidth)), eps(Float64))
  z = max(float(distance), 0.0) / sigma
  return exp(-0.5 * z * z)
end

function predictive_likelihood(
  mgr::Manager,
  successors::Vector{PredictiveSuccessor},
  candidate::PolySet,
)::Float64
  likelihood = 0.0
  for successor in successors
    distance = min_avg_distance(mgr, candidate, successor.value)
    likelihood += successor.mass * predictive_gaussian_similarity(
      distance,
      Config.PREDICTIVE_SUCCESSOR_DISTANCE_BANDWIDTH,
    )
  end
  return likelihood
end

"""Build a weighted successor distribution from every eligible suffix cluster."""
function build_predictive_distribution(mgr::Manager)::PredictiveDistribution
  data_length = length(mgr.data)
  data_length <= mgr.min_window_size && return EMPTY_PREDICTIVE_DISTRIBUTION

  clusters_each = collect_clusters_each(mgr)
  max_context = min(
    data_length - 1,
    max(Config.PREDICTIVE_MAX_CONTEXT_LENGTH, mgr.min_window_size),
  )
  now_index = data_length - 1
  scale_rows = Tuple{Float64,Vector{PolySet},Vector{Float64}}[]

  for window_size in sort!(collect(keys(clusters_each)))
    window_size < mgr.min_window_size && continue
    window_size > max_context && continue
    latest_start = data_length - window_size
    latest_start < 0 && continue

    current_context = mgr.data[(latest_start + 1):data_length]
    target = nothing
    for node in values(clusters_each[window_size])
      if latest_start in node.si
        target = node
        break
      end
    end
    target === nothing && continue

    historical_starts = sort!(unique(Int[
      start for start in target.si
      if start < latest_start && start + window_size < data_length
    ]))
    isempty(historical_starts) && continue
    history_limit = max(Config.PREDICTIVE_HISTORY_LIMIT_PER_CONTEXT, 1)
    if length(historical_starts) > history_limit
      historical_starts = historical_starts[(end - history_limit + 1):end]
    end

    successors = PolySet[]
    occurrence_weights = Float64[]
    context_similarity_sum = 0.0
    for start in historical_starts
      past_context = mgr.data[(start + 1):(start + window_size)]
      context_distance =
        euclidean_distance(mgr, current_context, past_context) /
        sqrt(float(max(window_size, 1)))
      context_similarity = predictive_gaussian_similarity(
        context_distance,
        Config.PREDICTIVE_CONTEXT_DISTANCE_BANDWIDTH,
      )
      successor_index = start + window_size
      occurrence_weight =
        recency_weight(mgr, now_index, successor_index) * context_similarity
      occurrence_weight <= 0.0 && continue
      push!(successors, copy(mgr.data[successor_index + 1]))
      push!(occurrence_weights, occurrence_weight)
      context_similarity_sum += context_similarity
    end
    isempty(successors) && continue

    occurrence_total = sum(occurrence_weights)
    occurrence_total <= 0.0 && continue
    occurrence_weights ./= occurrence_total

    support = float(length(successors))
    reliability = support / (support + Config.PREDICTIVE_SUPPORT_PRIOR)
    cohesion = context_similarity_sum / support
    scale_weight = float(window_size) * reliability * cohesion
    scale_weight <= 0.0 && continue
    push!(scale_rows, (scale_weight, successors, occurrence_weights))
  end

  isempty(scale_rows) && return EMPTY_PREDICTIVE_DISTRIBUTION
  scale_total = sum(row[1] for row in scale_rows)
  scale_total <= 0.0 && return EMPTY_PREDICTIVE_DISTRIBUTION

  masses = Dict{Tuple{Vararg{Float64}},Float64}()
  for (scale_weight, successors, occurrence_weights) in scale_rows
    normalized_scale_weight = scale_weight / scale_total
    for i in eachindex(successors)
      key = Tuple(successors[i])
      masses[key] = get(masses, key, 0.0) + normalized_scale_weight * occurrence_weights[i]
    end
  end

  combined = PredictiveSuccessor[
    PredictiveSuccessor(Float64[key...], mass)
    for (key, mass) in masses
    if mass > 0.0
  ]
  isempty(combined) && return EMPTY_PREDICTIVE_DISTRIBUTION
  sort!(combined; by=x -> Tuple(x.value))
  peak_likelihood = maximum(
    predictive_likelihood(mgr, combined, successor.value)
    for successor in combined
  )
  peak_likelihood <= 0.0 && return EMPTY_PREDICTIVE_DISTRIBUTION
  return PredictiveDistribution(combined, peak_likelihood, true)
end

function predictive_surprise_score(
  mgr::Manager,
  distribution::PredictiveDistribution,
  candidate::PolySet,
)::Union{Nothing,Float64}
  distribution.ready || return nothing
  likelihood = predictive_likelihood(mgr, distribution.successors, candidate)
  return clamp(1.0 - likelihood / distribution.peak_likelihood, 0.0, 1.0)
end

function _aggregate_current_metrics(
  mgr::Manager,
  clusters_each::Dict{Int,Dict{Int,PolyClusterNode}};
  include_singleton_complexity::Bool=false,
)::NTuple{3,Float64}
  sum_distances = 0.0
  sum_quantities = 0.0
  sum_complexities = 0.0
  now_index = length(mgr.data) - 1

  for (window_size, same_ws) in clusters_each
    cache = get(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    q_cache = get(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())

    if mgr.recency <= 0.0
      if !isempty(cache)
        sum_distances += sum(values(cache)) / float(window_size)
      end
      if !isempty(q_cache)
        sum_quantities += sum(values(q_cache))
      end
      if !isempty(c_cache)
        sum_complexities += sum(values(c_cache))
      end
      if include_singleton_complexity
        for (_, node) in same_ws
          length(node.si) == 1 || continue
          sum_complexities += calculate_cluster_complexity(mgr, node)
        end
      end
    else
      if !isempty(cache)
        sum_distances += weighted_distance_score(mgr, cache, same_ws, now_index)
      end
      sum_quantities += weighted_quantity_score(mgr, same_ws, window_size, now_index)
      if !isempty(c_cache)
        sum_complexities += weighted_complexity_score(mgr, c_cache, same_ws, now_index)
      end
      if include_singleton_complexity
        singleton_sum = 0.0
        singleton_weight = 0.0
        for (_, node) in same_ws
          length(node.si) == 1 || continue
          w = cluster_recency_weight(mgr, node, now_index)
          singleton_sum += calculate_cluster_complexity(mgr, node) * w
          singleton_weight += w
        end
        singleton_weight > 0.0 && (sum_complexities += singleton_sum / singleton_weight)
      end
    end
  end

  return (sum_distances, sum_quantities, sum_complexities)
end

function _occurrence_gaps(starts::Vector{Int})::Vector{Float64}
  gaps = Float64[]
  sizehint!(gaps, length(starts) - 1)
  @inbounds for i in 2:length(starts)
    gap = starts[i] - starts[i - 1]
    gap > 0 && push!(gaps, float(gap))
  end
  return gaps
end

function _occurrence_interval_scale(gaps::Vector{Float64}, min_window_size::Int)::Float64
  isempty(gaps) && return 1.0
  scale_count = min(length(gaps), max(min_window_size, 1))
  scale = sum(@view gaps[1:scale_count]) / float(scale_count)
  return scale > 0.0 ? scale : 1.0
end

@inline function _normalize_occurrence_gap(gap::Real, scale::Real)::Float64
  ratio_max = Config.OCCURRENCE_INTERVAL_RATIO_MAX
  safe_scale = float(scale) > 0.0 ? float(scale) : 1.0
  return clamp(float(gap) / safe_scale, 0.0, ratio_max)
end

function _build_occurrence_interval_manager(
  gaps::Vector{Float64},
  scale::Float64,
  merge_threshold_ratio::Real,
  min_window_size::Int,
)::Manager
  ratio_max = Config.OCCURRENCE_INTERVAL_RATIO_MAX
  history_limit = max(Config.OCCURRENCE_INTERVAL_HISTORY_LIMIT, min_window_size)
  first_gap = max(length(gaps) - history_limit + 1, 1)
  retained_gaps = @view gaps[first_gap:end]
  interval_series = PolySet[
    Float64[_normalize_occurrence_gap(gap, scale)]
    for gap in retained_gaps
  ]
  manager = Manager(
    interval_series,
    merge_threshold_ratio,
    min_window_size,
    false;
    value_min=0.0,
    value_max=ratio_max,
    range_min=0.0,
    range_max=ratio_max,
    max_set_size=1,
    recency=0.0,
    enable_occurrence_intervals=false,
  )
  process_data!(manager)
  update_caches_permanently!(manager)
  return manager
end

function _sync_occurrence_interval_state!(mgr::Manager, node::PolyClusterNode)::Nothing
  starts = sort!(unique(copy(node.si)))
  occurrence_count = length(starts)
  occurrence_count >= 2 || return nothing

  existing = get(mgr.occurrence_interval_states, node, nothing)
  gaps = _occurrence_gaps(starts)

  if occurrence_count < Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES
    if existing === nothing
      mgr.occurrence_interval_states[node] =
        OccurrenceIntervalState(occurrence_count, 1.0, nothing)
    else
      existing.source_occurrence_count = occurrence_count
    end
    return nothing
  end

  if existing === nothing || existing.manager === nothing ||
      existing.source_occurrence_count > occurrence_count
    scale = _occurrence_interval_scale(gaps, mgr.min_window_size)
    interval_manager = _build_occurrence_interval_manager(
      gaps,
      scale,
      mgr.merge_threshold_ratio,
      mgr.min_window_size,
    )
    mgr.occurrence_interval_states[node] =
      OccurrenceIntervalState(occurrence_count, scale, interval_manager)
    return nothing
  end

  if existing.source_occurrence_count < occurrence_count
    interval_manager = existing.manager::Manager
    history_limit = max(Config.OCCURRENCE_INTERVAL_HISTORY_LIMIT, mgr.min_window_size)
    if length(interval_manager.data) >= 2 * history_limit
      retained_start = max(length(gaps) - history_limit + 1, 1)
      retained_gaps = Float64[gaps[i] for i in retained_start:length(gaps)]
      scale = _occurrence_interval_scale(retained_gaps, mgr.min_window_size)
      existing.manager = _build_occurrence_interval_manager(
        retained_gaps,
        scale,
        mgr.merge_threshold_ratio,
        mgr.min_window_size,
      )
      existing.scale = scale
      existing.source_occurrence_count = occurrence_count
      return nothing
    end

    start_occurrence = existing.source_occurrence_count + 1
    for occurrence_idx in start_occurrence:occurrence_count
      gap = starts[occurrence_idx] - starts[occurrence_idx - 1]
      normalized_gap = _normalize_occurrence_gap(gap, existing.scale)
      add_data_point_permanently!(interval_manager, Float64[normalized_gap])
      update_caches_permanently!(interval_manager)
    end
    existing.source_occurrence_count = occurrence_count
  end
  return nothing
end

function _occurrence_interval_metrics_for_starts(
  starts_raw::Vector{Int},
  merge_threshold_ratio::Real,
  min_window_size::Int,
)::OccurrenceIntervalMetrics
  starts = sort!(unique(copy(starts_raw)))
  length(starts) < Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES &&
    return EMPTY_OCCURRENCE_INTERVAL_METRICS

  gaps = _occurrence_gaps(starts)
  length(gaps) < min_window_size && return EMPTY_OCCURRENCE_INTERVAL_METRICS

  history_limit = max(Config.OCCURRENCE_INTERVAL_HISTORY_LIMIT, min_window_size)
  retained_start = max(length(gaps) - history_limit + 1, 1)
  retained_gaps = Float64[gaps[i] for i in retained_start:length(gaps)]
  committed_gaps = retained_gaps[1:(end - 1)]
  if length(committed_gaps) < min_window_size
    scale = _occurrence_interval_scale(retained_gaps, min_window_size)
    interval_mgr = _build_occurrence_interval_manager(
      retained_gaps,
      scale,
      merge_threshold_ratio,
      min_window_size,
    )
    interval_clusters = collect_clusters_each(interval_mgr)
    d, q, c = _aggregate_current_metrics(
      interval_mgr,
      interval_clusters;
      include_singleton_complexity=true,
    )
    return OccurrenceIntervalMetrics(d, q, c, true)
  end

  scale = _occurrence_interval_scale(committed_gaps, min_window_size)
  interval_mgr = _build_occurrence_interval_manager(
    committed_gaps,
    scale,
    merge_threshold_ratio,
    min_window_size,
  )
  candidate = Float64[_normalize_occurrence_gap(retained_gaps[end], scale)]
  distribution = build_predictive_distribution(interval_mgr)
  prediction = predictive_surprise_score(interval_mgr, distribution, candidate)
  d, q, c = simulate_add_and_calculate_all(interval_mgr, candidate)
  return OccurrenceIntervalMetrics(
    d,
    q,
    c,
    prediction === nothing ? NaN : prediction,
    true,
  )
end

function _preview_occurrence_interval_metrics(
  mgr::Manager,
  node::PolyClusterNode,
)::OccurrenceIntervalMetrics
  starts = sort!(unique(copy(node.si)))
  occurrence_count = length(starts)
  occurrence_count < Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES &&
    return EMPTY_OCCURRENCE_INTERVAL_METRICS

  committed_count = occurrence_count - 1
  state = get(mgr.occurrence_interval_states, node, nothing)
  if state !== nothing &&
      state.manager !== nothing &&
      state.source_occurrence_count == committed_count
    interval_manager = state.manager::Manager
    gap = starts[end] - starts[end - 1]
    candidate = Float64[_normalize_occurrence_gap(gap, state.scale)]
    distribution = build_predictive_distribution(interval_manager)
    prediction = predictive_surprise_score(interval_manager, distribution, candidate)
    d, q, c = simulate_add_and_calculate_all(interval_manager, candidate)
    return OccurrenceIntervalMetrics(
      d,
      q,
      c,
      prediction === nothing ? NaN : prediction,
      true,
    )
  end

  return _occurrence_interval_metrics_for_starts(
    starts,
    mgr.merge_threshold_ratio,
    mgr.min_window_size,
  )
end

function _selected_latest_occurrence_targets(
  clusters_each::Dict{Int,Dict{Int,PolyClusterNode}},
  now_index::Int,
)::Vector{Tuple{Int,PolyClusterNode}}
  targets = Tuple{Int,PolyClusterNode}[]
  for (window_size, same_ws) in clusters_each
    latest_start = now_index - window_size + 1
    latest_start < 0 && continue
    for (_, node) in same_ws
      latest_start in node.si || continue
      length(node.si) >= Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES &&
        push!(targets, (window_size, node))
      break
    end
  end
  isempty(targets) && return targets
  sort!(targets; by=first)

  max_scales = max(Config.OCCURRENCE_INTERVAL_MAX_BASE_SCALES, 1)
  if length(targets) > max_scales
    selected = Tuple{Int,PolyClusterNode}[]
    selected_indices = Set{Int}()
    log_min = log(float(targets[1][1]))
    log_max = log(float(targets[end][1]))
    for scale_idx in 0:(max_scales - 1)
      fraction = max_scales == 1 ? 1.0 : float(scale_idx) / float(max_scales - 1)
      target_log = log_min + fraction * (log_max - log_min)
      best_idx = 1
      best_distance = Inf
      for i in eachindex(targets)
        distance = abs(log(float(targets[i][1])) - target_log)
        if distance < best_distance
          best_distance = distance
          best_idx = i
        end
      end
      push!(selected_indices, best_idx)
    end
    for i in sort!(collect(selected_indices))
      push!(selected, targets[i])
    end
    targets = selected
  end
  return targets
end

function latest_occurrence_interval_metrics(
  mgr::Manager,
  clusters_each::Dict{Int,Dict{Int,PolyClusterNode}},
  now_index::Int,
)::OccurrenceIntervalMetrics
  targets = _selected_latest_occurrence_targets(clusters_each, now_index)
  isempty(targets) && return EMPTY_OCCURRENCE_INTERVAL_METRICS

  sum_distance = 0.0
  sum_quantity = 0.0
  sum_complexity = 0.0
  sum_prediction = 0.0
  prediction_count = 0
  ready_count = 0

  for (_, target) in targets
    temporal = _preview_occurrence_interval_metrics(mgr, target)
    temporal.ready || continue

    sum_distance += temporal.distance
    sum_quantity += temporal.quantity
    sum_complexity += temporal.complexity
    if isfinite(temporal.prediction)
      sum_prediction += temporal.prediction
      prediction_count += 1
    end
    ready_count += 1
  end

  ready_count <= 0 && return EMPTY_OCCURRENCE_INTERVAL_METRICS
  denom = float(ready_count)
  return OccurrenceIntervalMetrics(
    sum_distance / denom,
    sum_quantity / denom,
    sum_complexity / denom,
    prediction_count > 0 ? sum_prediction / float(prediction_count) : NaN,
    true,
  )
end

function current_occurrence_interval_metrics(
  mgr::Manager,
  clusters_each::Dict{Int,Dict{Int,PolyClusterNode}},
  now_index::Int,
)::OccurrenceIntervalMetrics
  targets = _selected_latest_occurrence_targets(clusters_each, now_index)
  isempty(targets) && return EMPTY_OCCURRENCE_INTERVAL_METRICS

  sum_distance = 0.0
  sum_quantity = 0.0
  sum_complexity = 0.0
  sum_prediction = 0.0
  prediction_count = 0
  ready_count = 0

  for (_, target) in targets
    temporal = _occurrence_interval_metrics_for_starts(
      target.si,
      mgr.merge_threshold_ratio,
      mgr.min_window_size,
    )

    temporal.ready || continue
    sum_distance += temporal.distance
    sum_quantity += temporal.quantity
    sum_complexity += temporal.complexity
    if isfinite(temporal.prediction)
      sum_prediction += temporal.prediction
      prediction_count += 1
    end
    ready_count += 1
  end

  ready_count <= 0 && return EMPTY_OCCURRENCE_INTERVAL_METRICS
  denom = float(ready_count)
  return OccurrenceIntervalMetrics(
    sum_distance / denom,
    sum_quantity / denom,
    sum_complexity / denom,
    prediction_count > 0 ? sum_prediction / float(prediction_count) : NaN,
    true,
  )
end

"""Read the committed metric state without adding or simulating a candidate."""
function current_extended_metrics(mgr::Manager)::ExtendedClusterMetrics
  clusters_each = collect_clusters_each(mgr)
  d, q, c = _aggregate_current_metrics(mgr, clusters_each)
  temporal =
    if mgr.enable_occurrence_intervals
      current_occurrence_interval_metrics(mgr, clusters_each, length(mgr.data) - 1)
    else
      EMPTY_OCCURRENCE_INTERVAL_METRICS
    end
  return ExtendedClusterMetrics(d, q, c, temporal)
end

# Simulation with rollback

function simulate_add_and_calculate_all_extended(mgr::Manager, candidate::PolySet)::ExtendedClusterMetrics
  start_transaction!(mgr)
  reset_updated_ids_for_simulation!(mgr)

  # NOTE: This function is on the hottest path (called for every candidate).
  # Avoid JSON-facing transforms (Dict{String,Any}) here; we traverse typed nodes directly.

  try
    push!(mgr.data, candidate)
    record!(mgr, PJDataPush())

    clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
    clusters_each = collect_clusters_each(mgr)

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

        q = cluster_quantity_score(length(node.si), window_size)

        old_q = haskey(q_cache, cid) ? q_cache[cid] : nothing
        q_cache[cid] = q
        record!(mgr, PJCacheWriteQty(q_cache, cid, old_q))

        comp = calculate_cluster_complexity(mgr, node)
        old_c = haskey(c_cache, cid) ? c_cache[cid] : nothing
        c_cache[cid] = comp
        record!(mgr, PJCacheWriteComp(c_cache, cid, old_c))
      end

      if mgr.recency <= 0.0
        if !isempty(cache)
          sum_distances += (sum(values(cache)) / float(window_size))
        end
        if !isempty(q_cache)
          sum_quantities += sum(values(q_cache))
        end
        if !isempty(c_cache)
          sum_complexities += sum(values(c_cache))
        end
      else
        if !isempty(cache)
          sum_distances += weighted_distance_score(mgr, cache, same_ws, length(mgr.data) - 1)
        end
        sum_quantities += weighted_quantity_score(mgr, same_ws, window_size, length(mgr.data) - 1)
        if !isempty(c_cache)
          sum_complexities += weighted_complexity_score(mgr, c_cache, same_ws, length(mgr.data) - 1)
        end
      end
    end

    occurrence_intervals =
      if mgr.enable_occurrence_intervals
        latest_occurrence_interval_metrics(mgr, clusters_each, length(mgr.data) - 1)
      else
        EMPTY_OCCURRENCE_INTERVAL_METRICS
      end
    return ExtendedClusterMetrics(
      sum_distances,
      sum_quantities,
      sum_complexities,
      occurrence_intervals,
    )
  finally
    rollback!(mgr)
  end
end

function simulate_add_and_calculate_all(mgr::Manager, candidate::PolySet)
  metrics = simulate_add_and_calculate_all_extended(mgr, candidate)
  return (metrics.distance, metrics.quantity, metrics.complexity)
end

function simulate_add_and_calculate(mgr::Manager, candidate::PolySet)
  d, q, c = simulate_add_and_calculate_all(mgr, candidate)
  return (d, q, c)
end

@inline function _flat_mean(data_view)
    sum_val = 0.0
    count = 0
    for set in data_view
        for v in set
            sum_val += v
            count += 1
        end
    end
    count == 0 ? 0.0 : sum_val / count
end

function update_value_width!(mgr::Manager, upto_index::Int)
  mgr.scale_mode == :range_fixed && return

  last_idx = clamp(upto_index + 1, 1, length(mgr.data))
  context_data = @view mgr.data[1:last_idx]

  data_mean = _flat_mean(context_data)

  sum_lower = 0.0; count_lower = 0
  sum_upper = 0.0; count_upper = 0
  for set in context_data
      for v in set
          if v <= data_mean
              sum_lower += v
              count_lower += 1
          end
          if v >= data_mean
              sum_upper += v
              count_upper += 1
          end
      end
  end

  lower_half_average = count_lower == 0 ? 0.0 : sum_lower / count_lower
  upper_half_average = count_upper == 0 ? 0.0 : sum_upper / count_upper

  delta = abs(upper_half_average - lower_half_average)
  if mgr.scale_mode == :contextual_global_halves
    delta = max(delta, mgr.contextual_min_width)
  end
  mgr.value_width = delta <= 0.0 ? 1.0 : delta
end

# Incremental clustering core (polyphonic override)
@inline max_distance_for_length(len::Int)::Float64 = sqrt(float(max(len, 1)))

function clustering_subsequences_incremental!(mgr::Manager, data_index::Int)
  update_value_width!(mgr, data_index)

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

    # ★ここがポイント：距離関数の上限スケールに合わせる
    max_distance = max_distance_for_length(new_length)

    if !isempty(parent.cc)
      process_existing_clusters!(mgr, parent, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    else
      process_new_clusters!(mgr, parent, valid_si, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    end
  end

  # root（min_window_size）も同様
  root_max_distance = max_distance_for_length(mgr.min_window_size)
  process_root_clusters!(mgr, data_index, root_max_distance)
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
    new_cluster = _new_cluster_node([latest_start], deep_copy_seq(latest_seq))
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
    new_cluster = _new_cluster_node(starts, average_sequences(mgr, sequences))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJCcAdd(parent.cc, mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    if mgr.recency > 0.0
      add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_quantities, new_length, mgr.cluster_id_counter)
    end
    push!(mgr.tasks, (vcat(copy(keys_to_parent), [mgr.cluster_id_counter]), new_length))
    mgr.cluster_id_counter += 1
  else
    new_cluster = _new_cluster_node([latest_start], deep_copy_seq(latest_seq))
    parent.cc[mgr.cluster_id_counter] = new_cluster
    record!(mgr, PJCcAdd(parent.cc, mgr.cluster_id_counter))

    add_updated_id!(mgr.updated_cluster_ids_per_window_for_calculate_distance, new_length, mgr.cluster_id_counter)
    mgr.cluster_id_counter += 1
  end

  for s in invalid_group
    seq = deep_copy_seq(mgr.data[(s+1):(s+new_length)])
    new_cluster = _new_cluster_node([s], seq)
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
    new_cluster = _new_cluster_node([latest_start], deep_copy_seq(latest_seq))
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

update_caches_permanently(mgr::Manager) = update_caches_permanently!(mgr)

# Instance-style helper wrappers (argument order parity with Rails)
transform_clusters(mgr::Manager, clusters::Dict{Int,PolyClusterNode}, min_window_size::Int) =
  transform_clusters(clusters, min_window_size)

clusters_to_timeline(mgr::Manager, clusters::Dict{Int,PolyClusterNode}, min_window_size::Int) =
  clusters_to_timeline(clusters, min_window_size)

function cluster_to_dict(node::PolyClusterNode)
  Dict(
    "si" => sort(copy(node.si)),
    "as" => node.as,
    "cc" => Dict(string(cid) => cluster_to_dict(child) for (cid, child) in node.cc)
  )
end

function clusters_to_dict(clusters::Dict{Int,PolyClusterNode})
  Dict(string(cid) => cluster_to_dict(cl) for (cid, cl) in clusters)
end

end # module
