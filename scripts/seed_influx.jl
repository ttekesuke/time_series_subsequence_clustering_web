using HTTP, JSON3, Dates

influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
influx_db = get(ENV, "INFLUX_DB", "telegraf")
measurement = get(ENV, "INFLUX_MEASUREMENT", "timeseries")
num_series = parse(Int, get(ENV, "SEED_SERIES", "100"))
series_len = parse(Int, get(ENV, "SEED_LENGTH", "100"))
minv = parse(Int, get(ENV, "SEED_MIN", "0"))
maxv = parse(Int, get(ENV, "SEED_MAX", "11"))

function ping_influx(url)
  try
    resp = HTTP.request("GET", string(url, "/ping"))
    return resp.status == 204
  catch
    return false
  end
end

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
    resp = HTTP.post(string(influx_url, "/write"), [], body; query=Dict("db"=>influx_db, "precision"=>"s"))
    println("Wrote series ", sid, " -> status ", resp.status)
  catch e
    println("Write failed for series ", sid, ": ", e)
  end
end

println("Seeding complete")
