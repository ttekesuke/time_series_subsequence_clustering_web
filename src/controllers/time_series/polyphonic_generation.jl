# ------------------------------------------------------------
# Polyphonic helpers
# ------------------------------------------------------------

# 0-based index read (Rails compatible)
function array_param(raw::Dict{String,Any}, key::String, idx0::Int)
  raw === nothing && return nothing
  val = get(raw, key, nothing)
  val === nothing && return nothing

  if val isa AbstractVector
    isempty(val) && return nothing
    i = idx0 + 1
    if i < 1
      return val[1]
    elseif i > length(val)
      return val[end]
    else
      return val[i]
    end
  else
    return val
  end
end

# Accept JSON3.Object / Dict{Symbol,Any} etc.
function array_param(raw::AbstractDict, key::String, idx0::Int)
  return array_param(_to_string_dict(raw), key, idx0)
end

"""Read the first present parameter name, allowing canonical names to precede legacy aliases."""
function array_param_alias(raw::AbstractDict, idx0::Int, keys::AbstractString...)
  for key in keys
    value = array_param(raw, String(key), idx0)
    value === nothing || return value
  end
  return nothing
end

function _normalize_bpm_value(raw; fallback::Real=Config.POLYPHONIC_BPM)::Float64
  source = raw === nothing ? fallback : raw
  return Config.sanitize_bpm(_parse_float(source))
end

function _normalize_bpm_series(raw, expected_len::Int; fallback::Real=Config.POLYPHONIC_BPM)::Vector{Float64}
  fallback_bpm = _normalize_bpm_value(fallback; fallback=fallback)
  source = Any[]

  if raw isa AbstractVector
    append!(source, raw)
  elseif raw !== nothing
    push!(source, raw)
  end

  isempty(source) && push!(source, fallback_bpm)

  target_len = max(expected_len, 1)
  out = Float64[]
  sizehint!(out, target_len)
  last_raw = source[end]

  for i in 1:target_len
    raw_val = i <= length(source) ? source[i] : last_raw
    push!(out, _normalize_bpm_value(raw_val; fallback=fallback_bpm))
  end

  return out
end

function _step_durations_from_bpm_series(bpm_series::AbstractVector)::Vector{Float64}
  return Float64[Config.step_duration_from_bpm(bpm) for bpm in bpm_series]
end

function _step_onsets_from_durations(step_durations::AbstractVector)::Vector{Float64}
  onsets = Float64[]
  sizehint!(onsets, length(step_durations))
  current = 0.0
  for dur in step_durations
    push!(onsets, current)
    current += float(dur)
  end
  return onsets
end

function generate_centered_targets(n::Int, center::Real, spread::Real)::Vector{Float64}
  n = max(n, 1)
  if n == 1
    return [clamp(float(center), 0.0, 1.0)]
  end

  c = clamp(float(center), 0.0, 1.0)
  s = clamp(float(spread), 0.0, 1.0)

  halfw = s / 2.0
  startv = clamp(c - halfw, 0.0, 1.0)
  endv   = clamp(c + halfw, 0.0, 1.0)

  out = Vector{Float64}(undef, n)
  for i in 1:n
    t = (i - 1) / float(n - 1)
    out[i] = clamp(startv + (endv - startv) * t, 0.0, 1.0)
  end
  return out
end

struct CandidateMetric
  ordered_cand::Vector{Float64}
  global_dist::Float64
  global_qty::Float64
  global_comp::Float64
  stream_dists::Vector{Float64}
  stream_qtys::Vector{Float64}
  stream_comps::Vector{Float64}
  global_temporal::PolyphonicClusterManager.OccurrenceIntervalMetrics
  stream_temporals::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics}
  global_predictive::Float64
  stream_predictives::Vector{Float64}
  discordance::Float64
end

struct CandidateCostBreakdown
  total::Float64
  global_cost::Float64
  stream_cost::Float64
  conc_cost::Float64
  current_global::Float64
  stream_scores::Vector{Float64}
end

function _normalize_metric_weights(dw::Real, qw::Real, cw::Real)::NTuple{3,Float64}
  d = isfinite(float(dw)) ? max(float(dw), 0.0) : 0.0
  q = isfinite(float(qw)) ? max(float(qw), 0.0) : 0.0
  c = isfinite(float(cw)) ? max(float(cw), 0.0) : 0.0
  if d + q + c <= 0.0
    return (1.0, 1.0, 1.0)
  end
  return (d, q, c)
end

function _safe_simulate_add_and_calculate_all_extended(
  mgr::PolyphonicClusterManager.Manager,
  value::PolyphonicClusterManager.PolySet,
)::PolyphonicClusterManager.ExtendedClusterMetrics
  return PolyphonicClusterManager.simulate_add_and_calculate_all_extended(mgr, value)
end

function _set_generation_failure_context!(
  context::Dict{Symbol,Any};
  operation::AbstractString,
  dimension=nothing,
  stream_id=nothing,
  candidate=nothing,
)::Dict{Symbol,Any}
  context[:operation] = String(operation)
  context[:dimension] = dimension
  context[:stream_id] = stream_id
  context[:candidate] = candidate
  return context
end

function _stage_generate_polyphonic_step_state(managers, stm_mgr, stream_axis, voice_state)
  # PCM appends new rows but never mutates committed PolySet rows. Likewise,
  # lifecycle operations read the seed history, STM pruning replaces its
  # memory vector, and token selection reads the inventory. Reuse these
  # historical leaves while copying mutable clusters, cache outer maps,
  # stream containers, axis, and voice managers as a single graph. Cache
  # windows and occurrence-interval states remain shared until the staged
  # manager first writes each one.
  shared = IdDict{Any,Any}()
  function share_pcm_rows!(pcm)
    PolyphonicClusterManager.share_staged_payloads!(shared, pcm)
  end
  function mark_shared_caches!(staged_pcm, original_pcm)
    staged_pcm.shared_distance_cache_windows = Set(keys(original_pcm.cluster_distance_cache))
    staged_pcm.shared_quantity_cache_windows = Set(keys(original_pcm.cluster_quantity_cache))
    staged_pcm.shared_complexity_cache_windows = Set(keys(original_pcm.cluster_complexity_cache))
    staged_pcm.shared_occurrence_state_keys = Set(keys(original_pcm.occurrence_interval_states))
  end
  for mgrs in values(managers)
    share_pcm_rows!(mgrs[:global])
    stream_mgr = mgrs[:stream]
    shared[stream_mgr.history_matrix] = stream_mgr.history_matrix
    for container in stream_mgr.stream_pool
      share_pcm_rows!(container.manager)
    end
  end
  # commit! calls prune! first, which replaces this vector before appending.
  shared[stm_mgr.memory] = stm_mgr.memory
  if voice_state !== nothing
    # VoiceInventory is immutable, so deepcopy_internal reconstructs its
    # wrapper even when memoized. Its token vector is the costly read-only
    # leaf; restore the original wrapper after the graph has been copied.
    shared[voice_state.inventory.tokens] = voice_state.inventory.tokens
    share_pcm_rows!(voice_state.global_manager)
    for pcm in values(voice_state.stream_managers)
      share_pcm_rows!(pcm)
    end
  end
  staged = Base.deepcopy_internal((
    managers=managers,
    stm_mgr=stm_mgr,
    stream_axis=stream_axis,
    voice_state=voice_state,
  ), shared)
  if voice_state !== nothing
    staged.voice_state.inventory = voice_state.inventory
    mark_shared_caches!(staged.voice_state.global_manager, voice_state.global_manager)
    for (id, pcm) in voice_state.stream_managers
      mark_shared_caches!(staged.voice_state.stream_managers[id], pcm)
    end
  end
  for (key, mgrs) in managers
    staged_mgrs = staged.managers[key]
    mark_shared_caches!(staged_mgrs[:global], mgrs[:global])
    for (id, container) in mgrs[:stream].containers_by_id
      staged_container = staged_mgrs[:stream].containers_by_id[id]
      mark_shared_caches!(staged_container.manager, container.manager)
    end
  end
  return staged
end

function _log_generate_polyphonic_step_failure(err, bt, step_idx::Int, context::Dict{Symbol,Any})::Nothing
  @error "generate_polyphonic step failed; staged state discarded" step=step_idx operation=get(context, :operation, nothing) dimension=get(context, :dimension, nothing) stream_id=get(context, :stream_id, nothing) candidate=get(context, :candidate, nothing) exception=(err, bt)
  return nothing
end

function _safe_corrcoef(xs::Vector{Float64}, ys::Vector{Float64})::Float64
  n = min(length(xs), length(ys))
  n <= 1 && return NaN

  mx = sum(xs[1:n]) / float(n)
  my = sum(ys[1:n]) / float(n)

  sxx = 0.0
  syy = 0.0
  sxy = 0.0
  for i in 1:n
    dx = xs[i] - mx
    dy = ys[i] - my
    sxx += dx * dx
    syy += dy * dy
    sxy += dx * dy
  end

  if sxx <= 0.0 || syy <= 0.0
    return NaN
  end
  return sxy / sqrt(sxx * syy)
end

@inline function _concordance_cost(raw_conc::Real, discordance::Real)::Float64
  conc = clamp(float(raw_conc), -1.0, 1.0)
  weight = abs(conc)
  weight <= 0.0 && return 0.0

  target_concordance = conc > 0.0 ? 1.0 : 0.0
  concord01 = 1.0 - clamp(float(discordance), 0.0, 1.0)
  return weight * abs(concord01 - target_concordance)
end

function select_best_polyphonic_candidate_unified_with_cost(
  metrics::Vector{CandidateMetric},
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  global_metric_weights::NTuple{3,Float64},
  stream_metric_weights::NTuple{3,Float64};
  use_global_score::Bool = true,
  global_calibrator::ExtendedMetricCalibrator = DEFAULT_EXTENDED_METRIC_CALIBRATOR,
  stream_calibrators::Vector{ExtendedMetricCalibrator} = ExtendedMetricCalibrator[],
)
  best_i = 1
  min_cost = Inf
  breakdowns = CandidateCostBreakdown[]
  sizehint!(breakdowns, length(metrics))

  global_predictive_scores = Float64[
    isfinite(m.global_predictive) ? m.global_predictive : NaN
    for m in metrics
  ]
  global_scores = combine_predictive_structural_scores(
    global_predictive_scores,
    Float64[m.global_dist for m in metrics],
    Float64[m.global_qty for m in metrics],
    Float64[m.global_comp for m in metrics],
    PolyphonicClusterManager.OccurrenceIntervalMetrics[m.global_temporal for m in metrics];
    metric_weights=global_metric_weights,
    calibrator=global_calibrator,
  )

  n_stream_metrics = 0
  for m in metrics
    n_stream_metrics = max(
      n_stream_metrics,
      length(m.stream_dists),
      length(m.stream_qtys),
      length(m.stream_comps),
    )
  end
  stream_norm = Vector{Vector{Float64}}(undef, n_stream_metrics)

  for s_idx in 1:n_stream_metrics
    raw_d = Float64[(s_idx <= length(m.stream_dists)) ? m.stream_dists[s_idx] : 0.0 for m in metrics]
    raw_q = Float64[(s_idx <= length(m.stream_qtys)) ? m.stream_qtys[s_idx] : 0.0 for m in metrics]
    raw_c = Float64[(s_idx <= length(m.stream_comps)) ? m.stream_comps[s_idx] : 0.0 for m in metrics]
    temporal = PolyphonicClusterManager.OccurrenceIntervalMetrics[
      (s_idx <= length(m.stream_temporals)) ?
        m.stream_temporals[s_idx] :
        PolyphonicClusterManager.EMPTY_OCCURRENCE_INTERVAL_METRICS
      for m in metrics
    ]
    stream_calibrator =
      s_idx <= length(stream_calibrators) ?
        stream_calibrators[s_idx] :
        DEFAULT_EXTENDED_METRIC_CALIBRATOR
    predictive_stream_scores = Float64[
      s_idx <= length(m.stream_predictives) && isfinite(m.stream_predictives[s_idx]) ?
        m.stream_predictives[s_idx] :
        NaN
      for m in metrics
    ]
    stream_norm[s_idx] = combine_predictive_structural_scores(
      predictive_stream_scores,
      raw_d,
      raw_q,
      raw_c,
      temporal;
      metric_weights=stream_metric_weights,
      calibrator=stream_calibrator,
    )
  end

  conc_enabled = !isempty(metrics) && length(metrics[1].ordered_cand) > 1

  for (i, m) in enumerate(metrics)
    current_global = use_global_score ? global_scores[i] : 0.0
    cost_a = use_global_score ? abs(current_global - global_target) : 0.0

    cost_b = 0.0
    stream_scores = Float64[]
    if !isempty(stream_targets)
      n = min(length(stream_targets), n_stream_metrics)
      if n > 0
        sizehint!(stream_scores, n)
        for s_idx in 1:n
          stream_score = stream_norm[s_idx][i]
          cost_b += abs(stream_score - stream_targets[s_idx])
          push!(stream_scores, stream_score)
        end
        cost_b /= float(n)
      end
    end

    cost_c = 0.0
    if conc_enabled
      cost_c = _concordance_cost(concordance_weight, m.discordance)
    end

    total = cost_a + cost_b + cost_c
    push!(breakdowns, CandidateCostBreakdown(total, cost_a, cost_b, cost_c, current_global, copy(stream_scores)))
    if total < min_cost
      min_cost = total
      best_i = i
    end
  end

  return best_i, min_cost, breakdowns
end

function select_best_chord_for_dimension_with_cost(
  mgrs::Dict{Symbol,Any},
  candidates::Vector{<:AbstractVector{<:Real}},
  stream_costs,
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  n::Int,
  range_vec::Vector{<:Real};
  global_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  stream_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  debug_prefix::Union{Nothing,String} = nothing,
  debug_top_n::Int = Config.DEFAULT_DEBUG_TOP_N,
  absolute_bases::Union{Nothing,Vector{Int}} = nothing,
  active_note_counts::Union{Nothing,Vector{Int}} = nothing,
  active_total_notes::Union{Nothing,Int} = nothing,
  max_simultaneous_notes::Int = last(Config.CHORD_SIZE_RANGE),
  preserve_stream_order::Bool = false,
  use_global_score::Bool = true
)
  max_simul = max(max_simultaneous_notes, 1)

  assignment_distance_weight::Float64 = 1.0
  assignment_complexity_weight::Float64 = 1.0

  if active_total_notes !== nothing
    total_notes = Int(active_total_notes)
    density01 = (n <= 0) ? 0.0 : clamp(total_notes / float(max_simul * n), 0.0, 1.0)

    assignment_distance_weight   = density01
    assignment_complexity_weight = 1.0 - density01
  end

  vmin = isempty(range_vec) ? 0.0 : float(minimum(range_vec))
  vmax = isempty(range_vec) ? 1.0 : float(maximum(range_vec))
  range_width = abs(vmax - vmin)
  range_width = range_width <= 0.0 ? 1.0 : range_width

  global_calibrator = build_extended_metric_calibrator(mgrs[:global])
  stream_mgr = mgrs[:stream]
  actives = MultiStreamManager.active_stream_containers(stream_mgr, n)
  stream_calibrators = ExtendedMetricCalibrator[
    build_extended_metric_calibrator(actives[i].manager)
    for i in 1:min(n, length(actives))
  ]
  global_predictor = build_predictive_distribution(mgrs[:global])
  stream_predictors = PredictiveDistribution[
    build_predictive_distribution(actives[i].manager)
    for i in 1:min(n, length(actives))
  ]
  metrics = CandidateMetric[]

  for cand_set in candidates
    ordered_polysets = if preserve_stream_order
      [Float64[float(v)] for v in cand_set]
    else
      resolved_polysets, _stream_metric = MultiStreamManager.resolve_mapping_and_score(
        mgrs[:stream],
        cand_set,
        stream_costs;
        absolute_bases=absolute_bases,
        active_note_counts=active_note_counts,
        active_total_notes=active_total_notes,
        distance_weight=assignment_distance_weight,
        complexity_weight=assignment_complexity_weight,
      )
      resolved_polysets
    end

    ordered_vals = Float64[]
    for v in ordered_polysets
      if v isa AbstractVector && !isempty(v)
        push!(ordered_vals, float(v[1]))
      else
        push!(ordered_vals, 0.0)
      end
    end

    g_offset = get(mgrs, :global_offset, 0.0)
    stream_axis = get(mgrs, :stream_axis, nothing)
    stream_axis isa StableStreamAxis || error("Missing stable stream axis for global dimension evaluation.")
    length(actives) >= length(ordered_vals) || error(
      "Only $(length(actives)) active stream identities are available for $(length(ordered_vals)) global values.",
    )
    active_ids = Int[actives[i].id for i in 1:length(ordered_vals)]
    global_vals = _encode_streamwise_row(stream_axis, active_ids, ordered_vals, g_offset)
    global_metrics =
      PolyphonicClusterManager.simulate_add_and_calculate_all_extended(mgrs[:global], global_vals)
    disc =
      if isempty(ordered_vals)
        0.0
      else
        (maximum(ordered_vals) - minimum(ordered_vals)) / range_width
      end

    stream_dists = Float64[]
    stream_qtys = Float64[]
    stream_comps = Float64[]
    stream_temporals = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
    stream_predictives = Float64[]

    for i in 1:n
      if i <= length(actives) && i <= length(ordered_polysets)
        stream_metrics =
          _safe_simulate_add_and_calculate_all_extended(actives[i].manager, ordered_polysets[i])
        push!(stream_dists, isfinite(stream_metrics.distance) ? stream_metrics.distance : 0.0)
        push!(stream_qtys, isfinite(stream_metrics.quantity) ? stream_metrics.quantity : 0.0)
        push!(stream_comps, isfinite(stream_metrics.complexity) ? stream_metrics.complexity : 0.0)
        push!(stream_temporals, stream_metrics.occurrence_intervals)
        predictive = predictive_surprise_score(
          actives[i].manager,
          stream_predictors[i],
          ordered_polysets[i],
        )
        push!(stream_predictives, predictive === nothing ? NaN : predictive)
      else
        push!(stream_dists, 0.0)
        push!(stream_qtys, 0.0)
        push!(stream_comps, 0.0)
        push!(stream_temporals, PolyphonicClusterManager.EMPTY_OCCURRENCE_INTERVAL_METRICS)
        push!(stream_predictives, NaN)
      end
    end

    global_predictive = predictive_surprise_score(
      mgrs[:global],
      global_predictor,
      global_vals,
    )

    push!(metrics, CandidateMetric(
      ordered_vals,
      global_metrics.distance,
      global_metrics.quantity,
      global_metrics.complexity,
      stream_dists,
      stream_qtys,
      stream_comps,
      global_metrics.occurrence_intervals,
      stream_temporals,
      global_predictive === nothing ? NaN : global_predictive,
      stream_predictives,
      disc,
    ))
  end

  isempty(metrics) && return (Float64[], Inf)

  best_i, best_cost, breakdowns = select_best_polyphonic_candidate_unified_with_cost(
    metrics,
    global_target,
    stream_targets,
    concordance_weight,
    global_metric_weights,
    stream_metric_weights;
    use_global_score=use_global_score,
    global_calibrator=global_calibrator,
    stream_calibrators=stream_calibrators,
  )

  best = metrics[best_i]
  return best.ordered_cand, best_cost
end

function stream_priority_order(stream_mgr, n::Int)::Vector{Int}
  actives = MultiStreamManager.active_stream_containers(stream_mgr, n)
  ranked = Tuple{Float64,Int}[]
  sizehint!(ranked, n)
  for i in 1:n
    strength = i <= length(actives) ? clamp(float(actives[i].presence_avg), 0.0, 1.0) : 0.0
    push!(ranked, (-strength, i))
  end
  sort!(ranked; by=x -> (x[1], x[2]))
  return Int[x[2] for x in ranked]
end

function select_best_values_for_dimension_greedy(
  mgrs::Dict{Symbol,Any},
  range_vec::Vector{Float64},
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  n::Int;
  global_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  stream_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  use_global_score::Bool = true,
  priority_order::Union{Nothing,Vector{Int}} = nothing,
  trace_context::Union{Nothing,Dict{Symbol,Any}} = nothing,
  evaluation_budget = nothing
)::Vector{Float64}
  n = max(n, 1)
  isempty(range_vec) && return fill(0.0, n)

  chosen = fill(NaN, n)
  order = priority_order === nothing ? stream_priority_order(mgrs[:stream], n) : Int[i for i in priority_order if 1 <= i <= n]
  isempty(order) && (order = collect(1:n))
  actives = MultiStreamManager.active_stream_containers(mgrs[:stream], n)

  vmin = minimum(range_vec)
  vmax = maximum(range_vec)
  range_width = abs(vmax - vmin)
  range_width = range_width <= 0.0 ? 1.0 : range_width
  g_offset = float(get(mgrs, :global_offset, 0.0))
  stream_axis = get(mgrs, :stream_axis, nothing)
  stream_axis isa StableStreamAxis || error("Missing stable stream axis for global dimension evaluation.")

  for stream_idx in order
    global_calibrator = build_extended_metric_calibrator(mgrs[:global])
    stream_calibrator =
      stream_idx <= length(actives) ?
        build_extended_metric_calibrator(actives[stream_idx].manager) :
        DEFAULT_EXTENDED_METRIC_CALIBRATOR
    metrics = CandidateMetric[]
    global_predictor = build_predictive_distribution(mgrs[:global])
    stream_predictor =
      stream_idx <= length(actives) ?
        build_predictive_distribution(actives[stream_idx].manager) :
        EMPTY_PREDICTIVE_DISTRIBUTION
    sizehint!(metrics, length(range_vec))

    for cand in range_vec
      partial_vals = Tuple{Int,Float64}[]
      for i in 1:n
        if isfinite(chosen[i])
          push!(partial_vals, (i, chosen[i]))
        end
      end
      push!(partial_vals, (stream_idx, float(cand)))
      sort!(partial_vals; by=x -> x[1])

      ordered_vals = Float64[value for (_index, value) in partial_vals]
      partial_ids = Int[]
      sizehint!(partial_ids, length(partial_vals))
      for (index, _value) in partial_vals
        index <= length(actives) || error("Missing stable stream identity for active slot $(index).")
        push!(partial_ids, actives[index].id)
      end
      global_vals = _encode_streamwise_row(stream_axis, partial_ids, ordered_vals, g_offset)

      if trace_context !== nothing
        _set_generation_failure_context!(
          trace_context;
          operation="simulate_candidate",
          dimension=get(trace_context, :dimension, nothing),
          stream_id=(stream_idx <= length(actives) ? actives[stream_idx].id : nothing),
          candidate=float(cand),
        )
      end

      if evaluation_budget !== nothing
        dimension_name = trace_context === nothing ? "dimension" : string(get(trace_context, :dimension, "dimension"))
        _consume_dimension_evaluations!(evaluation_budget, 1; context="$(dimension_name) candidate")
      end

      global_metrics =
        _safe_simulate_add_and_calculate_all_extended(mgrs[:global], global_vals)
      disc = length(ordered_vals) <= 1 ? 0.0 : clamp((maximum(ordered_vals) - minimum(ordered_vals)) / range_width, 0.0, 1.0)

      stream_metrics =
        if stream_idx <= length(actives)
          _safe_simulate_add_and_calculate_all_extended(
            actives[stream_idx].manager,
            Float64[float(cand)],
          )
        else
          PolyphonicClusterManager.ExtendedClusterMetrics(
            0.0,
            0.0,
            0.0,
            PolyphonicClusterManager.EMPTY_OCCURRENCE_INTERVAL_METRICS,
          )
        end

      global_predictive = predictive_surprise_score(
        mgrs[:global],
        global_predictor,
        global_vals,
      )
      stream_predictive =
        stream_idx <= length(actives) ?
          predictive_surprise_score(
            actives[stream_idx].manager,
            stream_predictor,
            Float64[float(cand)],
          ) :
          nothing

      push!(metrics, CandidateMetric(
        ordered_vals,
        global_metrics.distance,
        global_metrics.quantity,
        global_metrics.complexity,
        Float64[stream_metrics.distance],
        Float64[stream_metrics.quantity],
        Float64[stream_metrics.complexity],
        global_metrics.occurrence_intervals,
        PolyphonicClusterManager.OccurrenceIntervalMetrics[
          stream_metrics.occurrence_intervals,
        ],
        global_predictive === nothing ? NaN : global_predictive,
        Float64[stream_predictive === nothing ? NaN : stream_predictive],
        disc,
      ))
    end

    target = stream_idx <= length(stream_targets) ? stream_targets[stream_idx] : 0.5
    best_i, _best_cost, _breakdowns = select_best_polyphonic_candidate_unified_with_cost(
      metrics,
      global_target,
      Float64[target],
      concordance_weight,
      global_metric_weights,
      stream_metric_weights;
      use_global_score=use_global_score,
      global_calibrator=global_calibrator,
      stream_calibrators=ExtendedMetricCalibrator[stream_calibrator],
    )
    chosen[stream_idx] = range_vec[best_i]
  end

  return Float64[isfinite(v) ? v : range_vec[1] for v in chosen]
end


function infer_chord_range_and_density_controls(abs_notes_raw)::Tuple{Int,Float64}
  notes = sort(unique(Int[
    clamp(_parse_int(v), Config.MIDI_NOTE_MIN, Config.MIDI_NOTE_MAX)
    for v in abs_notes_raw
  ]))
  isempty(notes) && return (0, 0.0)

  band_size = Config.AREA_BAND_SIZE
  band_low = Config.area_band_low(notes[cld(length(notes), 2)])
  band_high = min(band_low + band_size - 1, Config.MIDI_NOTE_MAX)
  chord_range = clamp(
    max(band_low - first(notes), last(notes) - band_high, 0),
    Config.CHORD_RANGE_VALUE_MIN,
    Config.CHORD_RANGE_VALUE_MAX,
  )
  low = clamp(band_low - chord_range, Config.MIDI_NOTE_MIN, Config.MIDI_NOTE_MAX)
  high = clamp(band_high + chord_range, Config.MIDI_NOTE_MIN, Config.MIDI_NOTE_MAX)
  slot_count = max(high - low + 1, 1)
  density = clamp(
    float(clamp(length(notes), 1, slot_count)) / float(slot_count),
    0.0,
    1.0,
  )
  return (chord_range, density)
end

function _observed_occurrence_complexity(
  temporal::PolyphonicClusterManager.OccurrenceIntervalMetrics,
  calibrator::ComplexityMetricCalibrator,
  predictive,
)
  temporal.ready || return predictive

  total = 0.0
  denominator = 0.0

  if isfinite(temporal.prediction)
    w = max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0)
    total += w * clamp(temporal.prediction, 0.0, 1.0)
    denominator += w
  elseif predictive !== nothing
    w = max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0)
    total += w * clamp(float(predictive), 0.0, 1.0)
    denominator += w
  end

  w_div = max(Config.COMPLEXITY_DIVERSITY_WEIGHT, 0.0)
  w_shape = max(Config.COMPLEXITY_SHAPE_WEIGHT, 0.0)
  total += w_div * calibrate_metric(temporal.distance, calibrator.distance)
  total += w_shape * calibrate_metric(temporal.complexity, calibrator.complexity)
  denominator += w_div + w_shape

  denominator <= 0.0 && return predictive
  return clamp(total / denominator, 0.0, 1.0)
end

"""Evaluate one observed value against committed history and then commit it.

This is the analysis counterpart of candidate scoring in generate/generate_polyphonic:
the same predictive distribution, structural metrics, calibrators and server-owned
weights are used, but there is no candidate-set normalization because an existing
score supplies exactly one observed next value.
"""
function evaluate_observed_complexity!(
  manager::PolyphonicClusterManager.Manager,
  value::PolyphonicClusterManager.PolySet;
  metric_weights::NTuple{3,Float64}=Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS,
  phase_timings::Union{Nothing,Dict{Symbol,Float64}}=nothing,
  committed_metrics_ref::Union{Nothing,Base.RefValue{PolyphonicClusterManager.ExtendedClusterMetrics}}=nothing,
  observed_distance_sums::Union{Nothing,Dict{Int,Float64}}=nothing,
  observed_quantity_totals::Union{Nothing,PolyphonicClusterManager.ObservedQuantityTotals}=nothing,
)::Dict{String,Any}
  phase_started = phase_timings === nothing ? 0 : time_ns()
  committed_metrics = committed_metrics_ref === nothing ?
    PolyphonicClusterManager.current_extended_metrics(manager) : committed_metrics_ref[]
  calibrator = manager.enable_occurrence_intervals ?
    build_extended_metric_calibrator(manager, committed_metrics) : nothing
  base_calibrator = manager.enable_occurrence_intervals ? calibrator.base :
    _build_complexity_metric_calibrator(
      committed_metrics,
      max(length(manager.data) - manager.min_window_size + 1, 1),
    )
  if phase_timings !== nothing
    phase_timings[:calibrator] += (time_ns() - phase_started) / 1.0e9
    phase_started = time_ns()
  end
  distribution = PolyphonicClusterManager.build_predictive_distribution(manager)
  predictive = PolyphonicClusterManager.predictive_surprise_score(
    manager,
    distribution,
    value,
  )
  if phase_timings !== nothing
    phase_timings[:prediction] += (time_ns() - phase_started) / 1.0e9
    phase_started = time_ns()
  end
  metrics = PolyphonicClusterManager.add_observed_and_calculate_all_extended!(
    manager,
    value,
    phase_timings=phase_timings,
    next_calibration_metrics_ref=committed_metrics_ref,
    observed_distance_sums=observed_distance_sums,
    observed_quantity_totals=observed_quantity_totals,
  )

  diversity = calibrate_metric(metrics.distance, base_calibrator.distance)
  shape = calibrate_metric(metrics.complexity, base_calibrator.complexity)
  mass = calibrate_metric(metrics.quantity, base_calibrator.quantity)
  if !manager.enable_occurrence_intervals
    return Dict(
      "prediction" => predictive,
      "diversity" => diversity,
      "shape" => shape,
      "mass" => mass,
      "raw" => Dict(
        "distance" => metrics.distance,
        "quantity" => metrics.quantity,
        "complexity" => metrics.complexity,
      ),
    )
  end
  occurrence = _observed_occurrence_complexity(
    metrics.occurrence_intervals,
    calibrator.occurrence_intervals,
    predictive,
  )

  total = 0.0
  denominator = 0.0
  if predictive !== nothing
    w = max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0)
    total += w * clamp(float(predictive), 0.0, 1.0)
    denominator += w
  end

  w_div = max(Config.COMPLEXITY_DIVERSITY_WEIGHT * metric_weights[1], 0.0)
  w_shape = max(Config.COMPLEXITY_SHAPE_WEIGHT * metric_weights[3], 0.0)
  w_mass = max(Config.COMPLEXITY_MASS_WEIGHT * metric_weights[2], 0.0)
  total += w_div * diversity + w_shape * shape + w_mass * mass
  denominator += w_div + w_shape + w_mass

  if occurrence !== nothing
    w_occ = max(Config.COMPLEXITY_OCCURRENCE_WEIGHT, 0.0)
    total += w_occ * clamp(float(occurrence), 0.0, 1.0)
    denominator += w_occ
  end

  combined = denominator > 0.0 ?
    clamp(total / denominator, 0.0, 1.0) :
    Config.DEFAULT_TARGET_01

  temporal = metrics.occurrence_intervals
  return Dict(
    "prediction" => predictive,
    "diversity" => diversity,
    "shape" => shape,
    "occurrence" => occurrence,
    "mass" => mass,
    "combined" => combined,
    "raw" => Dict(
      "distance" => metrics.distance,
      "quantity" => metrics.quantity,
      "complexity" => metrics.complexity,
      "occurrenceDistance" => temporal.ready ? temporal.distance : nothing,
      "occurrenceQuantity" => temporal.ready ? temporal.quantity : nothing,
      "occurrenceComplexity" => temporal.ready ? temporal.complexity : nothing,
    ),
  )
end

# ------------------------------------------------------------
# generate_polyphonic (main)
# ------------------------------------------------------------
function generate_polyphonic()
  t0 = time()

  payload = _payload()
  gp = _subhash(payload, "generate_polyphonic")
  compact_cluster_view = get(gp, "compact_cluster_view", false) == true
  validated_request = _validate_generate_polyphonic_request!(gp)
  evaluation_budget = PolyphonicEvaluationBudget(
    0,
    0,
    validated_request.limits.dimension_evaluations,
    validated_request.limits.note_evaluations,
  )
  # ----------------------------------------------------------
  # Params
  # ----------------------------------------------------------
  stream_counts = copy(validated_request.stream_counts)

  voice_counts_present = Config.voicevox_enabled() && haskey(gp, "voice_stream_counts")
  voice_stream_counts = Int[]
  if voice_counts_present
    raw_voice_counts = get(gp, "voice_stream_counts", Any[])
    raw_voice_counts isa AbstractVector || error("generate_polyphonic.voice_stream_counts must be an Array.")
    for value in raw_voice_counts
      count = _parse_int(value)
      count >= 0 || error("generate_polyphonic.voice_stream_counts values must be >= 0.")
      push!(voice_stream_counts, count)
    end
    length(voice_stream_counts) == length(stream_counts) || error(
      "generate_polyphonic.voice_stream_counts must have the same length as stream_counts.",
    )
    for i in eachindex(stream_counts)
      voice_stream_counts[i] <= stream_counts[i] || error(
        "voice_stream_counts[$(i)]=$(voice_stream_counts[i]) exceeds stream_counts[$(i)]=$(stream_counts[i]).",
      )
    end
  else
    voice_stream_counts = fill(0, length(stream_counts))
  end

  strength_targets_raw = get(gp, "stream_strength_target", Any[])
  strength_spreads_raw = get(gp, "stream_strength_spread", Any[])

  strength_targets = Float64[]
  if strength_targets_raw isa AbstractVector
    for x in strength_targets_raw
      push!(strength_targets, _parse_float(x))
    end
  end

  strength_spreads = Float64[]
  if strength_spreads_raw isa AbstractVector
    for x in strength_spreads_raw
      push!(strength_spreads, _parse_float(x))
    end
  end

  bpm = _normalize_bpm_value(get(gp, "bpm", Config.POLYPHONIC_BPM))

  ctx_raw = get(gp, "initial_context", Any[])

  # Stream record (REQUIRED):
  #   strict full: [abs_notes::Vector{Int}, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range::Int, density::Float64, tie::Float64]
  #
  # initial_context MUST be a 3-level array:
  #   initial_context[step][stream] = stream_record
  results = Vector{Vector{Vector{Any}}}()

  if !(ctx_raw isa AbstractVector)
    error("generate_polyphonic.initial_context must be an Array of steps; each step is an Array of streams; each stream must be strict [abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, tie].")
  end

  for step in ctx_raw
    step isa AbstractVector || error("generate_polyphonic.initial_context: each step must be an Array of streams.")
    streams = Vector{Vector{Any}}()
    for st in step
      st isa AbstractVector || error("generate_polyphonic.initial_context: each stream must be an Array in strict format.")
      push!(streams, Any[st...])
    end
    push!(results, streams)
  end

  # Defaults
  if isempty(results)
    push!(results, [Any[
      [Int(Config.abs_pitch_min())],
      Config.UNIT_MAX,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.CHORD_RANGE_VALUE_MIN,
      Config.UNIT_MIN,
      Config.UNIT_MIN
    ]])
  end

  initial_context_bpm = _normalize_bpm_series(get(gp, "initial_context_bpm", nothing), length(results); fallback=bpm)
  future_bpm = _normalize_bpm_series(get(gp, "future_bpm", nothing), length(stream_counts); fallback=bpm)
  function _normalize_unit_series(raw, n::Int; fallback::Float64=0.0)::Vector{Float64}
    target_len = max(n, 0)
    target_len == 0 && return Float64[]
    vals = Float64[]
    if raw isa AbstractVector
      for x in raw
        push!(vals, clamp(_parse_float(x), 0.0, 1.0))
      end
    elseif raw !== nothing
      push!(vals, clamp(_parse_float(raw), 0.0, 1.0))
    end
    isempty(vals) && push!(vals, clamp(fallback, 0.0, 1.0))
    out = Float64[]
    fallback_val = vals[end]
    for i in 1:target_len
      push!(out, i <= length(vals) ? vals[i] : fallback_val)
    end
    return out
  end
  function _normalize_signed_unit_series(raw, n::Int; fallback::Float64=0.0)::Vector{Float64}
    target_len = max(n, 0)
    target_len == 0 && return Float64[]
    vals = Float64[]
    if raw isa AbstractVector
      for x in raw
        push!(vals, clamp(_parse_float(x), -1.0, 1.0))
      end
    elseif raw !== nothing
      push!(vals, clamp(_parse_float(raw), -1.0, 1.0))
    end
    isempty(vals) && push!(vals, clamp(fallback, -1.0, 1.0))
    out = Float64[]
    fallback_val = vals[end]
    for i in 1:target_len
      push!(out, i <= length(vals) ? vals[i] : fallback_val)
    end
    return out
  end

  tie_cluster_param_keys = (
    "tie_global_complexity_target",
    "tie_stream_complexity_center",
    "tie_stream_complexity_span",
    "tie_concordance",
    "tie_value_target",
    "tie_value_radius",
    "tie_rate_target", # backward-compatible alias for tie_value_target
  )
  clustered_tie_enabled = any(haskey(gp, key) for key in tie_cluster_param_keys)

  # Legacy requests retain deterministic center±spread/2 distribution. New
  # Canonical tie parameters opt into clustered three-level generation.
  tie_center_raw = get(gp, "tie_center", nothing)
  tie_spread_raw = get(gp, "tie_spread", nothing)
  tie_center_series = _normalize_unit_series(tie_center_raw, length(stream_counts); fallback=0.0)
  tie_spread_series = _normalize_unit_series(tie_spread_raw, length(stream_counts); fallback=0.0)
  tie_global_complexity_series = _normalize_unit_series(get(gp, "tie_global_complexity_target", nothing), length(stream_counts); fallback=0.0)
  tie_stream_center_series = _normalize_unit_series(get(gp, "tie_stream_complexity_center", nothing), length(stream_counts); fallback=0.0)
  tie_stream_span_series = _normalize_unit_series(get(gp, "tie_stream_complexity_span", nothing), length(stream_counts); fallback=0.0)
  tie_concordance_series = _normalize_signed_unit_series(get(gp, "tie_concordance", nothing), length(stream_counts); fallback=0.0)
  voice_global_complexity_series = _normalize_unit_series(get(gp, "voice_token_global_complexity_target", nothing), length(stream_counts); fallback=0.0)
  voice_stream_center_series = _normalize_unit_series(get(gp, "voice_token_stream_complexity_center", nothing), length(stream_counts); fallback=0.0)
  voice_stream_span_series = _normalize_unit_series(get(gp, "voice_token_stream_complexity_span", nothing), length(stream_counts); fallback=0.0)
  voice_concordance_series = _normalize_signed_unit_series(get(gp, "voice_token_concordance", nothing), length(stream_counts); fallback=0.0)
  voice_transition_series = _normalize_unit_series(get(gp, "voice_transition_weight", nothing), length(stream_counts); fallback=0.0)
  initial_step_durations = _step_durations_from_bpm_series(initial_context_bpm)
  future_step_durations = _step_durations_from_bpm_series(future_bpm)
  initial_step_onsets = _step_onsets_from_durations(initial_step_durations)
  future_step_onsets = _step_onsets_from_durations(future_step_durations)
  base_onset = isempty(initial_step_durations) ? 0.0 : sum(initial_step_durations)
  future_step_onsets = Float64[base_onset + onset for onset in future_step_onsets]
  bpm_series = vcat(initial_context_bpm, future_bpm)
  step_durations = vcat(initial_step_durations, future_step_durations)

  # Indices for NEW format
  note_abs_idx    = 1
  vol_idx         = 2
  brightness_idx  = 3
  noise_idx = 4
  harmonicity_idx   = 5
  attack_idx   = 6
  decay_sustain_idx = 7
  release_idx = 8
  chord_range_idx = 9
  density_idx     = 10
  tie_idx         = 11

  # --- MIDI range (keep consistent across AREA/tmp_anchor and NOTE) ---
  ABS_MIN = Int(Config.abs_pitch_min())
  ABS_MAX = Int(Config.abs_pitch_max())

  BAND_SIZE = Config.AREA_BAND_SIZE
  BAND_LOW_MIN = Config.area_band_low_min()
  BAND_LOW_MAX = Config.area_band_low_max()
  BAND_WIDTH  = max(float(BAND_LOW_MAX - BAND_LOW_MIN), 1.0)
  CHORD_RANGE_MIN = Config.CHORD_RANGE_VALUE_MIN
  CHORD_RANGE_MAX = Config.CHORD_RANGE_VALUE_MAX

  function _canonical_dim_key(raw_key)::Union{Nothing,String}
    s = lowercase(strip(string(raw_key)))
    return haskey(_POLYPHONIC_DIMENSION_CONTRACT, s) ? s : nothing
  end

  function _normalize_fixed_value_for_dim(key::String, raw)
    contract = get(_POLYPHONIC_DIMENSION_CONTRACT, key, nothing)
    contract === nothing && return _parse_float(raw)
    min_value = float(contract["min"])
    max_value = float(contract["max"])
    if Bool(contract["is_int"])
      return float(clamp(_parse_int(raw), Int(round(min_value)), Int(round(max_value))))
    end
    return clamp(_parse_float(raw), min_value, max_value)
  end

  managed_dims = collect(keys(_POLYPHONIC_DIMENSION_CONTRACT))
  dim_accept = Dict{String,Bool}()
  dim_fixed = Dict{String,Float64}()
  dim_fixed_source = Dict{String,String}()

  function _normalize_fixed_value_source(raw)::String
    s = lowercase(strip(string(raw)))
    s in ("initial_context_last_step", "initial_context", "context_last_step", "last_step", "last-step") && return "initial_context_last_step"
    return "manual_input"
  end

  # Internal defaults and UI metadata share one JSON contract. UI defaults
  # remain separate fields so server-only requests preserve their historical policy.
  default_dim_policy = Dict{String,Dict{String,Any}}(
    key => Dict(
      "accept_params" => Bool(contract["server_default_accept_params"]),
      "fixed_value" => contract["server_default_fixed_value"],
    )
    for (key, contract) in _POLYPHONIC_DIMENSION_CONTRACT
  )
  for key in managed_dims
    d = default_dim_policy[key]
    dim_accept[key] = _parse_bool(get(d, "accept_params", true), true)
    dim_fixed[key] = _normalize_fixed_value_for_dim(key, get(d, "fixed_value", 0.0))
    dim_fixed_source[key] = "manual_input"
  end

  # Optional request-time override:
  # generate_polyphonic.dimension_policy = {
  #   vol: { accept_params: false, fixed_value: 1.0 }, cr: {...}, den: {...}, ...
  # }
  # generate_polyphonic.default_dim_policy also works as an alias.
  raw_dim_policy_src = get(gp, "dimension_policy", get(gp, "default_dim_policy", nothing))
  raw_dim_policy = _to_string_dict(raw_dim_policy_src)
  for (raw_key, raw_val) in raw_dim_policy
    key = _canonical_dim_key(raw_key)
    key === nothing && continue

    if raw_val isa AbstractDict
      p = _to_string_dict(raw_val)
      accept_src =
        haskey(p, "accept_params") ? p["accept_params"] :
        haskey(p, "receive_params") ? p["receive_params"] :
        haskey(p, "enabled") ? p["enabled"] :
        haskey(p, "use_user_params") ? p["use_user_params"] : nothing
      source_src =
        haskey(p, "fixed_value_source") ? p["fixed_value_source"] :
        haskey(p, "fixed_source") ? p["fixed_source"] :
        haskey(p, "value_source") ? p["value_source"] : nothing
      fixed_src =
        haskey(p, "fixed_value") ? p["fixed_value"] :
        haskey(p, "fallback_value") ? p["fallback_value"] :
        haskey(p, "value") ? p["value"] : nothing

      if accept_src !== nothing
        dim_accept[key] = _parse_bool(accept_src, dim_accept[key])
      end
      if source_src !== nothing
        dim_fixed_source[key] = _normalize_fixed_value_source(source_src)
      end
      if fixed_src !== nothing
        dim_fixed[key] = _normalize_fixed_value_for_dim(key, fixed_src)
      end
    elseif raw_val isa Bool
      dim_accept[key] = raw_val
    elseif raw_val !== nothing
      dim_fixed[key] = _normalize_fixed_value_for_dim(key, raw_val)
    end
  end

  function _anchor_from_stream(st::Vector{Any})::Int
    if length(st) >= note_abs_idx && st[note_abs_idx] isa AbstractVector
      abs_notes = Int[]
      for v in st[note_abs_idx]
        push!(abs_notes, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
      end
      if !isempty(abs_notes)
        sort!(abs_notes)
        return abs_notes[cld(length(abs_notes), 2)]
      end
    end
    return Int(Config.abs_pitch_min())
  end

  initial_last_step_snapshot = Any[]

  function _fixed_area_band_low_for_stream(stream_idx::Int)::Int
    if get(dim_fixed_source, "area", "manual_input") == "initial_context_last_step"
      last_step = initial_last_step_snapshot
      if 1 <= stream_idx <= length(last_step)
        anchor = _anchor_from_stream(last_step[stream_idx])
        return Config.area_band_low(anchor)
      end
    end

    v01 = clamp(dim_fixed["area"], 0.0, 1.0)
    n_bins = max(Int(fld(BAND_LOW_MAX - BAND_LOW_MIN, BAND_SIZE)), 0)
    idx = clamp(round(Int, v01 * n_bins), 0, n_bins)
    return clamp(BAND_LOW_MIN + (idx * BAND_SIZE), BAND_LOW_MIN, BAND_LOW_MAX)
  end

  function _resolved_fixed_value_for_stream(key::String, stream_idx::Int)::Float64
    if get(dim_fixed_source, key, "manual_input") != "initial_context_last_step"
      return dim_fixed[key]
    end

    if key == "area"
      band_low = _fixed_area_band_low_for_stream(stream_idx)
      n_bins = max(Int(fld(BAND_LOW_MAX - BAND_LOW_MIN, BAND_SIZE)), 0)
      n_bins <= 0 && return 0.0
      idx = clamp(Int(fld(band_low - BAND_LOW_MIN, BAND_SIZE)), 0, n_bins)
      return clamp(float(idx) / float(n_bins), 0.0, 1.0)
    end

    idx =
      key == "vol" ? vol_idx :
      key == "brightness" ? brightness_idx :
      key == "noise" ? noise_idx :
      key == "harmonicity" ? harmonicity_idx :
      key == "attack" ? attack_idx :
      key == "decay_sustain" ? decay_sustain_idx :
      key == "release" ? release_idx :
      key == "chord_range" ? chord_range_idx :
      key == "density" ? density_idx : 0

    if idx == 0
      return dim_fixed[key]
    end

    last_step = initial_last_step_snapshot
    if !(1 <= stream_idx <= length(last_step))
      return dim_fixed[key]
    end

    st = last_step[stream_idx]
    if length(st) < idx
      return dim_fixed[key]
    end

    return _normalize_fixed_value_for_dim(key, st[idx])
  end

  function _apply_fixed_dimension_values!(st::Vector{Any}, stream_idx::Int)
    if !get(dim_accept, "vol", true)
      st[vol_idx] = _resolved_fixed_value_for_stream("vol", stream_idx)
    end
    if !get(dim_accept, "brightness", true)
      st[brightness_idx] = _resolved_fixed_value_for_stream("brightness", stream_idx)
    end
    if !get(dim_accept, "noise", true)
      st[noise_idx] = _resolved_fixed_value_for_stream("noise", stream_idx)
    end
    if !get(dim_accept, "harmonicity", true)
      st[harmonicity_idx] = _resolved_fixed_value_for_stream("harmonicity", stream_idx)
    end
    if !get(dim_accept, "attack", true)
      st[attack_idx] = _resolved_fixed_value_for_stream("attack", stream_idx)
    end
    if !get(dim_accept, "decay_sustain", true)
      st[decay_sustain_idx] = _resolved_fixed_value_for_stream("decay_sustain", stream_idx)
    end
    if !get(dim_accept, "release", true)
      st[release_idx] = _resolved_fixed_value_for_stream("release", stream_idx)
    end
    if !get(dim_accept, "chord_range", true)
      st[chord_range_idx] = Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", stream_idx), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX))))
    end
    if !get(dim_accept, "density", true)
      st[density_idx] = _resolved_fixed_value_for_stream("density", stream_idx)
    end
    return st
  end


  function _normalize_abs_notes(x)::Vector{Int}
    out = Int[]
    if x isa AbstractVector
      for v in x
        v === nothing && continue
        push!(out, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
      end
    elseif x === nothing
      # noop
    else
      push!(out, clamp(_parse_int(x), ABS_MIN, ABS_MAX))
    end
    sort!(out)
    isempty(out) && push!(out, Int(Config.abs_pitch_min()))
    return out
  end
  function _normalize_stream!(st::Vector{Any})
    length(st) == 11 || error("generate_polyphonic.initial_context stream record must contain exactly 11 elements.")

    st[1] isa AbstractVector || error("generate_polyphonic.initial_context stream record must start with abs_notes.")
    abs_notes = _normalize_abs_notes(st[1])
    vol = clamp(_parse_float(st[2]), 0.0, 1.0)
    brightness = clamp(_parse_float(st[3]), 0.0, 1.0)
    noise = clamp(_parse_float(st[4]), 0.0, 1.0)
    harmonicity = clamp(_parse_float(st[5]), 0.0, 1.0)
    attack = clamp(_parse_float(st[6]), 0.0, 1.0)
    decay_sustain = clamp(_parse_float(st[7]), 0.0, 1.0)
    release = clamp(_parse_float(st[8]), 0.0, 1.0)
    cr = max(_parse_int(st[9]), 0)
    den = clamp(_parse_float(st[10]), 0.0, 1.0)
    tie = clamp(_parse_float(st[tie_idx]), 0.0, 1.0)

    empty!(st)
    push!(st, abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, cr, den, tie)
    return st
  end

  function _tie_render_compatible(previous::Vector{Any}, current::Vector{Any})::Bool
    previous_notes = _normalize_abs_notes(previous[note_abs_idx])
    current_notes = _normalize_abs_notes(current[note_abs_idx])
    previous_notes == current_notes || return false
    isempty(current_notes) && return false

    previous_vol = clamp(_parse_float(previous[vol_idx]), 0.0, 1.0)
    current_vol = clamp(_parse_float(current[vol_idx]), 0.0, 1.0)
    previous_vol > Config.SC_MIN_AUDIBLE_VOLUME || return false
    current_vol > Config.SC_MIN_AUDIBLE_VOLUME || return false

    # The renderer retains these controls from the first event in a tied run.
    # Only sustain/release may change because it is updated at the run tail.
    for idx in (vol_idx, brightness_idx, noise_idx, harmonicity_idx, attack_idx, decay_sustain_idx)
      isapprox(_parse_float(previous[idx]), _parse_float(current[idx]); atol=1e-9, rtol=0.0) || return false
    end
    return true
  end

  function _quantize_tie_value(raw)::Float64
    value = clamp(_parse_float(raw), 0.0, 1.0)
    return Config.TIE_STEPS[argmin(abs.(Config.TIE_STEPS .- value))]
  end

  for step in results
    for st in step
      _normalize_stream!(st)
    end
  end

  initial_context_steps = length(results)
  result_stream_ids = Vector{Int}[
    Int[stream_idx for stream_idx in 1:length(step)]
    for step in results
  ]

  # Clustered tie history contains eligible boundaries only. Initial records are
  # quantized to the three-level output here so an ineligible context boundary cannot
  # be rendered as a continuation or seed the tie managers as an ordinary OFF.
  initial_tie_stream_history = Dict{Int,Vector{Float64}}()
  initial_tie_global_history = Vector{Vector{Float64}}()
  if clustered_tie_enabled
    previous_initial_by_id = Dict{Int,Vector{Any}}()
    for step_idx in 1:length(results)
      current_initial_by_id = Dict{Int,Vector{Any}}()
      eligible_bits = Float64[]
      for (slot, stream_id) in enumerate(result_stream_ids[step_idx])
        slot <= length(results[step_idx]) || continue
        current = results[step_idx][slot]
        raw_value = _quantize_tie_value(current[tie_idx])
        previous = get(previous_initial_by_id, stream_id, nothing)
        if previous !== nothing && _tie_render_compatible(previous, current)
          current[tie_idx] = raw_value
          push!(get!(initial_tie_stream_history, stream_id, Float64[]), raw_value)
          push!(eligible_bits, raw_value)
        else
          current[tie_idx] = 0.0
        end
        current_initial_by_id[stream_id] = current
      end
      if !isempty(eligible_bits)
        push!(initial_tie_global_history, Float64[sum(eligible_bits) / float(length(eligible_bits))])
      end
      previous_initial_by_id = current_initial_by_id
    end
  end

  function _note_pool_geometry(band_low_raw::Integer, chord_range_raw::Integer)::Tuple{Int,Int,Int}
    band_low = clamp(Int(band_low_raw), BAND_LOW_MIN, BAND_LOW_MAX)
    band_high = min(band_low + (BAND_SIZE - 1), ABS_MAX)
    chord_range = clamp(Int(chord_range_raw), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
    low = clamp(band_low - chord_range, ABS_MIN, ABS_MAX)
    high = clamp(band_high + chord_range, ABS_MIN, ABS_MAX)
    return (low, high, max(high - low + 1, 1))
  end

  function _note_count_from_density(density_raw::Real, slot_count::Integer)::Int
    slots = max(Int(slot_count), 1)
    density = clamp(float(density_raw), 0.0, 1.0)
    return clamp(Int(round(density * float(slots))), 1, slots)
  end

  # CR/DEN are canonical per-stream generation controls. The frontend does not
  # expose them in initial-context rows, so infer compatible seed controls from
  # the notes while preserving the strict 11-element record contract.
  for step_idx in 1:initial_context_steps
    step = results[step_idx]
    for st in step
      abs_notes = _normalize_abs_notes(st[note_abs_idx])
      st[note_abs_idx] = abs_notes
      inferred_cr, inferred_den = infer_chord_range_and_density_controls(abs_notes)
      st[chord_range_idx] = inferred_cr
      st[density_idx] = inferred_den
    end
  end

  initial_last_step_snapshot = isempty(results) ? Any[] : deepcopy(results[end])

  merge_threshold_ratio = _parse_float(get(gp, "merge_threshold_ratio", Config.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO))
  min_window = Config.POLYPHONIC_MIN_WINDOW_SIZE

  function pad_history!(mat, fallback_row)
    if length(mat) < (min_window + 1)
      last_row = !isempty(mat) ? deepcopy(mat[end]) : deepcopy(fallback_row)
      for _ in 1:((min_window + 1) - length(mat))
        push!(mat, deepcopy(last_row))
      end
    end
    return mat
  end

  function pad_series!(ser::Vector{Vector{Float64}}, fallback::Vector{Float64})
    if length(ser) < (min_window + 1)
      last_row = !isempty(ser) ? deepcopy(ser[end]) : deepcopy(fallback)
      for _ in 1:((min_window + 1) - length(ser))
        push!(ser, deepcopy(last_row))
      end
    end
    return ser
  end

  function _anchor_from_abs(abs_notes)::Int
    if abs_notes isa AbstractVector && !isempty(abs_notes)
      s = sort(Int[_parse_int(x) for x in abs_notes])
      return clamp(s[cld(length(s), 2)], ABS_MIN, ABS_MAX)
    else
      return Int(Config.abs_pitch_min())
    end
  end

  function _restrict_area_anchors_by_register_window(
    anchors::Vector{Int},
    register_center::Float64,
    allowance::Float64
  )::Vector{Int}
    isempty(anchors) && return Int[]

    filtered = Int[]
    best_anchor = anchors[1]
    best_distance = Inf
    band_center_offset = float(BAND_SIZE - 1) / 2.0

    for anchor in anchors
      dist = abs((float(anchor) + band_center_offset) - register_center)
      if dist < best_distance - 1e-12
        best_distance = dist
        best_anchor = anchor
      end
      if dist <= allowance + 1e-9
        push!(filtered, anchor)
      end
    end

    if isempty(filtered)
      return Int[best_anchor]
    end

    return filtered
  end

  function _global_anchor_from_step(step)::Int
    alln = Int[]
    for st in step
      abs_notes = st[note_abs_idx]
      if abs_notes isa AbstractVector
        for v in abs_notes
          push!(alln, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
        end
      end
    end
    isempty(alln) && push!(alln, Int(Config.abs_pitch_min()))
    sort!(alln)
    return alln[cld(length(alln), 2)]
  end

  # ----------------------------------------------------------
  # Histories
  # ----------------------------------------------------------
  function matrix_for_idx(idx::Int)
    return [ [ (length(st) >= idx ? st[idx] : 0) for st in step ] for step in results ]
  end

  hist_vol          = matrix_for_idx(vol_idx)
  hist_brightness   = matrix_for_idx(brightness_idx)
  hist_noise = matrix_for_idx(noise_idx)
  hist_harmonicity    = matrix_for_idx(harmonicity_idx)
  hist_attack    = matrix_for_idx(attack_idx)
  hist_decay_sustain  = matrix_for_idx(decay_sustain_idx)
  hist_release  = matrix_for_idx(release_idx)
  hist_cr           = matrix_for_idx(chord_range_idx)
  hist_den          = matrix_for_idx(density_idx)

  hist_note_anchor = Vector{Vector{Int}}()
  note_global_series = Vector{Vector{Float64}}()

  for step in results
    row = Int[]
    for st in step
      push!(row, _anchor_from_abs(st[note_abs_idx]))
    end
    push!(hist_note_anchor, row)
    push!(note_global_series, Float64[float(_global_anchor_from_step(step))])
  end

    # area(tmp_anchor) history: 4-semitone band base (0..124)
  hist_area_tmp_anchor = Vector{Vector{Int}}()
  for row in hist_note_anchor
    tmp = Int[]
    for a in row
      push!(tmp, Config.area_band_low(a))
    end
    push!(hist_area_tmp_anchor, tmp)
  end


  initial_stream_count = 1
  for step in results
    initial_stream_count = max(initial_stream_count, length(step))
  end
  first_streams = initial_stream_count
  history_stream_ids = deepcopy(result_stream_ids)

  pad_history!(hist_vol,          [1.0 for _ in 1:first_streams])
  pad_history!(hist_brightness,   [0.5 for _ in 1:first_streams])
  pad_history!(hist_noise, [0.5 for _ in 1:first_streams])
  pad_history!(hist_harmonicity,    [0.5 for _ in 1:first_streams])
  pad_history!(hist_attack,    [0.5 for _ in 1:first_streams])
  pad_history!(hist_decay_sustain,  [0.5 for _ in 1:first_streams])
  pad_history!(hist_release,  [0.5 for _ in 1:first_streams])
  pad_history!(hist_cr,           [0   for _ in 1:first_streams])
  pad_history!(hist_den,          [0.0 for _ in 1:first_streams])
  pad_history!(hist_note_anchor, [Int(Config.abs_pitch_min()) for _ in 1:first_streams])
  pad_history!(hist_area_tmp_anchor, [Config.area_band_low(Config.abs_pitch_min()) for _ in 1:first_streams])
  pad_history!(history_stream_ids, collect(1:first_streams))

  pad_series!(note_global_series, Float64[float(Config.abs_pitch_min())])

  max_streams = initial_stream_count
  if !isempty(stream_counts)
    max_streams = max(max_streams, maximum(stream_counts))
  end

  stream_axis_capacity = _required_stream_axis_capacity(initial_stream_count, stream_counts)
  initial_axis_ids = Int[]
  for ids in result_stream_ids
    append!(initial_axis_ids, ids)
  end
  stream_axis = StableStreamAxis(stream_axis_capacity, initial_axis_ids)

  voice_inventory = nothing
  voice_state = nothing
  if any(count -> count > 0, voice_stream_counts)
    inventory_id = strip(string(get(gp, "voice_inventory_id", "ja_voicevox_all")))
    occursin(r"^[A-Za-z0-9_-]+$", inventory_id) || error(
      "generate_polyphonic.voice_inventory_id may contain only letters, digits, underscore, and hyphen.",
    )
    inventory_dir = normpath(joinpath(@__DIR__, "..", "..", "config", "voice_inventories"))
    inventory_path = joinpath(inventory_dir, "$(inventory_id).json")
    voice_inventory = VoiceTokenGeneration.load_inventory(inventory_path)
    voice_inventory.id == inventory_id || error(
      "Voice inventory id $(voice_inventory.id) does not match requested id $(inventory_id).",
    )
    voice_state = VoiceTokenGeneration.VoiceTokenState(
      voice_inventory,
      unique(initial_axis_ids),
      merge_threshold_ratio,
      min_window,
    )
  end

  voice_plan = Vector{Vector{Any}}()
  initial_voice_plan = get(gp, "initial_context_voice_plan", Any[])
  for (step_idx, ids) in enumerate(result_stream_ids)
    step_plan = Any[]
    for (slot, stream_id) in enumerate(ids)
      notes = slot <= length(results[step_idx]) ? copy(results[step_idx][slot][note_abs_idx]) : Int[]
      initial_voice_entry = nothing
      if step_idx <= initial_context_steps && initial_voice_plan isa AbstractVector && step_idx <= length(initial_voice_plan)
        for raw_entry in initial_voice_plan[step_idx]
          try
            entry = _to_string_dict(raw_entry)
            Int(entry["streamId"]) == stream_id || continue
            initial_voice_entry = entry
            break
          catch
          end
        end
      end
      raw_initial_text = initial_voice_entry === nothing ? nothing : get(initial_voice_entry, "text", nothing)
      # A JSON null must remain an empty lyric. `string(nothing)` is the
      # literal "nothing", which was incorrectly marked as a voice token.
      initial_text = raw_initial_text === nothing ? "" : strip(string(raw_initial_text))
      lowercase(initial_text) == "nothing" && (initial_text = "")
      initial_mode = isempty(initial_text) ? "synth" : "voice"
      push!(step_plan, Dict(
        "streamId" => stream_id,
        "mode" => initial_mode,
        "token" => nothing,
        "text" => isempty(initial_text) ? nothing : initial_text,
        "phones" => String[],
        "carrierNote" => nothing,
        "notes" => notes,
      ))
    end
    push!(voice_plan, step_plan)
  end
  # Initial lyrics must seed the token managers; otherwise they are only
  # echoed in the response and have no effect on subsequent generation.
  voice_state !== nothing && VoiceTokenGeneration.seed_initial_tokens!(voice_state, voice_plan)

  # ----------------------------------------------------------
  # Managers
  # ----------------------------------------------------------
  managers = Dict{String,Dict{Symbol,Any}}()

  function _safe_width(vmin::Real, vmax::Real)::Float64
    width = abs(float(vmax) - float(vmin))
    return width <= 0.0 ? 1.0 : width
  end

  function offset_for_range(vmin::Real, vmax::Real)::Float64
    return _safe_width(vmin, vmax) + 1.0
  end

  function global_series_from_matrix(mat, id_rows, axis::StableStreamAxis, offset::Real)
    length(mat) == length(id_rows) || error(
      "Global history has $(length(mat)) value rows but $(length(id_rows)) stable-ID rows.",
    )
    series = Vector{Vector{Float64}}()
    sizehint!(series, length(mat))
    for row_idx in eachindex(mat)
      row = mat[row_idx]
      ids = id_rows[row_idx]
      length(row) == length(ids) || error(
        "Global history row $(row_idx) has $(length(row)) values but $(length(ids)) stable IDs.",
      )
      push!(series, _encode_streamwise_row(axis, ids, row, offset))
    end
    return series
  end

  function _setup_dimension_manager!(
    key::String,
    history,
    value_range;
    value_min::Real,
    value_max::Real,
    global_capacity::Int,
    track_presence::Bool=false,
  )
    offset = offset_for_range(value_min, value_max)
    observed_global_row_width = 1
    for row in history
      observed_global_row_width = max(observed_global_row_width, length(row))
    end
    global_row_width = max(Int(global_capacity), 1)
    observed_global_row_width <= global_row_width || error(
      "$(key) global history width $(observed_global_row_width) exceeds configured row capacity $(global_row_width).",
    )

    s_mgr = MultiStreamManager.Manager(
      history,
      merge_threshold_ratio,
      min_window;
      use_complexity_mapping=true,
      value_range=value_range,
      track_presence=track_presence,
      recency=0.0
    )
    encoded_max = float(value_max) + (float(stream_axis.capacity - 1) * offset)
    g_mgr = PolyphonicClusterManager.Manager(
      global_series_from_matrix(history, history_stream_ids, stream_axis, offset),
      merge_threshold_ratio,
      min_window;
      use_streamwise_surface_average=true,
      stream_axis_offset=offset,
      stream_axis_capacity=stream_axis.capacity,
      value_min=float(value_min),
      value_max=encoded_max,
      range_min=float(value_min),
      range_max=encoded_max,
      max_set_size=global_row_width,
      recency=0.0
    )
    PolyphonicClusterManager.process_data!(g_mgr)
    PolyphonicClusterManager.update_caches_permanently(g_mgr)
    managers[key] = Dict(
      :global => g_mgr,
      :stream => s_mgr,
      :global_offset => offset,
      :global_capacity => global_row_width,
      :stream_axis => stream_axis,
    )
  end

  for (key, history, track_presence) in (
    ("vol", hist_vol, true),
    ("brightness", hist_brightness, false),
    ("noise", hist_noise, false),
    ("harmonicity", hist_harmonicity, false),
    ("attack", hist_attack, false),
    ("decay_sustain", hist_decay_sustain, false),
    ("release", hist_release, false)
  )
    if key == "vol" || get(dim_accept, key, true)
      _setup_dimension_manager!(
        key,
        history,
        key == "vol" ? Config.VOL_STEPS : Config.FLOAT_STEPS;
        value_min=0.0,
        value_max=1.0,
        global_capacity=max_streams,
        track_presence=track_presence
      )
    end
  end

  cr_values = collect(Config.CHORD_RANGE_SEARCH_RANGE)
  cr_min = float(first(Config.CHORD_RANGE_SEARCH_RANGE))
  cr_max = float(last(Config.CHORD_RANGE_SEARCH_RANGE))
  if get(dim_accept, "chord_range", true)
    _setup_dimension_manager!(
      "chord_range",
      hist_cr,
      cr_values;
      value_min=cr_min,
      value_max=cr_max,
      global_capacity=max_streams,
      track_presence=true
    )
  end

  if get(dim_accept, "density", true)
    _setup_dimension_manager!(
      "density",
      hist_den,
      Config.FLOAT_STEPS;
      value_min=0.0,
      value_max=1.0,
      global_capacity=max_streams,
      track_presence=true
    )
  end

  if clustered_tie_enabled
    tie_global_history = deepcopy(initial_tie_global_history)
    pad_series!(tie_global_history, Float64[0.0])

    tie_initial_stream_count = isempty(result_stream_ids) ? first_streams : max(length(result_stream_ids[1]), 1)
    tie_seed_history = Vector{Float64}[
      fill(0.0, tie_initial_stream_count)
      for _ in 1:(min_window + 1)
    ]
    tie_stream_mgr = MultiStreamManager.Manager(
      tie_seed_history,
      merge_threshold_ratio,
      min_window;
      use_complexity_mapping=true,
      value_range=Config.TIE_STEPS,
      track_presence=false,
      recency=0.0,
    )
    for container in tie_stream_mgr.stream_pool
      eligible_values = get(initial_tie_stream_history, container.id, Float64[])
      eligible_series = Vector{Float64}[Float64[value] for value in eligible_values]
      pad_series!(eligible_series, Float64[0.0])
      container.manager = MultiStreamManager.build_stream_manager(
        eligible_series,
        float(merge_threshold_ratio),
        min_window;
        value_min=0.0,
        value_max=1.0,
        max_set_size=1,
        recency=0.0,
      )
      container.last_value = copy(eligible_series[end])
    end
    tie_global_mgr = PolyphonicClusterManager.Manager(
      tie_global_history,
      merge_threshold_ratio,
      min_window;
      value_min=0.0,
      value_max=1.0,
      range_min=0.0,
      range_max=1.0,
      max_set_size=1,
      recency=0.0,
    )
    PolyphonicClusterManager.process_data!(tie_global_mgr)
    PolyphonicClusterManager.update_caches_permanently(tie_global_mgr)
    managers["tie"] = Dict(
      :global => tie_global_mgr,
      :stream => tie_stream_mgr,
      :global_scalar => true,
    )
  end

  area_min = float(BAND_LOW_MIN)
  area_max = float(BAND_LOW_MAX)
  _setup_dimension_manager!(
    "area",
    hist_area_tmp_anchor,
    collect(BAND_LOW_MIN:BAND_SIZE:BAND_LOW_MAX);
    value_min=area_min,
    value_max=area_max,
    global_capacity=max_streams,
    track_presence=true
  )

  # note (global: scalar anchor, stream: anchor per stream)
  note_min = float(ABS_MIN)
  note_max = float(ABS_MAX)
  s_note = MultiStreamManager.Manager(
    hist_note_anchor,
    merge_threshold_ratio,
    min_window;
    use_complexity_mapping=true,
    value_range=collect(ABS_MIN:ABS_MAX),
    track_presence=true,
    recency=0.0
  )
  g_note = PolyphonicClusterManager.Manager(
    note_global_series,
    merge_threshold_ratio,
    min_window;
    value_min=note_min,
    value_max=note_max,
    range_min=note_min,
    range_max=note_max,
    max_set_size=1,
    recency=0.0
  )
  PolyphonicClusterManager.process_data!(g_note)
  PolyphonicClusterManager.update_caches_permanently(g_note)
  managers["note"] = Dict(:global => g_note, :stream => s_note)

  function _apply_step_recency!(idx0::Int, desired_stream_count::Int)
    recency_center = clamp(_parse_float(array_param(gp, "recency_center", idx0)), 0.0, 1.0)
    recency_spread = clamp(_parse_float(array_param(gp, "recency_spread", idx0)), 0.0, 1.0)
    stream_recencies = generate_centered_targets(desired_stream_count, recency_center, recency_spread)
    global_recency = isempty(stream_recencies) ? recency_center : clamp(sum(stream_recencies) / float(length(stream_recencies)), 0.0, 1.0)

    for (_key, mgrs) in managers
      g_mgr = get(mgrs, :global, nothing)
      if g_mgr !== nothing
        g_mgr.recency = global_recency
      end

      s_mgr = get(mgrs, :stream, nothing)
      if s_mgr !== nothing
        s_mgr.recency = global_recency
        actives = MultiStreamManager.active_stream_containers(s_mgr, desired_stream_count)
        for c in s_mgr.stream_pool
          c.manager.recency = global_recency
        end
        for (i, c) in enumerate(actives)
          r = i <= length(stream_recencies) ? stream_recencies[i] : global_recency
          c.manager.recency = clamp(r, 0.0, 1.0)
        end
      end
    end

    return nothing
  end

  # ----------------------------------------------------------
  # Dissonance STM seed
  # ----------------------------------------------------------
  stm_mgr = DissonanceStmManager.Manager(
    memory_span=Config.DISSONANCE_STM_MEMORY_SPAN,
    memory_weight=Config.DISSONANCE_STM_MEMORY_WEIGHT,
    n_partials=Config.DISSONANCE_STM_N_PARTIALS,
    amp_profile=Config.DISSONANCE_STM_AMP_PROFILE
  )

  for (i, step) in enumerate(results)
    midi_notes = Int[]
    amps = Float64[]
    for st in step
      abs_notes = _normalize_abs_notes(st[note_abs_idx])
      vol = clamp(_parse_float(st[vol_idx]), 0.0, 1.0)
      a_each = isempty(abs_notes) ? vol : (vol / float(length(abs_notes)))
      for n in abs_notes
        push!(midi_notes, n)
        push!(amps, a_each)
      end
    end
    onset = i <= length(initial_step_onsets) ? initial_step_onsets[i] : base_onset
    DissonanceStmManager.commit!(stm_mgr, midi_notes, amps, onset)
  end

  function _tie_concordance_cost(values::Vector{Float64}, raw_concordance::Real)::Float64
    m = length(values)
    m < 2 && return 0.0
    pairwise_distance = 0.0
    pair_count = 0
    for i in 1:(m - 1), j in (i + 1):m
      pairwise_distance += abs(values[i] - values[j])
      pair_count += 1
    end
    disagreement01 = pair_count > 0 ? clamp(pairwise_distance / float(pair_count), 0.0, 1.0) : 0.0
    concordance = clamp(float(raw_concordance), -1.0, 1.0)
    if concordance > 0.0
      return concordance * disagreement01
    elseif concordance < 0.0
      return abs(concordance) * (1.0 - disagreement01)
    end
    return 0.0
  end

  previous_step_by_id = Dict{Int,Vector{Any}}()
  if clustered_tie_enabled
    for step_idx in 1:length(results)
      current_by_id = Dict{Int,Vector{Any}}()
      ids = result_stream_ids[step_idx]
      for (slot, stream_id) in enumerate(ids)
        slot <= length(results[step_idx]) || continue
        current = results[step_idx][slot]
        current_by_id[stream_id] = current
        previous = get(previous_step_by_id, stream_id, nothing)
        if previous !== nothing && _tie_render_compatible(previous, current)
          current[tie_idx] = _quantize_tie_value(current[tie_idx])
        end
      end
      previous_step_by_id = current_by_id
    end
  elseif !isempty(results)
    previous_step_by_id = Dict{Int,Vector{Any}}(
      stream_id => results[end][slot]
      for (slot, stream_id) in enumerate(result_stream_ids[end])
      if slot <= length(results[end])
    )
  end

  steps_to_generate = length(stream_counts)
  base_step_index = length(results)
  flush(stdout)

  function _recent_register_center_for_stream(note_stream_mgr, stream_id::Int)::Float64
    stream = get(note_stream_mgr.containers_by_id, stream_id, nothing)
    stream === nothing && error("Active note stream ID $(stream_id) has no container.")
    anchors = Int[]
    recent_steps = max(Int(Config.NOTE_REGISTER_MEMORY_STEPS), 1)
    data_len = length(stream.manager.data)
    start_idx = max(data_len - recent_steps + 1, 1)

    for i in start_idx:data_len
      value = stream.manager.data[i]
      isempty(value) && continue
      push!(anchors, clamp(round(Int, value[1]), ABS_MIN, ABS_MAX))
    end

    if isempty(anchors)
      return isempty(stream.last_value) ? float(ABS_MIN) : clamp(float(stream.last_value[1]), float(ABS_MIN), float(ABS_MAX))
    end

    sort!(anchors)
    return float(anchors[cld(length(anchors), 2)])
  end

  function _restrict_candidates_with_target_window(
    key::String,
    search_values::Vector{Float64},
    idx0::Int
  )::Vector{Float64}
    if !(key == "vol" || key == "brightness" || key == "noise" || key == "harmonicity" || key == "attack" || key == "decay_sustain" || key == "release" || key == "chord_range" || key == "density" || key == "tie")
      return search_values
    end

    isempty(search_values) && return search_values

    target_raw = array_param_alias(
      gp,
      idx0,
      "$(key)_value_target",
      "$(key)_target",
    )
    if key == "tie" && target_raw === nothing
      # Old params.json files used rate terminology. Treat that value as the
      # canonical three-level value target when loading them.
      target_raw = array_param(gp, "tie_rate_target", idx0)
    end
    spread_raw = array_param_alias(
      gp,
      idx0,
      "$(key)_value_radius",
      "$(key)_target_spread",
    )
    if key == "tie" && spread_raw === nothing && haskey(gp, "tie_rate_target")
      spread_raw = 0.0
    end
    if target_raw === nothing && spread_raw === nothing
      return search_values
    end

    vmin = minimum(search_values)
    vmax = maximum(search_values)
    default_target = (vmin + vmax) / 2.0
    default_spread = (vmax - vmin)

    target = clamp(_parse_float(target_raw === nothing ? default_target : target_raw), vmin, vmax)
    spread = abs(_parse_float(spread_raw === nothing ? default_spread : spread_raw))

    low = clamp(target - spread, vmin, vmax)
    high = clamp(target + spread, vmin, vmax)

    filtered = Float64[v for v in search_values if v >= (low - 1e-9) && v <= (high + 1e-9)]
    if !isempty(filtered)
      return filtered
    end

    nearest_idx = 1
    nearest_dist = Inf
    for (i, v) in enumerate(search_values)
      d = abs(v - target)
      if d < nearest_dist
        nearest_dist = d
        nearest_idx = i
      end
    end
    return Float64[search_values[nearest_idx]]
  end

  function _metric_weights_for_dimension(
    _key::String,
    _idx0::Int,
    scope::String
  )::NTuple{3,Float64}
    scope_l = lowercase(scope)
    scope_l == "global" && return Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS
    scope_l == "stream" && return Config.POLYPHONIC_STREAM_METRIC_WEIGHTS
    error("scope must be global or stream")
  end

  # ----------------------------------------------------------
  # Main generation loop
  # ----------------------------------------------------------
  for step_idx in 1:steps_to_generate
    committed_step_state = (
      managers=managers,
      stm_mgr=stm_mgr,
      stream_axis=stream_axis,
      voice_state=voice_state,
    )
    staged_step_state = _stage_generate_polyphonic_step_state(managers, stm_mgr, stream_axis, voice_state)
    managers = staged_step_state.managers
    stm_mgr = staged_step_state.stm_mgr
    stream_axis = staged_step_state.stream_axis
    voice_state = staged_step_state.voice_state

    results_len_before_step = length(results)
    stream_ids_len_before_step = length(result_stream_ids)
    voice_plan_len_before_step = length(voice_plan)
    # Previous rows are read-only in this step; only the dictionary binding is
    # replaced after success. Retain it for rollback without copying history.
    previous_step_by_id_before = previous_step_by_id
    failure_context = Dict{Symbol,Any}(
      :operation => "step_setup",
      :dimension => nothing,
      :stream_id => nothing,
      :candidate => nothing,
    )

    try
    desired_stream_count = max(stream_counts[step_idx], 1)
    desired_stream_count <= max_streams || error(
      "Requested $(desired_stream_count) streams exceeds global capacity $(max_streams).",
    )

    st_target = step_idx <= length(strength_targets) ? strength_targets[step_idx] : Config.DEFAULT_TARGET_01
    st_spread = step_idx <= length(strength_spreads) ? strength_spreads[step_idx] : Config.DEFAULT_SPREAD_01

    lifecycle_mgr = managers["vol"][:stream]
    _set_generation_failure_context!(failure_context; operation="lifecycle_plan")
    plan = MultiStreamManager.build_stream_lifecycle_plan(lifecycle_mgr, desired_stream_count; target=st_target, spread=st_spread)
    length(plan.active_ids) == desired_stream_count || error(
      "Lifecycle planned $(length(plan.active_ids)) active streams; expected $(desired_stream_count).",
    )
    length(unique(plan.active_ids)) == length(plan.active_ids) || error(
      "Lifecycle returned duplicate active stream IDs: $(plan.active_ids).",
    )
    _register_stream_ids!(stream_axis, plan.active_ids)

    # Apply one canonical ID order to every dimension before any recency,
    # candidate evaluation, or commit. Inspect active_ids directly here because
    # active_stream_containers() may resize that list as part of its API.
    for (manager_key, mgrs) in managers
      stream_mgr = mgrs[:stream]
      _set_generation_failure_context!(
        failure_context;
        operation="lifecycle_apply",
        dimension=manager_key,
      )
      MultiStreamManager.apply_stream_lifecycle_plan!(stream_mgr, plan)
      stream_mgr.active_ids == plan.active_ids || error(
        "$(manager_key) active stream IDs $(stream_mgr.active_ids) do not match lifecycle IDs $(plan.active_ids).",
      )
      missing_ids = Int[id for id in plan.active_ids if !haskey(stream_mgr.containers_by_id, id)]
      isempty(missing_ids) || error(
        "$(manager_key) has no containers for active stream IDs $(missing_ids).",
      )
    end
    idx0 = step_idx - 1
    _set_generation_failure_context!(failure_context; operation="apply_recency")
    _apply_step_recency!(idx0, desired_stream_count)
    step_stream_order = stream_priority_order(lifecycle_mgr, desired_stream_count)
    requested_voice_count = voice_stream_counts[step_idx]
    voice_ids = Int[]
    if voice_state !== nothing
      VoiceTokenGeneration.apply_lifecycle!(voice_state, plan)
      voice_ids = VoiceTokenGeneration.select_voice_ids!(
        voice_state,
        copy(plan.active_ids),
        requested_voice_count,
        step_stream_order,
      )
    end
    tie_values = if clustered_tie_enabled
      fill(0.0, desired_stream_count)
    else
      tie_center = step_idx <= length(tie_center_series) ? tie_center_series[step_idx] : 0.0
      tie_spread = step_idx <= length(tie_spread_series) ? tie_spread_series[step_idx] : 0.0
      [_quantize_tie_value(value) for value in generate_centered_targets(desired_stream_count, tie_center, tie_spread)]
    end

    current_step_values = [
      Any[
        Int[],
        clamp(_resolved_fixed_value_for_stream("vol", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("brightness", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("noise", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("harmonicity", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("attack", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("decay_sustain", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("release", s_i), 0.0, 1.0),
        Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", s_i), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))),
        clamp(_resolved_fixed_value_for_stream("density", s_i), 0.0, 1.0),
        tie_values[s_i]
      ] for s_i in 1:desired_stream_count
    ]
    step_decisions = Dict{String,Any}()

    vol_search_values = Float64[float(v) for v in Config.VOL_STEPS]
    density_search_values = Float64[float(v) for v in Config.FLOAT_STEPS]
    chord_range_search_values = Float64[float(v) for v in cr_values]

    dim_order = [
      ("vol",         vol_search_values,         vol_idx),
      ("chord_range", chord_range_search_values, chord_range_idx),
      ("density",     density_search_values,     density_idx),
      ("brightness",   Float64[float(v) for v in Config.FLOAT_STEPS], brightness_idx),
      ("noise", Float64[float(v) for v in Config.FLOAT_STEPS], noise_idx),
      ("harmonicity",    Float64[float(v) for v in Config.FLOAT_STEPS], harmonicity_idx),
      ("attack",    Float64[float(v) for v in Config.FLOAT_STEPS], attack_idx),
      ("decay_sustain",  Float64[float(v) for v in Config.FLOAT_STEPS], decay_sustain_idx),
      ("release",  Float64[float(v) for v in Config.FLOAT_STEPS], release_idx),
    ]

    for (key, range_vec, out_idx) in dim_order
      _set_generation_failure_context!(
        failure_context;
        operation="dimension_prepare",
        dimension=key,
      )
      if !get(dim_accept, key, true)
        fixed_vals = Float64[]
        sizehint!(fixed_vals, desired_stream_count)
        for s_i in 1:desired_stream_count
          fixed_v =
            if key == "chord_range"
              float(Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", s_i), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))))
            else
                clamp(_resolved_fixed_value_for_stream(key, s_i), 0.0, 1.0)
              end
          push!(fixed_vals, float(fixed_v))
        end
        step_decisions[key] = fixed_vals
        for s_i in 1:desired_stream_count
          if key == "chord_range"
            current_step_values[s_i][out_idx] = Int(round(fixed_vals[s_i]))
          else
            current_step_values[s_i][out_idx] = fixed_vals[s_i]
          end
        end
        if key == "vol"
          mgrs = managers["vol"]
          g_offset = get(mgrs, :global_offset, 0.0)
          global_vals = _encode_streamwise_row(stream_axis, plan.active_ids, fixed_vals, g_offset)
          _set_generation_failure_context!(failure_context; operation="commit_global", dimension="vol", candidate=copy(fixed_vals))
          PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], global_vals)
          PolyphonicClusterManager.update_caches_permanently(mgrs[:global])
          _set_generation_failure_context!(failure_context; operation="commit_streams", dimension="vol", candidate=copy(fixed_vals))
          MultiStreamManager.commit_state_staged!(mgrs[:stream], fixed_vals, (target=st_target, spread=st_spread))
          MultiStreamManager.update_caches_staged!(mgrs[:stream])
        end
        continue
      end

      mgrs = get(managers, key, nothing)
      mgrs === nothing && error("managers[\"$(key)\"] is missing while the dimension is enabled.")

      g_target = clamp(_parse_float(array_param_alias(gp, idx0, "$(key)_global_complexity_target", "$(key)_global")), 0.0, 1.0)
      s_center = clamp(_parse_float(array_param_alias(gp, idx0, "$(key)_stream_complexity_center", "$(key)_center")), 0.0, 1.0)
      s_spread = clamp(_parse_float(array_param_alias(gp, idx0, "$(key)_stream_complexity_span", "$(key)_spread")), 0.0, 1.0)
      conc_w   = _parse_float(array_param_alias(gp, idx0, "$(key)_concordance", "$(key)_conc"))
      global_metric_weights = _metric_weights_for_dimension(key, idx0, "global")
      stream_metric_weights = _metric_weights_for_dimension(key, idx0, "stream")

      stream_targets = generate_centered_targets(desired_stream_count, s_center, s_spread)

      restricted_range = _restrict_candidates_with_target_window(key, range_vec, idx0)
      isempty(restricted_range) && (restricted_range = range_vec)

      use_global_score = !(key == "vol" && desired_stream_count > 1)

      best_vals = select_best_values_for_dimension_greedy(
        mgrs,
        Float64[float(v) for v in restricted_range],
        g_target,
        stream_targets,
        conc_w,
        desired_stream_count;
        global_metric_weights=global_metric_weights,
        stream_metric_weights=stream_metric_weights,
        use_global_score=use_global_score,
        priority_order=step_stream_order,
        trace_context=failure_context,
        evaluation_budget=evaluation_budget,
      )

      # Commit the canonical stable-ID global row used by candidate evaluation.
      g_offset = get(mgrs, :global_offset, 0.0)
      global_vals = _encode_streamwise_row(stream_axis, plan.active_ids, best_vals, g_offset)
      _set_generation_failure_context!(failure_context; operation="commit_global", dimension=key, candidate=copy(best_vals))
      PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], global_vals)
      _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension=key, candidate=copy(best_vals))
      PolyphonicClusterManager.update_caches_permanently(mgrs[:global])

      _set_generation_failure_context!(failure_context; operation="commit_streams", dimension=key, candidate=copy(best_vals))
      if key == "vol"
        MultiStreamManager.commit_state_staged!(mgrs[:stream], best_vals, (target=st_target, spread=st_spread))
      else
        MultiStreamManager.commit_state_staged!(mgrs[:stream], best_vals)
      end
      _set_generation_failure_context!(failure_context; operation="commit_stream_caches", dimension=key, candidate=copy(best_vals))
      MultiStreamManager.update_caches_staged!(mgrs[:stream])

      step_decisions[key] = best_vals

      for s_i in 1:desired_stream_count
        if key == "chord_range"
          current_step_values[s_i][out_idx] = Int(trunc(best_vals[s_i]))
        else
          current_step_values[s_i][out_idx] = clamp(float(best_vals[s_i]), 0.0, 1.0)
        end
      end
    end

    # --------------------------------------------------------
    # NOTE generation (AREA tmp_anchor manager -> chord_range/density -> dissonance)
    #   - Evaluate/commit AREA using tmp_anchor clusters (managers["area"])
    #   - Then decide realized notes per stream by dissonance within the allowed band expanded by chord_range/density
    # --------------------------------------------------------
    area_mgrs = get(managers, "area", nothing)
    area_mgrs === nothing && error("managers[\"area\"] is missing. Please add AREA(tmp_anchor) managers before the main loop.")
    note_mgrs = managers["note"]

    # ---- AREA targets (same style as other dims) ----

    area_enabled = get(dim_accept, "area", true)
    area_fixed_target = clamp(dim_fixed["area"], 0.0, 1.0)
    area_global_target = area_enabled ? clamp(_parse_float(array_param(gp, "area_global", idx0)), 0.0, 1.0) : area_fixed_target
    area_center        = area_enabled ? clamp(_parse_float(array_param(gp, "area_center", idx0)), 0.0, 1.0) : area_fixed_target
    area_spread        = area_enabled ? clamp(_parse_float(array_param(gp, "area_spread", idx0)), 0.0, 1.0) : 0.0
    area_conc_w        = area_enabled ? _parse_float(array_param(gp, "area_conc", idx0)) : 1.0

    area_stream_targets = generate_centered_targets(desired_stream_count, area_center, area_spread)
    # Output slots follow plan.active_ids. Resolve each AREA container directly by
    # stable ID; do not use stream_pool position or a mutating active-list helper.
    stream_pool = [
      area_mgrs[:stream].containers_by_id[id]
      for id in plan.active_ids
    ]
    note_register_freedom_raw = array_param(gp, "note_register_freedom", idx0)
    note_register_freedom = clamp(_parse_float(note_register_freedom_raw === nothing ? 1.0 : note_register_freedom_raw), 0.0, 1.0)
    register_centers = Float64[]
    sizehint!(register_centers, desired_stream_count)
    for s in 1:desired_stream_count
      push!(register_centers, _recent_register_center_for_stream(note_mgrs[:stream], plan.active_ids[s]))
    end
    register_allowance = if note_register_freedom >= 1.0 - 1e-9
      float(ABS_MAX - ABS_MIN)
    elseif note_register_freedom <= 1e-9
      0.0
    else
      min_allow = float(Config.NOTE_REGISTER_MIN_ALLOWANCE)
      max_allow = float(Config.NOTE_REGISTER_MAX_ALLOWANCE)
      min_allow + (max_allow - min_allow) * note_register_freedom
    end

    # AREA is an intermediate decision (4-semitone band base). If we base the next AREA on realized notes,
    # dissonance/chord_range/density can "drag" the anchor and collapse AREA complexity.
    prev_tmp_anchors = Int[]
    sizehint!(prev_tmp_anchors, desired_stream_count)
    for s in 1:desired_stream_count
      if s <= length(stream_pool)
        lv = stream_pool[s].last_value
        a = isempty(lv) ? float(BAND_LOW_MIN) : lv[1]
        push!(prev_tmp_anchors, clamp(trunc(Int, a), BAND_LOW_MIN, BAND_LOW_MAX))
      else
        push!(prev_tmp_anchors, BAND_LOW_MIN)
      end
    end

  # ---- helper: build bin-derived tmp_anchor candidates (skip out-of-range; NO clamp-to-edge) ----
  # tmp_anchor is band_low (4-semitone band base)
  per_stream_anchor_candidates = Vector{Vector{Int}}()
  sizehint!(per_stream_anchor_candidates, desired_stream_count)

  for s in 1:desired_stream_count
    pa = prev_tmp_anchors[s]
    cand = Int[]
    seen = Set{Int}()
    for (lo, hi) in Config.AREA_MOVE_BINS
      for d in lo:hi
        a = pa + d
        # skip deltas that go out of configured MIDI range (no clamp, no sticking)
        (a < ABS_MIN || a > ABS_MAX) && continue

        # quantize to AREA band base
        band_low = Config.area_band_low(a)
        if !(band_low in seen)
          push!(cand, band_low)
          push!(seen, band_low)
        end
      end
    end

    if isempty(cand)
      # fallback: stay at current anchor's band
      push!(cand, Config.area_band_low(pa))
    end

    sort!(cand)
    if note_register_freedom < 1.0 - 1e-9
      cand = _restrict_area_anchors_by_register_window(cand, register_centers[s], register_allowance)
    end
    push!(per_stream_anchor_candidates, cand)
  end


# ---- Stage 1: prune each stream's bins using AGREEMENT of (d,q,c) ----

# NOTE:
# - Stage1 は「候補枝刈り」なので、multi-stream なら TOP>=3 を推奨
# - 1stream だけなら TOP=1 でもOK
top_bins_per_stream =
  desired_stream_count == 1 ?
  Config.AREA_TOP_BINS_PER_STREAM_SINGLE :
  Config.AREA_TOP_BINS_PER_STREAM_MULTI

per_stream_comp01 = Vector{Dict{Int,Float64}}()
top_anchors = Vector{Vector{Int}}()
sizehint!(per_stream_comp01, desired_stream_count)
sizehint!(top_anchors, desired_stream_count)

for s in 1:desired_stream_count
  sm = stream_pool[s].manager
  anchors = per_stream_anchor_candidates[s]
  stream_calibrator = build_extended_metric_calibrator(sm)
  stream_predictor = build_predictive_distribution(sm)

  raw_d = Float64[]  # avg_dist (complex when larger)
  raw_q = Float64[]  # quantity (complex when smaller)
  raw_c = Float64[]  # complexity (complex when larger)
  temporal_metrics = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
  sizehint!(raw_d, length(anchors))
  sizehint!(raw_q, length(anchors))
  sizehint!(raw_c, length(anchors))
  sizehint!(temporal_metrics, length(anchors))

  pa = prev_tmp_anchors[s]

  for a in anchors
    _consume_dimension_evaluations!(evaluation_budget, 1; context="area stage-1 candidate")
    _set_generation_failure_context!(
      failure_context;
      operation="simulate_candidate",
      dimension="area",
      stream_id=(s <= length(plan.active_ids) ? plan.active_ids[s] : nothing),
      candidate=a,
    )
    metrics =
      PolyphonicClusterManager.simulate_add_and_calculate_all_extended(sm, Float64[float(a)])

    dval = isfinite(metrics.distance) ? metrics.distance : 0.0
    qval = isfinite(metrics.quantity) ? metrics.quantity : 0.0
    cval = isfinite(metrics.complexity) ? metrics.complexity : 0.0

    push!(raw_d, dval)
    push!(raw_q, qval)
    push!(raw_c, cval)
    push!(temporal_metrics, metrics.occurrence_intervals)
  end

  predictive_scores = Float64[]
  sizehint!(predictive_scores, length(anchors))
  for (i, anchor) in enumerate(anchors)
    predictive = predictive_surprise_score(sm, stream_predictor, Float64[float(anchor)])
    push!(predictive_scores, predictive === nothing ? NaN : predictive)
  end
  scores = combine_predictive_structural_scores(
    predictive_scores,
    raw_d,
    raw_q,
    raw_c,
    temporal_metrics;
    calibrator=stream_calibrator,
  )

  m = Dict{Int,Float64}()
  for (i, a) in enumerate(anchors)
    m[a] = clamp(scores[i], 0.0, 1.0)
  end
  push!(per_stream_comp01, m)

  # rank by |score - target|
  t = area_stream_targets[s]
  prefer_big_jump = t >= 0.5

  ranked = Vector{Tuple{Float64,Float64,Int}}()  # (cost, tiebreak, anchor)
  sizehint!(ranked, length(anchors))

  for a in anchors
    cost = abs(m[a] - t)
    jump = abs(float(a) - float(pa))          # 実ジャンプ量
    tb   = prefer_big_jump ? -jump : jump     # target高いなら大ジャンプ優先
    push!(ranked, (cost, tb, a))
  end
  sort!(ranked, by=x->(x[1], x[2], x[3]))

  keep = Int[]
  for i in 1:min(top_bins_per_stream, length(ranked))
    push!(keep, ranked[i][3])
  end
  isempty(keep) && push!(keep, anchors[1])
  sort!(keep)
  push!(top_anchors, keep)

end

    # ---- Stage 2: decide AREA anchors greedily by stream priority ----
    area_gl = area_mgrs[:global]
    area_offset = float(get(area_mgrs, :global_offset, offset_for_range(area_min, area_max)))
    area_axis = get(area_mgrs, :stream_axis, nothing)
    area_axis isa StableStreamAxis || error("Missing stable stream axis for AREA global evaluation.")
    chosen_area = fill(typemin(Int), desired_stream_count)
    area_order = step_stream_order
    area_global_calibrator = build_extended_metric_calibrator(area_gl)
    area_global_predictor = build_predictive_distribution(area_gl)

    for stream_idx in area_order
      anchors = top_anchors[stream_idx]
      global_raw_d = Float64[]
      global_raw_q = Float64[]
      global_raw_c = Float64[]
      global_temporal = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
      global_candidates = PolyphonicClusterManager.PolySet[]
      sizehint!(global_raw_d, length(anchors))
      sizehint!(global_raw_q, length(anchors))
      sizehint!(global_raw_c, length(anchors))
      sizehint!(global_temporal, length(anchors))

      for cand_anchor in anchors
        _consume_dimension_evaluations!(evaluation_budget, 1; context="area stage-2 candidate")
        partial_ids = Int[]
        partial_values = Float64[]
        for i in 1:desired_stream_count
          if chosen_area[i] != typemin(Int)
            push!(partial_ids, plan.active_ids[i])
            push!(partial_values, float(chosen_area[i]))
          end
        end
        push!(partial_ids, plan.active_ids[stream_idx])
        push!(partial_values, float(cand_anchor))
        enc = _encode_streamwise_row(area_axis, partial_ids, partial_values, area_offset)
        push!(global_candidates, enc)

        _set_generation_failure_context!(
          failure_context;
          operation="simulate_candidate",
          dimension="area",
          stream_id=plan.active_ids[stream_idx],
          candidate=cand_anchor,
        )
        metrics = _safe_simulate_add_and_calculate_all_extended(area_gl, enc)
        push!(global_raw_d, isfinite(metrics.distance) ? metrics.distance : 0.0)
        push!(global_raw_q, isfinite(metrics.quantity) ? metrics.quantity : 0.0)
        push!(global_raw_c, isfinite(metrics.complexity) ? metrics.complexity : 0.0)
        push!(global_temporal, metrics.occurrence_intervals)
      end

      global_predictive_scores = Float64[]
      sizehint!(global_predictive_scores, length(global_candidates))
      for i in eachindex(global_candidates)
        predictive = predictive_surprise_score(
          area_gl,
          area_global_predictor,
          global_candidates[i],
        )
        push!(global_predictive_scores, predictive === nothing ? NaN : predictive)
      end
      global_scores = combine_predictive_structural_scores(
        global_predictive_scores,
        global_raw_d,
        global_raw_q,
        global_raw_c,
        global_temporal;
        calibrator=area_global_calibrator,
      )
      prefer_big_jump = ((area_global_target + area_stream_targets[stream_idx]) / 2.0) >= 0.5
      best_anchor = anchors[1]
      best_area_cost = Inf
      best_area_tiebreak = prefer_big_jump ? -Inf : Inf

      for (i, cand_anchor) in enumerate(anchors)
        g_cost = abs(global_scores[i] - area_global_target)
        s_cost = abs(get(per_stream_comp01[stream_idx], cand_anchor, 0.0) - area_stream_targets[stream_idx])

        decided_vals = Float64[]
        for j in 1:desired_stream_count
          if chosen_area[j] != typemin(Int)
            push!(decided_vals, float(chosen_area[j]))
          end
        end
        push!(decided_vals, float(cand_anchor))

        conc_cost = 0.0
        if length(decided_vals) >= 2 && abs(area_conc_w) > 1e-12
          dist_sum = 0.0
          cnt = 0
          for a_i in 1:(length(decided_vals)-1)
            for b_i in (a_i+1):length(decided_vals)
              dist_sum += abs(decided_vals[a_i] - decided_vals[b_i])
              cnt += 1
            end
          end
          spread01 = cnt == 0 ? 0.0 : clamp((dist_sum / float(cnt)) / BAND_WIDTH, 0.0, 1.0)
          conc_cost = area_conc_w > 0 ? abs(area_conc_w) * spread01 : abs(area_conc_w) * (1.0 - spread01)
        end

        register_cost = 0.0
        if note_register_freedom < 1.0 - 1e-9
          candidate_center = float(cand_anchor) + (float(BAND_SIZE - 1) / 2.0)
          excess = max(0.0, abs(candidate_center - register_centers[stream_idx]) - register_allowance)
          register_cost = (excess / max(float(ABS_MAX - ABS_MIN), 1.0)) * (1.0 - note_register_freedom)
        end

        total = g_cost + s_cost + conc_cost + register_cost
        jump = abs(float(cand_anchor) - float(prev_tmp_anchors[stream_idx]))
        tie_ok = prefer_big_jump ? (jump > best_area_tiebreak + 1e-12) : (jump < best_area_tiebreak - 1e-12)
        if (total < best_area_cost - 1e-12) || (abs(total - best_area_cost) <= 1e-12 && tie_ok)
          best_area_cost = total
          best_anchor = cand_anchor
          best_area_tiebreak = jump
        end
      end

      chosen_area[stream_idx] = best_anchor
    end

    if !area_enabled
      chosen_area = Int[_fixed_area_band_low_for_stream(s_i) for s_i in 1:desired_stream_count]
    end

    # ---- Commit AREA(tmp_anchor) managers (NOW consistent with evaluation) ----
    # global: stable-ID stream-axis encoding
    enc_best = _encode_streamwise_row(area_axis, plan.active_ids, chosen_area, area_offset)
    _set_generation_failure_context!(failure_context; operation="commit_global", dimension="area", candidate=copy(chosen_area))
    PolyphonicClusterManager.add_data_point_permanently(area_gl, enc_best)
    _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension="area", candidate=copy(chosen_area))
    PolyphonicClusterManager.update_caches_permanently(area_gl)

    # stream: commit per-stream anchors
    chosen_area_f = Float64[float(chosen_area[s]) for s in 1:desired_stream_count]
    _set_generation_failure_context!(failure_context; operation="commit_streams", dimension="area", candidate=copy(chosen_area))
    MultiStreamManager.commit_state_staged!(area_mgrs[:stream], chosen_area_f)
    _set_generation_failure_context!(failure_context; operation="commit_stream_caches", dimension="area", candidate=copy(chosen_area))
    MultiStreamManager.update_caches_staged!(area_mgrs[:stream])

    # ---- Decide realized notes per stream (within band + chord_range, size by density, choose by dissonance LAST) ----
    onset = step_idx <= length(future_step_onsets) ? future_step_onsets[step_idx] : base_onset

    dis_target_raw = array_param(gp, "dissonance_target", idx0)
    target01 = dis_target_raw === nothing ? Config.DEFAULT_TARGET_01 : clamp(_parse_float(dis_target_raw), 0.0, 1.0)

    # vols for amplitude (already decided in dim_order)
    vols = Float64[clamp(_parse_float(current_step_values[s][vol_idx]), 0.0, 1.0) for s in 1:desired_stream_count]
    stream_note_pools = Vector{Vector{Int}}(undef, desired_stream_count)
    stream_note_counts = Vector{Int}(undef, desired_stream_count)
    selected_chords = [Int[] for _ in 1:desired_stream_count]

    for s in 1:desired_stream_count
      band_low = chosen_area[s]
      chord_range_val = clamp(Int(trunc(step_decisions["chord_range"][s])), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
      density_val = clamp(float(step_decisions["density"][s]), 0.0, 1.0)
      low, high, slot_count = _note_pool_geometry(band_low, chord_range_val)

      stream_note_pools[s] = collect(low:high)
      stream_note_counts[s] = _note_count_from_density(density_val, slot_count)
      if plan.active_ids[s] in voice_ids
        voice_low = max(low, Config.VOICE_NOTE_MIN)
        voice_high = min(high, Config.VOICE_NOTE_MAX)
        if voice_low <= voice_high
          stream_note_pools[s] = collect(voice_low:voice_high)
        else
          # Keep the complete singer range when AREA/CR do not overlap it.
          # A singleton fallback would force low registers to VOICE_NOTE_MIN.
          stream_note_pools[s] = collect(Config.VOICE_NOTE_MIN:Config.VOICE_NOTE_MAX)
        end
        stream_note_counts[s] = min(stream_note_counts[s], length(stream_note_pools[s]))
        stream_note_counts[s] = max(stream_note_counts[s], 1)
      end
    end

    # Dissonance selection is done on pitch-class-normalized MIDI notes so octave distance
    # does not dominate roughness ranking.
    function _pc_normalized_notes(midi_notes::Vector{Int})
      out = Int[]
      sizehint!(out, length(midi_notes))
      for n in midi_notes
        pc = mod(n, Config.STEPS_PER_OCTAVE)
        push!(out, Config.MIDI_C4 + pc)
      end
      return out
    end

    # Decide global dissonance greedily by stream priority. Each stream is
    # evaluated one added note at a time against STM plus earlier streams.
    chosen_note_flags = fill(false, desired_stream_count)
    note_order = step_stream_order
    dissonance_calibrator = build_dissonance_calibrator(stm_mgr)
    note_global_calibrator = build_extended_metric_calibrator(note_mgrs[:global])
    note_global_predictor = build_predictive_distribution(note_mgrs[:global])
    note_stream_containers = MultiStreamManager.active_stream_containers(note_mgrs[:stream], desired_stream_count)
    note_stream_calibrators = ExtendedMetricCalibrator[
      build_extended_metric_calibrator(note_stream_containers[i].manager)
      for i in 1:min(desired_stream_count, length(note_stream_containers))
    ]
    note_stream_predictors = PredictiveDistribution[
      build_predictive_distribution(note_stream_containers[i].manager)
      for i in 1:min(desired_stream_count, length(note_stream_containers))
    ]

    for stream_idx in note_order
      note_pool = stream_note_pools[stream_idx]
      if isempty(note_pool)
        selected_chords[stream_idx] = Int[chosen_area[stream_idx]]
        chosen_note_flags[stream_idx] = true
        continue
      end

      function evaluate_partial_chord(cand::Vector{Int})::Float64
        partial = Vector{Vector{Int}}()
        partial_vols = Float64[]
        for s in 1:desired_stream_count
          if chosen_note_flags[s]
            push!(partial, selected_chords[s])
            push!(partial_vols, vols[s])
          end
        end
        push!(partial, cand)
        push!(partial_vols, vols[stream_idx])

        midi_notes_all = Int[]
        amps_all = Float64[]
        for (i, chord) in enumerate(partial)
          v = partial_vols[i]
          a_each = isempty(chord) ? v : (v / float(length(chord)))
          for n in chord
            push!(midi_notes_all, n)
            push!(amps_all, a_each)
          end
        end

        eval_notes = _pc_normalized_notes(midi_notes_all)
        return float(DissonanceStmManager.evaluate(stm_mgr, eval_notes, amps_all, onset))
      end

      function evaluate_note_complexity_cost_batch(chords::Vector{Vector{Int}})::Vector{Float64}
        global_candidates = PolyphonicClusterManager.PolySet[]
        stream_candidates = PolyphonicClusterManager.PolySet[]
        global_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]
        stream_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]

        for cand in chords
          cand_anchor = float(_anchor_from_abs(cand))
        _set_generation_failure_context!(
          failure_context;
          operation="simulate_candidate",
          dimension="note",
          stream_id=(stream_idx <= length(plan.active_ids) ? plan.active_ids[stream_idx] : nothing),
          candidate=copy(cand),
        )
          partial_anchors = Float64[]
          for s in 1:desired_stream_count
            if chosen_note_flags[s]
              push!(partial_anchors, float(_anchor_from_abs(selected_chords[s])))
            end
          end
          push!(partial_anchors, cand_anchor)
          sort!(partial_anchors)
          global_anchor = partial_anchors[cld(length(partial_anchors), 2)]
          global_candidate = Float64[global_anchor]
          stream_candidate = Float64[cand_anchor]
          push!(global_candidates, global_candidate)
          push!(stream_candidates, stream_candidate)
          push!(
            global_metrics,
            _safe_simulate_add_and_calculate_all_extended(note_mgrs[:global], global_candidate),
          )
          if stream_idx <= length(note_stream_containers)
            push!(
              stream_metrics,
              _safe_simulate_add_and_calculate_all_extended(
                note_stream_containers[stream_idx].manager,
                stream_candidate,
              ),
            )
          end
        end

        predictive_global_scores = Float64[]
        for i in eachindex(global_candidates)
          predictive = predictive_surprise_score(
            note_mgrs[:global],
            note_global_predictor,
            global_candidates[i],
          )
          push!(
            predictive_global_scores,
            predictive === nothing ? NaN : predictive,
          )
        end
        global_scores = combine_predictive_structural_scores(
          predictive_global_scores,
          Float64[m.distance for m in global_metrics],
          Float64[m.quantity for m in global_metrics],
          Float64[m.complexity for m in global_metrics],
          PolyphonicClusterManager.OccurrenceIntervalMetrics[
            m.occurrence_intervals for m in global_metrics
          ];
          calibrator=note_global_calibrator,
        )

        stream_scores = fill(Config.DEFAULT_TARGET_01, length(chords))
        if stream_idx <= length(note_stream_containers)
          stream_calibrator = note_stream_calibrators[stream_idx]
          predictive_stream_scores = Float64[]
          for i in eachindex(stream_candidates)
            predictive = predictive_surprise_score(
              note_stream_containers[stream_idx].manager,
              note_stream_predictors[stream_idx],
              stream_candidates[i],
            )
            push!(
              predictive_stream_scores,
              predictive === nothing ? NaN : predictive,
            )
          end
          stream_scores = combine_predictive_structural_scores(
            predictive_stream_scores,
            Float64[m.distance for m in stream_metrics],
            Float64[m.quantity for m in stream_metrics],
            Float64[m.complexity for m in stream_metrics],
            PolyphonicClusterManager.OccurrenceIntervalMetrics[
              m.occurrence_intervals for m in stream_metrics
            ];
            calibrator=stream_calibrator,
          )
        end

        stream_target =
          stream_idx <= length(area_stream_targets) ?
            area_stream_targets[stream_idx] :
            area_center
        return Float64[
          abs(global_scores[i] - area_global_target) +
          abs(stream_scores[i] - stream_target)
          for i in eachindex(chords)
        ]
      end

      selected_chords[stream_idx] = select_notes_by_single_addition_greedy(
        note_pool,
        stream_note_counts[stream_idx],
        target01,
        dissonance_calibrator,
        evaluate_partial_chord;
        register_center=register_centers[stream_idx],
        register_allowance=register_allowance,
        tie_center=float(chosen_area[stream_idx]) + float(BAND_SIZE - 1) / 2.0,
        complexity_cost_batch=evaluate_note_complexity_cost_batch,
        complexity_weight=1.0,
        evaluation_budget=evaluation_budget,
      )
      chosen_note_flags[stream_idx] = true
    end

    for s in 1:desired_stream_count
      best_chord = copy(selected_chords[s])
      sort!(best_chord)
      current_step_values[s][note_abs_idx] = best_chord
    end

    # ---- Commit STM using realized notes across all streams (NOT area tmp) ----
    midi_notes_all = Int[]
    amps_all = Float64[]
    for s in 1:desired_stream_count
      ns = current_step_values[s][note_abs_idx]
      v = vols[s]
      a_each = isempty(ns) ? v : (v / float(length(ns)))
      for n in ns
        push!(midi_notes_all, n)
        push!(amps_all, a_each)
      end
    end
    _set_generation_failure_context!(failure_context; operation="commit_stm", dimension="note", candidate=copy(midi_notes_all))
    DissonanceStmManager.commit!(stm_mgr, midi_notes_all, amps_all, onset)

    # ---- Commit NOTE managers using realized anchors (global scalar + per-stream) ----
    global_anchor_note = _global_anchor_from_step(current_step_values)

    _set_generation_failure_context!(failure_context; operation="commit_global", dimension="note", candidate=global_anchor_note)
    PolyphonicClusterManager.add_data_point_permanently(note_mgrs[:global], Float64[float(global_anchor_note)])
    _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension="note", candidate=global_anchor_note)
    PolyphonicClusterManager.update_caches_permanently(note_mgrs[:global])

    stream_anchors = Float64[]
    sizehint!(stream_anchors, desired_stream_count)
    for s in 1:desired_stream_count
      push!(stream_anchors, float(_anchor_from_abs(current_step_values[s][note_abs_idx])))
    end
    _set_generation_failure_context!(failure_context; operation="commit_streams", dimension="note", candidate=copy(stream_anchors))
    MultiStreamManager.commit_state_staged!(note_mgrs[:stream], stream_anchors)
    _set_generation_failure_context!(failure_context; operation="commit_stream_caches", dimension="note", candidate=copy(stream_anchors))
    MultiStreamManager.update_caches_staged!(note_mgrs[:stream])

    if clustered_tie_enabled
      tie_mgrs = managers["tie"]
      tie_global_mgr = tie_mgrs[:global]
      tie_stream_mgr = tie_mgrs[:stream]
      global_target = tie_global_complexity_series[step_idx]
      stream_center = tie_stream_center_series[step_idx]
      stream_span = tie_stream_span_series[step_idx]
      concordance = tie_concordance_series[step_idx]
      stream_targets = generate_centered_targets(desired_stream_count, stream_center, stream_span)

      eligible_slots = Int[]
      for slot in 1:desired_stream_count
        stream_id = plan.active_ids[slot]
        previous = get(previous_step_by_id, stream_id, nothing)
        current = current_step_values[slot]
        if previous !== nothing && _tie_render_compatible(previous, current)
          push!(eligible_slots, slot)
        else
          current[tie_idx] = 0.0
        end
      end

      chosen_ties = Dict{Int,Float64}()
      global_calibrator = build_extended_metric_calibrator(tie_global_mgr)
      global_predictor = build_predictive_distribution(tie_global_mgr)
      for slot in step_stream_order
        slot in eligible_slots || continue
        stream_id = plan.active_ids[slot]
        container = tie_stream_mgr.containers_by_id[stream_id]
        stream_calibrator = build_extended_metric_calibrator(container.manager)
        stream_predictor = build_predictive_distribution(container.manager)
        candidate_bits = _restrict_candidates_with_target_window(
          "tie",
          Float64[float(value) for value in Config.TIE_STEPS],
          step_idx - 1,
        )
        isempty(candidate_bits) && (candidate_bits = Float64[float(value) for value in Config.TIE_STEPS])

        global_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]
        stream_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]
        for bit in candidate_bits
          _consume_dimension_evaluations!(evaluation_budget, 1; context="tie candidate")
          _set_generation_failure_context!(
            failure_context;
            operation="simulate_candidate",
            dimension="tie",
            stream_id=stream_id,
            candidate=bit,
          )
          partial_bits = Float64[chosen_ties[s] for s in sort!(collect(keys(chosen_ties)))]
          push!(partial_bits, bit)
          projected_global = sum(partial_bits) / float(length(partial_bits))
          push!(global_metrics, _safe_simulate_add_and_calculate_all_extended(tie_global_mgr, Float64[projected_global]))
          push!(stream_metrics, _safe_simulate_add_and_calculate_all_extended(container.manager, Float64[bit]))
        end

        global_scores = fill(NaN, length(candidate_bits))
        stream_scores = fill(NaN, length(candidate_bits))
        for (candidate_idx, bit) in enumerate(candidate_bits)
          partial_bits = Float64[chosen_ties[s] for s in sort!(collect(keys(chosen_ties)))]
          push!(partial_bits, bit)
          projected_global = sum(partial_bits) / float(length(partial_bits))
          global_predictive = predictive_surprise_score(
            tie_global_mgr,
            global_predictor,
            Float64[projected_global],
          )
          stream_predictive = predictive_surprise_score(
            container.manager,
            stream_predictor,
            Float64[bit],
          )
          global_predictive !== nothing && (global_scores[candidate_idx] = global_predictive)
          stream_predictive !== nothing && (stream_scores[candidate_idx] = stream_predictive)
        end
        global_scores = combine_predictive_structural_scores(
          global_scores,
          Float64[m.distance for m in global_metrics],
          Float64[m.quantity for m in global_metrics],
          Float64[m.complexity for m in global_metrics],
          PolyphonicClusterManager.OccurrenceIntervalMetrics[
            m.occurrence_intervals for m in global_metrics
          ];
          calibrator=global_calibrator,
        )
        stream_scores = combine_predictive_structural_scores(
          stream_scores,
          Float64[m.distance for m in stream_metrics],
          Float64[m.quantity for m in stream_metrics],
          Float64[m.complexity for m in stream_metrics],
          PolyphonicClusterManager.OccurrenceIntervalMetrics[
            m.occurrence_intervals for m in stream_metrics
          ];
          calibrator=stream_calibrator,
        )

        best_bit = 0.0
        best_cost = Inf
        for (candidate_idx, bit) in enumerate(candidate_bits)
          partial_bits = Float64[chosen_ties[s] for s in sort!(collect(keys(chosen_ties)))]
          push!(partial_bits, bit)
          cost =
            abs(global_scores[candidate_idx] - global_target) +
            abs(stream_scores[candidate_idx] - stream_targets[slot]) +
            _tie_concordance_cost(partial_bits, concordance)
          if cost < best_cost - 1e-12
            best_cost = cost
            best_bit = bit
          end
        end
        chosen_ties[slot] = best_bit
        current_step_values[slot][tie_idx] = best_bit
      end

      if !isempty(eligible_slots)
        committed_bits = Float64[current_step_values[slot][tie_idx] for slot in eligible_slots]
        global_tie_value = sum(committed_bits) / float(length(committed_bits))
        _set_generation_failure_context!(failure_context; operation="commit_global", dimension="tie", candidate=global_tie_value)
        PolyphonicClusterManager.add_data_point_permanently(tie_global_mgr, Float64[global_tie_value])
        _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension="tie", candidate=global_tie_value)
        PolyphonicClusterManager.update_caches_permanently!(tie_global_mgr)

        for slot in eligible_slots
          stream_id = plan.active_ids[slot]
          bit = Float64(current_step_values[slot][tie_idx])
          container = tie_stream_mgr.containers_by_id[stream_id]
          _set_generation_failure_context!(failure_context; operation="commit_stream", dimension="tie", stream_id=stream_id, candidate=bit)
          PolyphonicClusterManager.add_data_point_permanently(container.manager, Float64[bit])
          _set_generation_failure_context!(failure_context; operation="commit_stream_cache", dimension="tie", stream_id=stream_id, candidate=bit)
          PolyphonicClusterManager.update_caches_permanently!(container.manager)
          container.last_value = Float64[bit]
        end
      end
      step_decisions["tie"] = Float64[current_step_values[slot][tie_idx] for slot in 1:desired_stream_count]
    end

    generated_voice_tokens = Dict{Int,VoiceTokenGeneration.VoiceToken}()
    if voice_state !== nothing && !isempty(voice_ids)
      voice_targets = generate_centered_targets(
        length(voice_ids),
        voice_stream_center_series[step_idx],
        voice_stream_span_series[step_idx],
      )
      targets_by_id = Dict{Int,Float64}(
        stream_id => voice_targets[i] for (i, stream_id) in enumerate(voice_ids)
      )
      recency = clamp(_parse_float(array_param(gp, "recency_center", step_idx - 1)), 0.0, 1.0)
      forced_voice_tokens = Dict{Int,VoiceTokenGeneration.VoiceToken}()
      for stream_id in voice_ids
        previous = get(previous_step_by_id, stream_id, nothing)
        current_slot = findfirst(id -> id == stream_id, plan.active_ids)
        current_slot === nothing && continue
        previous === nothing && continue
        previous_voice_plan = isempty(voice_plan) ? Any[] : voice_plan[end]
        previous_voice = nothing
        for entry in previous_voice_plan
          try
            Int(entry["streamId"]) == stream_id || continue
            lowercase(string(get(entry, "mode", "synth"))) == "voice" || break
            previous_voice = entry
            break
          catch
          end
        end
        previous_voice === nothing && continue
        current = current_step_values[current_slot]
        same_notes = length(previous[note_abs_idx]) == length(current[note_abs_idx]) &&
          all(previous[note_abs_idx][i] == current[note_abs_idx][i] for i in eachindex(previous[note_abs_idx], current[note_abs_idx]))
        same_notes || continue
        _parse_float(current[tie_idx]) >= 1.0 || continue
        continuation = VoiceTokenGeneration.continuation_token(voice_state, stream_id)
        continuation === nothing || (forced_voice_tokens[stream_id] = continuation)
      end
      _set_generation_failure_context!(
        failure_context;
        operation="generate_tokens",
        dimension="voice_token",
        candidate=copy(voice_ids),
      )
      generated_voice_tokens = VoiceTokenGeneration.generate_tokens!(
        voice_state,
        voice_ids;
        global_target=voice_global_complexity_series[step_idx],
        stream_targets=targets_by_id,
        concordance=voice_concordance_series[step_idx],
        transition_weight=voice_transition_series[step_idx],
        recency=recency,
        forced_tokens=forced_voice_tokens,
      )
    end

    current_voice_plan = Any[]
    for (slot, stream_id) in enumerate(plan.active_ids)
      notes = Int[Int(note) for note in current_step_values[slot][note_abs_idx]]
      token = get(generated_voice_tokens, stream_id, nothing)
      if token === nothing
        push!(current_voice_plan, Dict(
          "streamId" => stream_id,
          "mode" => "synth",
          "token" => nothing,
          "text" => nothing,
          "phones" => String[],
          "carrierNote" => nothing,
          "notes" => notes,
        ))
      else
        carrier_note = isempty(notes) ? nothing : notes[cld(length(notes), 2)]
        push!(current_voice_plan, Dict(
          "streamId" => stream_id,
          "mode" => "voice",
          "token" => token.id,
          "text" => token.text,
          "phones" => copy(token.phones),
          "carrierNote" => carrier_note,
          "notes" => notes,
        ))
      end
    end
    push!(voice_plan, current_voice_plan)
    @info "Voice token decisions" step=step_idx bpm=future_bpm[step_idx] step_duration=future_step_durations[step_idx] decisions=[(stream_id=entry["streamId"], mode=entry["mode"], text=entry["text"], notes=entry["notes"], vol=current_step_values[slot][vol_idx]) for (slot, entry) in enumerate(current_voice_plan)]

    # store decisions
    step_decisions["area_tmp_anchor"] = chosen_area
    step_decisions["note_anchor"] = global_anchor_note

    push!(result_stream_ids, copy(plan.active_ids))
    previous_step_by_id = Dict{Int,Vector{Any}}(
      stream_id => current_step_values[slot]
      for (slot, stream_id) in enumerate(plan.active_ids)
      if slot <= length(current_step_values)
    )
    push!(results, current_step_values)
    elapsed = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)
    println("[generate_polyphonic] step $(step_idx)/$(steps_to_generate) elapsed=$(elapsed)s")
    flush(stdout)
    catch err
      managers = committed_step_state.managers
      stm_mgr = committed_step_state.stm_mgr
      stream_axis = committed_step_state.stream_axis
      voice_state = committed_step_state.voice_state
      resize!(results, results_len_before_step)
      resize!(result_stream_ids, stream_ids_len_before_step)
      resize!(voice_plan, voice_plan_len_before_step)
      previous_step_by_id = previous_step_by_id_before
      _log_generate_polyphonic_step_failure(err, catch_backtrace(), step_idx, failure_context)
      rethrow()
    end
  end

  # ----------------------------------------------------------
  # Post-process / clamp
  # ----------------------------------------------------------
  for (step_idx, step) in enumerate(results)
    is_generated_step = step_idx > base_step_index
    for (stream_idx, vec) in enumerate(step)
      vec[note_abs_idx] = _normalize_abs_notes(vec[note_abs_idx])
      vec[vol_idx] = (!get(dim_accept, "vol", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("vol", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[vol_idx]), 0.0, 1.0)
      vec[brightness_idx] = (!get(dim_accept, "brightness", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("brightness", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[brightness_idx]), 0.0, 1.0)
      vec[noise_idx] = (!get(dim_accept, "noise", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("noise", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[noise_idx]), 0.0, 1.0)
      vec[harmonicity_idx] = (!get(dim_accept, "harmonicity", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("harmonicity", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[harmonicity_idx]), 0.0, 1.0)
      vec[attack_idx] = (!get(dim_accept, "attack", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("attack", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[attack_idx]), 0.0, 1.0)
      vec[decay_sustain_idx] = (!get(dim_accept, "decay_sustain", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("decay_sustain", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[decay_sustain_idx]), 0.0, 1.0)
      vec[release_idx] = (!get(dim_accept, "release", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("release", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[release_idx]), 0.0, 1.0)
      vec[chord_range_idx] = (!get(dim_accept, "chord_range", true) && is_generated_step) ? Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", stream_idx), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))) : clamp(_parse_int(vec[chord_range_idx]), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
      vec[density_idx] = (!get(dim_accept, "density", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("density", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[density_idx]), 0.0, 1.0)
      vec[tie_idx] = _quantize_tie_value(vec[tie_idx])
    end
  end

  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)

  timbre_series = Dict(
    "brightness" => Any[
      Float64[clamp(_parse_float(st[brightness_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "noise" => Any[
      Float64[clamp(_parse_float(st[noise_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "harmonicity" => Any[
      Float64[clamp(_parse_float(st[harmonicity_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "attack" => Any[
      Float64[clamp(_parse_float(st[attack_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "decay_sustain" => Any[
      Float64[clamp(_parse_float(st[decay_sustain_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "release" => Any[
      Float64[clamp(_parse_float(st[release_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "tie" => Any[
      Float64[clamp(_parse_float(st[tie_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
  )

  cluster_payload = Dict{String,Any}()
  compressed_cluster_payload = Dict{String,Any}()
  for key in ["note", "area", "vol", "brightness", "noise", "harmonicity", "attack", "decay_sustain", "release", "chord_range", "density", "tie"]
    mgrs = get(managers, key, nothing)
    mgrs === nothing && continue

    g_mgr = mgrs[:global]
    s_mgr = mgrs[:stream]

    global_spans = PolyphonicClusterManager.compressed_clusters_payload(g_mgr)

    stream_spans = Dict{Int,Any}()
    for container in s_mgr.stream_pool
      stream_spans[container.id] = PolyphonicClusterManager.compressed_clusters_payload(container.manager)
    end
    compressed_cluster_payload[key] = Dict(
      "global" => global_spans,
      "streams" => stream_spans,
    )

    if !compact_cluster_view
      streams_hash = Dict{Int,Any}()
      for container in s_mgr.stream_pool
        streams_hash[container.id] = PolyphonicClusterManager.clusters_to_timeline(container.manager)
      end
      cluster_payload[key] = Dict(
        "global" => PolyphonicClusterManager.clusters_to_timeline(g_mgr),
        "streams" => streams_hash,
      )
    end
  end
  if voice_state !== nothing && !compact_cluster_view
    cluster_payload["voice_token"] = VoiceTokenGeneration.clusters_payload(voice_state, min_window)
  end

  strength_report = MultiStreamManager.stream_strengths_report(managers["vol"][:stream])
  stream_strengths = Dict{String,Any}(
    string(stream_id) => Dict(
      "active" => entry.active,
      "presenceAvg" => entry.presence_avg,
      "presenceCount" => entry.presence_count,
      "lastValue" => copy(entry.last_value),
    )
    for (stream_id, entry) in strength_report
  )

  response = Dict(
    "timeSeries" => results,
    "streamIds" => result_stream_ids,
    "voicePlan" => voice_plan,
    "voiceStreamCounts" => voice_stream_counts,
    "voiceInventory" => voice_inventory === nothing ? nothing : Dict(
      "id" => voice_inventory.id,
      "modelId" => voice_inventory.model_id,
      "featureVersion" => voice_inventory.feature_version,
      "source" => voice_inventory.source,
      "dimensions" => voice_inventory.dimensions,
    ),
    "compressedClusterSpans" => compressed_cluster_payload,
    "processingTime" => processing_time_s,
    "streamStrengths" => stream_strengths,
    "timbreSeries" => timbre_series,
    "bpm" => isempty(future_bpm) ? bpm : future_bpm[1],
    "stepDuration" => isempty(future_step_durations) ? Config.step_duration_from_bpm(bpm) : future_step_durations[1],
    "initialContextBpm" => initial_context_bpm,
    "futureBpm" => future_bpm,
    "bpmSeries" => bpm_series,
    "stepDurations" => step_durations
  )
  if !compact_cluster_view
    response["clusters"] = cluster_payload
  end
  return response
end
