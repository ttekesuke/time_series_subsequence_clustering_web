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

"""Combine occurrence-interval distance and shape metrics for the candidates."""
function combine_occurrence_interval_scores(
  temporal_metrics::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics},
  calibrator::ComplexityMetricCalibrator,
)::Tuple{Vector{Float64},Bool}
  n = length(temporal_metrics)
  n == 0 && return (Float64[], false)

  diversity_raw = fill(NaN, n)
  shape_raw = fill(NaN, n)
  for i in eachindex(temporal_metrics)
    temporal = temporal_metrics[i]
    temporal.ready || continue
    diversity_raw[i] = calibrate_metric(temporal.distance, calibrator.distance)
    shape_raw[i] = calibrate_metric(temporal.complexity, calibrator.complexity)
  end

  diversity, diversity_ready = _normalize_candidate_axis(diversity_raw)
  shape, shape_ready = _normalize_candidate_axis(shape_raw)
  diversity_weight = diversity_ready ? max(Config.COMPLEXITY_DIVERSITY_WEIGHT, 0.0) : 0.0
  shape_weight = shape_ready ? max(Config.COMPLEXITY_SHAPE_WEIGHT, 0.0) : 0.0
  denominator = diversity_weight + shape_weight
  denominator <= 0.0 && return (fill(Config.DEFAULT_TARGET_01, n), false)

  combined = Float64[
    (diversity_weight * diversity[i] + shape_weight * shape[i]) / denominator
    for i in 1:n
  ]
  normalized, has_span = _normalize_candidate_axis(combined)
  return (has_span ? normalized : combined, true)
end

"""Combine diversity, shape, occurrence structure, and repeated mass."""
function combine_structural_scores(
  raw_dist::Vector{Float64},
  raw_quantity::Vector{Float64},
  raw_complexity::Vector{Float64},
  temporal_metrics::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics};
  metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  calibrator::ExtendedMetricCalibrator = DEFAULT_EXTENDED_METRIC_CALIBRATOR,
)::Vector{Float64}
  n = length(raw_dist)
  n == 0 && return Float64[]

  diversity_raw = Float64[
    calibrate_metric(raw_dist[i], calibrator.base.distance) for i in 1:n
  ]
  shape_raw = Float64[
    i <= length(raw_complexity) ?
      calibrate_metric(raw_complexity[i], calibrator.base.complexity) : NaN
    for i in 1:n
  ]
  mass_raw = Float64[
    i <= length(raw_quantity) ?
      calibrate_metric(raw_quantity[i], calibrator.base.quantity) : NaN
    for i in 1:n
  ]
  diversity, diversity_ready = _normalize_candidate_axis(diversity_raw)
  shape, shape_ready = _normalize_candidate_axis(shape_raw)
  mass, mass_ready = _normalize_candidate_axis(mass_raw)
  occurrence, occurrence_ready = combine_occurrence_interval_scores(
    temporal_metrics,
    calibrator.occurrence_intervals,
  )

  diversity_weight = diversity_ready ? max(Config.COMPLEXITY_DIVERSITY_WEIGHT * metric_weights[1], 0.0) : 0.0
  shape_weight = shape_ready ? max(Config.COMPLEXITY_SHAPE_WEIGHT * metric_weights[3], 0.0) : 0.0
  occurrence_weight = occurrence_ready ? max(Config.COMPLEXITY_OCCURRENCE_WEIGHT, 0.0) : 0.0
  mass_weight = mass_ready ? max(Config.COMPLEXITY_MASS_WEIGHT * metric_weights[2], 0.0) : 0.0
  denominator = diversity_weight + shape_weight + occurrence_weight + mass_weight
  denominator <= 0.0 && return fill(Config.DEFAULT_TARGET_01, n)

  combined = Vector{Float64}(undef, n)
  for i in 1:n
    combined[i] = (
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
