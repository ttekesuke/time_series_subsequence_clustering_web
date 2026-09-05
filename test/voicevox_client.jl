using Test
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

