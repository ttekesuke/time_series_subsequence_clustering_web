using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _predictive_controller = Main.TimeseriesClusteringAPI.TimeSeriesController
const _predictive_pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const _predictive_msm = Main.TimeseriesClusteringAPI.MultiStreamManager

function _predictive_manager(data; range_min=0.0, range_max=11.0, recency=0.0)
  manager = _predictive_pcm.Manager(
    [Float64[float(value) for value in point] for point in data],
    0.02,
    2,
    false;
    scale_mode=:range_fixed,
    range_min=range_min,
    range_max=range_max,
    recency=recency,
  )
  _predictive_pcm.process_data!(manager)
  _predictive_pcm.update_caches_permanently!(manager)
  return manager
end

@testset "predictive complexity follows deviation from a repeated continuation" begin
  manager = _predictive_manager([
    Float64[value]
    for value in [0, 7, 4, 7, 0, 7, 4, 7, 0, 7, 4, 7]
  ])
  distribution = _predictive_controller.build_predictive_distribution(manager)
  scores = Float64[
    _predictive_controller.predictive_surprise_score(
      manager,
      distribution,
      Float64[candidate],
    )
    for candidate in 0:11
  ]

  @test distribution.ready
  @test scores[1] == 0.0
  @test scores[3] ≈ 0.289 atol=0.02
  @test scores[end] > 0.999
  @test issorted(scores)

  calibrator = _predictive_controller.build_extended_metric_calibrator(manager)
  metrics = [
    _predictive_pcm.simulate_add_and_calculate_all_extended(manager, Float64[candidate])
    for candidate in 0:11
  ]
  combined = _predictive_controller.combine_predictive_structural_scores(
    scores,
    Float64[metric.distance for metric in metrics],
    Float64[metric.complexity for metric in metrics],
    _predictive_pcm.OccurrenceIntervalMetrics[
      metric.occurrence_intervals for metric in metrics
    ];
    calibrator=calibrator,
  )
  @test argmin(abs.(combined .- 0.3)) == 3
end

@testset "predictive distribution supports PolySet successors" begin
  manager = _predictive_manager([
    [0.0, 4.0],
    [7.0],
    [0.0, 4.0],
    [7.0],
    [0.0, 4.0],
    [7.0],
  ])
  distribution = _predictive_controller.build_predictive_distribution(manager)
  repeated = _predictive_controller.predictive_surprise_score(
    manager,
    distribution,
    [0.0, 4.0],
  )
  novel = _predictive_controller.predictive_surprise_score(
    manager,
    distribution,
    [11.0],
  )

  @test distribution.ready
  @test repeated == 0.0
  @test novel > repeated
end

@testset "structural axes affect the combined complexity score" begin
  empty_temporal = _predictive_pcm.EMPTY_OCCURRENCE_INTERVAL_METRICS
  predictive = Float64[0.0, 0.0]

  diversity = _predictive_controller.combine_predictive_structural_scores(
    predictive,
    Float64[0.0, 10.0],
    Float64[0.0, 0.0],
    _predictive_pcm.OccurrenceIntervalMetrics[empty_temporal, empty_temporal],
  )
  shape = _predictive_controller.combine_predictive_structural_scores(
    predictive,
    Float64[0.0, 0.0],
    Float64[0.0, 10.0],
    _predictive_pcm.OccurrenceIntervalMetrics[empty_temporal, empty_temporal],
  )
  occurrence = _predictive_controller.combine_predictive_structural_scores(
    predictive,
    Float64[0.0, 0.0],
    Float64[0.0, 0.0],
    _predictive_pcm.OccurrenceIntervalMetrics[
      _predictive_pcm.OccurrenceIntervalMetrics(0.0, 1.0, 0.0, 0.0, true),
      _predictive_pcm.OccurrenceIntervalMetrics(10.0, 1.0, 10.0, 1.0, true),
    ],
  )

  @test diversity == [0.0, 1.0]
  @test shape == [0.0, 1.0]
  @test occurrence == [0.0, 1.0]
end

@testset "occurrence score ignores interval quantity" begin
  temporal = _predictive_pcm.OccurrenceIntervalMetrics[
    _predictive_pcm.OccurrenceIntervalMetrics(1.0, 0.0, 2.0, 0.25, true),
    _predictive_pcm.OccurrenceIntervalMetrics(1.0, 100.0, 2.0, 0.25, true),
  ]
  scores, ready = _predictive_controller.combine_occurrence_interval_scores(
    temporal,
    [0.0, 1.0],
    _predictive_controller.DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
  )

  @test !ready
  @test scores == [0.0, 1.0]
end

@testset "recency changes votes inside the predictive distribution" begin
  data = [
    [1.0], [2.0], [0.0], [8.0],
    [1.0], [2.0], [10.0], [9.0],
    [1.0], [2.0],
  ]
  uniform_manager = _predictive_manager(data; range_min=0.0, range_max=10.0, recency=0.0)
  recent_manager = _predictive_manager(data; range_min=0.0, range_max=10.0, recency=1.0)
  uniform = _predictive_controller.build_predictive_distribution(uniform_manager)
  recent = _predictive_controller.build_predictive_distribution(recent_manager)

  function mass_at(distribution, value)
    return sum(successor.mass for successor in distribution.successors if successor.value == [value])
  end

  @test mass_at(uniform, 0.0) ≈ mass_at(uniform, 10.0)
  @test mass_at(recent, 10.0) > mass_at(recent, 0.0)
end

@testset "polyphonic selector uses predictive scores for global and streams" begin
  empty_temporal = _predictive_pcm.EMPTY_OCCURRENCE_INTERVAL_METRICS
  function metric(value, predictive)
    return _predictive_controller.CandidateMetric(
      Float64[value],
      0.0,
      0.0,
      0.0,
      0.0,
      Float64[0.0],
      Float64[0.0],
      Float64[0.0],
      Float64[0.0],
      empty_temporal,
      _predictive_pcm.OccurrenceIntervalMetrics[empty_temporal],
      predictive,
      Float64[predictive],
      0.0,
    )
  end

  metrics = [metric(0.0, 0.0), metric(1.0, 1.0)]
  best, cost, breakdowns =
    _predictive_controller.select_best_polyphonic_candidate_unified_with_cost(
      metrics,
      1.0,
      Float64[1.0],
      0.0,
      (1.0, 1.0, 1.0, 1.0),
      (1.0, 1.0, 1.0, 1.0),
    )

  @test best == 2
  @test cost == 0.0
  @test breakdowns[best].current_global == 1.0
  @test breakdowns[best].stream_scores == [1.0]
end

@testset "note greedy passes candidate chords to structural batch scoring" begin
  batch_calls = Ref(0)
  selected = _predictive_controller.select_notes_by_single_addition_greedy(
    Int[60, 62, 64],
    2,
    0.0,
    _predictive_controller.DissonanceCalibrator(1.0),
    _chord -> 0.0;
    register_center=62.0,
    register_allowance=12.0,
    tie_center=62.0,
    complexity_cost_batch=chords -> begin
      batch_calls[] += 1
      zeros(Float64, length(chords))
    end,
  )

  @test length(selected) == 2
  @test batch_calls[] == 2
end

@testset "polyphonic dimension generation uses the shared predictive distribution" begin
  values = [0, 7, 4, 7, 0, 7, 4, 7, 0, 7, 4, 7]
  history = [[float(value)] for value in values]
  stream_manager = _predictive_msm.Manager(
    history,
    0.02,
    2;
    use_complexity_mapping=true,
    value_range=collect(0.0:11.0),
  )
  global_manager = _predictive_manager([Float64[value] for value in values])
  axis = _predictive_controller.StableStreamAxis(1, [1])
  managers = Dict{Symbol,Any}(
    :global => global_manager,
    :stream => stream_manager,
    :global_offset => 12.0,
    :stream_axis => axis,
  )

  selected = _predictive_controller.select_best_values_for_dimension_greedy(
    managers,
    Float64[0.0, 2.0, 11.0],
    0.3,
    Float64[0.3],
    0.0,
    1,
  )

  @test selected == [2.0]
end
