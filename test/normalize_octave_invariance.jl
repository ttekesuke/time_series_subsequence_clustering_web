using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _time_series_controller_for_octave = Main.TimeseriesClusteringAPI.TimeSeriesController

@testset "octave invariant note matching" begin
  midi_c4 = float(_time_series_controller_for_octave.Config.MIDI_C4)
  steps_per_octave = float(_time_series_controller_for_octave.Config.STEPS_PER_OCTAVE)

  points_query = [[midi_c4, 1.0], [midi_c4 + 2.0, 1.0], [midi_c4 + 6.0, 1.0]]
  points_db_shifted_down = [[midi_c4 - steps_per_octave, 1.0], [midi_c4 - steps_per_octave + 2.0, 1.0], [midi_c4 - steps_per_octave + 6.0, 1.0]]
  points_db_shifted_up = [[midi_c4 + steps_per_octave, 1.0], [midi_c4 + steps_per_octave + 2.0, 1.0], [midi_c4 + steps_per_octave + 6.0, 1.0]]
  points_db_unrelated_octaves = [[midi_c4 - steps_per_octave, 1.0], [midi_c4, 1.0], [midi_c4 + steps_per_octave, 1.0]]

  normalized_query = _time_series_controller_for_octave._normalize_note_vol_points_for_octave_invariance(points_query)
  normalized_db = _time_series_controller_for_octave._normalize_note_vol_points_for_octave_invariance(points_db_shifted_down)

  @test [pt[1] for pt in normalized_query] == [midi_c4, midi_c4 + 2.0, midi_c4 + 6.0]
  @test [pt[1] for pt in normalized_db] == [midi_c4, midi_c4 + 2.0, midi_c4 + 6.0]

  @test _time_series_controller_for_octave._octave_invariant_note_vol_window_distance01(points_query, points_db_shifted_down, 0, 0, 3) == 0.0
  @test _time_series_controller_for_octave._octave_invariant_note_vol_window_distance01(points_query, points_db_shifted_up, 0, 0, 3) == 0.0
  @test _time_series_controller_for_octave._octave_invariant_note_vol_window_distance01(points_query, points_db_unrelated_octaves, 0, 0, 3) > 0.0

  @test _time_series_controller_for_octave._find_octave_invariant_note_vol_matches(points_query, points_db_shifted_down, 0.0, 3) == Any[Dict("q_start"=>0, "start"=>0, "windowSize"=>3)]
  @test isempty(_time_series_controller_for_octave._find_octave_invariant_note_vol_matches(points_query, points_db_unrelated_octaves, 0.0, 3))
end

@testset "octave invariant octave leaps stay literal" begin
  midi_c4 = float(_time_series_controller_for_octave.Config.MIDI_C4)
  steps_per_octave = float(_time_series_controller_for_octave.Config.STEPS_PER_OCTAVE)
  points_query = [[midi_c4, 0.0], [midi_c4 + steps_per_octave, 0.0]]
  points_db_shifted_down = [[midi_c4 - steps_per_octave, 0.0], [midi_c4, 0.0]]
  points_db_shifted_up = [[midi_c4 + steps_per_octave, 0.0], [midi_c4 + (2.0 * steps_per_octave), 0.0]]
  points_db_flat_pitch_class = [[midi_c4 - steps_per_octave, 0.0], [midi_c4 - steps_per_octave, 0.0]]

  @test _time_series_controller_for_octave._octave_invariant_note_vol_window_distance01(points_query, points_db_shifted_down, 0, 0, 2) == 0.0
  @test _time_series_controller_for_octave._octave_invariant_note_vol_window_distance01(points_query, points_db_shifted_up, 0, 0, 2) == 0.0
  @test _time_series_controller_for_octave._octave_invariant_note_vol_window_distance01(points_query, points_db_flat_pitch_class, 0, 0, 2) > 0.0
end
