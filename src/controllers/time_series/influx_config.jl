function _env_present(key::AbstractString)::Bool
  return !isempty(strip(string(get(ENV, key, ""))))
end

function _influx_cloud_enabled()::Bool
  return _env_present("INFLUX_TOKEN") || _env_present("INFLUX_BUCKET")
end

function _influx_flux_enabled()::Bool
  return lowercase(strip(string(get(ENV, "INFLUX_QUERY_MODE", "")))) == "flux"
end

function _influx_sql_enabled()::Bool
  return lowercase(strip(string(get(ENV, "INFLUX_QUERY_MODE", "")))) == "sql"
end

function _influx_query_mode()::String
  mode = lowercase(strip(string(get(ENV, "INFLUX_QUERY_MODE", ""))))
  isempty(mode) && return "influxql"
  return mode
end

function _influx_v2_bucket()::String
  bucket = strip(string(get(ENV, "INFLUX_BUCKET", "")))
  isempty(bucket) && error("INFLUX_BUCKET is required for InfluxDB Cloud/v2")
  return bucket
end

function _influx_v2_token()::String
  token = strip(string(get(ENV, "INFLUX_TOKEN", "")))
  isempty(token) && error("INFLUX_TOKEN is required for InfluxDB Cloud/v2")
  return token
end

function _influx_v1_database(influx_db)::String
  explicit = strip(string(get(ENV, "INFLUX_V1_DB", "")))
  !isempty(explicit) && return explicit

  if _env_present("INFLUX_DB")
    return strip(string(get(ENV, "INFLUX_DB", "")))
  end

  return _influx_v2_bucket()
end

function _influx_query_database(influx_db)::String
  if _influx_cloud_enabled()
    return _influx_v1_database(influx_db)
  end
  return string(influx_db)
end
