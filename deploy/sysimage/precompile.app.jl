# deploy/sysimage/precompile_app.jl
# ここで「よく叩く処理」を一回だけ実行してコンパイルさせる

using TimeseriesClusteringAPI

# Genie起動はしない（あくまで関数呼び出しでコンパイルさせる）
# generate_polyphonic は Requests payload が無くてもデフォルト値で動く実装なので
# ここで1回動かしておくとかなり効きます
try
  TimeseriesClusteringAPI.TimeSeriesController.generate_polyphonic()
catch err
  # precompile段階では例外が出てもビルドを止めたくないので握りつぶす
  @warn "precompile_app generate_polyphonic failed (ignored)" err
end

# analyse は空入力だと落ちる可能性があるので基本やらない（必要なら後で足す）
