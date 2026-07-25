using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _controller = Main.TimeseriesClusteringAPI.TimeSeriesController
const _pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

@testset "metric calibrator is fixed before candidate evaluation" begin
  dist = _controller.ScalarMetricCalibrator(10.0, 2.0, 1.0)
  inverse = _controller.ScalarMetricCalibrator(10.0, 2.0, -1.0)
  fixed = _controller.ComplexityMetricCalibrator(dist, inverse, dist, inverse)

  scores_a = _controller.combine_complexity_metric_scores(
    [10.0, 12.0],
    [0.0, 0.0],
    [0.0, 0.0],
    [0.0, 0.0];
    metric_weights=(1.0, 0.0, 0.0, 0.0),
    calibrator=fixed,
  )
  scores_b = _controller.combine_complexity_metric_scores(
    [-100.0, 10.0, 12.0, 100.0],
    zeros(4),
    zeros(4),
    zeros(4);
    metric_weights=(1.0, 0.0, 0.0, 0.0),
    calibrator=fixed,
  )

  @test scores_a[1] == scores_b[2]
  @test scores_a[2] == scores_b[3]
  @test _controller.calibrate_metric(12.0, dist) > 0.5
  @test _controller.calibrate_metric(12.0, inverse) < 0.5
end

@testset "calibrator snapshot reads only committed manager state" begin
  manager = _pcm.Manager(
    [[0.0], [1.0], [0.0], [1.0]],
    0.02,
    2,
    false;
    range_min=0.0,
    range_max=2.0,
  )
  _pcm.process_data!(manager)
  _pcm.update_caches_permanently!(manager)

  before_data = deepcopy(manager.data)
  calibrator = _controller.build_extended_metric_calibrator(manager)
  _pcm.simulate_add_and_calculate_all_extended(manager, [2.0])

  @test manager.data == before_data
  @test calibrator.base.distance.scale > 0.0
  @test calibrator.base.quantity.direction == -1.0
end

@testset "chord selection adds one note at a time" begin
  evaluations = Ref(0)
  evaluate_chord = function (chord)
    evaluations[] += 1
    return sum(abs(note - 63) for note in chord)
  end

  selected = _controller.select_notes_by_single_addition_greedy(
    collect(60:66),
    3,
    0.0,
    _controller.DissonanceCalibrator(1.0),
    evaluate_chord;
    register_center=63.0,
    register_allowance=100.0,
    tie_center=63.0,
  )

  @test length(selected) == 3
  @test length(unique(selected)) == 3
  @test evaluations[] == 7 + 6 + 5
  @test selected == sort(selected)
end
