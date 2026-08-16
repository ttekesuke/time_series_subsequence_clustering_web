using Test
using Base64
using CodecZlib

const _time_series_controller_for_github_dispatch = Main.TimeseriesClusteringAPI.TimeSeriesController

@testset "GitHub workflow dispatch payload compression" begin
  payload = "{\"series\":[" * join(fill("0.25", 100_000), ",") * "]}"
  encoded = _time_series_controller_for_github_dispatch._gzip_base64encode(payload)
  decoded = String(transcode(GzipDecompressor, base64decode(encoded)))

  @test decoded == payload
  @test length(encoded) < Main.TimeseriesClusteringAPI.Config.GITHUB_WORKFLOW_PARAMS_B64_MAX_CHARS
  @test length(encoded) < ncodeunits(payload)
end
