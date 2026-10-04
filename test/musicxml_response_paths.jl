if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

using Test

const _musicxml_response_tc = Main.TimeseriesClusteringAPI.TimeSeriesController

@testset "MusicXML response dataset paths" begin
  mktempdir() do dir
    previous = get(ENV, "ASAP_DATASET_DIR", nothing)
    ENV["ASAP_DATASET_DIR"] = dir
    try
      @test _musicxml_response_tc._xml_file_path(
        "Bach",
        "Prelude",
        "../score.musicxml",
      ) == normpath(joinpath(dir, "Bach", "Prelude", "score.musicxml"))

      @test _musicxml_response_tc._xml_file_path(
        "Bach",
        "Bach/Prelude",
        "score.musicxml",
      ) == normpath(joinpath(dir, "Bach", "Prelude", "score.musicxml"))

      @test _musicxml_response_tc._xml_file_path(
        "../Bach",
        "../Prelude",
        "nested/score.musicxml",
      ) == normpath(joinpath(dir, "Bach", "Prelude", "score.musicxml"))
    finally
      if previous === nothing
        pop!(ENV, "ASAP_DATASET_DIR", nothing)
      else
        ENV["ASAP_DATASET_DIR"] = previous
      end
    end
  end
end
