using Test

const StructuralController = Main.TimeseriesClusteringAPI.TimeSeriesController
const StructuralPCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

@testset "candidate complexity combines structural cluster metrics only" begin
  empty_temporal = StructuralPCM.EMPTY_OCCURRENCE_INTERVAL_METRICS
  scores = StructuralController.combine_structural_scores(
    Float64[0.0, 10.0],
    Float64[10.0, 0.0],
    Float64[0.0, 10.0],
    StructuralPCM.OccurrenceIntervalMetrics[empty_temporal, empty_temporal],
  )

  @test length(scores) == 2
  @test all(isfinite, scores)
  @test all(value -> 0.0 <= value <= 1.0, scores)
end

@testset "occurrence interval score uses distance and shape only" begin
  temporal = StructuralPCM.OccurrenceIntervalMetrics[
    StructuralPCM.OccurrenceIntervalMetrics(1.0, 1.0, 2.0, true),
    StructuralPCM.OccurrenceIntervalMetrics(10.0, 100.0, 12.0, true),
  ]
  scores, ready = StructuralController.combine_occurrence_interval_scores(
    temporal,
    StructuralController.DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
  )

  @test ready
  @test length(scores) == 2
  @test all(isfinite, scores)
  @test all(value -> 0.0 <= value <= 1.0, scores)
end

@testset "occurrence interval score is unavailable before structural evidence" begin
  empty_temporal = StructuralPCM.EMPTY_OCCURRENCE_INTERVAL_METRICS
  scores, ready = StructuralController.combine_occurrence_interval_scores(
    StructuralPCM.OccurrenceIntervalMetrics[empty_temporal, empty_temporal],
    StructuralController.DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
  )

  @test !ready
  @test length(scores) == 2
end
