function _influx_v2_org_query()::Dict{String,String}
  org_id = strip(string(get(ENV, "INFLUX_ORG_ID", "")))
  !isempty(org_id) && return Dict("orgID" => org_id)

  org = strip(string(get(ENV, "INFLUX_ORG", "")))
  !isempty(org) && return Dict("org" => org)

  return Dict{String,String}()
end

function _influx_v2_headers()::Vector{Pair{String,String}}
  return [
    "Authorization" => "Token $(_influx_v2_token())",
    "Content-Type" => "application/json",
    "Accept" => "application/csv",
  ]
end

function _influx_v2_query(influx_url::AbstractString, flux::AbstractString)
  url = string(_trim_trailing_slashes(influx_url), "/api/v2/query")
  body = JSON3.write(Dict("query" => flux, "type" => "flux"))
  return HTTP.post(url, _influx_v2_headers(), body; query=_influx_v2_org_query())
end

function _trim_trailing_slashes(s::AbstractString)::String
  out = String(s)
  while endswith(out, "/")
    out = chop(out)
  end
  return out
end

function _fetch_series_stats_v2(influx_url, measurement; errors=nothing)::Vector{Any}
  bucket = _influx_v2_bucket()
  field = _influx_field()
  flux = """
from(bucket: "$(_flux_escape(bucket))")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "$(_flux_escape(measurement))" and r._field == "$(_flux_escape(field))" and r.composer == "Rachmaninoff")
  |> group(columns: ["series_id"])
  |> count(column: "_value")
"""

  resp = try
    _influx_v2_query(influx_url, flux)
  catch e
    _push_influx_error!(errors, "fetching Flux series stats failed: $(e)")
    return Any[]
  end

  stats = Any[]
  for row in _influx_csv_rows(String(resp.body))
    sid = strip(get(row, "series_id", ""))
    isempty(sid) && continue
    push!(stats, Dict(
      "series_id" => sid,
      "source_index" => length(stats),
      "count" => max(1, _parse_int(get(row, "_value", "1")))
    ))
  end
  return stats
end

function _fetch_series_stats_note_vol_v2(influx_url, measurement; errors=nothing)::Vector{Any}
  bucket = _influx_v2_bucket()
  note_field = _influx_note_field()
  flux = """
from(bucket: "$(_flux_escape(bucket))")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "$(_flux_escape(measurement))" and r._field == "$(_flux_escape(note_field))" and r.composer == "Rachmaninoff")
  |> group(columns: ["series_id"])
  |> count(column: "_value")
"""

  resp = try
    _influx_v2_query(influx_url, flux)
  catch e
    _push_influx_error!(errors, "fetching Flux note/vol series stats failed: $(e)")
    return Any[]
  end

  stats = Any[]
  for row in _influx_csv_rows(String(resp.body))
    sid = strip(get(row, "series_id", ""))
    isempty(sid) && continue
    push!(stats, Dict(
      "series_id" => sid,
      "source_index" => length(stats),
      "count" => max(1, _parse_int(get(row, "_value", "1")))
    ))
  end
  return stats
end

function _fetch_grouped_db_series_v2(influx_url, measurement, series_stats; errors=nothing)::Vector{Any}
  series_ids = [string(stat["series_id"]) for stat in series_stats]
  id_to_source_index = Dict(string(stat["series_id"]) => _parse_int(get(stat, "source_index", 0)) for stat in series_stats)
  field = _influx_field()
  set_expr = "[" * join(["\"$(_flux_escape(sid))\"" for sid in series_ids], ", ") * "]"
  flux = """
from(bucket: "$(_flux_escape(_influx_v2_bucket()))")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "$(_flux_escape(measurement))" and r._field == "$(_flux_escape(field))")
  |> filter(fn: (r) => contains(value: r.series_id, set: $(set_expr)))
  |> group(columns: ["series_id"])
  |> sort(columns: ["_time"])
  |> keep(columns: ["series_id", "_value"])
"""

  resp = try
    _influx_v2_query(influx_url, flux)
  catch e
    _push_influx_error!(errors, "fetching Flux grouped series failed: $(e)")
    return Any[]
  end

  values_by_id = Dict{String,Vector{Float64}}()
  for row in _influx_csv_rows(String(resp.body))
    sid = strip(get(row, "series_id", ""))
    isempty(sid) && continue
    values = get!(values_by_id, sid, Float64[])
    push!(values, _parse_float(get(row, "_value", 0)))
  end

  grouped = Any[]
  for sid in series_ids
    values = get(values_by_id, sid, Float64[])
    isempty(values) && continue
    push!(grouped, Dict(
      "series_id" => sid,
      "source_index" => get(id_to_source_index, sid, length(grouped)),
      "values" => values
    ))
  end
  return grouped
end

function _fetch_grouped_db_series_note_vol_v2(influx_url, measurement, series_stats; errors=nothing)::Vector{Any}
  series_ids = [string(stat["series_id"]) for stat in series_stats]
  id_to_source_index = Dict(string(stat["series_id"]) => _parse_int(get(stat, "source_index", 0)) for stat in series_stats)
  note_field = _influx_note_field()
  vol_field = _influx_vol_field()
  set_expr = "[" * join(["\"$(_flux_escape(sid))\"" for sid in series_ids], ", ") * "]"
  flux = """
from(bucket: "$(_flux_escape(_influx_v2_bucket()))")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "$(_flux_escape(measurement))" and (r._field == "$(_flux_escape(note_field))" or r._field == "$(_flux_escape(vol_field))"))
  |> filter(fn: (r) => contains(value: r.series_id, set: $(set_expr)))
  |> pivot(rowKey: ["_time", "series_id"], columnKey: ["_field"], valueColumn: "_value")
  |> group(columns: ["series_id"])
  |> sort(columns: ["_time"])
  |> keep(columns: ["series_id", "$(_flux_escape(note_field))", "$(_flux_escape(vol_field))"])
"""

  resp = try
    _influx_v2_query(influx_url, flux)
  catch e
    _push_influx_error!(errors, "fetching Flux note/vol grouped series failed: $(e)")
    return Any[]
  end

  values_by_id = Dict{String,Vector{Vector{Float64}}}()
  for row in _influx_csv_rows(String(resp.body))
    sid = strip(get(row, "series_id", ""))
    isempty(sid) && continue
    values = get!(values_by_id, sid, Vector{Vector{Float64}}())
    push!(values, Float64[_parse_float(get(row, note_field, 0)), _parse_float(get(row, vol_field, 0))])
  end

  grouped = Any[]
  for sid in series_ids
    values = get(values_by_id, sid, Vector{Vector{Float64}}())
    isempty(values) && continue
    push!(grouped, Dict(
      "series_id" => sid,
      "source_index" => get(id_to_source_index, sid, length(grouped)),
      "values" => values
    ))
  end
  return grouped
end

function _flux_escape(s)::String
  out = IOBuffer()
  for c in String(s)
    if c == '\\' || c == '"'
      print(out, '\\')
    end
    print(out, c)
  end
  return String(take!(out))
end

function _influx_csv_rows(body::AbstractString)::Vector{Dict{String,String}}
  header = String[]
  rows = Dict{String,String}[]
  for raw_line in split(body, '\n')
    line = chomp(String(raw_line))
    isempty(line) && continue
    startswith(line, "#") && continue

    cells = _parse_csv_line(line)
    if isempty(header)
      header = cells
      continue
    end
    cells == header && continue

    row = Dict{String,String}()
    for (idx, key) in enumerate(header)
      isempty(key) && continue
      row[key] = idx <= length(cells) ? cells[idx] : ""
    end
    push!(rows, row)
  end
  return rows
end

function _parse_csv_line(line::AbstractString)::Vector{String}
  cells = String[]
  buf = IOBuffer()
  in_quotes = false
  chars = collect(String(line))
  i = 1
  while i <= length(chars)
    c = chars[i]
    if c == '"'
      if in_quotes && i < length(chars) && chars[i + 1] == '"'
        print(buf, '"')
        i += 1
      else
        in_quotes = !in_quotes
      end
    elseif c == ',' && !in_quotes
      push!(cells, String(take!(buf)))
    else
      print(buf, c)
    end
    i += 1
  end
  push!(cells, String(take!(buf)))
  return cells
end
