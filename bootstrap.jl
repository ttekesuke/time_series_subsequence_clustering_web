# bootstrap.jl

# --- local .env loader (kept out of git) ---
function _load_dotenv(path::AbstractString)
  isfile(path) || return
  for rawline in eachline(path)
    line = strip(rawline)
    isempty(line) && continue
    startswith(line, "#") && continue
    # allow: export KEY=VALUE
    if startswith(lowercase(line), "export ")
      line = strip(line[8:end])
    end
    occursin("=", line) || continue
    k, v = split(line, "=", limit=2)
    key = strip(k)
    val = strip(v)
    # strip surrounding quotes
    if (startswith(val, "\"") && endswith(val, "\"")) || (startswith(val, "'") && endswith(val, "'"))
      val = val[2:end-1]
    end
    isempty(key) && continue
    haskey(ENV, key) || (ENV[key] = val)
  end
end

_load_dotenv(joinpath(@__DIR__, ".env"))

(pwd() != @__DIR__) && cd(@__DIR__) # allow starting app from bin/ dir

# --- IMPORTANT: Start Genie server in blocking mode ---
using Genie

# アプリのルーティング等を読み込む（サーバはまだ起動しない）
Genie.loadapp(".", autostart=false)

# あなたのモジュールもロード（コントローラ等の定義が確実に入る）
using TimeseriesClusteringAPI

# PORT/HOST を確実に反映（Actions では PORT=9111 を渡すのを推奨）
host = get(ENV, "HOST", "127.0.0.1")
port = parse(Int, get(ENV, "PORT", get(ENV, "GENIE_PORT", "8000")))

Genie.config.server_host = host
Genie.config.server_port = port

# ここが肝：スクリプトが終わって落ちないようにブロッキング起動
Genie.config.run_as_server = true
Genie.up(port, host; async=false)
