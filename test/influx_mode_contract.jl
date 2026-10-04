using Test
using JSON3

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _influx_mode_tc = Main.TimeseriesClusteringAPI.TimeSeriesController

function _with_env_pair(key::String, value, f::Function)
  previous = get(ENV, key, nothing)
  try
    if value === nothing
      pop!(ENV, key, nothing)
    else
      ENV[key] = String(value)
    end
    return f()
  finally
    if previous === nothing
      pop!(ENV, key, nothing)
    else
      ENV[key] = previous
    end
  end
end

function _stats_from_influxql(body::String)
  parsed = JSON3.read(body)
  series = _influx_mode_tc._influx_series_list(parsed, body, "fixture")
  series === nothing && return Tuple{String,Int}[]
  return [
    (
      string(item["tags"]["series_id"]),
      Int(item["values"][1][2]),
    )
    for item in series
  ]
end

function _stats_from_sql(body::String)
  return [
    (
      string(row["series_id"]),
      Int(row["count"]),
    )
    for row in _influx_mode_tc._parse_jsonl_rows(body)
  ]
end

function _stats_from_flux(body::String)
  return [
    (
      row["series_id"],
      parse(Int, row["_value"]),
    )
    for row in _influx_mode_tc._influx_csv_rows(body)
  ]
end

function _group_scalar_pairs(pairs)
  grouped = Dict{String,Vector{Float64}}()
  for (sid, value) in pairs
    push!(get!(grouped, String(sid), Float64[]), Float64(value))
  end
  return grouped
end

function _scalar_from_influxql(body::String)
  parsed = JSON3.read(body)
  series = parsed["results"][1]["series"]
  pairs = Tuple{String,Float64}[]
  for item in series
    sid = string(item["tags"]["series_id"])
    for row in item["values"]
      push!(pairs, (sid, Float64(row[2])))
    end
  end
  return _group_scalar_pairs(pairs)
end

function _scalar_from_sql(body::String)
  return _group_scalar_pairs([
    (string(row["series_id"]), Float64(row["value"]))
    for row in _influx_mode_tc._parse_jsonl_rows(body)
  ])
end

function _scalar_from_flux(body::String)
  return _group_scalar_pairs([
    (row["series_id"], parse(Float64, row["_value"]))
    for row in _influx_mode_tc._influx_csv_rows(body)
  ])
end

function _group_note_vol(pairs)
  grouped = Dict{String,Vector{Vector{Float64}}}()
  for (sid, note, vol) in pairs
    push!(
      get!(grouped, String(sid), Vector{Vector{Float64}}()),
      Float64[note, vol],
    )
  end
  return grouped
end

function _note_vol_from_influxql(body::String)
  parsed = JSON3.read(body)
  pairs = Tuple{String,Float64,Float64}[]
  for item in parsed["results"][1]["series"]
    sid = string(item["tags"]["series_id"])
    columns = [string(value) for value in item["columns"]]
    note_idx = findfirst(==("note"), columns)
    vol_idx = findfirst(==("vol"), columns)
    note_idx === nothing && continue
    for row in item["values"]
      note = Float64(row[note_idx])
      vol = vol_idx === nothing ? 0.0 : Float64(row[vol_idx])
      push!(pairs, (sid, note, vol))
    end
  end
  return _group_note_vol(pairs)
end

function _note_vol_from_sql(body::String)
  return _group_note_vol([
    (
      string(row["series_id"]),
      Float64(row["note"]),
      Float64(row["vol"]),
    )
    for row in _influx_mode_tc._parse_jsonl_rows(body)
  ])
end

function _note_vol_from_flux(body::String)
  return _group_note_vol([
    (
      row["series_id"],
      parse(Float64, row["note"]),
      parse(Float64, row["vol"]),
    )
    for row in _influx_mode_tc._influx_csv_rows(body)
  ])
end

@testset "Influx query mode contract" begin
  _with_env_pair("INFLUX_QUERY_MODE", nothing) do
    @test _influx_mode_tc._influx_query_mode() == "influxql"
    @test !_influx_mode_tc._influx_sql_enabled()
    @test !_influx_mode_tc._influx_flux_enabled()
  end

  _with_env_pair("INFLUX_QUERY_MODE", "sql") do
    @test _influx_mode_tc._influx_query_mode() == "sql"
    @test _influx_mode_tc._influx_sql_enabled()
    @test !_influx_mode_tc._influx_flux_enabled()
  end

  _with_env_pair("INFLUX_QUERY_MODE", "flux") do
    @test _influx_mode_tc._influx_query_mode() == "flux"
    @test !_influx_mode_tc._influx_sql_enabled()
    @test _influx_mode_tc._influx_flux_enabled()
  end
end

@testset "Influx DB mode series-stat fixture equivalence" begin
  influxql = """
  {"results":[{"series":[
    {"tags":{"series_id":"s1"},"columns":["time","count"],"values":[[0,3]]},
    {"tags":{"series_id":"s2"},"columns":["time","count"],"values":[[0,2]]}
  ]}]}
  """
  sql = """
  {"series_id":"s1","count":3}
  {"series_id":"s2","count":2}
  """
  flux = """
  #datatype,string,long
  series_id,_value
  s1,3
  s2,2
  """

  expected = [("s1", 3), ("s2", 2)]
  @test _stats_from_influxql(influxql) == expected
  @test _stats_from_sql(sql) == expected
  @test _stats_from_flux(flux) == expected
end

@testset "Influx DB mode scalar grouped-series fixture equivalence" begin
  influxql = """
  {"results":[{"series":[
    {"tags":{"series_id":"s1"},"columns":["time","value"],"values":[[1,60],[2,62],[3,64]]},
    {"tags":{"series_id":"s2"},"columns":["time","value"],"values":[[1,70],[2,72]]}
  ]}]}
  """
  sql = """
  {"series_id":"s1","value":60}
  {"series_id":"s1","value":62}
  {"series_id":"s1","value":64}
  {"series_id":"s2","value":70}
  {"series_id":"s2","value":72}
  """
  flux = """
  series_id,_value
  s1,60
  s1,62
  s1,64
  s2,70
  s2,72
  """

  expected = Dict(
    "s1" => Float64[60, 62, 64],
    "s2" => Float64[70, 72],
  )
  @test _scalar_from_influxql(influxql) == expected
  @test _scalar_from_sql(sql) == expected
  @test _scalar_from_flux(flux) == expected
end

@testset "Influx DB mode note-vol grouped-series fixture equivalence" begin
  influxql = """
  {"results":[{"series":[
    {"tags":{"series_id":"s1"},"columns":["time","note","vol"],"values":[[1,60,0.5],[2,62,0.7]]},
    {"tags":{"series_id":"s2"},"columns":["time","note","vol"],"values":[[1,70,0.2]]}
  ]}]}
  """
  sql = """
  {"series_id":"s1","note":60,"vol":0.5}
  {"series_id":"s1","note":62,"vol":0.7}
  {"series_id":"s2","note":70,"vol":0.2}
  """
  flux = """
  series_id,note,vol
  s1,60,0.5
  s1,62,0.7
  s2,70,0.2
  """

  expected = Dict(
    "s1" => [Float64[60, 0.5], Float64[62, 0.7]],
    "s2" => [Float64[70, 0.2]],
  )
  @test _note_vol_from_influxql(influxql) == expected
  @test _note_vol_from_sql(sql) == expected
  @test _note_vol_from_flux(flux) == expected
end
