function _influx_query_get(influx_url, influx_db, q::AbstractString; extra_query=Dict{String,String}())
  url = string(_trim_trailing_slashes(influx_url), "/query")
  query = Dict{String,String}(
    "db" => _influx_query_database(influx_db),
    "q" => String(q),
  )
  for (k, v) in extra_query
    query[string(k)] = string(v)
  end

  rp = strip(string(get(ENV, "INFLUX_RP", "")))
  isempty(rp) || (query["rp"] = rp)

  if _influx_cloud_enabled()
    return _influx_query_get_cloud(url, query)
  end

  return HTTP.get(url, _influx_query_headers(); query=query)
end

function _influx_query_headers()::Vector{Pair{String,String}}
  if !_influx_cloud_enabled()
    return Pair{String,String}[]
  end

  return [
    "Authorization" => "Token $(_influx_v2_token())",
    "Accept" => "application/json",
  ]
end

function _influx_query_get_cloud(url::AbstractString, base_query::Dict{String,String}; allow_dbrp_create::Bool=true)
  last_status = 0
  last_body = ""
  last_failure_reason = ""

  for scheme in _influx_v1_auth_schemes()
    query = copy(base_query)
    headers = _influx_v1_auth_headers(scheme)

    if scheme == "query"
      query["u"] = string(get(ENV, "INFLUX_V1_USER", "any"))
      query["p"] = _influx_v2_token()
    end

    _influx_log("v1 query attempt", merge(_influx_query_summary(query), Dict("authScheme" => scheme)))
    resp = HTTP.get(url, headers; query=query, status_exception=false)
    body = String(resp.body)
    _influx_log("v1 query response", merge(_influx_query_summary(query), Dict(
      "authScheme" => scheme,
      "status" => resp.status,
      "bodyBytes" => sizeof(body),
      "bodyPreview" => _body_preview(body),
    )))
    if 200 <= resp.status < 300
      if _influx_query_body_looks_json(body)
        if _is_influx_database_not_found(body)
          last_status = resp.status
          last_body = body
          last_failure_reason = "InfluxQL database not found"
          _influx_log("v1 query response requires DBRP mapping", Dict(
            "authScheme" => scheme,
            "status" => resp.status,
            "bodyBytes" => sizeof(body),
            "bodyPreview" => _body_preview(body),
          ))
          break
        end
        return _cached_influx_response(resp.status, body)
      end
      last_status = resp.status
      last_body = body
      last_failure_reason = "2xx response did not contain a JSON /query body"
      _influx_log("v1 query response ignored", Dict(
        "authScheme" => scheme,
        "reason" => "2xx response did not contain a JSON /query body",
        "status" => resp.status,
        "bodyBytes" => sizeof(body),
      ))
      continue
    end

    last_status = resp.status
    last_body = body
    last_failure_reason = "HTTP $(resp.status)"
    if !(resp.status in (401, 403))
      break
    end
  end

  if _is_influx_database_not_found(last_body)
    db = get(base_query, "db", _influx_v2_bucket())
    rp = get(base_query, "rp", _influx_default_rp())
    if allow_dbrp_create && _should_auto_create_dbrp()
      _influx_log("DBRP mapping missing; attempting create", Dict("db" => db, "rp" => rp, "bucket" => _influx_v2_bucket()))
      if _ensure_cloud_dbrp_mapping(db, rp)
        query_with_rp = copy(base_query)
        query_with_rp["rp"] = rp
        return _influx_query_get_cloud(url, query_with_rp; allow_dbrp_create=false)
      end
    end
    error(_missing_dbrp_message(db, rp))
  end

  error("Influx /query failed with HTTP $(last_status) ($(last_failure_reason), bodyBytes=$(sizeof(last_body))): $(_body_preview(last_body))")
end

function _cached_influx_response(status::Integer, body::AbstractString)
  return (
    status = Int(status),
    body = Vector{UInt8}(codeunits(String(body))),
  )
end

function _influx_v1_auth_schemes()::Vector{String}
  raw = lowercase(strip(string(get(ENV, "INFLUX_V1_AUTH_SCHEME", ""))))
  if !isempty(raw)
    return [strip(s) for s in split(raw, ",") if !isempty(strip(s))]
  end
  return ["query", "basic", "token", "bearer"]
end

function _influx_v1_auth_headers(scheme::AbstractString)::Vector{Pair{String,String}}
  headers = Pair{String,String}["Accept" => "application/json"]
  token = _influx_v2_token()
  if scheme == "token"
    push!(headers, "Authorization" => "Token $(token)")
  elseif scheme == "basic"
    user = string(get(ENV, "INFLUX_V1_USER", "any"))
    push!(headers, "Authorization" => "Basic $(base64encode("$(user):$(token)"))")
  elseif scheme == "bearer"
    push!(headers, "Authorization" => "Bearer $(token)")
  end
  return headers
end
