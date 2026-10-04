if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

using Test

const _polyphonic_generation_tc = Main.TimeseriesClusteringAPI.TimeSeriesController

@testset "polyphonic generation resource paths" begin
  inventory_dir = _polyphonic_generation_tc._voice_inventory_dir()
  @test isdir(inventory_dir)
  @test isfile(joinpath(inventory_dir, "ja_voicevox_all.json"))
end
