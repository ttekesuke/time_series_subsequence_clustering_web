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
  version::Int                        # increments whenever representative changes
end


"""Storage-independent logical reference used by the clustering write path.

The algorithm below must use these accessors instead of reading PolyClusterNode
fields directly.  The current implementation points at the legacy mutable tree;
a compressed-span reference can replace it without changing clustering logic.
"""
abstract type AbstractClusterRef end

struct TreeClusterRef <: AbstractClusterRef
  cluster_id::Int
  node::PolyClusterNode
end

@inline _cluster_id(ref::TreeClusterRef)::Int = ref.cluster_id
@inline _cluster_si(ref::TreeClusterRef)::Vector{Int} = ref.node.si
@inline _cluster_as(ref::TreeClusterRef)::PolySeq = ref.node.as
@inline _cluster_version(ref::TreeClusterRef)::Int = ref.node.version

# Legacy explicit-tree helpers remain available for frozen-oracle tests.
@inline _cluster_si(node::PolyClusterNode)::Vector{Int} = node.si
@inline _cluster_as(node::PolyClusterNode)::PolySeq = node.as
@inline _cluster_version(node::PolyClusterNode)::Int = node.version
@inline _cluster_has_children(ref::TreeClusterRef)::Bool = !isempty(ref.node.cc)

function _cluster_children(ref::TreeClusterRef)::Vector{TreeClusterRef}
  TreeClusterRef[
    TreeClusterRef(cid, ref.node.cc[cid])
    for cid in sort!(collect(keys(ref.node.cc)))
  ]
end

"""Incremental extension task.

The two distance fields are exact reusable state for the suffix occurrence that
created this task. They do not alter clustering semantics; if the referenced
representative changed before the task is consumed, the fast path is disabled.
"""
struct ClusterTask
  keys::Vector{Int}
  length::Int
  member_squared_distances::Dict{Int,Float64}
  representative_squared_distance::Float64
  representative_version::Int
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

abstract type PolyJournalEntry end

struct PJDataPush <: PolyJournalEntry end

struct PJSiPush <: PolyJournalEntry
  node::PolyClusterNode
end

struct PJAsUpdate <: PolyJournalEntry
  node::PolyClusterNode
  old_as::PolySeq
  old_version::Int
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

"""Lossless physical path-compressed cluster storage.

A span stores a chain of logical window nodes.  `si_min` and `as_max` hold
the heavy repeated data once; each logical node keeps only its id, version and
the historical fit limit needed to reconstruct its exact start indices even
after the time series later grows.
"""
mutable struct CompressedClusterSpan
  window_min::Int
  window_max::Int
  cluster_ids::Vector{Int}
  si_min::Vector{Int}
  as_max::PolySeq
  versions::Vector{Int}
  fit_limits::Vector{Int}
  children::Vector{CompressedClusterSpan}
end

"""Mutable logical reference into one virtual node of a compressed span."""
mutable struct SpanClusterRef <: AbstractClusterRef
  span::CompressedClusterSpan
  offset::Int
end

@inline _cluster_id(ref::SpanClusterRef)::Int = ref.span.cluster_ids[ref.offset]
@inline _cluster_window(ref::SpanClusterRef)::Int = ref.span.window_min + ref.offset - 1
@inline _cluster_version(ref::SpanClusterRef)::Int = ref.span.versions[ref.offset]

@inline function _cluster_si_count(ref::SpanClusterRef)::Int
  window_size = _cluster_window(ref)
  fit_limit = ref.span.fit_limits[ref.offset]
  # si_min is chronological, so the logical start set is always a prefix.
  return searchsortedlast(ref.span.si_min, fit_limit - window_size)
end

@inline function _cluster_si_view(ref::SpanClusterRef)
  count = _cluster_si_count(ref)
  return @view ref.span.si_min[1:count]
end

@inline function _cluster_si(ref::SpanClusterRef)::Vector{Int}
  return collect(_cluster_si_view(ref))
end

@inline function _cluster_as_view(ref::SpanClusterRef)
  window_size = _cluster_window(ref)
  return @view ref.span.as_max[1:window_size]
end

@inline function _cluster_as(ref::SpanClusterRef)::PolySeq
  return PolySet[copy(row) for row in _cluster_as_view(ref)]
end

@inline _cluster_si_view(ref::TreeClusterRef) = ref.node.si
@inline _cluster_as_view(ref::TreeClusterRef) = ref.node.as
@inline _cluster_si_count(ref::TreeClusterRef)::Int = length(ref.node.si)
@inline _cluster_si_view(node::PolyClusterNode) = node.si
@inline _cluster_as_view(node::PolyClusterNode) = node.as
@inline _cluster_si_count(node::PolyClusterNode)::Int = length(node.si)

# Read compatibility for callers that historically received PolyClusterNode
# values from collect_clusters_each().  The physical object remains a compact
# span reference; si/as are reconstructed only when that caller asks for them.
function Base.getproperty(ref::SpanClusterRef, name::Symbol)
  name === :si && return _cluster_si(ref)
  name === :as && return _cluster_as(ref)
  name === :version && return _cluster_version(ref)
  return getfield(ref, name)
end

function Base.propertynames(::SpanClusterRef, private::Bool=false)
  base = (:span, :offset, :si, :as, :version)
  return base
end

# Public logical accessors.  Production code outside this module should use
# these rather than depending on the physical compressed representation or
# compatibility getproperty hooks.
cluster_starts(ref::AbstractClusterRef)::Vector{Int} = collect(_cluster_si_view(ref))
cluster_representative(ref::AbstractClusterRef)::PolySeq = PolySet[copy(row) for row in _cluster_as_view(ref)]
cluster_version(ref::AbstractClusterRef)::Int = _cluster_version(ref)

@inline function _cluster_has_children(ref::SpanClusterRef)::Bool
  return ref.offset < length(ref.span.cluster_ids) || !isempty(ref.span.children)
end

function _cluster_children(ref::SpanClusterRef)::Vector{SpanClusterRef}
  if ref.offset < length(ref.span.cluster_ids)
    return SpanClusterRef[SpanClusterRef(ref.span, ref.offset + 1)]
  end
  return SpanClusterRef[
    SpanClusterRef(child, 1)
    for child in sort(copy(ref.span.children); by=child -> child.cluster_ids[1])
  ]
end

"""Rollback snapshot.

Cluster storage itself is path-compressed.  Simulation snapshots preserve the
root span vector so rollback restores the exact physical structure as well as
the exact logical result.
"""
struct PolySnapshot
  tasks::Vector{ClusterTask}
  cluster_id_counter::Int
  updated_dist_ids::Dict{Int,Set{Int}}
  updated_quant_ids::Dict{Int,Set{Int}}
  cluster_spans::Vector{CompressedClusterSpan}
  cluster_horizon::Int
end

"""Read-only logical node reconstructed from compressed storage."""
struct LogicalClusterView
  si::Vector{Int}
  as::PolySeq
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

  cluster_spans::Vector{CompressedClusterSpan} # canonical physical cluster storage
  cluster_horizon::Int # number of time points incorporated into cluster state
  cluster_id_counter::Int
  tasks::Vector{ClusterTask}

  updated_cluster_ids_per_window_for_calculate_distance::Dict{Int,Set{Int}}
  updated_cluster_ids_per_window_for_calculate_quantities::Dict{Int,Set{Int}}

  cluster_distance_cache::Dict{Int,Dict{Tuple{Int,Int},Float64}}
  cluster_quantity_cache::Dict{Int,Dict{Int,Float64}}
  cluster_complexity_cache::Dict{Int,Dict{Int,Float64}}

  recency::Float64
  enable_occurrence_intervals::Bool
  occurrence_interval_states::Dict{Tuple{Int,Int},OccurrenceIntervalState}

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
  return PolyClusterNode(starts, Dict{Int,PolyClusterNode}(), as, 0)
end


function _find_cluster_ref(
  mgr::Manager,
  keys::Vector{Int},
)::Union{Nothing,SpanClusterRef}
  isempty(keys) && return nothing

  spans = mgr.cluster_spans
  span::Union{Nothing,CompressedClusterSpan} = nothing
  offset = 0

  for (key_index, key) in enumerate(keys)
    if key_index == 1
      for candidate in spans
        if !isempty(candidate.cluster_ids) && candidate.cluster_ids[1] == key
          span = candidate
          offset = 1
          break
        end
      end
      span === nothing && return nothing
      continue
    end

    current = span::CompressedClusterSpan
    if offset < length(current.cluster_ids)
      current.cluster_ids[offset + 1] == key || return nothing
      offset += 1
      continue
    end

    next_span = nothing
    for child in current.children
      if !isempty(child.cluster_ids) && child.cluster_ids[1] == key
        next_span = child
        break
      end
    end
    next_span === nothing && return nothing
    span = next_span
    offset = 1
  end

  return SpanClusterRef(span::CompressedClusterSpan, offset)
end

function _root_cluster_refs(mgr::Manager)::Vector{SpanClusterRef}
  return SpanClusterRef[
    SpanClusterRef(span, 1)
    for span in sort(copy(mgr.cluster_spans); by=span -> span.cluster_ids[1])
  ]
end

@inline function _new_singleton_span(
  window_size::Int,
  cluster_id::Int,
  starts::Vector{Int},
  representative::PolySeq,
  version::Int,
  fit_limit::Int,
)::CompressedClusterSpan
  return CompressedClusterSpan(
    window_size,
    window_size,
    Int[cluster_id],
    copy(starts),
    deep_copy_seq(representative),
    Int[version],
    Int[fit_limit],
    CompressedClusterSpan[],
  )
end

function _find_span_container(
  roots::Vector{CompressedClusterSpan},
  target::CompressedClusterSpan,
)::Union{Nothing,Tuple{Vector{CompressedClusterSpan},Int}}
  for i in eachindex(roots)
    roots[i] === target && return (roots, i)
    nested = _find_span_container(roots[i].children, target)
    nested === nothing || return nested
  end
  return nothing
end

@inline function _span_starts_at(span::CompressedClusterSpan, offset::Int)::Vector{Int}
  window_size = span.window_min + offset - 1
  fit_limit = span.fit_limits[offset]
  return Int[s for s in span.si_min if s + window_size <= fit_limit]
end

function _slice_span(
  span::CompressedClusterSpan,
  first_offset::Int,
  last_offset::Int,
  children::Vector{CompressedClusterSpan},
)::CompressedClusterSpan
  window_min = span.window_min + first_offset - 1
  window_max = span.window_min + last_offset - 1
  starts = _span_starts_at(span, first_offset)
  return CompressedClusterSpan(
    window_min,
    window_max,
    copy(span.cluster_ids[first_offset:last_offset]),
    starts,
    deep_copy_seq(span.as_max[1:window_max]),
    copy(span.versions[first_offset:last_offset]),
    copy(span.fit_limits[first_offset:last_offset]),
    children,
  )
end

"""Split a physical span so `ref` becomes a one-node span.

The logical node is unchanged.  This is the only structural operation required
before mutating one virtual node; unchanged prefix/suffix pieces remain
compressed and are eligible for lossless re-merge after the committed step.
"""
function _isolate_cluster_ref!(
  mgr::Manager,
  ref::SpanClusterRef,
)::SpanClusterRef
  span = ref.span
  n = length(span.cluster_ids)
  n == 1 && return ref

  offset = ref.offset
  found = _find_span_container(mgr.cluster_spans, span)
  found === nothing && error("Compressed cluster span is detached from manager storage.")
  container, container_index = found

  original_children = span.children
  current = _slice_span(span, offset, offset, CompressedClusterSpan[])

  if offset < n
    suffix = _slice_span(span, offset + 1, n, original_children)
    current.children = CompressedClusterSpan[suffix]
  else
    current.children = original_children
  end

  replacement = current
  if offset > 1
    prefix = _slice_span(span, 1, offset - 1, CompressedClusterSpan[current])
    replacement = prefix
  end

  container[container_index] = replacement
  ref.span = current
  ref.offset = 1
  return ref
end

function _append_cluster_start!(mgr::Manager, ref::SpanClusterRef, start::Int)::Nothing
  span = ref.span
  offset = ref.offset
  window_size = _cluster_window(ref)

  # A longer virtual window often receives a start that is already present in
  # the shortest node's shared si_min. In that case no span split is required:
  # advancing this virtual node's historical fit limit may reveal the new
  # occurrence. Take the fast path only when the resulting logical starts are
  # *exactly* legacy's old starts plus this one start.
  if offset > 1 && start in span.si_min
    current_starts = _span_starts_at(span, offset)
    candidate_limit = max(span.fit_limits[offset], mgr.cluster_horizon)
    candidate_starts = Int[
      s for s in span.si_min
      if s + window_size <= candidate_limit
    ]
    expected_starts = vcat(current_starts, Int[start])
    if candidate_starts == expected_starts
      fit_limits = copy(span.fit_limits)
      fit_limits[offset] = candidate_limit
      span.fit_limits = fit_limits
      return nothing
    end
  end

  # The first virtual node owns si_min. Copy-on-write append keeps simulation
  # snapshots safe, while longer nodes remain unchanged behind their own fit
  # limits until they independently match.
  if offset == 1
    span.si_min = vcat(span.si_min, Int[start])
    fit_limits = copy(span.fit_limits)
    fit_limits[1] = max(fit_limits[1], mgr.cluster_horizon)
    span.fit_limits = fit_limits
    return nothing
  end

  # Genuine non-prefix divergence: isolate only this logical node and preserve
  # the exact legacy tree semantics.
  _isolate_cluster_ref!(mgr, ref)
  ref.span.si_min = vcat(ref.span.si_min, Int[start])
  fit_limits = copy(ref.span.fit_limits)
  fit_limits[1] = max(fit_limits[1], mgr.cluster_horizon)
  ref.span.fit_limits = fit_limits
  return nothing
end

function _replace_cluster_representative!(
  mgr::Manager,
  ref::SpanClusterRef,
  representative::PolySeq,
)::Nothing
  _isolate_cluster_ref!(mgr, ref)
  ref.span.as_max = deep_copy_seq(representative)
  versions = copy(ref.span.versions)
  versions[1] += 1
  ref.span.versions = versions
  return nothing
end

function _add_child_cluster!(
  mgr::Manager,
  parent::SpanClusterRef,
  cluster_id::Int,
  starts::Vector{Int},
  representative::PolySeq,
)::SpanClusterRef
  # A node can acquire a new explicit child without splitting only when it is
  # already the end of its compressed span. A middle virtual node has the
  # implicit next node as its child and therefore must be isolated first.
  if parent.offset < length(parent.span.cluster_ids)
    _isolate_cluster_ref!(mgr, parent)
  end
  child = _new_singleton_span(
    _cluster_window(parent) + 1,
    cluster_id,
    starts,
    representative,
    0,
    mgr.cluster_horizon,
  )
  push!(parent.span.children, child)
  sort!(parent.span.children; by=span -> span.cluster_ids[1])
  return SpanClusterRef(child, 1)
end

function _add_root_cluster!(
  mgr::Manager,
  cluster_id::Int,
  starts::Vector{Int},
  representative::PolySeq,
)::SpanClusterRef
  root = _new_singleton_span(
    mgr.min_window_size,
    cluster_id,
    starts,
    representative,
    0,
    mgr.cluster_horizon,
  )
  push!(mgr.cluster_spans, root)
  sort!(mgr.cluster_spans; by=span -> span.cluster_ids[1])
  return SpanClusterRef(root, 1)
end

function _span_extends_representative_exactly(
  parent::CompressedClusterSpan,
  child::CompressedClusterSpan,
)::Bool
  length(child.as_max) >= length(parent.as_max) || return false
  @inbounds for i in eachindex(parent.as_max)
    parent.as_max[i] == child.as_max[i] || return false
  end
  return true
end

function _can_merge_spans(
  parent::CompressedClusterSpan,
  child::CompressedClusterSpan,
)::Bool
  parent.window_max + 1 == child.window_min || return false
  _span_extends_representative_exactly(parent, child) || return false

  # Every child virtual node must remain exactly reconstructable from the
  # parent's first start set with that node's own historical fit limit.
  for child_offset in eachindex(child.cluster_ids)
    window_size = child.window_min + child_offset - 1
    fit_limit = child.fit_limits[child_offset]
    expected = sort(Int[
      s for s in parent.si_min
      if s + window_size <= fit_limit
    ])
    actual = sort(_span_starts_at(child, child_offset))
    expected == actual || return false
  end
  return true
end

function _normalize_span!(span::CompressedClusterSpan)::Nothing
  for child in span.children
    _normalize_span!(child)
  end
  sort!(span.children; by=child -> child.cluster_ids[1])

  while length(span.children) == 1
    child = span.children[1]
    _can_merge_spans(span, child) || break
    span.window_max = child.window_max
    append!(span.cluster_ids, child.cluster_ids)
    append!(span.versions, child.versions)
    append!(span.fit_limits, child.fit_limits)
    span.as_max = deep_copy_seq(child.as_max)
    span.children = child.children
    sort!(span.children; by=grandchild -> grandchild.cluster_ids[1])
  end
  return nothing
end

function _normalize_cluster_store!(mgr::Manager)::Nothing
  for span in mgr.cluster_spans
    _normalize_span!(span)
  end
  sort!(mgr.cluster_spans; by=span -> span.cluster_ids[1])
  return nothing
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

  # A root represents the first real min-window subsequence. Short inputs
  # have no such subsequence and therefore start with an empty compressed store.
  has_root = length(data) >= min_window_size
  cluster_spans = CompressedClusterSpan[]
  if has_root
    seed_as = deep_copy_seq(data[1:min_window_size])
    push!(cluster_spans, _new_singleton_span(
      min_window_size,
      0,
      Int[0],
      seed_as,
      0,
      min(length(data), min_window_size),
    ))
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
    cluster_spans,
    min(length(data), min_window_size),
    cluster_id_counter,
    ClusterTask[],
    updated_dist,
    updated_qty,
    dist_cache,
    qty_cache,
    comp_cache,
    clamp(float(recency), 0.0, 1.0),
    Bool(enable_occurrence_intervals),
    Dict{Tuple{Int,Int},OccurrenceIntervalState}(),
    false,
    PolyJournalEntry[],
    nothing
  )
end

function _initialize_root_cluster_if_ready!(mgr::Manager)::Bool
  !isempty(mgr.cluster_spans) && return false
  length(mgr.data) >= mgr.min_window_size || return false
  seed_as = deep_copy_seq(mgr.data[1:mgr.min_window_size])
  push!(mgr.cluster_spans, _new_singleton_span(
    mgr.min_window_size,
    0,
    Int[0],
    seed_as,
    0,
    mgr.min_window_size,
  ))
  mgr.cluster_horizon = mgr.min_window_size
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
function squared_euclidean_distance(mgr::Manager, seq_a::AbstractVector{<:PolySet}, seq_b::AbstractVector{<:PolySet})::Float64
  len = min(length(seq_a), length(seq_b))
  s = 0.0
  @inbounds for i in 1:len
    d = min_avg_distance(mgr, seq_a[i], seq_b[i])
    s += d * d
  end
  return s
end

"""Euclidean distance between two sequences."""
euclidean_distance(mgr::Manager, seq_a::AbstractVector{<:PolySet}, seq_b::AbstractVector{<:PolySet})::Float64 = sqrt(squared_euclidean_distance(mgr, seq_a, seq_b))

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
  isempty(mgr.cluster_spans) && return nothing
  for i in 1:length(mgr.data)
    data_index = i - 1
    if data_index <= mgr.min_window_size - 1
      continue
    end
    mgr.cluster_horizon = data_index + 1
    clustering_subsequences_incremental!(mgr, data_index)
    _normalize_cluster_store!(mgr)
  end
  return nothing
end

function add_data_point_permanently!(mgr::Manager, val::PolySet)
  push!(mgr.data, val)
  length(mgr.data) < mgr.min_window_size && return nothing
  _initialize_root_cluster_if_ready!(mgr) && return nothing
  mgr.cluster_horizon = length(mgr.data)
  clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
  _normalize_cluster_store!(mgr)
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

@inline function cluster_last_occurrence(node::AbstractClusterRef)::Int
  starts = _cluster_si_view(node)
  isempty(starts) && return 0
  return starts[end]
end

@inline function cluster_recency_weight(mgr::Manager, node, now_index::Int)::Float64
  return recency_weight(mgr, now_index, cluster_last_occurrence(node))
end

function recent_quantity_score(mgr::Manager, node, window_size::Int, now_index::Int)::Float64
  total = 0.0
  @inbounds for s in _cluster_si_view(node)
    total += recency_weight(mgr, now_index, s)
  end
  return total * float(window_size)
end

function weighted_distance_score(
  mgr::Manager,
  cache::Dict{Tuple{Int,Int},Float64},
  same_ws,
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

function weighted_quantity_score(mgr::Manager, same_ws, window_size::Int, now_index::Int)::Float64
  total = 0.0
  for (_, node) in same_ws
    _cluster_si_count(node) <= 1 && continue
    total += recent_quantity_score(mgr, node, window_size, now_index)
  end
  return total
end

function weighted_complexity_score(
  mgr::Manager,
  c_cache::Dict{Int,Float64},
  same_ws,
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

function update_caches_permanently!(
  mgr::Manager;
  sync_occurrence::Bool=true,
  clear_updated::Bool=true,
)
  # Cache writes are incremental. Materialize logical refs only for window
  # sizes that actually changed on this append instead of expanding the full
  # compressed cluster store.
  touched_windows = union(
    Set(keys(mgr.updated_cluster_ids_per_window_for_calculate_distance)),
    Set(keys(mgr.updated_cluster_ids_per_window_for_calculate_quantities)),
  )
  clusters_each = collect_clusters_each(mgr, touched_windows)

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
          cache[key] = euclidean_distance(mgr, _cluster_as_view(node1), _cluster_as_view(node2))
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
          cache[key] = euclidean_distance(mgr, _cluster_as_view(node1), _cluster_as_view(node2))
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
        _cluster_si_count(node) <= 1 && continue

        q = cluster_quantity_score(_cluster_si_count(node), window_size)
        q_cache[cid] = q
        c_cache[cid] = calculate_cluster_complexity(mgr, _cluster_as_view(node))
      end
    elseif updated_quant_set !== nothing && !isempty(updated_quant_set)
      for cid in updated_quant_set
        node = get(same_ws, cid, nothing)
        node === nothing && continue
        _cluster_si_count(node) > 1 || continue

        q = cluster_quantity_score(_cluster_si_count(node), window_size)
        q_cache[cid] = q
        c_cache[cid] = calculate_cluster_complexity(mgr, _cluster_as_view(node))
      end
    end
  end

  if sync_occurrence && mgr.enable_occurrence_intervals
    now_index = length(mgr.data) - 1
    for (window_size, cluster_id, node) in _selected_latest_occurrence_targets(clusters_each, now_index)
      _sync_occurrence_interval_state!(mgr, window_size, cluster_id, node)
    end
  end

  if clear_updated
    # reset updated ids (Rails behavior)
    empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
    empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
  end
  return clusters_each
end

# Cluster complexity

# Typed overloads used in the hot path (avoid Dict{String,Any} allocations)
@inline function calculate_cluster_complexity(mgr::Manager, seq::AbstractVector{<:PolySet})::Float64
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

function _snapshot_cluster_span(span::CompressedClusterSpan)::CompressedClusterSpan
  # Snapshot only the small span topology. Heavy payload arrays are shared
  # read-only; speculative writes replace their arrays copy-on-write.
  return CompressedClusterSpan(
    span.window_min,
    span.window_max,
    span.cluster_ids,
    span.si_min,
    span.as_max,
    span.versions,
    span.fit_limits,
    CompressedClusterSpan[_snapshot_cluster_span(child) for child in span.children],
  )
end

function _snapshot_cluster_spans(
  spans::Vector{CompressedClusterSpan},
)::Vector{CompressedClusterSpan}
  return CompressedClusterSpan[_snapshot_cluster_span(span) for span in spans]
end

function start_transaction!(mgr::Manager)
  mgr.recording_mode = true
  empty!(mgr.journal)

  # Keep rollback independent from simulation-owned task dictionaries.
  snapshot_tasks = ClusterTask[
    ClusterTask(
      copy(t.keys),
      t.length,
      copy(t.member_squared_distances),
      t.representative_squared_distance,
      t.representative_version,
    )
    for t in mgr.tasks
  ]

  mgr.snapshot_state = PolySnapshot(
    snapshot_tasks,
    mgr.cluster_id_counter,
    deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_distance),
    deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_quantities),
    _snapshot_cluster_spans(mgr.cluster_spans),
    mgr.cluster_horizon,
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
    mgr.cluster_spans = mgr.snapshot_state.cluster_spans
    mgr.cluster_horizon = mgr.snapshot_state.cluster_horizon
  end

  mgr.recording_mode = false
  empty!(mgr.journal)
  mgr.snapshot_state = nothing
end

"""Return window-indexed logical clusters reconstructed from compressed storage.

Production callers must use this read view instead of the mutable working tree.
"""
function collect_clusters_each(
  mgr::Manager,
  requested_windows::AbstractSet{Int},
)::Dict{Int,Dict{Int,SpanClusterRef}}
  clusters_each = Dict{Int,Dict{Int,SpanClusterRef}}()
  isempty(requested_windows) && return clusters_each

  requested = sort!(collect(requested_windows))
  stack = CompressedClusterSpan[reverse(mgr.cluster_spans)...]

  while !isempty(stack)
    span = pop!(stack)
    lo = searchsortedfirst(requested, span.window_min)
    hi = searchsortedlast(requested, span.window_max)
    if lo <= hi
      for request_index in lo:hi
        window_size = requested[request_index]
        offset = window_size - span.window_min + 1
        cluster_id = span.cluster_ids[offset]
        same_ws = get!(clusters_each, window_size, Dict{Int,SpanClusterRef}())
        same_ws[cluster_id] = SpanClusterRef(span, offset)
      end
    end
    for child in reverse(span.children)
      push!(stack, child)
    end
  end

  return clusters_each
end

function collect_clusters_each(mgr::Manager)::Dict{Int,Dict{Int,SpanClusterRef}}
  # Hot-path index over the canonical compressed store. Values are lightweight
  # references into physical spans; no si/as payload is copied here.
  clusters_each = Dict{Int,Dict{Int,SpanClusterRef}}()
  stack = CompressedClusterSpan[reverse(mgr.cluster_spans)...]

  while !isempty(stack)
    span = pop!(stack)
    for offset in eachindex(span.cluster_ids)
      window_size = span.window_min + offset - 1
      cluster_id = span.cluster_ids[offset]
      same_ws = get!(clusters_each, window_size, Dict{Int,SpanClusterRef}())
      same_ws[cluster_id] = SpanClusterRef(span, offset)
    end
    for child in reverse(span.children)
      push!(stack, child)
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

  max_context = min(
    data_length - 1,
    max(Config.PREDICTIVE_MAX_CONTEXT_LENGTH, mgr.min_window_size),
  )
  clusters_each = collect_clusters_each(
    mgr,
    Set(mgr.min_window_size:max_context),
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
      if latest_start in _cluster_si_view(node)
        target = node
        break
      end
    end
    target === nothing && continue

    historical_starts = sort!(unique(Int[
      start for start in _cluster_si_view(target)
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
  clusters_each;
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
          _cluster_si_count(node) == 1 || continue
          sum_complexities += calculate_cluster_complexity(mgr, _cluster_as_view(node))
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
          _cluster_si_count(node) == 1 || continue
          w = cluster_recency_weight(mgr, node, now_index)
          singleton_sum += calculate_cluster_complexity(mgr, _cluster_as_view(node)) * w
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

function _sync_occurrence_interval_state!(
  mgr::Manager,
  window_size::Int,
  cluster_id::Int,
  node,
)::Nothing
  starts = sort!(unique(collect(_cluster_si_view(node))))
  occurrence_count = length(starts)
  occurrence_count >= 2 || return nothing

  state_key = (window_size, cluster_id)
  existing = get(mgr.occurrence_interval_states, state_key, nothing)
  gaps = _occurrence_gaps(starts)

  if occurrence_count < Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES
    if existing === nothing
      mgr.occurrence_interval_states[state_key] =
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
    mgr.occurrence_interval_states[state_key] =
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
  window_size::Int,
  cluster_id::Int,
  node,
)::OccurrenceIntervalMetrics
  starts = sort!(unique(collect(_cluster_si_view(node))))
  occurrence_count = length(starts)
  occurrence_count < Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES &&
    return EMPTY_OCCURRENCE_INTERVAL_METRICS

  committed_count = occurrence_count - 1
  state = get(mgr.occurrence_interval_states, (window_size, cluster_id), nothing)
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
  clusters_each,
  now_index::Int,
)
  targets = Tuple{Int,Int,Any}[]
  for (window_size, same_ws) in clusters_each
    latest_start = now_index - window_size + 1
    latest_start < 0 && continue
    for (cluster_id, node) in same_ws
      latest_start in _cluster_si_view(node) || continue
      _cluster_si_count(node) >= Config.OCCURRENCE_INTERVAL_MIN_OCCURRENCES &&
        push!(targets, (window_size, cluster_id, node))
      break
    end
  end
  isempty(targets) && return targets
  sort!(targets; by=x -> x[1])

  max_scales = max(Config.OCCURRENCE_INTERVAL_MAX_BASE_SCALES, 1)
  if length(targets) > max_scales
    selected = Tuple{Int,Int,Any}[]
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
  clusters_each,
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

  for (window_size, cluster_id, target) in targets
    temporal = _preview_occurrence_interval_metrics(mgr, window_size, cluster_id, target)
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
  clusters_each,
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

  for (_, _, target) in targets
    temporal = _occurrence_interval_metrics_for_starts(
      collect(_cluster_si_view(target)),
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

"""Return the extended metrics for the manager's already-committed current state.

The caller must have updated the permanent caches after the latest append.  This
is the observed-data counterpart of simulate_add_and_calculate_all_extended:
it avoids a transactional append/rollback when the next value is already known
and has been permanently committed.
"""
function calculate_all_extended_current_state(mgr::Manager)::ExtendedClusterMetrics
  clusters_each = collect_clusters_each(mgr)
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
    else
      if !isempty(cache)
        sum_distances += weighted_distance_score(mgr, cache, same_ws, now_index)
      end
      sum_quantities += weighted_quantity_score(mgr, same_ws, window_size, now_index)
      if !isempty(c_cache)
        sum_complexities += weighted_complexity_score(mgr, c_cache, same_ws, now_index)
      end
    end
  end

  occurrence_intervals =
    if mgr.enable_occurrence_intervals
      latest_occurrence_interval_metrics(mgr, clusters_each, now_index)
    else
      EMPTY_OCCURRENCE_INTERVAL_METRICS
    end

  return ExtendedClusterMetrics(
    sum_distances,
    sum_quantities,
    sum_complexities,
    occurrence_intervals,
  )
end

"""Append a known observed value once and return the same candidate metrics that
`simulate_add_and_calculate_all_extended` would have returned before rollback.

This is for analysis of already-observed series. It avoids clustering the same
value once speculatively and again permanently. Occurrence metrics are previewed
against the pre-append occurrence state, then that state is advanced only after
the metric snapshot has been taken.
"""
function add_and_calculate_all_extended_permanently!(
  mgr::Manager,
  value::PolySet,
)::ExtendedClusterMetrics
  add_data_point_permanently!(mgr, value)

  updated_clusters_each = update_caches_permanently!(
    mgr;
    sync_occurrence=false,
    clear_updated=false,
  )

  sum_distances = 0.0
  sum_quantities = 0.0
  sum_complexities = 0.0

  if mgr.recency <= 0.0
    for (window_size, cache) in mgr.cluster_distance_cache
      isempty(cache) || (sum_distances += sum(values(cache)) / float(window_size))
    end
    for (_, cache) in mgr.cluster_quantity_cache
      isempty(cache) || (sum_quantities += sum(values(cache)))
    end
    for (_, cache) in mgr.cluster_complexity_cache
      isempty(cache) || (sum_complexities += sum(values(cache)))
    end
  else
    clusters_each = collect_clusters_each(mgr)
    now_index = length(mgr.data) - 1
    for (window_size, same_ws) in clusters_each
      d_cache = get(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
      c_cache = get(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())
      isempty(d_cache) || (
        sum_distances += weighted_distance_score(mgr, d_cache, same_ws, now_index)
      )
      sum_quantities += weighted_quantity_score(mgr, same_ws, window_size, now_index)
      isempty(c_cache) || (
        sum_complexities += weighted_complexity_score(mgr, c_cache, same_ws, now_index)
      )
    end
  end

  now_index = length(mgr.data) - 1
  occurrence_intervals =
    if mgr.enable_occurrence_intervals
      latest_occurrence_interval_metrics(mgr, updated_clusters_each, now_index)
    else
      EMPTY_OCCURRENCE_INTERVAL_METRICS
    end

  if mgr.enable_occurrence_intervals
    for (window_size, cluster_id, node) in
        _selected_latest_occurrence_targets(updated_clusters_each, now_index)
      _sync_occurrence_interval_state!(mgr, window_size, cluster_id, node)
    end
  end

  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_quantities)

  return ExtendedClusterMetrics(
    sum_distances,
    sum_quantities,
    sum_complexities,
    occurrence_intervals,
  )
end

function simulate_add_and_calculate_all_extended(mgr::Manager, candidate::PolySet)::ExtendedClusterMetrics
  start_transaction!(mgr)
  reset_updated_ids_for_simulation!(mgr)

  # NOTE: This function is on the hottest path (called for every candidate).
  # Avoid JSON-facing transforms (Dict{String,Any}) here; we traverse typed nodes directly.

  try
    push!(mgr.data, candidate)
    record!(mgr, PJDataPush())
    mgr.cluster_horizon = length(mgr.data)

    clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)
    touched_windows = union(
      Set(keys(mgr.updated_cluster_ids_per_window_for_calculate_distance)),
      Set(keys(mgr.updated_cluster_ids_per_window_for_calculate_quantities)),
    )
    updated_clusters_each = collect_clusters_each(mgr, touched_windows)

    sum_distances = 0.0
    sum_quantities = 0.0
    sum_complexities = 0.0

    for (window_size, same_ws) in updated_clusters_each
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
          dist = euclidean_distance(mgr, _cluster_as_view(node1), _cluster_as_view(node2))
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
        _cluster_si_count(node) > 1 || continue

        q = cluster_quantity_score(_cluster_si_count(node), window_size)

        old_q = haskey(q_cache, cid) ? q_cache[cid] : nothing
        q_cache[cid] = q
        record!(mgr, PJCacheWriteQty(q_cache, cid, old_q))

        comp = calculate_cluster_complexity(mgr, _cluster_as_view(node))
        old_c = haskey(c_cache, cid) ? c_cache[cid] : nothing
        c_cache[cid] = comp
        record!(mgr, PJCacheWriteComp(c_cache, cid, old_c))
      end

    end

    if mgr.recency <= 0.0
      for (window_size, cache) in mgr.cluster_distance_cache
        isempty(cache) || (sum_distances += sum(values(cache)) / float(window_size))
      end
      for (_, cache) in mgr.cluster_quantity_cache
        isempty(cache) || (sum_quantities += sum(values(cache)))
      end
      for (_, cache) in mgr.cluster_complexity_cache
        isempty(cache) || (sum_complexities += sum(values(cache)))
      end
    else
      # Recency weighting depends on cluster start positions, so preserve the
      # full logical view only for recency-enabled managers.
      clusters_each = collect_clusters_each(mgr)
      now_index = length(mgr.data) - 1
      for (window_size, same_ws) in clusters_each
        cache = get(mgr.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
        q_cache = get(mgr.cluster_quantity_cache, window_size, Dict{Int,Float64}())
        c_cache = get(mgr.cluster_complexity_cache, window_size, Dict{Int,Float64}())
        isempty(cache) || (sum_distances += weighted_distance_score(mgr, cache, same_ws, now_index))
        sum_quantities += weighted_quantity_score(mgr, same_ws, window_size, now_index)
        isempty(c_cache) || (sum_complexities += weighted_complexity_score(mgr, c_cache, same_ws, now_index))
      end
    end

    occurrence_intervals =
      if mgr.enable_occurrence_intervals
        latest_occurrence_interval_metrics(mgr, updated_clusters_each, length(mgr.data) - 1)
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

# ------------------------------------------------------------------
# Lossless path-compressed cluster view
#
# A span may collapse only a single-child chain when extending the parent
# loses no occurrence except those that cannot fit at the right boundary of
# the currently available data, and the child representative extends the
# parent representative exactly. Every virtual window node remains exactly
# reconstructable.
# ------------------------------------------------------------------


@inline function _representative_extends_exactly(
  parent::PolyClusterNode,
  child::PolyClusterNode,
)::Bool
  length(child.as) == length(parent.as) + 1 || return false
  @inbounds for i in eachindex(parent.as)
    parent.as[i] == child.as[i] || return false
  end
  return true
end

function _starts_extend_without_semantic_loss(
  parent::PolyClusterNode,
  child::PolyClusterNode,
  child_window_size::Int,
  data_length::Int,
)::Bool
  expected = Int[
    s for s in parent.si
    if s + child_window_size <= data_length
  ]
  sort!(expected)
  actual = sort(copy(child.si))
  return expected == actual
end

function _compress_cluster_span(
  cluster_id::Int,
  node::PolyClusterNode,
  window_size::Int,
  data_length::Int,
)::CompressedClusterSpan
  ids = Int[cluster_id]
  versions = Int[node.version]
  first_starts = copy(_cluster_si(node))
  current = node
  current_window = window_size

  while length(current.cc) == 1
    child_id, child = first(current.cc)
    _starts_extend_without_semantic_loss(
      current,
      child,
      current_window + 1,
      data_length,
    ) || break
    _representative_extends_exactly(current, child) || break
    push!(ids, child_id)
    push!(versions, child.version)
    current = child
    current_window += 1
  end

  children = CompressedClusterSpan[]
  for child_id in sort!(collect(keys(current.cc)))
    push!(children, _compress_cluster_span(
      child_id,
      current.cc[child_id],
      current_window + 1,
      data_length,
    ))
  end

  return CompressedClusterSpan(
    window_size,
    current_window,
    ids,
    first_starts,
    deep_copy_seq(current.as),
    versions,
    fill(data_length, length(ids)),
    children,
  )
end

"""Legacy-tree adapter kept only for oracle/backward-compatibility tests."""
function compress_cluster_tree(
  clusters::Dict{Int,PolyClusterNode},
  min_window_size::Int,
  data_length::Int,
)::Vector{CompressedClusterSpan}
  spans = CompressedClusterSpan[]
  for cluster_id in sort!(collect(keys(clusters)))
    push!(spans, _compress_cluster_span(
      cluster_id,
      clusters[cluster_id],
      min_window_size,
      data_length,
    ))
  end
  return spans
end

"""Return the canonical physical cluster storage."""
compress_cluster_tree(mgr::Manager)::Vector{CompressedClusterSpan} = mgr.cluster_spans

function compressed_virtual_nodes(
  spans::Vector{CompressedClusterSpan},
)::Vector{NamedTuple}
  rows = NamedTuple[]
  stack = Tuple{CompressedClusterSpan,Union{Nothing,Int}}[
    (span, nothing) for span in reverse(spans)
  ]

  while !isempty(stack)
    span, parent_id = pop!(stack)
    previous_id = parent_id
    for (offset, cluster_id) in enumerate(span.cluster_ids)
      window_size = span.window_min + offset - 1
      representative = deep_copy_seq(span.as_max[1:window_size])
      fit_limit = span.fit_limits[offset]
      starts = sort(Int[
        s for s in span.si_min
        if s + window_size <= fit_limit
      ])
      push!(rows, (
        window_size=window_size,
        cluster_id=cluster_id,
        parent_id=previous_id,
        si=starts,
        as=representative,
      ))
      previous_id = cluster_id
    end
    for child in reverse(span.children)
      push!(stack, (child, previous_id))
    end
  end

  sort!(rows; by=row -> (row.window_size, row.cluster_id))
  return rows
end

function logical_virtual_nodes(
  clusters::Dict{Int,PolyClusterNode},
  min_window_size::Int,
)::Vector{NamedTuple}
  rows = NamedTuple[]
  stack = Tuple{Int,Int,PolyClusterNode,Union{Nothing,Int}}[]
  for cluster_id in sort!(collect(keys(clusters)); rev=true)
    push!(stack, (min_window_size, cluster_id, clusters[cluster_id], nothing))
  end

  while !isempty(stack)
    window_size, cluster_id, node, parent_id = pop!(stack)
    push!(rows, (
      window_size=window_size,
      cluster_id=cluster_id,
      parent_id=parent_id,
      si=sort(copy(_cluster_si(node))),
      as=deep_copy_seq(node.as),
    ))
    for child_id in sort!(collect(keys(node.cc)); rev=true)
      push!(stack, (window_size + 1, child_id, node.cc[child_id], cluster_id))
    end
  end

  sort!(rows; by=row -> (row.window_size, row.cluster_id))
  return rows
end

# Incremental clustering core (polyphonic override)
@inline max_distance_for_length(len::Int)::Float64 = sqrt(float(max(len, 1)))

function _extend_task_member_squared_distances(
  mgr::Manager,
  task::ClusterTask,
  valid_si::Vector{Int},
  latest_seq::PolySeq,
  latest_start::Int,
  new_length::Int,
)::Dict{Int,Float64}
  result = Dict{Int,Float64}()
  isempty(valid_si) && return result

  parent_length = task.length
  latest_parent = latest_seq[1:parent_length]
  latest_last = latest_seq[end]

  for s in valid_si
    previous = get(task.member_squared_distances, s, NaN)
    if !isfinite(previous)
      previous_seq = mgr.data[(s + 1):(s + parent_length)]
      previous = squared_euclidean_distance(mgr, previous_seq, latest_parent)
    end

    historical_last = mgr.data[s + new_length]
    d = min_avg_distance(mgr, historical_last, latest_last)
    result[s] = previous + d * d
  end
  return result
end

function _member_squared_distances_for_node(
  mgr::Manager,
  node::AbstractClusterRef,
  latest_seq::PolySeq,
  latest_start::Int,
  window_size::Int,
)::Dict{Int,Float64}
  result = Dict{Int,Float64}()
  for s in _cluster_si_view(node)
    s == latest_start && continue
    s + window_size <= length(mgr.data) || continue
    seq = mgr.data[(s + 1):(s + window_size)]
    result[s] = squared_euclidean_distance(mgr, seq, latest_seq)
  end
  return result
end

@inline function _can_extend_representative_distance(
  task::ClusterTask,
  parent::AbstractClusterRef,
  child::AbstractClusterRef,
)::Bool
  parent_as = _cluster_as_view(parent)
  child_as = _cluster_as_view(child)
  length(child_as) == length(parent_as) + 1 || return false
  task.representative_version == _cluster_version(parent) || return false
  @inbounds for i in eachindex(parent_as)
    parent_as[i] == child_as[i] || return false
  end
  return true
end

function _extended_representative_squared_distance(
  mgr::Manager,
  task::ClusterTask,
  parent::AbstractClusterRef,
  child::AbstractClusterRef,
  latest_seq::PolySeq,
)::Float64
  if _can_extend_representative_distance(task, parent, child)
    d = min_avg_distance(mgr, _cluster_as(child)[end], latest_seq[end])
    return task.representative_squared_distance + d * d
  end
  return squared_euclidean_distance(mgr, _cluster_as(child), latest_seq)
end

function _task_member_subset(
  mgr::Manager,
  node::AbstractClusterRef,
  extended_member_distances::Dict{Int,Float64},
  latest_seq::PolySeq,
  latest_start::Int,
  window_size::Int,
)::Dict{Int,Float64}
  result = Dict{Int,Float64}()
  for s in _cluster_si_view(node)
    s == latest_start && continue
    value = get(extended_member_distances, s, NaN)
    if !isfinite(value)
      seq = mgr.data[(s + 1):(s + window_size)]
      value = squared_euclidean_distance(mgr, seq, latest_seq)
    end
    result[s] = value
  end
  return result
end

function clustering_subsequences_incremental!(mgr::Manager, data_index::Int)
  update_value_width!(mgr, data_index)

  current_tasks = copy(mgr.tasks)
  empty!(mgr.tasks)

  for task in current_tasks
    keys_to_parent = copy(task.keys)
    length0 = task.length
    parent = _find_cluster_ref(mgr, keys_to_parent)
    parent === nothing && continue

    new_length = length0 + 1
    latest_start = data_index - new_length + 1
    latest_start < 0 && continue

    latest_seq = mgr.data[(latest_start + 1):(latest_start + new_length)]
    valid_si = Int[
      s for s in _cluster_si_view(parent)
      if (s + new_length <= data_index + 1) && (s != latest_start)
    ]
    isempty(valid_si) && continue

    max_distance = max_distance_for_length(new_length)

    if _cluster_has_children(parent)
      process_existing_clusters!(
        mgr,
        parent,
        valid_si,
        latest_seq,
        max_distance,
        latest_start,
        new_length,
        keys_to_parent,
        task,
      )
    else
      process_new_clusters!(
        mgr,
        parent,
        valid_si,
        latest_seq,
        max_distance,
        latest_start,
        new_length,
        keys_to_parent,
        task,
      )
    end
  end

  root_max_distance = max_distance_for_length(mgr.min_window_size)
  process_root_clusters!(mgr, data_index, root_max_distance)
end


function process_existing_clusters!(
  mgr::Manager,
  parent::AbstractClusterRef,
  valid_si::Vector{Int},
  latest_seq::PolySeq,
  max_distance::Float64,
  latest_start::Int,
  new_length::Int,
  keys_to_parent::Vector{Int},
  task::ClusterTask,
)
  extended_member_distances = _extend_task_member_squared_distances(
    mgr,
    task,
    valid_si,
    latest_seq,
    latest_start,
    new_length,
  )

  best_cluster_id = -1
  best_child::Union{Nothing,AbstractClusterRef} = nothing
  min_distance = Inf

  for child in _cluster_children(parent)
    cluster_id = _cluster_id(child)
    squared_distance = _extended_representative_squared_distance(
      mgr,
      task,
      parent,
      child,
      latest_seq,
    )
    distance = sqrt(squared_distance)

    if distance < min_distance ||
       (distance == min_distance && (best_cluster_id < 0 || cluster_id < best_cluster_id))
      min_distance = distance
      best_child = child
      best_cluster_id = cluster_id
    end
  end

  ratio = max_distance == 0.0 ? 0.0 : (min_distance / max_distance)

  if best_child !== nothing && ratio <= mgr.merge_threshold_ratio
    _append_cluster_start!(mgr, best_child, latest_start)

    # Adding the current representative itself cannot change the representative:
    # arithmetic means stay unchanged, the ragged-cardinality fallback chooses
    # the latest (identical) value, and streamwise means also stay unchanged.
    # This exact equality shortcut removes the dominant O(support * window)
    # rebuild on long exact repeats without changing any logical result.
    if _cluster_as_view(best_child) != latest_seq
      starts = _cluster_si(best_child)
      sequences = [mgr.data[(s + 1):(s + new_length)] for s in starts]
      _replace_cluster_representative!(
        mgr,
        best_child,
        average_sequences(mgr, sequences),
      )
    end

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_quantities,
      new_length,
      best_cluster_id,
    )
    if mgr.calculate_distance_when_added_subsequence_to_cluster
      add_updated_id!(
        mgr.updated_cluster_ids_per_window_for_calculate_distance,
        new_length,
        best_cluster_id,
      )
    end

    member_distances = _task_member_subset(
      mgr,
      best_child,
      extended_member_distances,
      latest_seq,
      latest_start,
      new_length,
    )
    representative_squared_distance = _extended_representative_squared_distance(
      mgr,
      task,
      parent,
      best_child,
      latest_seq,
    )
    push!(mgr.tasks, ClusterTask(
      vcat(copy(keys_to_parent), [best_cluster_id]),
      new_length,
      member_distances,
      representative_squared_distance,
      _cluster_version(best_child),
    ))
  else
    _add_child_cluster!(
      mgr,
      parent,
      mgr.cluster_id_counter,
      Int[latest_start],
      deep_copy_seq(latest_seq),
    )

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_distance,
      new_length,
      mgr.cluster_id_counter,
    )
    mgr.cluster_id_counter += 1
  end
end

function process_new_clusters!(
  mgr::Manager,
  parent::AbstractClusterRef,
  valid_si::Vector{Int},
  latest_seq::PolySeq,
  max_distance::Float64,
  latest_start::Int,
  new_length::Int,
  keys_to_parent::Vector{Int},
  task::ClusterTask,
)
  extended_member_distances = _extend_task_member_squared_distances(
    mgr,
    task,
    valid_si,
    latest_seq,
    latest_start,
    new_length,
  )

  valid_group = Int[]
  invalid_group = Int[]

  for s in valid_si
    distance = sqrt(extended_member_distances[s])
    ratio = max_distance == 0.0 ? 0.0 : (distance / max_distance)
    if ratio <= mgr.merge_threshold_ratio
      push!(valid_group, s)
    else
      push!(invalid_group, s)
    end
  end

  if !isempty(valid_group)
    starts = vcat(valid_group, [latest_start])
    scalar_exact_repeat =
      mgr.max_set_size == 1 &&
      mgr.point_distance_mode == :set &&
      !mgr.use_streamwise_surface_average &&
      all(get(extended_member_distances, s, Inf) == 0.0 for s in valid_group)

    representative =
      if scalar_exact_repeat
        deep_copy_seq(latest_seq)
      else
        sequences = [mgr.data[(s + 1):(s + new_length)] for s in starts]
        average_sequences(mgr, sequences)
      end
    new_cluster_id = mgr.cluster_id_counter
    new_cluster = _add_child_cluster!(
      mgr,
      parent,
      new_cluster_id,
      starts,
      representative,
    )

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_distance,
      new_length,
      new_cluster_id,
    )
    if mgr.recency > 0.0
      add_updated_id!(
        mgr.updated_cluster_ids_per_window_for_calculate_quantities,
        new_length,
        new_cluster_id,
      )
    end

    member_distances = Dict{Int,Float64}(
      s => extended_member_distances[s] for s in valid_group
    )
    representative_squared_distance = _extended_representative_squared_distance(
      mgr,
      task,
      parent,
      new_cluster,
      latest_seq,
    )
    push!(mgr.tasks, ClusterTask(
      vcat(copy(keys_to_parent), [new_cluster_id]),
      new_length,
      member_distances,
      representative_squared_distance,
      _cluster_version(new_cluster),
    ))
    mgr.cluster_id_counter += 1
  else
    _add_child_cluster!(
      mgr,
      parent,
      mgr.cluster_id_counter,
      Int[latest_start],
      deep_copy_seq(latest_seq),
    )

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_distance,
      new_length,
      mgr.cluster_id_counter,
    )
    mgr.cluster_id_counter += 1
  end

  for s in invalid_group
    seq = deep_copy_seq(mgr.data[(s + 1):(s + new_length)])
    _add_child_cluster!(
      mgr,
      parent,
      mgr.cluster_id_counter,
      Int[s],
      seq,
    )

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_distance,
      new_length,
      mgr.cluster_id_counter,
    )
    mgr.cluster_id_counter += 1
  end
end

function process_root_clusters!(mgr::Manager, data_index::Int, max_distance::Float64)
  latest_start = data_index - 1
  latest_start < 0 && return
  latest_seq = mgr.data[(latest_start + 1):(latest_start + mgr.min_window_size)]

  best_cluster_id = -1
  best_cluster::Union{Nothing,AbstractClusterRef} = nothing
  min_distance = Inf

  for cluster in _root_cluster_refs(mgr)
    cluster_id = _cluster_id(cluster)
    latest_start in _cluster_si(cluster) && continue

    distance = euclidean_distance(mgr, _cluster_as(cluster), latest_seq)
    if distance < min_distance ||
       (distance == min_distance && (best_cluster_id < 0 || cluster_id < best_cluster_id))
      min_distance = distance
      best_cluster = cluster
      best_cluster_id = cluster_id
    end
  end

  ratio = max_distance == 0.0 ? 0.0 : (min_distance / max_distance)

  if best_cluster !== nothing && ratio <= mgr.merge_threshold_ratio
    _append_cluster_start!(mgr, best_cluster, latest_start)

    if _cluster_as(best_cluster) != latest_seq
      sequences = [
        mgr.data[(s + 1):(s + mgr.min_window_size)]
        for s in _cluster_si(best_cluster)
      ]
      _replace_cluster_representative!(
        mgr,
        best_cluster,
        average_sequences(mgr, sequences),
      )
    end

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_quantities,
      mgr.min_window_size,
      best_cluster_id,
    )
    if mgr.calculate_distance_when_added_subsequence_to_cluster
      add_updated_id!(
        mgr.updated_cluster_ids_per_window_for_calculate_distance,
        mgr.min_window_size,
        best_cluster_id,
      )
    end

    member_distances = _member_squared_distances_for_node(
      mgr,
      best_cluster,
      latest_seq,
      latest_start,
      mgr.min_window_size,
    )
    representative_squared_distance =
      squared_euclidean_distance(mgr, _cluster_as(best_cluster), latest_seq)
    push!(mgr.tasks, ClusterTask(
      [best_cluster_id],
      mgr.min_window_size,
      member_distances,
      representative_squared_distance,
      _cluster_version(best_cluster),
    ))
  else
    _add_root_cluster!(
      mgr,
      mgr.cluster_id_counter,
      Int[latest_start],
      deep_copy_seq(latest_seq),
    )

    add_updated_id!(
      mgr.updated_cluster_ids_per_window_for_calculate_distance,
      mgr.min_window_size,
      mgr.cluster_id_counter,
    )
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

# Manager-level logical view API.
#
# Production callers should use these methods rather than reaching into
# `mgr.working_clusters` directly.  The physical cluster storage is intentionally an
# implementation detail so it can be replaced by path-compressed spans without
# changing controllers, generators, MusicXML analysis, or UI payload builders.
#
# For now the manager still mutates the legacy tree internally, but all read
# APIs below round-trip through the lossless compressed representation.  This
# continuously exercises the compressed representation while preserving the
# exact legacy logical result.
function logical_virtual_nodes(mgr::Manager)::Vector{NamedTuple}
  return compressed_virtual_nodes(compress_cluster_tree(mgr))
end

function transform_clusters(mgr::Manager)
  clusters_each = Dict{Int,Dict{Int,Dict{String,Any}}}()
  for row in logical_virtual_nodes(mgr)
    sequences = [[s, s + row.window_size - 1] for s in row.si]
    same_ws = get!(clusters_each, row.window_size, Dict{Int,Dict{String,Any}}())
    same_ws[row.cluster_id] = Dict(
      "si" => sequences,
      "as" => deep_copy_seq(row.as),
    )
  end
  return clusters_each
end

function clusters_to_timeline(mgr::Manager)
  result = Vector{Dict{String,Any}}()
  for row in logical_virtual_nodes(mgr)
    isempty(row.si) && continue
    push!(result, Dict(
      "window_size" => row.window_size,
      "cluster_id" => string(row.cluster_id),
      "indices" => sort(copy(row.si)),
    ))
  end
  return result
end

function compressed_clusters_payload(mgr::Manager)
  function span_payload(span::CompressedClusterSpan)
    return Dict(
      "window_min" => span.window_min,
      "window_max" => span.window_max,
      "cluster_ids" => copy(span.cluster_ids),
      "indices" => sort(copy(span.si_min)),
      "children" => Any[span_payload(child) for child in span.children],
    )
  end
  spans = compress_cluster_tree(mgr)
  return Any[span_payload(span) for span in spans]
end

# Backward-compatible explicit-tree overloads.  Keep these for tests and
# internal migration only; new production code should call the Manager forms.
transform_clusters(mgr::Manager, clusters::Dict{Int,PolyClusterNode}, min_window_size::Int) =
  transform_clusters(clusters, min_window_size)

clusters_to_timeline(mgr::Manager, clusters::Dict{Int,PolyClusterNode}, min_window_size::Int) =
  clusters_to_timeline(clusters, min_window_size)

function cluster_to_dict(node::PolyClusterNode)
  Dict(
    "si" => sort(copy(_cluster_si(node))),
    "as" => node.as,
    "cc" => Dict(string(cid) => cluster_to_dict(child) for (cid, child) in node.cc)
  )
end

function clusters_to_dict(clusters::Dict{Int,PolyClusterNode})
  Dict(string(cid) => cluster_to_dict(cl) for (cid, cl) in clusters)
end

function clusters_to_dict(mgr::Manager)
  # Preserve the legacy nested JSON shape exactly by rebuilding it from the
  # lossless virtual-node view instead of exposing physical storage.
  rows = logical_virtual_nodes(mgr)
  isempty(rows) && return Dict{String,Any}()

  children_by_parent = Dict{Union{Nothing,Int},Vector{NamedTuple}}()
  for row in rows
    push!(get!(children_by_parent, row.parent_id, NamedTuple[]), row)
  end
  for values in values(children_by_parent)
    sort!(values; by=row -> row.cluster_id)
  end

  function build(row)
    children = get(children_by_parent, row.cluster_id, NamedTuple[])
    return Dict(
      "si" => sort(copy(row.si)),
      "as" => deep_copy_seq(row.as),
      "cc" => Dict(
        string(child.cluster_id) => build(child)
        for child in children
      ),
    )
  end

  roots = get(children_by_parent, nothing, NamedTuple[])
  return Dict(string(row.cluster_id) => build(row) for row in roots)
end

end # module
