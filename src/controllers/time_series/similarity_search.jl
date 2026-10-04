function query_db()
  t0 = time()
  payload = _payload()
  p = _subhash(payload, "query")
  db_series_all = Any[]

  raw_query = get(p, "query_series", Any[])
  query_series = Float64[]
  for v in raw_query
    push!(query_series, _parse_float(v))
  end
  query_vectors = get(p, "query_vectors", Any[])
  query_axes = get(p, "query_axes", Any[])
  query_mode = string(get(p, "query_mode", "single"))
  query_points = _parse_note_vol_query_points(p)
  if !isempty(query_points) || query_mode == "midi_note_vol"
    return _query_db_note_vol(t0, p, query_points)
  end

  # influx params
  measurement = string(get(p, "measurement", get(ENV, "INFLUX_MEASUREMENT", "timeseries")))
  influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
  influx_db = string(get(ENV, "INFLUX_DB", "timeseries"))
  debug_influx = _parse_bool(get(p, "debug", false), false)
  merge_threshold = _parse_float(get(p, "merge_threshold_ratio", Config.DEFAULT_MERGE_THRESHOLD_RATIO))
  min_window = Config.SUBSEQUENCE_MIN_WINDOW_SIZE
  min_match_window = _parse_int(get(p, "min_match_window", Config.DEFAULT_QUERY_MIN_MATCH_WINDOW))
  candidate_min_master = _parse_int(get(p, "range_min", Config.DEFAULT_RANGE_MIN))
  candidate_max_master = _parse_int(get(p, "range_max", Config.DEFAULT_RANGE_MAX))
  max_series = _parse_int(get(p, "max_series", 0))

  clusters_per_series = Dict{Int,Any}()
  matched_series = Any[]

  influx_errors = String[]
  _influx_log("query_db start", Dict(
    "cloud" => _influx_cloud_enabled(),
    "mode" => _influx_query_mode(),
    "measurement" => measurement,
    "field" => _influx_field(),
    "bucketOrDb" => _influx_query_database(influx_db),
    "queryLength" => length(query_series),
    "queryModeInput" => query_mode,
    "minMatchWindow" => min_match_window,
  ))
  series_stats = _fetch_series_stats(influx_url, influx_db, measurement; errors=influx_errors)
  if max_series > 0 && length(series_stats) > max_series
    series_stats = series_stats[1:max_series]
  end

  if isempty(series_stats)
    processing_time_s = round(time()-t0;digits=Config.PROCESSING_TIME_DIGITS)
    db_status = isempty(influx_errors) ? "db_empty" : "influx_error"
    diagnostics = _query_db_diagnostics(influx_db, measurement, 0, 0, 0, 0, db_status)
    _influx_log("query_db finished", merge(copy(diagnostics), Dict("processingTime" => processing_time_s, "errorCount" => length(influx_errors))))
    result = Dict(
      "query"=>query_series,
      "queryVectors"=>query_vectors,
      "queryAxes"=>query_axes,
      "queryModeInput"=>query_mode,
      "dbSeries"=>Any[],
      "clustersPerSeries"=>Dict{Int,Any}(),
      "processingTime"=>processing_time_s,
      "dbStatus"=>db_status,
      "dbDiagnostics"=>diagnostics,
    )
    if !isempty(influx_errors)
      result["influxError"] = influx_errors[end]
      result["influxErrors"] = influx_errors
    end
    if debug_influx
      result["debug"] = Dict(
        "influxCloud" => _influx_cloud_enabled(),
        "queryMode" => _influx_query_mode(),
        "measurement" => measurement,
        "field" => _influx_field(),
        "bucketOrDb" => _influx_query_database(influx_db),
        "seriesStatsCount" => 0,
      )
    end
    return result
  end

  chunks = _chunk_series_by_memory_budget(series_stats)
  q_int = [ _parse_int(v) for v in query_series ]
  fetched_series_count = 0
  fetched_point_count = 0

  query_seed_manager = PolyphonicClusterManager.Manager(
    Vector{Float64}[[float(v)] for v in q_int],
    merge_threshold,
    min_window,
    true;
    scale_mode = :range_fixed,
    range_min = candidate_min_master,
    range_max = candidate_max_master
  )

  # Seed all query-side subsequences once, then reuse this state for each DB
  # series. This preserves the per-series scan behavior while avoiding repeated
  # query-only clustering work.
  PolyphonicClusterManager.process_data!(query_seed_manager)

  series_scan_count = 0
  for (chunk_idx, chunk) in enumerate(chunks)
    println("[query_db] fetching chunk $(chunk_idx)/$(length(chunks)) series=$(length(chunk))")
    flush(stdout)
    db_series_grouped = _fetch_grouped_db_series(influx_url, influx_db, measurement, chunk; errors=influx_errors)
    fetched_series_count += length(db_series_grouped)
    for item in db_series_grouped
      fetched_point_count += length(item["values"])
    end

    for series_info in db_series_grouped
      sid = string(series_info["series_id"])
      source_index = _parse_int(get(series_info, "source_index", 0))
      series_label = string(get(series_info, "label", sid))
      series_scan_count += 1
      println("[query_db] $(series_scan_count)/$(length(series_stats)) $(series_label)")
      flush(stdout)
      db_series_values = series_info["values"]::Vector{Float64}

      manager = deepcopy(query_seed_manager)

      matched_result = nothing

      for v in db_series_values
        PolyphonicClusterManager.add_data_point_permanently!(manager, Float64[_parse_int(v)])
      end

      timeline = PolyphonicClusterManager.clusters_to_timeline(manager)
      qlen = length(q_int)
      slen = length(db_series_values)
      cross_entries = Any[]
      for entry in timeline
        inds = entry["indices"]::Vector{Int}
        has_q = any(i -> i < qlen, inds)
        has_db = any(i -> i >= qlen, inds)
        if has_q && has_db
          ws = Int(entry["window_size"])
          if ws < min_match_window
            continue
          end
          q_raw = [i for i in inds if i < qlen]
          db_raw = [i for i in inds if i >= qlen]
          q_indices = [i for i in q_raw if i + ws <= qlen]
          db_indices = [i - qlen for i in db_raw if (i - qlen) + ws <= slen]
          if !isempty(q_indices) && !isempty(db_indices)
            push!(cross_entries, Dict("window_size"=>ws, "cluster_id"=>entry["cluster_id"], "q_indices"=>sort(q_indices), "db_indices"=>sort(db_indices)))
          end
        end
      end

      if !isempty(cross_entries)
        simple_matches = _matches_from_cross_entries(cross_entries)
        match_score = _match_score(simple_matches)
        matched_result = Dict(
          "series_id" => sid,
          "series_label" => series_label,
          "source_index" => source_index,
          "match_score" => match_score,
          "timeline" => cross_entries,
          "clusters" => PolyphonicClusterManager.clusters_to_dict(manager),
          "matches" => simple_matches,
          "metadata" => get(series_info, "metadata", Dict())
        )
      end

      if matched_result !== nothing
        push!(matched_series, Dict(
          "db_series" => db_series_values,
          "result" => matched_result,
          "score" => get(matched_result, "match_score", 0)
        ))
      end
    end
  end

  sort!(matched_series; by = item -> item["score"], rev=true)
  for item in matched_series
    result_index = length(db_series_all)
    push!(db_series_all, item["db_series"])
    clusters_per_series[result_index] = item["result"]
  end

  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)
  db_status = if !isempty(influx_errors) && fetched_series_count == 0
    "influx_error"
  elseif fetched_series_count == 0
    "db_empty"
  elseif isempty(db_series_all)
    "no_match"
  else
    "ok"
  end
  diagnostics = _query_db_diagnostics(influx_db, measurement, length(series_stats), length(chunks), fetched_series_count, fetched_point_count, db_status)
  diagnostics["matchedSeriesCount"] = length(db_series_all)
  _influx_log("query_db finished", merge(copy(diagnostics), Dict("processingTime" => processing_time_s, "errorCount" => length(influx_errors))))
  result = Dict(
    "query"=>query_series,
    "queryVectors"=>query_vectors,
    "queryAxes"=>query_axes,
    "queryModeInput"=>query_mode,
    "dbSeries"=>db_series_all,
    "clustersPerSeries"=>clusters_per_series,
    "processingTime"=>processing_time_s,
    "dbStatus"=>db_status,
    "dbDiagnostics"=>diagnostics,
  )
  if !isempty(influx_errors)
    result["influxError"] = influx_errors[end]
    result["influxErrors"] = influx_errors
  end
  if debug_influx
    result["debug"] = Dict(
      "influxCloud" => _influx_cloud_enabled(),
      "queryMode" => _influx_query_mode(),
      "measurement" => measurement,
      "field" => _influx_field(),
      "bucketOrDb" => _influx_query_database(influx_db),
      "seriesStatsCount" => length(series_stats),
      "chunksCount" => length(chunks),
      "fetchedSeriesCount" => fetched_series_count,
      "fetchedPointCount" => fetched_point_count,
      "matchedSeriesCount" => length(db_series_all),
      "influxErrors" => influx_errors,
    )
  end
  return result
end

function _parse_note_vol_query_points(p)::Vector{Vector{Float64}}
  raw_points = get(p, "query_points", nothing)
  points = Vector{Vector{Float64}}()
  if raw_points isa AbstractVector
    for pt in raw_points
      pt isa AbstractVector || continue
      length(pt) >= 2 || continue
      push!(points, Float64[_parse_float(pt[1]), _parse_float(pt[2])])
    end
    !isempty(points) && return points
  end

  raw_vectors = get(p, "query_vectors", nothing)
  if raw_vectors isa AbstractVector && length(raw_vectors) >= 2
    notes = raw_vectors[1]
    vols = raw_vectors[2]
    if notes isa AbstractVector && vols isa AbstractVector
      n = min(length(notes), length(vols))
      for i in 1:n
        push!(points, Float64[_parse_float(notes[i]), _parse_float(vols[i])])
      end
    end
  elseif raw_vectors isa AbstractVector && length(raw_vectors) == 1
    notes = raw_vectors[1]
    if notes isa AbstractVector
      for note in notes
        push!(points, Float64[_parse_float(note), 0.0])
      end
    end
  end
  return points
end

function _new_note_vol_manager(data::Vector{Vector{Float64}}, merge_threshold::Real, min_window::Int)
  return PolyphonicClusterManager.Manager(
    data,
    merge_threshold,
    min_window;
    value_min=Config.MIDI_NOTE_VOL_VALUE_MIN,
    value_max=Config.MIDI_NOTE_VOL_VALUE_MAX,
    max_set_size=Config.MIDI_NOTE_VOL_MAX_SET_SIZE,
    point_distance_mode=:ordered_vector,
    point_axis_ranges=Config.MIDI_NOTE_VOL_AXIS_RANGES
  )
end

function _note_vol_points_to_rows(points::Vector{Vector{Float64}})::Vector{Vector{Float64}}
  notes = Float64[]
  vols = Float64[]
  sizehint!(notes, length(points))
  sizehint!(vols, length(points))
  for pt in points
    push!(notes, length(pt) >= 1 ? pt[1] : 0.0)
    push!(vols, length(pt) >= 2 ? pt[2] : 0.0)
  end
  return Vector{Vector{Float64}}([notes, vols])
end

function _normalize_note_vol_points_for_octave_invariance(points::Vector{Vector{Float64}})::Vector{Vector{Float64}}
  isempty(points) && return Vector{Vector{Float64}}()

  first_note = length(points[1]) >= 1 ? _parse_float(points[1][1]) : 0.0
  steps_per_octave = float(Config.STEPS_PER_OCTAVE)
  octave_shift = -steps_per_octave * round((first_note - float(Config.MIDI_C4)) / steps_per_octave)
  normalized = Vector{Vector{Float64}}()
  sizehint!(normalized, length(points))
  for pt in points
    note = length(pt) >= 1 ? _parse_float(pt[1]) : 0.0
    vol = length(pt) >= 2 ? _parse_float(pt[2]) : 0.0
    push!(normalized, Float64[note + octave_shift, vol])
  end

  return normalized
end

function _note_vol_point_distance01(query_pt::Vector{Float64}, db_pt::Vector{Float64}, db_note_shift::Real)::Float64
  q_note = length(query_pt) >= 1 ? _parse_float(query_pt[1]) : 0.0
  q_vol = length(query_pt) >= 2 ? _parse_float(query_pt[2]) : 0.0
  d_note = (length(db_pt) >= 1 ? _parse_float(db_pt[1]) : 0.0) + float(db_note_shift)
  d_vol = length(db_pt) >= 2 ? _parse_float(db_pt[2]) : 0.0

  note_width = length(Config.MIDI_NOTE_VOL_AXIS_RANGES) >= 1 ? abs(Config.MIDI_NOTE_VOL_AXIS_RANGES[1]) : 127.0
  vol_width = length(Config.MIDI_NOTE_VOL_AXIS_RANGES) >= 2 ? abs(Config.MIDI_NOTE_VOL_AXIS_RANGES[2]) : 1.0
  note_width = note_width <= 0.0 ? 1.0 : note_width
  vol_width = vol_width <= 0.0 ? 1.0 : vol_width

  note_d = (q_note - d_note) / note_width
  vol_d = (q_vol - d_vol) / vol_width
  return min(sqrt((note_d * note_d + vol_d * vol_d) / 2.0), 1.0)
end

function _octave_invariant_note_vol_window_distance01(
  query_points::Vector{Vector{Float64}},
  db_points::Vector{Vector{Float64}},
  q_start::Int,
  db_start::Int,
  window_size::Int
)::Float64
  window_size <= 0 && return 1.0
  q_first = query_points[q_start + 1]
  d_first = db_points[db_start + 1]
  q_note = length(q_first) >= 1 ? _parse_float(q_first[1]) : 0.0
  d_note = length(d_first) >= 1 ? _parse_float(d_first[1]) : 0.0
  steps_per_octave = float(Config.STEPS_PER_OCTAVE)
  center_octave_shift = round((q_note - d_note) / steps_per_octave)

  best = Inf
  for octave_shift in (center_octave_shift - 1.0):(center_octave_shift + 1.0)
    note_shift = steps_per_octave * octave_shift
    squared = 0.0
    for offset in 0:(window_size - 1)
      d = _note_vol_point_distance01(query_points[q_start + offset + 1], db_points[db_start + offset + 1], note_shift)
      squared += d * d
      squared >= best * best * window_size && break
    end
    distance = sqrt(squared / float(window_size))
    best = min(best, distance)
  end

  return isfinite(best) ? best : 1.0
end

function _find_octave_invariant_note_vol_matches(
  query_points::Vector{Vector{Float64}},
  db_points::Vector{Vector{Float64}},
  merge_threshold::Real,
  min_match_window::Int
)::Vector{Any}
  qlen = length(query_points)
  slen = length(db_points)
  max_window = min(qlen, slen)
  max_window < min_match_window && return Any[]

  matches = Any[]
  threshold = max(float(merge_threshold), 0.0)
  for qi in 0:(qlen - min_match_window)
    max_q_window = qlen - qi
    for dbi in 0:(slen - min_match_window)
      max_db_window = slen - dbi
      for ws in min(max_q_window, max_db_window):-1:min_match_window
        distance = _octave_invariant_note_vol_window_distance01(query_points, db_points, qi, dbi, ws)
        if distance <= threshold
          push!(matches, Dict("q_start"=>qi, "start"=>dbi, "windowSize"=>ws))
          break
        end
      end
    end
  end

  return _filter_contained_matches(matches)
end

function _query_db_note_vol(t0, p, query_points::Vector{Vector{Float64}})
  db_series_all = Any[]
  measurement = string(get(p, "measurement", get(ENV, "INFLUX_MEASUREMENT", "timeseries")))
  influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
  influx_db = string(get(ENV, "INFLUX_DB", "timeseries"))
  debug_influx = _parse_bool(get(p, "debug", false), false)
  merge_threshold = _parse_float(get(p, "merge_threshold_ratio", Config.DEFAULT_MERGE_THRESHOLD_RATIO))
  min_window = Config.SUBSEQUENCE_MIN_WINDOW_SIZE
  min_match_window = _parse_int(get(p, "min_match_window", Config.DEFAULT_QUERY_MIN_MATCH_WINDOW))
  max_series = _parse_int(get(p, "max_series", 0))
  search_octave_invariant = _parse_bool(get(p, "search_octave_invariant", false), false)

  clusters_per_series = Dict{Int,Any}()
  matched_series = Any[]
  influx_errors = String[]

  _influx_log("query_db note_vol start", Dict(
    "cloud" => _influx_cloud_enabled(),
    "mode" => _influx_query_mode(),
    "measurement" => measurement,
    "noteField" => _influx_note_field(),
    "volField" => _influx_vol_field(),
    "bucketOrDb" => _influx_query_database(influx_db),
    "queryLength" => length(query_points),
    "minMatchWindow" => min_match_window,
  ))

  series_stats = _fetch_series_stats_note_vol(influx_url, influx_db, measurement; errors=influx_errors)
  if max_series > 0 && length(series_stats) > max_series
    series_stats = series_stats[1:max_series]
  end
  if isempty(series_stats)
    processing_time_s = round(time()-t0;digits=Config.PROCESSING_TIME_DIGITS)
    db_status = isempty(influx_errors) ? "db_empty" : "influx_error"
    diagnostics = _query_db_diagnostics(influx_db, measurement, 0, 0, 0, 0, db_status)
    diagnostics["queryValueShape"] = "note_vol"
    return Dict(
      "query"=>query_points,
      "queryPoints"=>query_points,
      "queryVectors"=>_note_vol_points_to_rows(query_points),
      "queryAxes"=>["midiPitch", "midiVol"],
      "queryModeInput"=>"midi_note_vol",
      "dbSeries"=>Any[],
      "clustersPerSeries"=>Dict{Int,Any}(),
      "processingTime"=>processing_time_s,
      "dbStatus"=>db_status,
      "dbDiagnostics"=>diagnostics,
      "influxError"=>isempty(influx_errors) ? nothing : influx_errors[end],
      "influxErrors"=>influx_errors,
    )
  end

  chunks = _chunk_series_by_memory_budget(series_stats)
  fetched_series_count = 0
  fetched_point_count = 0

  query_seed_manager = nothing
  if !search_octave_invariant
    query_seed_manager = _new_note_vol_manager(deepcopy(query_points), merge_threshold, min_window)
    PolyphonicClusterManager.PolyphonicClusterManager.process_data!(query_seed_manager)
  end

  series_scan_count = 0
  for (chunk_idx, chunk) in enumerate(chunks)
    println("[query_db] fetching chunk $(chunk_idx)/$(length(chunks)) series=$(length(chunk))")
    flush(stdout)
    db_series_grouped = _fetch_grouped_db_series_note_vol(influx_url, influx_db, measurement, chunk; errors=influx_errors)
    fetched_series_count += length(db_series_grouped)
    for item in db_series_grouped
      fetched_point_count += length(item["values"])
    end

    for series_info in db_series_grouped
      sid = string(series_info["series_id"])
      source_index = _parse_int(get(series_info, "source_index", 0))
      series_label = string(get(series_info, "label", sid))
      series_scan_count += 1
      println("[query_db] $(series_scan_count)/$(length(series_stats)) $(series_label)")
      flush(stdout)
      db_series_values = series_info["values"]::Vector{Vector{Float64}}
      qlen = length(query_points)
      slen = length(db_series_values)

      simple_matches = Any[]
      cross_entries = Any[]
      if search_octave_invariant
        simple_matches = _find_octave_invariant_note_vol_matches(query_points, db_series_values, merge_threshold, min_match_window)
        for (idx, m) in enumerate(simple_matches)
          push!(cross_entries, Dict(
            "window_size"=>_parse_int(get(m, "windowSize", 0)),
            "cluster_id"=>idx - 1,
            "q_indices"=>[_parse_int(get(m, "q_start", 0))],
            "db_indices"=>[_parse_int(get(m, "start", 0))]
          ))
        end
      else
        manager = deepcopy(query_seed_manager)

        for v in db_series_values
          PolyphonicClusterManager.add_data_point_permanently!(manager, copy(v))
        end

        timeline = PolyphonicClusterManager.clusters_to_timeline(manager)
        for entry in timeline
          inds = entry["indices"]::Vector{Int}
          has_q = any(i -> i < qlen, inds)
          has_db = any(i -> i >= qlen, inds)
          if has_q && has_db
            ws = Int(entry["window_size"])
            ws < min_match_window && continue
            q_raw = [i for i in inds if i < qlen]
            db_raw = [i for i in inds if i >= qlen]
            q_indices = [i for i in q_raw if i + ws <= qlen]
            db_indices = [i - qlen for i in db_raw if (i - qlen) + ws <= slen]
            if !isempty(q_indices) && !isempty(db_indices)
              push!(cross_entries, Dict("window_size"=>ws, "cluster_id"=>entry["cluster_id"], "q_indices"=>sort(q_indices), "db_indices"=>sort(db_indices)))
            end
          end
        end

        simple_matches = _matches_from_cross_entries(cross_entries)
      end

      isempty(simple_matches) && continue
      match_score = _match_score(simple_matches)
      matched_result = Dict(
        "series_id" => sid,
        "series_label" => series_label,
        "source_index" => source_index,
        "match_score" => match_score,
        "timeline" => cross_entries,
        "matches" => simple_matches,
        "metadata" => get(series_info, "metadata", Dict())
      )
      push!(matched_series, Dict("db_series" => db_series_values, "result" => matched_result, "score" => match_score))
    end
  end

  sort!(matched_series; by = item -> item["score"], rev=true)
  for item in matched_series
    result_index = length(db_series_all)
    push!(db_series_all, item["db_series"])
    clusters_per_series[result_index] = item["result"]
  end

  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)
  db_status = if !isempty(influx_errors) && fetched_series_count == 0
    "influx_error"
  elseif fetched_series_count == 0
    "db_empty"
  elseif isempty(db_series_all)
    "no_match"
  else
    "ok"
  end
  diagnostics = _query_db_diagnostics(influx_db, measurement, length(series_stats), length(chunks), fetched_series_count, fetched_point_count, db_status)
  diagnostics["matchedSeriesCount"] = length(db_series_all)
  diagnostics["queryValueShape"] = "note_vol"
  result = Dict(
    "query"=>query_points,
    "queryPoints"=>query_points,
    "queryVectors"=>_note_vol_points_to_rows(query_points),
    "queryAxes"=>["midiPitch", "midiVol"],
    "queryModeInput"=>"midi_note_vol",
    "dbSeries"=>db_series_all,
    "clustersPerSeries"=>clusters_per_series,
    "processingTime"=>processing_time_s,
    "dbStatus"=>db_status,
    "dbDiagnostics"=>diagnostics,
  )
  if !isempty(influx_errors)
    result["influxError"] = influx_errors[end]
    result["influxErrors"] = influx_errors
  end
  if debug_influx
    result["debug"] = Dict(
      "influxCloud" => _influx_cloud_enabled(),
      "queryMode" => _influx_query_mode(),
      "measurement" => measurement,
      "noteField" => _influx_note_field(),
      "volField" => _influx_vol_field(),
      "bucketOrDb" => _influx_query_database(influx_db),
      "seriesStatsCount" => length(series_stats),
      "chunksCount" => length(chunks),
      "fetchedSeriesCount" => fetched_series_count,
      "fetchedPointCount" => fetched_point_count,
      "matchedSeriesCount" => length(db_series_all),
      "influxErrors" => influx_errors,
    )
  end
  return result
end
