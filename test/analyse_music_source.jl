if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

using Test

const _analyse_source_tc = Main.TimeseriesClusteringAPI.TimeSeriesController
const _analyse_source_music = Main.TimeseriesClusteringAPI.MusicAnalysis

@testset "MusicAnalyse source preparation" begin
  @test _analyse_source_tc._safe_asap_relative_path("Bach/Fugue/music_score.musicxml") ==
    "Bach/Fugue/music_score.musicxml"

  for invalid in ("", "/absolute.musicxml", "../escape.musicxml", "Bach/../escape.musicxml")
    err = try
      _analyse_source_tc._safe_asap_relative_path(invalid)
      nothing
    catch caught
      caught
    end
    @test err isa _analyse_source_music.RequestError
    @test err.code == "invalid_asap_path"
  end

  mktempdir() do dir
    previous = get(ENV, "ASAP_DATASET_DIR", nothing)
    ENV["ASAP_DATASET_DIR"] = dir
    try
      @test _analyse_source_tc._analyse_music_dataset_dir() == normpath(dir)
    finally
      if previous === nothing
        delete!(ENV, "ASAP_DATASET_DIR")
      else
        ENV["ASAP_DATASET_DIR"] = previous
      end
    end
  end

  upload = _analyse_source_tc._prepare_analyse_music_params(Dict(
    "source_type" => "upload",
    "filename" => "fixture.musicxml",
    "musicxml_text" => "<score-partwise version=\"4.0\"/>",
  ))
  @test upload["source_type"] == "upload"
  @test upload["filename"] == "fixture.musicxml"
  @test occursin("score-partwise", upload["musicxml_text"])

  invalid_upload = try
    _analyse_source_tc._prepare_analyse_music_params(Dict(
      "source_type" => "upload",
      "filename" => "fixture.mxl",
      "musicxml_text" => "ignored",
    ))
    nothing
  catch caught
    caught
  end
  @test invalid_upload isa _analyse_source_music.RequestError
  @test invalid_upload.code == "unsupported_file_type"
end
