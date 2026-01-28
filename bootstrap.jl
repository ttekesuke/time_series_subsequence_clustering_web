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

# NOTE: Genie.loadapp() がこのファイルを読む。ここでサーバ起動すると再帰/ハングするので絶対に起動しない。
using TimeseriesClusteringAPI
