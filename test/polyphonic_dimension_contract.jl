using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _dimension_contract_tc = Main.TimeseriesClusteringAPI.TimeSeriesController
const _dimension_contract_config = Main.TimeseriesClusteringAPI.Config

@testset "polyphonic dimension contract" begin
  contract = _dimension_contract_tc._POLYPHONIC_DIMENSION_CONTRACT
  expected = Set([
    "area", "chord_range", "density", "vol", "brightness",
    "noise", "harmonicity", "attack", "decay_sustain", "release",
  ])
  @test Set(keys(contract)) == expected
  @test isfile(_dimension_contract_tc._POLYPHONIC_DIMENSION_CONTRACT_PATH)

  for key in expected
    entry = contract[key]
    minimum = float(entry["min"])
    maximum = float(entry["max"])
    step = float(entry["step"])
    ui_default = float(entry["ui_default_fixed_value"])
    server_default = float(entry["server_default_fixed_value"])

    @test minimum <= maximum
    @test step > 0
    @test minimum <= ui_default <= maximum
    @test minimum <= server_default <= maximum
    @test entry["is_int"] isa Bool
    @test entry["ui_default_use_fixed_value"] isa Bool
    @test entry["server_default_accept_params"] isa Bool
  end

  chord = contract["chord_range"]
  @test Int(chord["min"]) == _dimension_contract_config.CHORD_RANGE_VALUE_MIN
  @test Int(chord["max"]) == _dimension_contract_config.CHORD_RANGE_VALUE_MAX
end
