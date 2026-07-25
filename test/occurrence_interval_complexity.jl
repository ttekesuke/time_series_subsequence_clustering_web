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

@testset "repeating interval subsequences use the existing four metrics" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

  regular = pcm._occurrence_interval_metrics_for_starts([0, 4, 8, 12], 0.02, 2)
  alternating = pcm._occurrence_interval_metrics_for_starts([0, 3, 8, 11, 16], 0.02, 2)

  @test regular.ready
  @test regular.quantity > 0.0
  @test regular.usage > 0.0
  @test alternating.ready
  @test alternating.quantity > 0.0
  @test alternating.usage > 0.0
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
  @test length(legacy) == 4
end

@testset "not-ready interval metrics do not change candidate scores" begin
  pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
  controller = Main.TimeseriesClusteringAPI.TimeSeriesController
  empty_temporal = pcm.EMPTY_OCCURRENCE_INTERVAL_METRICS
  irregular = pcm._occurrence_interval_metrics_for_starts([0, 4, 9], 0.02, 2)

  base = controller.combine_complexity_metric_scores(
    [0.0, 1.0],
    [0.0, 0.0],
    [0.0, 0.0],
    [0.0, 0.0],
  )
  combined = controller.combine_complexity_metric_scores_with_occurrence_intervals(
    [0.0, 1.0],
    [0.0, 0.0],
    [0.0, 0.0],
    [0.0, 0.0],
    [empty_temporal, irregular],
  )

  @test combined[1] == base[1]
  @test combined[2] != base[2]
end
