function _fetch_series_stats_sql(influx_url, influx_db, measurement; errors=nothing)::Vector{Any}
  field = _influx_field()
  q = """
SELECT series_id, COUNT($(_sql_identifier(field))) AS count
FROM $(_sql_identifier(measurement))
WHERE composer = 'Rachmaninoff'
GROUP BY series_id
ORDER BY series_id
"""

  rows = try
    _influx_sql_query(influx_url, influx_db, q)
  catch e
    println("Influx SQL query failed while fetching series stats: ", e)
    _push_influx_error!(errors, "fetching SQL series stats failed: $(e)")
    return Any[]
  end

  stats = Any[]
  for row in rows
    sid = strip(string(get(row, "series_id", "")))
    isempty(sid) && continue
    push!(stats, Dict(
      "series_id" => sid,
      "source_index" => length(stats),
      "count" => max(1, _parse_int(get(row, "count", 1)))
    ))
  end
  return stats
end

function _fetch_series_stats_note_vol_sql(influx_url, influx_db, measurement; errors=nothing)::Vector{Any}
  note_field = _influx_note_field()
  q = """
SELECT series_id, COUNT($(_sql_identifier(note_field))) AS count
FROM $(_sql_identifier(measurement))
WHERE composer = 'Rachmaninoff'
GROUP BY series_id
ORDER BY series_id
"""

  rows = try
    _influx_sql_query(influx_url, influx_db, q)
  catch e
    _push_influx_error!(errors, "fetching SQL note/vol series stats failed: $(e)")
    return Any[]
  end

  stats = Any[]
  for row in rows
    sid = strip(string(get(row, "series_id", "")))
    isempty(sid) && continue
    push!(stats, Dict(
      "series_id" => sid,
      "source_index" => length(stats),
      "count" => max(1, _parse_int(get(row, "count", 1)))
    ))
  end
  return stats
end

function _fetch_grouped_db_series_sql(influx_url, influx_db, measurement, series_stats; errors=nothing)::Vector{Any}
  series_ids = [string(stat["series_id"]) for stat in series_stats]
  id_to_source_index = Dict(string(stat["series_id"]) => _parse_int(get(stat, "source_index", 0)) for stat in series_stats)
  field = _influx_field()
  ids_sql = join([_sql_literal(sid) for sid in series_ids], ", ")
  q = """
SELECT series_id, $(_sql_identifier(field)) AS value
FROM $(_sql_identifier(measurement))
ORDER BY series_id, time
"""

  rows = try
    _influx_sql_query(influx_url, influx_db, q)
  catch e
    println("Influx SQL query failed while fetching grouped series: ", e)
    _push_influx_error!(errors, "fetching SQL grouped series failed: $(e)")
    return Any[]
  end

  values_by_id = Dict{String,Vector{Float64}}()
  for row in rows
    sid = strip(string(get(row, "series_id", "")))
    isempty(sid) && continue
    values = get!(values_by_id, sid, Float64[])
    push!(values, _parse_float(get(row, "value", 0)))
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

function _fetch_grouped_db_series_note_vol_sql(influx_url, influx_db, measurement, series_stats; errors=nothing)::Vector{Any}
  series_ids = [string(stat["series_id"]) for stat in series_stats]
  id_to_source_index = Dict(string(stat["series_id"]) => _parse_int(get(stat, "source_index", 0)) for stat in series_stats)
  note_field = _influx_note_field()
  vol_field = _influx_vol_field()
  ids_sql = join([_sql_literal(sid) for sid in series_ids], ", ")
  q = """
SELECT series_id, $(_sql_identifier(note_field)) AS note, $(_sql_identifier(vol_field)) AS vol
FROM $(_sql_identifier(measurement))
ORDER BY series_id, time
"""

  rows = try
    _influx_sql_query(influx_url, influx_db, q)
  catch e
    _push_influx_error!(errors, "fetching SQL note/vol grouped series failed: $(e)")
    return Any[]
  end

  values_by_id = Dict{String,Vector{Vector{Float64}}}()
  for row in rows
    sid = strip(string(get(row, "series_id", "")))
    isempty(sid) && continue
    values = get!(values_by_id, sid, Vector{Vector{Float64}}())
    push!(values, Float64[_parse_float(get(row, "note", 0)), _parse_float(get(row, "vol", 0))])
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

function _influx_sql_query(influx_url, influx_db, q::AbstractString)::Vector{Any}
  url = string(_trim_trailing_slashes(influx_url), "/api/v3/query_sql")
  query = Dict(
    "db" => _influx_query_database(influx_db),
    "q" => String(q),
    "format" => "jsonl",
  )
  headers = [
    "Authorization" => "Bearer $(_influx_v2_token())",
    "Accept" => "application/json",
  ]
  resp = HTTP.get(url, headers; query=query)
  body = String(resp.body)
  if !_looks_like_jsonl(body)
    preview = _body_preview(body)
    error("Influx SQL query returned non-JSONL response from /api/v3/query_sql: ", preview)
  end
  return _parse_jsonl_rows(body)
end

function _parse_jsonl_rows(body::AbstractString)::Vector{Any}
  rows = Any[]
  for raw_line in split(body, '\n')
    line = strip(String(raw_line))
    isempty(line) && continue
    push!(rows, _to_string_dict(JSON3.read(line)))
  end
  return rows
end

function _looks_like_jsonl(body::AbstractString)::Bool
  for raw_line in split(body, '\n')
    line = strip(String(raw_line))
    isempty(line) && continue
    return startswith(line, "{") || startswith(line, "[")
  end
  return true
end

function _sql_identifier(s)::String
  return "\"" * replace(String(s), "\"" => "\"\"") * "\""
end

function _sql_literal(s)::String
  return "'" * replace(String(s), "'" => "''") * "'"
end
