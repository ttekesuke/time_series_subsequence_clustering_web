function _should_auto_create_dbrp()::Bool
  return _parse_bool(get(ENV, "INFLUX_AUTO_CREATE_DBRP", "false"), false)
end

function _is_influx_database_not_found(body::AbstractString)::Bool
  return occursin("database not found", lowercase(String(body)))
end

function _influx_default_rp()::String
  rp = strip(string(get(ENV, "INFLUX_RP", "")))
  isempty(rp) && return "autogen"
  return rp
end

function _missing_dbrp_message(db::AbstractString, rp::AbstractString)::String
  return string(
    "InfluxDB Cloud DBRP mapping is missing for db='", db, "', rp='", rp, "'. ",
    "Create a one-time mapping from that DB/RP pair to bucket='", _influx_v2_bucket(), "' ",
    "or run scripts/ensure_influx_dbrp.jl with INFLUX_URL, INFLUX_TOKEN, INFLUX_BUCKET, INFLUX_ORG_ID, INFLUX_DB, and INFLUX_RP set. ",
    "Set INFLUX_AUTO_CREATE_DBRP=true only if the app token is allowed to manage DBRP mappings."
  )
end

function _ensure_cloud_dbrp_mapping(database::AbstractString, rp::AbstractString)::Bool
  bucket_id = _influx_bucket_id()
  isempty(bucket_id) && error("Influx DBRP mapping cannot be created because bucket id was not found for bucket '$(_influx_v2_bucket())'")

  url = string(_trim_trailing_slashes(string(get(ENV, "INFLUX_URL", ""))), "/api/v2/dbrps")
  org_query = _influx_v2_org_query()
  body = Dict{String,Any}(
    "bucketID" => bucket_id,
    "database" => String(database),
    "retention_policy" => String(rp),
    "default" => true,
  )
  for (k, v) in org_query
    body[k] = v
  end
  body_json = JSON3.write(body)

  headers = [
    "Authorization" => "Token $(_influx_v2_token())",
    "Content-Type" => "application/json",
    "Accept" => "application/json",
  ]
  _influx_log("DBRP mapping create attempt", Dict(
    "db" => String(database),
    "rp" => String(rp),
    "bucketID" => bucket_id,
    "orgKeys" => collect(keys(org_query)),
  ))
  resp = try
    HTTP.post(url, headers, body_json; status_exception=false)
  catch e
    error("Influx DBRP mapping creation request failed before response: $(e)")
  end
  _influx_log("DBRP mapping create response", Dict(
    "db" => String(database),
    "rp" => String(rp),
    "status" => resp.status,
    "bodyPreview" => _body_preview(String(resp.body)),
  ))
  if resp.status in (200, 201)
    return true
  end
  if resp.status == 422 && occursin("already", lowercase(String(resp.body)))
    return true
  end
  error("Influx DBRP mapping creation failed with HTTP $(resp.status): $(_body_preview(String(resp.body)))")
end

function _influx_bucket_id()::String
  explicit = strip(string(get(ENV, "INFLUX_BUCKET_ID", "")))
  isempty(explicit) || return explicit

  url = string(_trim_trailing_slashes(string(get(ENV, "INFLUX_URL", ""))), "/api/v2/buckets")
  query = merge(Dict("name" => _influx_v2_bucket()), _influx_v2_org_query())
  headers = [
    "Authorization" => "Token $(_influx_v2_token())",
    "Accept" => "application/json",
  ]
  resp = HTTP.get(url, headers; query=query, status_exception=false)
  bucket_body = String(resp.body)
  _influx_log("bucket lookup response", Dict(
    "bucket" => _influx_v2_bucket(),
    "status" => resp.status,
    "bodyBytes" => sizeof(bucket_body),
    "bodyPreview" => _body_preview(bucket_body),
  ))
  if !(200 <= resp.status < 300)
    error("Influx bucket lookup failed with HTTP $(resp.status): $(_body_preview(bucket_body))")
  end

  parsed = try
    JSON3.read(bucket_body)
  catch e
    fallback_id = _bucket_id_from_lookup_body(bucket_body, _influx_v2_bucket())
    if !isempty(fallback_id)
      _influx_log("bucket lookup JSON parse failed; using fallback bucket id", Dict(
        "bucket" => _influx_v2_bucket(),
        "bucketID" => fallback_id,
        "error" => string(e),
      ))
      return fallback_id
    end
    error("Influx bucket lookup returned unparsable JSON: $(e) bodyBytes=$(sizeof(bucket_body)) preview=$(_body_preview(bucket_body))")
  end
  try
    buckets = parsed["buckets"]
    for b in buckets
      if string(b["name"]) == _influx_v2_bucket()
        bucket_id = string(b["id"])
        _influx_log("bucket lookup matched bucket", Dict("bucket" => _influx_v2_bucket(), "bucketID" => bucket_id))
        return bucket_id
      end
    end
  catch
  end
  return ""
end

function _bucket_id_from_lookup_body(body::AbstractString, bucket_name::AbstractString)::String
  s = String(body)
  name_pattern = Regex("\"name\"\\s*:\\s*\"" * _regex_escape_literal(String(bucket_name)) * "\"")
  name_match = match(name_pattern, s)
  name_match === nothing && return ""

  before_name = s[1:name_match.offset]
  id_matches = collect(eachmatch(Regex("\"id\"\\s*:\\s*\"([^\"]+)\""), before_name))
  isempty(id_matches) && return ""
  return String(id_matches[end].captures[1])
end

function _regex_escape_literal(s::AbstractString)::String
  out = IOBuffer()
  specials = Set(['\\', '"', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}'])
  for c in String(s)
    if c in specials
      print(out, '\\')
    end
    print(out, c)
  end
  return String(take!(out))
end
