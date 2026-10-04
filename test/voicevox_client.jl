using Test
using Base64
using HTTP
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


@testset "VOICEVOX binary stem transfer writes and cleans files" begin
  requests = [
    Dict("stream_id" => 1, "controls" => Any[]),
    Dict("stream_id" => 2, "controls" => Any[]),
  ]

  mktempdir() do output_dir
    calls = Ref(0)
    seen_urls = String[]
    success_post = function (url, headers, body; kwargs...)
      calls[] += 1
      push!(seen_urls, String(url))
      stream_id = calls[]
      return HTTP.Response(
        200,
        [
          "Content-Type" => "audio/wav",
          "X-Voicevox-Stream-Id" => string(stream_id),
          "X-Voicevox-Backend" => "fake-binary",
        ],
        Vector{UInt8}(codeunits(stream_id == 1 ? "RIFF" : "WAVE")),
      )
    end

    stems = VVC.render_stems(
      requests;
      worker_url="http://voicevox.test",
      output_dir=output_dir,
      post_fn=success_post,
    )
    @test length(stems) == 2
    @test all(endswith(url, "/render-stem") for url in seen_urls)
    @test read(stems[1]["path"], String) == "RIFF"
    @test read(stems[2]["path"], String) == "WAVE"
    @test all(stem["backend"] == "fake-binary" for stem in stems)
    VVC.cleanup_stems!(stems)
    @test isempty(readdir(output_dir))

    calls[] = 0
    failing_post = function (url, headers, body; kwargs...)
      calls[] += 1
      if calls[] == 1
        return HTTP.Response(
          200,
          [
            "Content-Type" => "audio/wav",
            "X-Voicevox-Stream-Id" => "1",
            "X-Voicevox-Backend" => "fake-binary",
          ],
          Vector{UInt8}(codeunits("RIFF")),
        )
      end
      return HTTP.Response(
        500,
        ["Content-Type" => "application/json"],
        Vector{UInt8}(codeunits("{\"error\":\"engine failed\"}")),
      )
    end

    @test_throws Exception VVC.render_stems(
      requests;
      worker_url="http://voicevox.test",
      output_dir=output_dir,
      post_fn=failing_post,
    )
    @test isempty(readdir(output_dir))
  end
end
