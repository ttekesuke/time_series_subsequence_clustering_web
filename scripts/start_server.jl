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
println("[start_server] ENV RUN_GENERATE_POLYPHONIC_ON_GITHUB_ACTIONS=$(get(ENV,"RUN_GENERATE_POLYPHONIC_ON_GITHUB_ACTIONS","(none)"))")
flush(stdout)

using Genie
using TimeseriesClusteringAPI
using HTTP
using JSON3

# ここが重要：routes を明示ロード（/api/health 含む）
include(joinpath(pwd(), "routes.jl"))

host = get(ENV, "HOST", get(ENV, "GENIE_HOST", "127.0.0.1"))
port = parse(Int, get(ENV, "PORT", get(ENV, "GENIE_PORT", "9111")))

Genie.config.run_as_server = true
Genie.config.server_host = host
Genie.config.server_port = port

function _bool_env(key::AbstractString, default::Bool)::Bool
  raw = lowercase(strip(get(ENV, key, default ? "true" : "false")))
  raw in ("1", "true", "yes", "y", "on") && return true
  raw in ("0", "false", "no", "n", "off") && return false
  return default
end

function _trim_trailing_slashes(s::AbstractString)::String
  out = String(s)
  while endswith(out, "/")
    out = chop(out)
  end
  return out
end

function _influx_v1_db()::String
  explicit = strip(get(ENV, "INFLUX_V1_DB", ""))
  !isempty(explicit) && return explicit
  db = strip(get(ENV, "INFLUX_DB", ""))
  !isempty(db) && return db
  bucket = strip(get(ENV, "INFLUX_BUCKET", ""))
  !isempty(bucket) && return bucket
  return "timeseries"
end

function _influx_query_headers()
  token = strip(get(ENV, "INFLUX_TOKEN", ""))
  isempty(token) && return Pair{String,String}[]
  return ["Authorization" => "Token $(token)"]
end

function _influx_query(q::AbstractString)
  influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
  query = Dict{String,String}("db" => _influx_v1_db(), "q" => String(q))
  rp = strip(get(ENV, "INFLUX_RP", ""))
  isempty(rp) || (query["rp"] = rp)
  return HTTP.get(
    string(_trim_trailing_slashes(influx_url), "/query"),
    _influx_query_headers();
    query=query,
    status_exception=false,
    readtimeout=10,
  )
end

function _influx_series_count(measurement::AbstractString)::Union{Int,Nothing}
  q = "SHOW TAG VALUES FROM \"$(measurement)\" WITH KEY = \"series_id\""
  resp = _influx_query(q)
  200 <= resp.status < 300 || error("HTTP $(resp.status): $(String(resp.body))")
  parsed = JSON3.read(String(resp.body))
  rows = try
    parsed["results"][1]["series"][1]["values"]
  catch
    return 0
  end
  return length(rows)
end

function _influx_point_count(measurement::AbstractString)::Union{Int,Nothing}
  for field in (get(ENV, "INFLUX_NOTE_FIELD", "note"), get(ENV, "INFLUX_FIELD", "value"))
    q = "SELECT COUNT(\"$(field)\") FROM \"$(measurement)\""
    resp = _influx_query(q)
    200 <= resp.status < 300 || continue
    parsed = try
      JSON3.read(String(resp.body))
    catch
      continue
    end
    val = try
      parsed["results"][1]["series"][1]["values"][1][2]
    catch
      nothing
    end
    val === nothing && continue
    return parse(Int, string(val))
  end
  return nothing
end

function _log_startup_influx_counts()
  measurement = get(ENV, "INFLUX_MEASUREMENT", "timeseries")
  seed_on_start = get(ENV, "SEED_ON_START", "(unset)")
  println("[startup_db] SEED_ON_START=$(seed_on_start) measurement=$(measurement) db=$(_influx_v1_db()) url=$(get(ENV, "INFLUX_URL", "http://influxdb:8086"))")
  flush(stdout)

  last_err = nothing
  for attempt in 1:10
    try
      series_count = _influx_series_count(measurement)
      point_count = _influx_point_count(measurement)
      point_text = point_count === nothing ? "unknown" : string(point_count)
      println("[startup_db] measurement=$(measurement) series_count=$(series_count) point_count=$(point_text)")
      flush(stdout)
      return
    catch err
      last_err = err
      attempt < 10 && sleep(1)
    end
  end
  println("[startup_db] failed to count measurement=$(measurement): $(last_err)")
  flush(stdout)
end

function _warmup_base_url(host::AbstractString, port::Integer)::String
  connect_host = host in ("0.0.0.0", "::", "") ? "127.0.0.1" : host
  return "http://$(connect_host):$(port)"
end

function _load_warmup_actions(path::AbstractString)
  parsed = JSON3.read(read(path, String))
  actions = try
    parsed["actions"]
  catch
    error("warmup config must contain an actions array")
  end
  return actions
end

function _json_get(obj, key::AbstractString, default)
  try
    haskey(obj, key) && return obj[key]
  catch
  end
  return default
end

function _wait_for_warmup_server(base_url::AbstractString)
  max_wait_s = try
    parse(Float64, get(ENV, "STARTUP_WARMUP_READY_TIMEOUT_SECONDS", "180"))
  catch
    180.0
  end

  t0 = time()
  while time() - t0 <= max_wait_s
    try
      resp = HTTP.get(string(base_url, "/api/health"); status_exception=false, readtimeout=5)
      if 200 <= resp.status < 500
        return true
      end
    catch
    end
    sleep(0.5)
  end
  return false
end

function _run_startup_warmup(base_url::AbstractString)
  enabled = _bool_env("STARTUP_WARMUP_ENABLED", true)
  if !enabled
    println("[warmup] skipped: STARTUP_WARMUP_ENABLED=false")
    flush(stdout)
    return
  end

  config_path = get(ENV, "STARTUP_WARMUP_CONFIG", joinpath(pwd(), "config", "warmup_actions.json"))
  if !isfile(config_path)
    println("[warmup] skipped: config not found at $(config_path)")
    flush(stdout)
    return
  end

  delay_s = try
    parse(Float64, get(ENV, "STARTUP_WARMUP_DELAY_SECONDS", "3"))
  catch
    3.0
  end
  delay_s > 0 && sleep(delay_s)
  if !_wait_for_warmup_server(base_url)
    println("[warmup] skipped: server was not ready at $(base_url)")
    flush(stdout)
    return
  end

  actions = try
    _load_warmup_actions(config_path)
  catch err
    println("[warmup] failed to load config: $(err)")
    flush(stdout)
    return
  end

  println("[warmup] starting startup warmup actions=$(length(actions)) config=$(config_path)")
  flush(stdout)

  headers = ["Content-Type" => "application/json", "Accept" => "application/json"]
  for action in actions
    name = string(_json_get(action, "name", "unknown"))
    path = string(_json_get(action, "path", ""))
    payload = _json_get(action, "payload", Dict{String,Any}())
    url = string(base_url, path)
    t0 = time()
    try
      resp = HTTP.post(url, headers, JSON3.write(payload); status_exception=false, readtimeout=300)
      elapsed = round(time() - t0; digits=2)
      if 200 <= resp.status < 300
        println("[warmup] action complete name=$(name) status=$(resp.status) elapsed=$(elapsed)s")
      else
        body = String(resp.body)
        preview = length(body) <= 240 ? body : string(first(body, 240), "...")
        println("[warmup] action failed name=$(name) status=$(resp.status) elapsed=$(elapsed)s body=$(preview)")
      end
    catch err
      elapsed = round(time() - t0; digits=2)
      println("[warmup] action error name=$(name) elapsed=$(elapsed)s error=$(err)")
    end
    flush(stdout)
  end

  println("[warmup] startup warmup complete")
  flush(stdout)
end

println("[start_server] starting on http://$host:$port")
flush(stdout)

_log_startup_influx_counts()

@async _run_startup_warmup(_warmup_base_url(host, port))

Genie.up(port, host; async=false)
