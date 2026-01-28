# bootstrap.jl

# --- local .env loader (kept out of git) ---
function _load_dotenv(path::AbstractString)
  isfile(path) || return
  for rawline in eachline(path)
    line = strip(rawline)
    isempty(line) && continue
    startswith(line, "#") && continue
    if startswith(lowercase(line), "export ")
      line = strip(line[8:end])
    end
    occursin("=", line) || continue
    k, v = split(line, "=", limit=2)
    key = strip(k)
    val = strip(v)
    if (startswith(val, "\"") && endswith(val, "\"")) || (startswith(val, "'") && endswith(val, "'"))
      val = val[2:end-1]
    end
    isempty(key) && continue
    haskey(ENV, key) || (ENV[key] = val)
  end
end

_load_dotenv(joinpath(@__DIR__, ".env"))
(pwd() != @__DIR__) && cd(@__DIR__)

# ★ここで必ずログを出す（Actionsで server.log が空になるのを防ぐ）
println("[bootstrap] starting"); flush(stdout)
println("[bootstrap] HOST=$(get(ENV,"HOST","(none)")) PORT=$(get(ENV,"PORT","(none)")) GENIE_PORT=$(get(ENV,"GENIE_PORT","(none)")) GENIE_ENV=$(get(ENV,"GENIE_ENV","(none)"))"); flush(stdout)

using Genie

# アプリ読み込み（起動しない）
Genie.loadapp(".", autostart=false)

# コントローラ定義等の確実なロード
using TimeseriesClusteringAPI

host = get(ENV, "HOST", "127.0.0.1")
port = parse(Int, get(ENV, "PORT", get(ENV, "GENIE_PORT", "8000")))

Genie.config.server_host = host
Genie.config.server_port = port
Genie.config.run_as_server = true

println("[bootstrap] launching server on http://$host:$port"); flush(stdout)

# ブロッキング起動（これでプロセスが落ちない）
Genie.up(port, host; async=false)
