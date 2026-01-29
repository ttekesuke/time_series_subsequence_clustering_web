# scripts/start_server.jl
cd(joinpath(@__DIR__, ".."))  # repo root

# --- local .env loader (optional) ---
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

_load_dotenv(joinpath(pwd(), ".env"))

println("[start_server] ENV HOST=$(get(ENV,"HOST","(none)")) PORT=$(get(ENV,"PORT","(none)")) GENIE_HOST=$(get(ENV,"GENIE_HOST","(none)")) GENIE_PORT=$(get(ENV,"GENIE_PORT","(none)")) GENIE_ENV=$(get(ENV,"GENIE_ENV","(none)"))")
flush(stdout)

using Genie
using TimeseriesClusteringAPI

# ここが重要：routes を明示ロード（/api/health 含む）
include(joinpath(pwd(), "routes.jl"))

host = get(ENV, "HOST", get(ENV, "GENIE_HOST", "127.0.0.1"))
port = parse(Int, get(ENV, "PORT", get(ENV, "GENIE_PORT", "9111")))

Genie.config.run_as_server = true
Genie.config.server_host = host
Genie.config.server_port = port

println("[start_server] starting on http://$host:$port")
flush(stdout)

Genie.up(port, host; async=false)
