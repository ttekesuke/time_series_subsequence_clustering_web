using Test

@testset "occurrence interval complexity starts at three occurrences" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

  not_ready = pcm._occurrence_interval_metrics_for_starts([0, 4], 0.02, 2)
  regular = pcm._occurrence_interval_metrics_for_starts([0, 4, 8], 0.02, 2)
  irregular = pcm._occurrence_interval_metrics_for_starts([0, 4, 9], 0.02, 2)

  @test !not_ready.ready
  @test regular.ready
  @test irregular.ready
  @test regular.complexity == 0.0
  @test irregular.complexity > regular.complexity
end

@testset "occurrence intervals predict the next normalized gap" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

  regular = pcm._occurrence_interval_metrics_for_starts([0, 4, 8, 12, 16], 0.02, 2)
  delayed = pcm._occurrence_interval_metrics_for_starts([0, 4, 8, 12, 20], 0.02, 2)

  @test regular.ready
  @test delayed.ready
  @test isfinite(regular.prediction)
  @test isfinite(delayed.prediction)
  @test regular.prediction == 0.0
  @test delayed.prediction > regular.prediction
end

@testset "candidate simulation exposes interval metrics only at the third match" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

  two_match_manager = pcm.Manager(
    [[1.0], [1.0]],
    0.02,
    2;
    range_min=0.0,
    range_max=2.0,
  )
  pcm.process_data!(two_match_manager)
  pcm.update_caches_permanently!(two_match_manager)
  before_third_match =
    pcm.simulate_add_and_calculate_all_extended(two_match_manager, [1.0])

  three_match_manager = pcm.Manager(
    [[1.0], [1.0], [1.0]],
    0.02,
    2;
    range_min=0.0,
    range_max=2.0,
  )
  pcm.process_data!(three_match_manager)
  pcm.update_caches_permanently!(three_match_manager)
  at_third_match =
    pcm.simulate_add_and_calculate_all_extended(three_match_manager, [1.0])

  @test !before_third_match.occurrence_intervals.ready
  @test at_third_match.occurrence_intervals.ready
  @test at_third_match.occurrence_intervals.complexity == 0.0
end

@testset "occurrence interval cache stays permanent across preview rollback" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
  manager = pcm.Manager(
    [[1.0], [1.0], [1.0], [1.0]],
    0.02,
    2;
    range_min=0.0,
    range_max=2.0,
  )
  pcm.process_data!(manager)
  pcm.update_caches_permanently!(manager)

  before_lengths = sort([
    length(state.manager.data)
    for state in values(manager.occurrence_interval_states)
    if state.manager !== nothing
  ])
  extended = pcm.simulate_add_and_calculate_all_extended(manager, [1.0])
  after_lengths = sort([
    length(state.manager.data)
    for state in values(manager.occurrence_interval_states)
    if state.manager !== nothing
  ])
  legacy = pcm.simulate_add_and_calculate_all(manager, [1.0])

  @test extended.occurrence_intervals.ready
  @test before_lengths == after_lengths
  @test length(legacy) == 3
end

@testset "recency changes candidate complexity scores" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
  controller = Main.TimeseriesClusteringAPI.TimeSeriesController
  config = Main.TimeseriesClusteringAPI.Config

  function scores_for_recency(recency)
    manager = pcm.Manager(
      [[0.0], [0.0], [0.0], [1.0], [1.0], [1.0], [0.0], [0.0], [0.0]],
      config.DEFAULT_MERGE_THRESHOLD_RATIO,
      config.SUBSEQUENCE_MIN_WINDOW_SIZE,
      false;
      scale_mode=:range_fixed,
      range_min=0.0,
      range_max=5.0,
      recency=recency,
    )
    pcm.process_data!(manager)
    controller.initial_calc_values!(
      manager,
      pcm.transform_clusters(manager.clusters, config.SUBSEQUENCE_MIN_WINDOW_SIZE),
    )
    empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

    calibrator = controller.build_extended_metric_calibrator(manager)
    raw_dist = Float64[]
    raw_quantity = Float64[]
    raw_complexity = Float64[]
    temporal_metrics = pcm.OccurrenceIntervalMetrics[]
    for candidate in 0:5
      metrics = pcm.simulate_add_and_calculate_all_extended(manager, Float64[candidate])
      push!(raw_dist, metrics.distance)
      push!(raw_quantity, metrics.quantity)
      push!(raw_complexity, metrics.complexity)
      push!(temporal_metrics, metrics.occurrence_intervals)
    end

    return controller.combine_complexity_metric_scores_with_occurrence_intervals(
      raw_dist,
      raw_quantity,
      raw_complexity,
      temporal_metrics;
      calibrator=calibrator,
    )
  end

  no_recency = scores_for_recency(0.0)
  max_recency = scores_for_recency(1.0)

  @test length(no_recency) == length(max_recency) == 6
  @test maximum(abs.(no_recency .- max_recency)) > 0.1
end
