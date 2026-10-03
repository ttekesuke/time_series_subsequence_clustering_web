using Test
using Base64
using Main.TimeseriesClusteringAPI

const VVC = Main.TimeseriesClusteringAPI.VoicevoxClient

@testset "VOICEVOX stem request null lyric handling" begin
  time_series = [[[ [60], 0.8, 0.5, 0.1, 0.8, 0.1, 0.3, 0.6, 0.0, 0.0, 0.0 ]]]
  stream_ids = [[1]]
  voice_plan = [[Dict("streamId" => 1, "mode" => "voice", "text" => nothing)]]
  requests, voice_keys = VVC.build_stem_requests(time_series, stream_ids, voice_plan, [0.125])
  @test isempty(requests)
  @test isempty(voice_keys)
end

@testset "VOICEVOX partial stem failure removes files already written" begin
  requests = [Dict("stream_id" => id, "controls" => Any[]) for id in (1, 2)]
  first = Dict("stream_id" => 1, "audio_base64" => base64encode("RIFF"))
  mktempdir() do output_dir
    complete = Dict("stems" => [first, Dict("stream_id" => 2,
      "audio_base64" => base64encode("WAVE"))])
    stems = VVC._decode_stems(complete, requests; output_dir=output_dir)
    @test length(stems) == 2
    @test read(stems[1]["path"], String) == "RIFF"
    VVC.cleanup_stems!(stems)
    @test isempty(readdir(output_dir))

    for result in (
      Dict("stems" => [first, Dict("stream_id" => 2, "audio_base64" => "!")]),
      Dict("stems" => [first]),
    )
      @test_throws Exception VVC._decode_stems(result, requests; output_dir=output_dir)
      @test isempty(readdir(output_dir))
    end
  end
end
