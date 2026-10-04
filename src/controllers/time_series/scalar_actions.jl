function analyse()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "analyse")

  raw_series = get(p, "time_series", Any[])
  data = Int[]
  for v in raw_series
    push!(data, _parse_int(v))
  end

  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", Config.DEFAULT_MERGE_THRESHOLD_RATIO))
  contextual_min_width = _parse_float(get(p, "contextual_min_width", Config.DEFAULT_CONTEXTUAL_MIN_WIDTH))
  min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE
  calculate_distance_when_added_subsequence_to_cluster = true

  manager = PolyphonicClusterManager.Manager(
    Vector{Float64}[[float(v)] for v in data],
    merge_threshold_ratio,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster;
    scale_mode = :contextual_global_halves,
    contextual_min_width = contextual_min_width
  )

  PolyphonicClusterManager.process_data!(manager)

  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)
  println("analyse processing time (s): ", processing_time_s)

  response = Dict(
    "compressedClusterSpans" => PolyphonicClusterManager.compressed_clusters_payload(manager),
    "timeSeries" => data,
    "processingTime" => processing_time_s
  )
  if get(p, "compact_cluster_view", false) != true
    response["clusteredSubsequences"] = PolyphonicClusterManager.clusters_to_timeline(manager)
    response["clusters"] = PolyphonicClusterManager.clusters_to_dict(manager)
  end
  return response
end

function generate()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "generate")

  first_elements = _parse_csv_ints(string(get(p, "first_elements", "")))
  complexity_targets = _parse_csv_floats(string(get(p, "complexity_transition", "")))
  recency_centers = _parse_csv_floats(string(get(p, "recency_center", "")))
  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", Config.DEFAULT_MERGE_THRESHOLD_RATIO))
  contextual_min_width = _parse_float(get(p, "contextual_min_width", Config.DEFAULT_CONTEXTUAL_MIN_WIDTH))

  candidate_min_master = _parse_int(get(p, "range_min", Config.DEFAULT_RANGE_MIN))
  candidate_max_master = _parse_int(get(p, "range_max", Config.DEFAULT_RANGE_MAX))
  candidate_min_master <= candidate_max_master || _invalid_generate_request(
    "invalid_range",
    "generate.range_min must be less than or equal to generate.range_max.",
  )

  min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE
  calculate_distance_when_added_subsequence_to_cluster = false

  manager = PolyphonicClusterManager.Manager(
    Vector{Float64}[[float(v)] for v in first_elements],
    merge_threshold_ratio,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster;
    scale_mode = :range_fixed,
    range_min = candidate_min_master,
    range_max = candidate_max_master,
    contextual_min_width = contextual_min_width,
    recency = 0.0
  )

  PolyphonicClusterManager.process_data!(manager)

  clusters_each = PolyphonicClusterManager.transform_clusters(manager)
  initial_calc_values!(
    manager,
    clusters_each
  )
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

  results = copy(first_elements)

  for (step_idx, target_val) in enumerate(complexity_targets)
    candidates = collect(candidate_min_master:candidate_max_master)
    manager.recency = step_idx <= length(recency_centers) ? clamp(recency_centers[step_idx], 0.0, 1.0) : 0.0
    calibrator = build_extended_metric_calibrator(manager)
    raw_dist = Float64[]
    raw_quantity = Float64[]
    raw_complexity = Float64[]
    temporal_metrics = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
    sizehint!(raw_dist, length(candidates))
    sizehint!(raw_quantity, length(candidates))
    sizehint!(raw_complexity, length(candidates))
    sizehint!(temporal_metrics, length(candidates))

    for candidate in candidates
      metrics =
        PolyphonicClusterManager.simulate_add_and_calculate_all_extended(manager, Float64[candidate])
      push!(raw_dist, metrics.distance)
      push!(raw_quantity, metrics.quantity)
      push!(raw_complexity, metrics.complexity)
      push!(temporal_metrics, metrics.occurrence_intervals)
    end

    candidate_polysets = PolyphonicClusterManager.PolySet[
      Float64[candidate] for candidate in candidates
    ]
    predictive_scores = predictive_surprise_scores(manager, candidate_polysets)
    scores = combine_predictive_structural_scores(
      predictive_scores,
      raw_dist,
      raw_quantity,
      raw_complexity,
      temporal_metrics;
      calibrator=calibrator,
    )
    result_index = select_candidate_by_complexity_score(scores, float(target_val))
    result_value = candidates[result_index + 1]

    push!(results, result_value)
    PolyphonicClusterManager.add_data_point_permanently!(manager, Float64[result_value])
    PolyphonicClusterManager.update_caches_permanently!(manager)
  end

  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)

  complexity_transition_stream = Any[missing for _ in first_elements]
  append!(complexity_transition_stream, complexity_targets)

  response = Dict(
    "compressedClusterSpans" => PolyphonicClusterManager.compressed_clusters_payload(manager),
    "timeSeries" => results,
    "complexityTransition" => complexity_transition_stream,
    "processingTime" => processing_time_s
  )
  if get(p, "compact_cluster_view", false) != true
    response["clusteredSubsequences"] = PolyphonicClusterManager.clusters_to_timeline(manager)
    response["clusters"] = PolyphonicClusterManager.clusters_to_dict(manager)
  end
  return response
end
