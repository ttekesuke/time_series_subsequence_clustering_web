struct ScalarMetricCalibrator
  center::Float64
  scale::Float64
  direction::Float64
end

struct ComplexityMetricCalibrator
  distance::ScalarMetricCalibrator
  quantity::ScalarMetricCalibrator
  complexity::ScalarMetricCalibrator
end

struct ExtendedMetricCalibrator
  base::ComplexityMetricCalibrator
  occurrence_intervals::ComplexityMetricCalibrator
end

const DEFAULT_COMPLEXITY_METRIC_CALIBRATOR = ComplexityMetricCalibrator(
  ScalarMetricCalibrator(0.0, 1.0, 1.0),
  ScalarMetricCalibrator(0.0, 1.0, -1.0),
  ScalarMetricCalibrator(0.0, 1.0, 1.0),
)
const DEFAULT_EXTENDED_METRIC_CALIBRATOR = ExtendedMetricCalibrator(
  DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
  DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
)

@inline function calibrate_metric(raw::Real, calibrator::ScalarMetricCalibrator)::Float64
  value = float(raw)
  isfinite(value) || return 0.5
  scale = max(abs(calibrator.scale), eps(Float64))
  z = calibrator.direction * (value - calibrator.center) / scale
  return clamp(0.5 + atan(z) / pi, 0.0, 1.0)
end

@inline function _metric_calibration_scale(
  center::Float64,
  effective_steps::Int,
  minimum_step::Float64,
)::Float64
  return max(abs(center) / float(max(effective_steps, 1)), minimum_step)
end

function _build_complexity_metric_calibrator(
  metrics,
  effective_steps::Int,
)::ComplexityMetricCalibrator
  steps = max(effective_steps, 1)
  normalized_floor = 1.0 / float(steps)
  return ComplexityMetricCalibrator(
    ScalarMetricCalibrator(
      metrics.distance,
      _metric_calibration_scale(metrics.distance, steps, normalized_floor),
      1.0,
    ),
    ScalarMetricCalibrator(
      metrics.quantity,
      _metric_calibration_scale(metrics.quantity, steps, 1.0),
      -1.0,
    ),
    ScalarMetricCalibrator(
      metrics.complexity,
      _metric_calibration_scale(metrics.complexity, steps, normalized_floor),
      1.0,
    ),
  )
end

"""Freeze all metric mappings from the committed manager state."""
function build_extended_metric_calibrator(
  mgr::PolyphonicClusterManager.Manager,
  committed_metrics::Union{Nothing,PolyphonicClusterManager.ExtendedClusterMetrics}=nothing,
)::ExtendedMetricCalibrator
  committed = committed_metrics === nothing ?
    PolyphonicClusterManager.current_extended_metrics(mgr) : committed_metrics
  effective_steps = max(length(mgr.data) - mgr.min_window_size + 1, 1)
  return ExtendedMetricCalibrator(
    _build_complexity_metric_calibrator(committed, effective_steps),
    _build_complexity_metric_calibrator(
      committed.occurrence_intervals,
      effective_steps,
    ),
  )
end

struct DissonanceCalibrator
  scale::Float64
end

function build_dissonance_calibrator(
  mgr::DissonanceStmManager.Manager,
)::DissonanceCalibrator
  committed = sort!(Float64[
    event.dissonance_current
    for event in mgr.memory
    if isfinite(event.dissonance_current) && event.dissonance_current > 0.0
  ])
  if isempty(committed)
    return DissonanceCalibrator(Config.DISSONANCE_CALIBRATION_SCALE)
  end
  center = committed[cld(length(committed), 2)]
  return DissonanceCalibrator(max(center, Config.DISSONANCE_CALIBRATION_MIN_SCALE))
end

@inline function calibrate_dissonance(
  raw::Real,
  calibrator::DissonanceCalibrator,
)::Float64
  roughness = max(isfinite(float(raw)) ? float(raw) : 0.0, 0.0)
  scale = max(calibrator.scale, Config.DISSONANCE_CALIBRATION_MIN_SCALE)
  return clamp(roughness / (roughness + scale), 0.0, 1.0)
end

function select_notes_by_single_addition_greedy(
  note_pool::Vector{Int},
  note_count::Int,
  target::Float64,
  calibrator::DissonanceCalibrator,
  evaluate_chord;
  register_center::Float64,
  register_allowance::Float64,
  tie_center::Float64,
  complexity_cost = nothing,
  complexity_cost_batch = nothing,
  complexity_weight::Real = 1.0,
  evaluation_budget = nothing,
)::Vector{Int}
  pool = sort!(unique(copy(note_pool)))
  isempty(pool) && return Int[]
  desired_count = clamp(note_count, 1, length(pool))
  selected = Int[]

  for _ in 1:desired_count
    candidate_rows = Tuple{Int,Vector{Int},Float64}[]
    nearest_register_distance = Inf
    for note in pool
      note in selected && continue
      chord = sort!(vcat(selected, Int[note]))
      anchor = float(chord[cld(length(chord), 2)])
      register_distance = abs(anchor - register_center)
      nearest_register_distance = min(nearest_register_distance, register_distance)
      push!(candidate_rows, (note, chord, register_distance))
    end

    eligible = Tuple{Int,Vector{Int},Float64}[
      row for row in candidate_rows
      if row[3] <= register_allowance + 1e-9
    ]
    if isempty(eligible)
      eligible = Tuple{Int,Vector{Int},Float64}[
        row for row in candidate_rows
        if abs(row[3] - nearest_register_distance) <= 1e-12
      ]
    end

    evaluation_budget === nothing || _consume_note_evaluations!(
      evaluation_budget,
      length(eligible);
      context="note candidate",
    )

    batch_complexity_penalties =
      complexity_cost_batch === nothing ?
        nothing :
        complexity_cost_batch(Vector{Int}[row[2] for row in eligible])
    if batch_complexity_penalties !== nothing
      length(batch_complexity_penalties) == length(eligible) || error(
        "complexity_cost_batch returned $(length(batch_complexity_penalties)) values for $(length(eligible)) chords.",
      )
    end

    best_note = eligible[1][1]
    best_key = (Inf, Inf, Inf, typemax(Int))
    for (eligible_idx, (note, chord, register_distance)) in enumerate(eligible)
      roughness01 = calibrate_dissonance(evaluate_chord(chord), calibrator)
      complexity_penalty = if batch_complexity_penalties !== nothing
        max(float(batch_complexity_penalties[eligible_idx]), 0.0)
      elseif complexity_cost !== nothing
        max(float(complexity_cost(chord)), 0.0)
      else
        0.0
      end
      primary_cost = abs(roughness01 - target) + max(float(complexity_weight), 0.0) * complexity_penalty
      key = (
        primary_cost,
        register_distance,
        abs(float(note) - tie_center),
        note,
      )
      if isless(key, best_key)
        best_key = key
        best_note = note
      end
    end
    push!(selected, best_note)
    sort!(selected)
  end

  return selected
end

struct PredictiveSuccessor
  value::PolyphonicClusterManager.PolySet
  mass::Float64
end

struct PredictiveDistribution
  successors::Vector{PredictiveSuccessor}
  peak_likelihood::Float64
  ready::Bool
end

const EMPTY_PREDICTIVE_DISTRIBUTION =
  PredictiveDistribution(PredictiveSuccessor[], 0.0, false)

@inline function _gaussian_similarity(distance::Real, bandwidth::Real)::Float64
  sigma = max(abs(float(bandwidth)), eps(Float64))
  z = max(float(distance), 0.0) / sigma
  return exp(-0.5 * z * z)
end

function _predictive_likelihood(
  mgr::PolyphonicClusterManager.Manager,
  successors::Vector{PredictiveSuccessor},
  candidate::PolyphonicClusterManager.PolySet,
)::Float64
  likelihood = 0.0
  for successor in successors
    distance = PolyphonicClusterManager.min_avg_distance(mgr, candidate, successor.value)
    likelihood += successor.mass * _gaussian_similarity(
      distance,
      Config.PREDICTIVE_SUCCESSOR_DISTANCE_BANDWIDTH,
    )
  end
  return likelihood
end

"""Build a multi-window distribution of values observed after the current suffix.

Every eligible window contributes one normalized successor distribution. Longer,
better-supported, and more cohesive suffix clusters receive more weight. Recency
changes occurrence votes inside each window without selecting a single window.
"""
function build_predictive_distribution(
  mgr::PolyphonicClusterManager.Manager,
)::PredictiveDistribution
  data_length = length(mgr.data)
  data_length <= mgr.min_window_size && return EMPTY_PREDICTIVE_DISTRIBUTION

  max_context = min(
    data_length - 1,
    max(Config.PREDICTIVE_MAX_CONTEXT_LENGTH, mgr.min_window_size),
  )
  clusters_each = PolyphonicClusterManager.collect_clusters_each(
    mgr,
    Set(mgr.min_window_size:max_context),
  )
  now_index = data_length - 1
  scale_rows = Tuple{Float64,Vector{PolyphonicClusterManager.PolySet},Vector{Float64}}[]

  for window_size in sort!(collect(keys(clusters_each)))
    window_size < mgr.min_window_size && continue
    window_size > max_context && continue
    latest_start = data_length - window_size
    latest_start < 0 && continue

    current_context = mgr.data[(latest_start + 1):data_length]
    same_window = clusters_each[window_size]
    target = nothing
    for node in values(same_window)
      if latest_start in PolyphonicClusterManager.cluster_starts(node)
        target = node
        break
      end
    end
    target === nothing && continue

    historical_starts = sort!(unique(Int[
      start for start in PolyphonicClusterManager.cluster_starts(target)
      if start < latest_start && start + window_size < data_length
    ]))
    isempty(historical_starts) && continue
    history_limit = max(Config.PREDICTIVE_HISTORY_LIMIT_PER_CONTEXT, 1)
    if length(historical_starts) > history_limit
      historical_starts = historical_starts[(end - history_limit + 1):end]
    end

    successors = PolyphonicClusterManager.PolySet[]
    occurrence_weights = Float64[]
    context_similarity_sum = 0.0
    for start in historical_starts
      past_context = mgr.data[(start + 1):(start + window_size)]
      context_distance =
        PolyphonicClusterManager.euclidean_distance(mgr, current_context, past_context) /
        sqrt(float(max(window_size, 1)))
      context_similarity = _gaussian_similarity(
        context_distance,
        Config.PREDICTIVE_CONTEXT_DISTANCE_BANDWIDTH,
      )
      successor_index = start + window_size
      occurrence_weight =
        PolyphonicClusterManager.recency_weight(mgr, now_index, successor_index) *
        context_similarity
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
    _predictive_likelihood(mgr, combined, successor.value)
    for successor in combined
  )
  peak_likelihood <= 0.0 && return EMPTY_PREDICTIVE_DISTRIBUTION
  return PredictiveDistribution(combined, peak_likelihood, true)
end

function predictive_surprise_score(
  mgr::PolyphonicClusterManager.Manager,
  distribution::PredictiveDistribution,
  candidate::PolyphonicClusterManager.PolySet,
)::Union{Nothing,Float64}
  distribution.ready || return nothing
  likelihood = _predictive_likelihood(mgr, distribution.successors, candidate)
  return clamp(1.0 - likelihood / distribution.peak_likelihood, 0.0, 1.0)
end

function predictive_surprise_scores(
  mgr::PolyphonicClusterManager.Manager,
  candidates::Vector{PolyphonicClusterManager.PolySet},
)::Vector{Float64}
  distribution = build_predictive_distribution(mgr)
  scores = Vector{Float64}(undef, length(candidates))
  for i in eachindex(candidates)
    score = predictive_surprise_score(mgr, distribution, candidates[i])
    scores[i] = score === nothing ? NaN : score
  end
  return scores
end

function _normalize_candidate_axis(
  values::Vector{Float64},
  unavailable_fallback::Vector{Float64}=Float64[],
)::Tuple{Vector{Float64},Bool}
  finite_values = Float64[value for value in values if isfinite(value)]
  isempty(finite_values) && return (zeros(Float64, length(values)), false)
  lo = minimum(finite_values)
  hi = maximum(finite_values)
  span = hi - lo
  span <= 1e-12 && return (zeros(Float64, length(values)), false)

  normalized = Vector{Float64}(undef, length(values))
  for i in eachindex(values)
    normalized[i] = if isfinite(values[i])
      clamp((values[i] - lo) / span, 0.0, 1.0)
    elseif i <= length(unavailable_fallback)
      clamp(unavailable_fallback[i], 0.0, 1.0)
    else
      Config.DEFAULT_TARGET_01
    end
  end
  return normalized, true
end

"""Score occurrence intervals with the same predictive structural model as values.

Interval quantity remains available as a diagnostic metric, but does not
participate in this score. An interval axis without candidate variation is omitted.
"""
function combine_occurrence_interval_scores(
  temporal_metrics::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics},
  unavailable_fallback::Vector{Float64},
  calibrator::ComplexityMetricCalibrator,
)::Tuple{Vector{Float64},Bool}
  n = length(unavailable_fallback)
  n == 0 && return (Float64[], false)

  prediction_raw = fill(NaN, n)
  diversity_raw = fill(NaN, n)
  shape_raw = fill(NaN, n)
  for i in 1:min(n, length(temporal_metrics))
    temporal = temporal_metrics[i]
    temporal.ready || continue
    prediction_raw[i] = temporal.prediction
    diversity_raw[i] = calibrate_metric(temporal.distance, calibrator.distance)
    shape_raw[i] = calibrate_metric(temporal.complexity, calibrator.complexity)
  end

  prediction, prediction_ready =
    _normalize_candidate_axis(prediction_raw, unavailable_fallback)
  diversity, diversity_ready = _normalize_candidate_axis(diversity_raw)
  shape, shape_ready = _normalize_candidate_axis(shape_raw)

  prediction_weight = prediction_ready ? max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0) : 0.0
  diversity_weight =
    diversity_ready ? max(Config.COMPLEXITY_DIVERSITY_WEIGHT, 0.0) : 0.0
  shape_weight = shape_ready ? max(Config.COMPLEXITY_SHAPE_WEIGHT, 0.0) : 0.0
  denominator = prediction_weight + diversity_weight + shape_weight
  if denominator <= 0.0
    fallback = Float64[
      isfinite(value) ? clamp(value, 0.0, 1.0) : Config.DEFAULT_TARGET_01
      for value in unavailable_fallback
    ]
    return (fallback, false)
  end

  combined = Float64[
    (
      prediction_weight * prediction[i] +
      diversity_weight * diversity[i] +
      shape_weight * shape[i]
    ) / denominator
    for i in 1:n
  ]
  normalized, has_span = _normalize_candidate_axis(combined, unavailable_fallback)
  return (has_span ? normalized : combined, true)
end

"""Combine transition surprise with diversity, shape, and interval structure.

Structural axes are normalized within the current candidate set. An axis with no
candidate variation is omitted. Missing occurrence evidence falls back to the
candidate's predictive surprise instead of treating absence as simple or complex.
"""
function combine_predictive_structural_scores(
  predictive_scores::Vector{Float64},
  raw_dist::Vector{Float64},
  raw_quantity::Vector{Float64},
  raw_complexity::Vector{Float64},
  temporal_metrics::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics};
  metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  calibrator::ExtendedMetricCalibrator = DEFAULT_EXTENDED_METRIC_CALIBRATOR,
)::Vector{Float64}
  n = length(predictive_scores)
  n == 0 && return Float64[]

  diversity_raw = Float64[
    i <= length(raw_dist) ? calibrate_metric(raw_dist[i], calibrator.base.distance) : NaN
    for i in 1:n
  ]
  shape_raw = Float64[
    i <= length(raw_complexity) ?
      calibrate_metric(raw_complexity[i], calibrator.base.complexity) :
      NaN
    for i in 1:n
  ]
  mass_raw = Float64[
    i <= length(raw_quantity) ? calibrate_metric(raw_quantity[i], calibrator.base.quantity) : NaN
    for i in 1:n
  ]
  prediction, prediction_ready = _normalize_candidate_axis(predictive_scores)
  diversity, diversity_ready = _normalize_candidate_axis(diversity_raw)
  shape, shape_ready = _normalize_candidate_axis(shape_raw)
  mass, mass_ready = _normalize_candidate_axis(mass_raw)
  occurrence, occurrence_ready = combine_occurrence_interval_scores(
    temporal_metrics,
    predictive_scores,
    calibrator.occurrence_intervals,
  )

  prediction_weight = any(isfinite, predictive_scores) ? max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0) : 0.0
  diversity_weight = diversity_ready ? max(Config.COMPLEXITY_DIVERSITY_WEIGHT * metric_weights[1], 0.0) : 0.0
  shape_weight = shape_ready ? max(Config.COMPLEXITY_SHAPE_WEIGHT * metric_weights[3], 0.0) : 0.0
  occurrence_weight = occurrence_ready ? max(Config.COMPLEXITY_OCCURRENCE_WEIGHT, 0.0) : 0.0
  mass_weight = mass_ready ? max(Config.COMPLEXITY_MASS_WEIGHT * metric_weights[2], 0.0) : 0.0
  denominator = prediction_weight + diversity_weight + shape_weight + occurrence_weight + mass_weight
  denominator <= 0.0 && return fill(Config.DEFAULT_TARGET_01, n)

  combined = Vector{Float64}(undef, n)
  for i in 1:n
    combined[i] = (
      prediction_weight * prediction[i] +
      diversity_weight * diversity[i] +
      shape_weight * shape[i] +
      occurrence_weight * occurrence[i] +
      mass_weight * mass[i]
    ) / denominator
  end

  normalized, has_span = _normalize_candidate_axis(combined)
  return has_span ? normalized : combined
end

function select_candidate_by_complexity_score(scores::Vector{Float64}, target_val::Float64)::Int
  isempty(scores) && throw(ArgumentError("candidate complexity scores must not be empty"))
  best_index = 0
  min_diff = Inf
  for (idx0, score) in enumerate(scores)
    diff = abs(score - target_val)
    if diff < min_diff
      min_diff = diff
      best_index = idx0 - 1
    end
  end
  return best_index
end

@inline cluster_quantity_score(cluster_size::Int, window_size::Int)::Float64 = float(cluster_size * window_size)

# Initialize cache values (we compute "full" caches for stability)
function initial_calc_values!(
  manager,
  clusters_each_window_size
)
  for (window_size, same_ws) in clusters_each_window_size
    all_ids = collect(keys(same_ws))

    cache = get!(manager.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    for i in 1:length(all_ids)
      for j in (i+1):length(all_ids)
        cid1 = all_ids[i]
        cid2 = all_ids[j]
        as1 = same_ws[cid1]["as"]
        as2 = same_ws[cid2]["as"]
        key = cid1 < cid2 ? (cid1,cid2) : (cid2,cid1)
        cache[key] = PolyphonicClusterManager.euclidean_distance(manager, as1, as2)
      end
    end

    q_cache = get!(manager.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get!(manager.cluster_complexity_cache, window_size, Dict{Int,Float64}())
    for (cid, cluster) in same_ws
      si = cluster["si"]
      length(si) > 1 || continue
      q = cluster_quantity_score(length(si), window_size)
      q_cache[cid] = q
      c_cache[cid] = PolyphonicClusterManager.calculate_cluster_complexity(manager, cluster)
    end
  end

  return nothing
end
