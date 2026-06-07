using HTTP, JSON3

function env_required(key)
  value = strip(get(ENV, key, ""))
  isempty(value) && error("$(key) is required")
  return value
end

function env_optional(key, default="")
  return strip(get(ENV, key, default))
end

function trim_trailing_slashes(s)
  out = String(s)
  while endswith(out, "/")
    out = chop(out)
  end
  return out
end

function org_query()
  org_id = env_optional("INFLUX_ORG_ID")
  !isempty(org_id) && return Dict("orgID" => org_id)

  org = env_optional("INFLUX_ORG")
  !isempty(org) && return Dict("org" => org)

  return Dict{String,String}()
end

function body_preview(body)
  s = replace(strip(String(body)), '\n' => ' ')
  length(s) <= 240 && return s
  return string(first(s, 240), "...")
end

function bucket_id(influx_url, token, bucket)
  explicit = env_optional("INFLUX_BUCKET_ID")
  !isempty(explicit) && return explicit

  url = string(trim_trailing_slashes(influx_url), "/api/v2/buckets")
  query = merge(Dict("name" => bucket), org_query())
  headers = [
    "Authorization" => "Token $(token)",
    "Accept" => "application/json",
  ]
  resp = HTTP.get(url, headers; query=query, status_exception=false)
  if !(200 <= resp.status < 300)
    error("Bucket lookup failed with HTTP $(resp.status): $(body_preview(String(resp.body)))")
  end

  parsed = JSON3.read(String(resp.body))
  for b in parsed["buckets"]
    if string(b["name"]) == bucket
      return string(b["id"])
    end
  end

  error("Bucket '$(bucket)' was not found")
end

function ensure_dbrp()
  influx_url = env_required("INFLUX_URL")
  token = env_required("INFLUX_TOKEN")
  bucket = env_required("INFLUX_BUCKET")
  db = env_optional("INFLUX_DB", bucket)
  rp = env_optional("INFLUX_RP", "autogen")
  bid = bucket_id(influx_url, token, bucket)

  url = string(trim_trailing_slashes(influx_url), "/api/v2/dbrps")
  body = Dict{String,Any}(
    "bucketID" => bid,
    "database" => db,
    "retention_policy" => rp,
    "default" => true,
  )
  for (k, v) in org_query()
    body[k] = v
  end

  headers = [
    "Authorization" => "Token $(token)",
    "Content-Type" => "application/json",
    "Accept" => "application/json",
  ]
  resp = HTTP.post(url, headers, JSON3.write(body); status_exception=false)
  if resp.status in (200, 201)
    println("DBRP mapping created: db=$(db), rp=$(rp), bucket=$(bucket), bucketID=$(bid)")
    return
  end
  if resp.status == 422 && occursin("already", lowercase(String(resp.body)))
    println("DBRP mapping already exists: db=$(db), rp=$(rp), bucket=$(bucket), bucketID=$(bid)")
    return
  end

  error("DBRP mapping creation failed with HTTP $(resp.status): $(body_preview(String(resp.body)))")
end

ensure_dbrp()
