using HTTP, JSON3, Dates

influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
influx_db = get(ENV, "INFLUX_DB", "telegraf")
influx_bucket = get(ENV, "INFLUX_BUCKET", "")
influx_token = get(ENV, "INFLUX_TOKEN", "")
measurement = get(ENV, "INFLUX_MEASUREMENT", "timeseries")
num_series = parse(Int, get(ENV, "SEED_SERIES", "100"))
series_len = parse(Int, get(ENV, "SEED_LENGTH", "100"))
minv = parse(Int, get(ENV, "SEED_MIN", "0"))
maxv = parse(Int, get(ENV, "SEED_MAX", "11"))

influx_v2_enabled() = !isempty(strip(influx_token)) || !isempty(strip(influx_bucket))

function ping_influx(url)
  try
    resp = HTTP.request("GET", string(url, "/ping"))
    return resp.status == 204
  catch
    return false
  end
end

if influx_v2_enabled()
  isempty(strip(influx_bucket)) && error("INFLUX_BUCKET is required for InfluxDB Cloud/v2")
  isempty(strip(influx_token)) && error("INFLUX_TOKEN is required for InfluxDB Cloud/v2")
  println("Using InfluxDB Cloud/v2 bucket: ", influx_bucket)
else
  println("Waiting for InfluxDB at ", influx_url)
  for i in 1:60
    if ping_influx(influx_url)
      println("InfluxDB is up")
      break
    end
    sleep(1)
  end

  # create db
  try
    q = "CREATE DATABASE \"$(influx_db)\""
    r = HTTP.get(string(influx_url, "/query"), query=Dict("q"=>q))
    println("Created DB (or already exists): ", influx_db)
  catch e
    println("DB create failed: ", e)
  end
end

function influx_v2_org_query()
  org_id = strip(get(ENV, "INFLUX_ORG_ID", ""))
  !isempty(org_id) && return Dict("orgID" => org_id)
  org = strip(get(ENV, "INFLUX_ORG", ""))
  !isempty(org) && return Dict("org" => org)
  return Dict{String,String}()
end

function write_influx(body)
  if influx_v2_enabled()
    url = string(strip_trailing_slashes(influx_url), "/api/v2/write")
    query = merge(Dict("bucket" => influx_bucket, "precision" => "s"), influx_v2_org_query())
    headers = [
      "Authorization" => "Token $(influx_token)",
      "Content-Type" => "text/plain; charset=utf-8",
    ]
    return HTTP.post(url, headers, body; query=query)
  else
    return HTTP.post(string(influx_url, "/write"), [], body; query=Dict("db"=>influx_db, "precision"=>"s"))
  end
end

function strip_trailing_slashes(s)
  out = String(s)
  while endswith(out, "/")
    out = chop(out)
  end
  return out
end

# seed data in line protocol.
# InfluxDB overwrites points with the same measurement + tag set + timestamp.
# Give every point in a series a deterministic unique timestamp.
for sid in 0:(num_series-1)
  buf = IOBuffer()
  for t in 1:series_len
    v = rand(minv:maxv)
    timestamp_s = sid * series_len + (t - 1)
    # line protocol: measurement,series_id=SID value=V
    println(buf, "$(measurement),series_id=$(sid) value=$(v) $(timestamp_s)")
  end
  body = String(take!(buf))
  try
    resp = write_influx(body)
    println("Wrote series ", sid, " -> status ", resp.status)
  catch e
    println("Write failed for series ", sid, ": ", e)
  end
end

println("Seeding complete")
