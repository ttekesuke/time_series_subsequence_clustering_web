using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _time_series_controller_for_tie = Main.TimeseriesClusteringAPI.TimeSeriesController
const _supercollider_controller_for_tie = Main.TimeseriesClusteringAPI.SupercollidersController

function _tie_test_voice(note::Int; tie::Float64=0.0)
  return Any[
    [note],
    1.0,
    0.5,
    0.0,
    1.0,
    0.05,
    0.20,
    0.75,
    0,
    0.0,
    tie,
  ]
end

function _poly_synth_event_lines(scd::String)
  return filter(line -> occursin("['/s_new', \\polySynth", line), split(scd, '\n'))
end

@testset "tie target distribution is deterministic" begin
  @test _time_series_controller_for_tie.generate_centered_targets(1, 0.6, 1.0) == [0.6]
  @test _time_series_controller_for_tie.generate_centered_targets(3, 0.5, 0.5) == [0.25, 0.5, 0.75]
end

@testset "SuperCollider tie joins only identical consecutive notes" begin
  tied = _supercollider_controller_for_tie.build_score_events_scd(
    [[_tie_test_voice(60)], [_tie_test_voice(60; tie=1.0)]],
    [0.5, 0.5],
    "/tmp/tie_rendering.wav",
    0.0,
  )
  tied_events = _poly_synth_event_lines(tied)
  @test length(tied_events) == 1
  @test occursin("\\dur, 1.000000", only(tied_events))

  untied = _supercollider_controller_for_tie.build_score_events_scd(
    [[_tie_test_voice(60)], [_tie_test_voice(60)]],
    [0.5, 0.5],
    "/tmp/tie_rendering.wav",
    0.0,
  )
  @test length(_poly_synth_event_lines(untied)) == 2

  changed_note = _supercollider_controller_for_tie.build_score_events_scd(
    [[_tie_test_voice(60)], [_tie_test_voice(61; tie=1.0)]],
    [0.5, 0.5],
    "/tmp/tie_rendering.wav",
    0.0,
  )
  @test length(_poly_synth_event_lines(changed_note)) == 2
end
