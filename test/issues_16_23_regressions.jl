using Test

const IssuesController = Main.TimeseriesClusteringAPI.TimeSeriesController
const IssuesPCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const IssuesMSM = Main.TimeseriesClusteringAPI.MultiStreamManager
const IssuesSTM = Main.TimeseriesClusteringAPI.DissonanceStmManager
const IssuesVoice = Main.TimeseriesClusteringAPI.VoiceTokenGeneration
const IssuesConfig = Main.TimeseriesClusteringAPI.Config

@testset "#17 dissonance STM is pitch-class canonical" begin
  a = IssuesSTM.Manager()
  b = IssuesSTM.Manager()
  amps = [0.5, 0.5]
  da = IssuesSTM.commit!(a, [48, 55], amps, 0.0)
  db = IssuesSTM.commit!(b, [60, 67], amps, 0.0)
  @test da ≈ db atol=1e-12
  @test a.memory[1].midi_notes == [60, 67]
  @test b.memory[1].midi_notes == [60, 67]
  ea = IssuesSTM.evaluate(a, [50, 57], amps, 0.25)
  eb = IssuesSTM.evaluate(b, [62, 69], amps, 0.25)
  @test ea ≈ eb atol=1e-12
end

function _issue_manager(values)
  m = IssuesPCM.Manager(
    Vector{Float64}[Float64[v] for v in values],
    0.3,
    2;
    range_min=0.0,
    range_max=10.0,
    max_set_size=1,
  )
  IssuesPCM.process_data!(m)
  IssuesPCM.update_caches_permanently!(m)
  return m
end

function _expected_voice_scores(manager, candidates)
  distribution = IssuesPCM.build_predictive_distribution(manager)
  calibrator = IssuesController.build_extended_metric_calibrator(manager)
  predictive = Float64[]
  d = Float64[]
  q = Float64[]
  c = Float64[]
  temporal = IssuesPCM.OccurrenceIntervalMetrics[]
  for candidate in candidates
    metrics = IssuesPCM.simulate_add_and_calculate_all_extended(manager, candidate)
    p = IssuesPCM.predictive_surprise_score(manager, distribution, candidate)
    push!(predictive, p === nothing ? NaN : float(p))
    push!(d, metrics.distance)
    push!(q, metrics.quantity)
    push!(c, metrics.complexity)
    push!(temporal, metrics.occurrence_intervals)
  end
  return IssuesController.combine_predictive_structural_scores(
    predictive, d, q, c, temporal; calibrator=calibrator,
  ), predictive
end

@testset "#20 voice token complexity uses common score ready/not-ready" begin
  candidates = Vector{Float64}[[0.0], [4.0], [9.0]]

  not_ready = _issue_manager([1.0, 2.0])
  actual_nr = IssuesVoice._candidate_complexity_scores(not_ready, candidates)
  expected_nr, predictive_nr = _expected_voice_scores(not_ready, candidates)
  @test actual_nr ≈ expected_nr atol=1e-12
  @test all(isfinite, actual_nr)
  @test any(!isfinite, predictive_nr) || length(unique(round.(predictive_nr; digits=10))) <= 1

  ready = _issue_manager([1.0, 2.0, 1.0, 3.0, 1.0, 5.0, 1.0, 7.0])
  actual_r = IssuesVoice._candidate_complexity_scores(ready, candidates)
  expected_r, predictive_r = _expected_voice_scores(ready, candidates)
  @test actual_r ≈ expected_r atol=1e-12
  @test length(actual_r) == length(candidates)
  @test all(x -> 0.0 <= x <= 1.0, actual_r)
end

@testset "#22 short series has no phantom root and initializes when ready" begin
  empty_mgr = IssuesPCM.Manager(Vector{Float64}[], 0.3, 2)
  IssuesPCM.process_data!(empty_mgr)
  @test isempty(empty_mgr.clusters)
  @test isempty(IssuesPCM.clusters_to_timeline(empty_mgr.clusters, 2))

  one_mgr = IssuesPCM.Manager(Vector{Float64}[[3.0]], 0.3, 2)
  IssuesPCM.process_data!(one_mgr)
  @test isempty(one_mgr.clusters)
  IssuesPCM.add_data_point_permanently!(one_mgr, [4.0])
  @test haskey(one_mgr.clusters, 0)
  @test one_mgr.clusters[0].si == [0]
  @test one_mgr.clusters[0].as == [[3.0], [4.0]]

  normal_mgr = IssuesPCM.Manager(Vector{Float64}[[3.0], [4.0]], 0.3, 2)
  IssuesPCM.process_data!(normal_mgr)
  @test haskey(normal_mgr.clusters, 0)
  @test normal_mgr.clusters[0].si == [0]
end

@testset "#23 candidate selector rejects empty scores and accepts singleton" begin
  @test_throws ArgumentError IssuesController.select_candidate_by_complexity_score(Float64[], 0.5)
  @test IssuesController.select_candidate_by_complexity_score([0.25], 0.9) == 0
end

@testset "#19 BPM frontend/backend contract" begin
  @test IssuesConfig.POLYPHONIC_BPM_DEFAULT == 480.0
  @test IssuesConfig.POLYPHONIC_BPM == IssuesConfig.POLYPHONIC_BPM_DEFAULT
  frontend_default = read(joinpath(pwd(), "frontend", "src", "constants", "musicDefaults.ts"), String)
  @test occursin("POLYPHONIC_BPM_DEFAULT = 480", frontend_default)
end

@testset "#16/#18/#21 source contracts" begin
  controller = read(joinpath(pwd(), "src", "controllers", "time_series_controller.jl"), String)
  dialog = read(joinpath(pwd(), "frontend", "src", "components", "dialog", "MusicGenerateDialog.vue"), String)
  @test occursin("initial_last_step_snapshot", controller)
  @test !occursin("haskey(managers, \"vol\") ? managers[\"vol\"][:stream] : managers[\"note\"][:stream]", controller)
  @test occursin("lifecycle_mgr = managers[\"vol\"][:stream]", controller)
  @test occursin("stream_strengths_report(managers[\"vol\"][:stream])", controller)
  @test !occursin("use_recent_position_weight:", dialog)
  @test !occursin("debug_score_key:", dialog)
  @test !occursin("debug_score_top_n:", dialog)
end
