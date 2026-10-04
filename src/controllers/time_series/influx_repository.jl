function _fetch_series_stats(influx_url, influx_db, measurement; errors=nothing)::Vector{Any}
  if _influx_sql_enabled()
    return _fetch_series_stats_sql(influx_url, influx_db, measurement; errors=errors)
  end

  if _influx_flux_enabled()
    return _fetch_series_stats_v2(influx_url, measurement; errors=errors)
  end

  if _influx_cloud_enabled()
    # InfluxDB Cloud Serverless supports HTTP queries through the v1-compatible
    # /query endpoint. The v3 SQL HTTP endpoint is for InfluxDB 3 Core and is
    # only used when INFLUX_QUERY_MODE=sql is explicitly set.
    return _fetch_series_stats_from_counts(influx_url, influx_db, measurement; errors=errors)
  end

  q_ids = "SHOW TAG VALUES FROM \"$(measurement)\" WITH KEY = \"series_id\" WHERE \"composer\" = 'Rachmaninoff'"
  resp_ids = try
    _influx_query_get(influx_url, influx_db, q_ids)
  catch e
    println("Influx query failed while fetching series ids: ", e)
    _push_influx_error!(errors, "fetching series ids failed: $(e)")
    return Any[]
  end
  parsed_ids = try JSON3.read(String(resp_ids.body)) catch
    _push_influx_error!(errors, "fetching series ids returned non-JSON: $(_body_preview(String(resp_ids.body)))")
    return Any[]
  end

  series_ids = String[]
  try
    rows = parsed_ids["results"][1]["series"][1]["values"]
    for row in rows
      push!(series_ids, string(row[2]))
    end
  catch e
    _push_influx_error!(errors, "fetching series ids returned unexpected shape: $(e)")
    return Any[]
  end

  counts = Dict{String,Int}()
  q_counts = "SELECT COUNT(\"value\") FROM \"$(measurement)\" WHERE \"composer\" = 'Rachmaninoff' GROUP BY \"series_id\""
  resp_counts = try
    _influx_query_get(influx_url, influx_db, q_counts)
  catch e
    println("Influx query failed while fetching series counts: ", e)
    _push_influx_error!(errors, "fetching series counts failed: $(e)")
    nothing
  end
  parsed_counts = try JSON3.read(String(resp_counts.body)) catch
    resp_counts === nothing || _push_influx_error!(errors, "fetching series counts returned non-JSON: $(_body_preview(String(resp_counts.body)))")
    Dict()
  end
  try
    for s in parsed_counts["results"][1]["series"]
      sid = string(s["tags"]["series_id"])
      counts[sid] = _parse_int(s["values"][1][2])
    end
  catch
  end

  stats = Any[]
  for (idx, sid) in enumerate(series_ids)
    push!(stats, Dict(
      "series_id" => sid,
      "source_index" => idx - 1,
      "count" => get(counts, sid, 1)
    ))
  end
  return stats
end

function _fetch_grouped_db_series(influx_url, influx_db, measurement, series_stats; errors=nothing)::Vector{Any}
  isempty(series_stats) && return Any[]
  if _influx_sql_enabled()
    return _fetch_grouped_db_series_sql(influx_url, influx_db, measurement, series_stats; errors=errors)
  end

  if _influx_flux_enabled()
    return _fetch_grouped_db_series_v2(influx_url, measurement, series_stats; errors=errors)
  end

  # Cloud Serverless stays on this v1-compatible query path unless an explicit
  # query mode above selected SQL or Flux.

  series_ids = [string(stat["series_id"]) for stat in series_stats]
  id_to_source_index = Dict(string(stat["series_id"]) => _parse_int(get(stat, "source_index", 0)) for stat in series_stats)
  pattern = join([_escape_influx_regex(sid) for sid in series_ids], "|")
  field = _influx_field()
  q = "SELECT \"$(field)\" FROM \"$(measurement)\" WHERE \"series_id\" =~ /^(?:$(pattern))\$/ GROUP BY \"series_id\",\"composer\",\"title\",\"folder\",\"xml_score\",\"part\",\"part_name\",\"staff\",\"voice\",\"phrase_index\""
  resp = try
    _influx_query_get(influx_url, influx_db, q; extra_query=Dict("epoch"=>"ms"))
  catch e
    println("Influx query failed while fetching grouped series: ", e)
    _push_influx_error!(errors, "fetching grouped series failed: $(e)")
    return Any[]
  end
  body = String(resp.body)
  parsed = try JSON3.read(body) catch
    _push_influx_error!(errors, "fetching grouped series returned non-JSON: $(_body_preview(body))")
    return Any[]
  end

  grouped = Any[]
  try
    series_list = parsed["results"][1]["series"]
    for (idx, s) in enumerate(series_list)
      sid = try
        string(s["tags"]["series_id"])
      catch
        string(idx - 1)
      end
      composer  = try string(s["tags"]["composer"]) catch _ "" end
      title     = try string(s["tags"]["title"]) catch _ "" end
      folder    = try string(s["tags"]["folder"]) catch _ "" end
      xml_score = try string(s["tags"]["xml_score"]) catch _ "" end
      part_name = try string(s["tags"]["part_name"]) catch _ "" end
      part      = try string(s["tags"]["part"]) catch _ "" end
      staff     = try string(s["tags"]["staff"]) catch _ "" end
      voice     = try string(s["tags"]["voice"]) catch _ "" end
      phrase    = try string(s["tags"]["phrase_index"]) catch _ "" end
      label = _series_label(composer, title, part_name, staff, voice, phrase)

      values = Float64[]
      for row in s["values"]
        push!(values, _parse_float(row[2]))
      end

      if !isempty(values)
        push!(grouped, Dict(
          "series_id" => sid,
          "source_index" => get(id_to_source_index, sid, idx - 1),
          "label" => label,
          "values" => values,
          "metadata" => Dict(
            "series_id" => sid,
            "composer" => composer,
            "title" => title,
            "folder" => folder,
            "xml_score" => xml_score,
            "part" => part,
            "staff" => staff,
            "voice" => voice,
            "phrase_index" => phrase
          )
        ))
      end
    end
  catch e
    _push_influx_error!(errors, "fetching grouped series returned unexpected shape: $(e)")
    return Any[]
  end

  return grouped
end

function _fetch_series_stats_note_vol(influx_url, influx_db, measurement; errors=nothing)::Vector{Any}
  if _influx_sql_enabled()
    return _fetch_series_stats_note_vol_sql(influx_url, influx_db, measurement; errors=errors)
  end
  if _influx_flux_enabled()
    return _fetch_series_stats_note_vol_v2(influx_url, measurement; errors=errors)
  end

  note_field = _influx_note_field()
  q_counts = "SELECT COUNT(\"$(note_field)\") FROM \"$(measurement)\" WHERE \"composer\" = 'Rachmaninoff' GROUP BY \"series_id\""
  resp_counts = try
    _influx_query_get(influx_url, influx_db, q_counts)
  catch e
    _push_influx_error!(errors, "fetching note/vol series counts failed: $(e)")
    return Any[]
  end

  body = String(resp_counts.body)
  parsed_counts = try JSON3.read(body) catch
    _push_influx_error!(errors, "fetching note/vol series counts returned non-JSON: $(_body_preview(body))")
    return Any[]
  end

  series_list = _influx_series_list(parsed_counts, body, "note/vol series counts"; errors=errors)
  series_list === nothing && return Any[]

  stats = Any[]
  try
    for s in series_list
      sid = string(s["tags"]["series_id"])
      push!(stats, Dict(
        "series_id" => sid,
        "source_index" => length(stats),
        "count" => max(1, _parse_int(s["values"][1][2]))
      ))
    end
  catch e
    _push_influx_error!(errors, "fetching note/vol series counts returned unexpected shape: $(e)")
    return Any[]
  end
  return stats
end

function _column_index(columns, name::AbstractString)::Int
  for (i, col) in enumerate(columns)
    string(col) == name && return i
  end
  return 0
end

function _fetch_grouped_db_series_note_vol(influx_url, influx_db, measurement, series_stats; errors=nothing)::Vector{Any}
  isempty(series_stats) && return Any[]
  if _influx_sql_enabled()
    return _fetch_grouped_db_series_note_vol_sql(influx_url, influx_db, measurement, series_stats; errors=errors)
  end
  if _influx_flux_enabled()
    return _fetch_grouped_db_series_note_vol_v2(influx_url, measurement, series_stats; errors=errors)
  end

  series_ids = [string(stat["series_id"]) for stat in series_stats]
  id_to_source_index = Dict(string(stat["series_id"]) => _parse_int(get(stat, "source_index", 0)) for stat in series_stats)
  pattern = join([_escape_influx_regex(sid) for sid in series_ids], "|")
  note_field = _influx_note_field()
  vol_field = _influx_vol_field()
  q = "SELECT \"$(note_field)\", \"$(vol_field)\" FROM \"$(measurement)\" WHERE \"series_id\" =~ /^(?:$(pattern))\$/ GROUP BY \"series_id\",\"composer\",\"title\",\"folder\",\"xml_score\",\"part\",\"part_name\",\"staff\",\"voice\",\"phrase_index\""
  resp = try
    _influx_query_get(influx_url, influx_db, q; extra_query=Dict("epoch"=>"ms"))
  catch e
    _push_influx_error!(errors, "fetching note/vol grouped series failed: $(e)")
    return Any[]
  end

  body = String(resp.body)
  parsed = try JSON3.read(body) catch
    _push_influx_error!(errors, "fetching note/vol grouped series returned non-JSON: $(_body_preview(body))")
    return Any[]
  end

  grouped = Any[]
  try
    series_list = parsed["results"][1]["series"]
    for (idx, s) in enumerate(series_list)
      sid = try
        string(s["tags"]["series_id"])
      catch
        string(idx - 1)
      end
      composer  = try string(s["tags"]["composer"]) catch _ "" end
      title     = try string(s["tags"]["title"]) catch _ "" end
      folder    = try string(s["tags"]["folder"]) catch _ "" end
      xml_score = try string(s["tags"]["xml_score"]) catch _ "" end
      part_name = try string(s["tags"]["part_name"]) catch _ "" end
      part      = try string(s["tags"]["part"]) catch _ "" end
      staff     = try string(s["tags"]["staff"]) catch _ "" end
      voice     = try string(s["tags"]["voice"]) catch _ "" end
      phrase    = try string(s["tags"]["phrase_index"]) catch _ "" end
      label = _series_label(composer, title, part_name, staff, voice, phrase)
      columns = s["columns"]
      note_idx = _column_index(columns, note_field)
      vol_idx = _column_index(columns, vol_field)
      if note_idx <= 0
        continue
      end

      values = Vector{Vector{Float64}}()
      for row in s["values"]
        vol = vol_idx > 0 ? _parse_float(row[vol_idx]) : 0.0
        push!(values, Float64[_parse_float(row[note_idx]), vol])
      end

      if !isempty(values)
        push!(grouped, Dict(
          "series_id" => sid,
          "source_index" => get(id_to_source_index, sid, idx - 1),
          "label" => label,
          "values" => values,
          "metadata" => Dict(
            "series_id" => sid,
            "composer" => composer,
            "title" => title,
            "folder" => folder,
            "xml_score" => xml_score,
            "part" => part,
            "staff" => staff,
            "voice" => voice,
            "phrase_index" => phrase
          )
        ))
      end
    end
  catch e
    _push_influx_error!(errors, "fetching note/vol grouped series returned unexpected shape: $(e)")
    return Any[]
  end
  return grouped
end


function _influx_field()::String
  return string(get(ENV, "INFLUX_FIELD", "value"))
end

function _influxql_string_literal(s::AbstractString)::String
  return "'" * replace(String(s), "\\" => "\\\\", "'" => "\\'") * "'"
end

function _influx_note_field()::String
  return string(get(ENV, "INFLUX_NOTE_FIELD", "note"))
end

function _influx_vol_field()::String
  return string(get(ENV, "INFLUX_VOL_FIELD", "vol"))
end

function _series_label(composer::AbstractString, title::AbstractString, part_name::AbstractString, staff::AbstractString, voice::AbstractString, phrase::AbstractString)::String
  base_parts = filter(!isempty, [String(composer), String(title)])
  base = isempty(base_parts) ? "unknown" : join(base_parts, " - ")
  detail_parts = filter(!isempty, [String(part_name), isempty(staff) ? "" : "staff $(staff)", isempty(voice) ? "" : "voice $(voice)"])
  isempty(detail_parts) || (base = string(base, " / ", join(detail_parts, " ")))
  isempty(phrase) && return base
  return string(base, " [phrase ", phrase, "]")
end

function _query_db_diagnostics(influx_db, measurement, series_stats_count::Int, chunks_count::Int, fetched_series_count::Int, fetched_point_count::Int, status::AbstractString)
  return Dict{String,Any}(
    "status" => String(status),
    "influxCloud" => _influx_cloud_enabled(),
    "queryMode" => _influx_query_mode(),
    "measurement" => String(measurement),
    "field" => _influx_field(),
    "bucketOrDb" => _influx_query_database(influx_db),
    "retentionPolicy" => _influx_default_rp(),
    "seriesStatsCount" => series_stats_count,
    "chunksCount" => chunks_count,
    "fetchedSeriesCount" => fetched_series_count,
    "fetchedPointCount" => fetched_point_count,
  )
end

function _influx_query_summary(query)::Dict{String,Any}
  q = string(get(query, "q", ""))
  summary = Dict{String,Any}(
    "db" => string(get(query, "db", "")),
    "rp" => string(get(query, "rp", "")),
    "epoch" => string(get(query, "epoch", "")),
    "queryPreview" => _body_preview(q),
  )
  if haskey(query, "u")
    summary["v1User"] = string(get(query, "u", ""))
  end
  return summary
end

function _influx_query_body_looks_json(body::AbstractString)::Bool
  s = strip(String(body))
  isempty(s) && return false
  return startswith(s, "{") || startswith(s, "[")
end

function _influx_log(message::AbstractString, details=Dict{String,Any}())
  enabled = _parse_bool(get(ENV, "INFLUX_QUERY_LOG", _influx_cloud_enabled() ? "true" : "false"), false)
  enabled || return nothing
  try
    println("[query_db][influx] ", String(message), " ", JSON3.write(details))
  catch
    println("[query_db][influx] ", String(message))
  end
  return nothing
end


function _fetch_series_stats_from_counts(influx_url, influx_db, measurement; errors=nothing)::Vector{Any}
  field = _influx_field()
  q_counts = "SELECT COUNT(\"$(field)\") FROM \"$(measurement)\" WHERE \"composer\" = 'Rachmaninoff' GROUP BY \"series_id\""
  resp_counts = try
    _influx_query_get(influx_url, influx_db, q_counts)
  catch e
    println("Influx query failed while fetching cloud series counts: ", e)
    _push_influx_error!(errors, "fetching cloud series counts failed: $(e)")
    return Any[]
  end

  counts_body = String(resp_counts.body)
  parsed_counts = try
    JSON3.read(counts_body)
  catch e
    println("Influx query returned non-JSON while fetching cloud series counts: ", counts_body)
    _push_influx_error!(errors, "fetching cloud series counts returned non-JSON: $(e) bodyBytes=$(sizeof(counts_body)) body=$(_body_preview(counts_body))")
    return Any[]
  end

  body = counts_body
  series_list = _influx_series_list(parsed_counts, body, "cloud series counts"; errors=errors)
  if series_list === nothing
    stats = _fetch_series_stats_from_sample(influx_url, influx_db, measurement; errors=errors)
    isempty(stats) || return stats
    _push_influx_error!(errors, "fetching cloud series counts returned no series: $(_body_preview(body))")
    return Any[]
  end

  stats = Any[]
  try
    for s in series_list
      sid = string(s["tags"]["series_id"])
      push!(stats, Dict(
        "series_id" => sid,
        "source_index" => length(stats),
        "count" => max(1, _parse_int(s["values"][1][2]))
      ))
    end
  catch e
    println("Influx query returned unexpected shape while fetching cloud series counts: ", e, " body=", String(resp_counts.body))
    _push_influx_error!(errors, "fetching cloud series counts returned unexpected shape: $(e) body=$(_body_preview(body))")
    return Any[]
  end
  return stats
end

function _fetch_series_stats_from_sample(influx_url, influx_db, measurement; errors=nothing)::Vector{Any}
  field = _influx_field()
  q = "SELECT \"$(field)\" FROM \"$(measurement)\" WHERE \"composer\" = 'Rachmaninoff' GROUP BY \"series_id\" LIMIT 1"
  resp = try
    _influx_query_get(influx_url, influx_db, q)
  catch e
    _push_influx_error!(errors, "fetching cloud series sample failed: $(e)")
    return Any[]
  end

  body = String(resp.body)
  parsed = try JSON3.read(body) catch
    _push_influx_error!(errors, "fetching cloud series sample returned non-JSON: $(_body_preview(body))")
    return Any[]
  end

  series_list = _influx_series_list(parsed, body, "cloud series sample"; errors=errors)
  series_list === nothing && return Any[]

  stats = Any[]
  for s in series_list
    sid = try
      strip(string(s["tags"]["series_id"]))
    catch
      ""
    end
    isempty(sid) && continue
    push!(stats, Dict(
      "series_id" => sid,
      "source_index" => length(stats),
      "count" => 1
    ))
  end
  return stats
end

function _influx_series_list(parsed, body::AbstractString, context::AbstractString; errors=nothing)
  result = try
    parsed["results"][1]
  catch e
    _push_influx_error!(errors, "$(context) returned no results: $(e) body=$(_body_preview(body))")
    return nothing
  end

  try
    err = result["error"]
    _push_influx_error!(errors, "$(context) returned Influx error: $(err)")
    return nothing
  catch
  end

  try
    return result["series"]
  catch
    return nothing
  end
end
