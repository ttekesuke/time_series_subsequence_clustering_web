module TimeSeriesController

using Genie.Requests
using Dates
using HTTP
using JSON3
using Base64
using CodecZlib
using UUIDs
using EzXML

# The manager is defined in the parent module (TimeseriesClusteringAPI)

# polyphonic modules (Stage5+)
import ..Config
import ..PolyphonicClusterManager
import ..MultiStreamManager
import ..DissonanceStmManager
import ..VoiceTokenGeneration

struct GeneratePolyphonicRequestError <: Exception
  code::String
  message::String
end

Base.showerror(io::IO, err::GeneratePolyphonicRequestError) = print(io, err.message)

@noinline function _invalid_generate_polyphonic_request(code::AbstractString, message::AbstractString)
  throw(GeneratePolyphonicRequestError(String(code), String(message)))
end

mutable struct PolyphonicEvaluationBudget
  dimension_evaluations::Int
  note_evaluations::Int
  dimension_limit::Int
  note_limit::Int
end

function _generate_polyphonic_limits()
  return (
    future_steps=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_FUTURE_STEPS",
      Config.POLYPHONIC_MAX_FUTURE_STEPS_DEFAULT,
    ),
    streams_per_step=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_STREAMS_PER_STEP",
      Config.POLYPHONIC_MAX_STREAMS_PER_STEP_DEFAULT,
    ),
    initial_context_steps=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS",
      Config.POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS_DEFAULT,
    ),
    notes_per_stream=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_NOTES_PER_STREAM",
      Config.POLYPHONIC_MAX_NOTES_PER_STREAM_DEFAULT,
    ),
    total_initial_notes=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_TOTAL_INITIAL_NOTES",
      Config.POLYPHONIC_MAX_TOTAL_INITIAL_NOTES_DEFAULT,
    ),
    dimension_evaluations=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_DIMENSION_EVALUATIONS",
      Config.POLYPHONIC_MAX_DIMENSION_EVALUATIONS_DEFAULT,
    ),
    note_evaluations=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_NOTE_EVALUATIONS",
      Config.POLYPHONIC_MAX_NOTE_EVALUATIONS_DEFAULT,
    ),
  )
end

function _request_finite_float(raw, path::AbstractString)::Float64
  raw isa Bool && _invalid_generate_polyphonic_request(
    "invalid_type",
    "$(path) must be numeric, not Bool.",
  )
  value = if raw isa Real
    float(raw)
  elseif raw isa AbstractString
    parsed = tryparse(Float64, strip(raw))
    parsed === nothing && _invalid_generate_polyphonic_request(
      "invalid_number",
      "$(path) must be numeric.",
    )
    parsed
  else
    _invalid_generate_polyphonic_request(
      "invalid_type",
      "$(path) must be numeric.",
    )
  end
  isfinite(value) || _invalid_generate_polyphonic_request(
    "non_finite_number",
    "$(path) must be finite.",
  )
  return value
end

function _request_finite_int(raw, path::AbstractString)::Int
  value = _request_finite_float(raw, path)
  isinteger(value) || _invalid_generate_polyphonic_request(
    "invalid_integer",
    "$(path) must be an integer.",
  )
  typemin(Int) <= value <= typemax(Int) || _invalid_generate_polyphonic_request(
    "invalid_integer",
    "$(path) is outside the supported integer range.",
  )
  return Int(round(value))
end

function _polyphonic_text_field(key)::Bool
  normalized = lowercase(String(key))
  return normalized in (
    "text",
    "mode",
    "token",
    "phones",
    "voice_inventory_id",
    "job_id",
    "fixed_value_source",
    "fixed_source",
    "value_source",
  ) || endswith(normalized, "_id") || occursin("source", normalized)
end

function _reject_nonfinite_request_values!(
  raw,
  path::AbstractString="generate_polyphonic";
  allow_non_numeric_strings::Bool=false,
)::Nothing
  if raw isa AbstractFloat
    isfinite(raw) || _invalid_generate_polyphonic_request(
      "non_finite_number",
      "$(path) must be finite.",
    )
  elseif raw isa AbstractString && !allow_non_numeric_strings
    sentinel = lowercase(strip(raw))
    if sentinel in ("nan", "+nan", "-nan", "inf", "+inf", "-inf", "infinity", "+infinity", "-infinity")
      _invalid_generate_polyphonic_request(
        "non_finite_number",
        "$(path) must be finite.",
      )
    end
  elseif raw isa AbstractVector
    for (index, value) in enumerate(raw)
      _reject_nonfinite_request_values!(
        value,
        "$(path)[$(index)]";
        allow_non_numeric_strings=allow_non_numeric_strings,
      )
    end
  elseif raw isa AbstractDict
    for (key, value) in pairs(raw)
      _reject_nonfinite_request_values!(
        value,
        "$(path).$(key)";
        allow_non_numeric_strings=_polyphonic_text_field(key),
      )
    end
  end
  return nothing
end

function _validate_generate_polyphonic_request!(raw_gp)
  gp = _to_string_dict(raw_gp)
  limits = _generate_polyphonic_limits()
  _reject_nonfinite_request_values!(gp)

  raw_stream_counts = get(gp, "stream_counts", nothing)
  stream_counts = Int[]
  if raw_stream_counts === nothing
    push!(stream_counts, 1)
  elseif raw_stream_counts isa AbstractVector
    isempty(raw_stream_counts) && _invalid_generate_polyphonic_request(
      "empty_stream_counts",
      "generate_polyphonic.stream_counts must not be empty when provided.",
    )
    length(raw_stream_counts) <= limits.future_steps || _invalid_generate_polyphonic_request(
      "limit_exceeded",
      "generate_polyphonic.stream_counts has $(length(raw_stream_counts)) future steps; limit is $(limits.future_steps).",
    )
    for (index, raw_count) in enumerate(raw_stream_counts)
      push!(stream_counts, _request_finite_int(raw_count, "generate_polyphonic.stream_counts[$(index)]"))
    end
  else
    push!(stream_counts, _request_finite_int(raw_stream_counts, "generate_polyphonic.stream_counts"))
  end

  for (index, count) in enumerate(stream_counts)
    1 <= count <= limits.streams_per_step || _invalid_generate_polyphonic_request(
      "limit_exceeded",
      "generate_polyphonic.stream_counts[$(index)]=$(count) must be within 1..$(limits.streams_per_step).",
    )
  end

  if Config.voicevox_enabled() && haskey(gp, "voice_stream_counts")
    raw_voice_counts = gp["voice_stream_counts"]
    raw_voice_counts isa AbstractVector || _invalid_generate_polyphonic_request(
      "invalid_type",
      "generate_polyphonic.voice_stream_counts must be an Array.",
    )
    length(raw_voice_counts) == length(stream_counts) || _invalid_generate_polyphonic_request(
      "length_mismatch",
      "generate_polyphonic.voice_stream_counts must have the same length as stream_counts.",
    )
    for (index, raw_count) in enumerate(raw_voice_counts)
      count = _request_finite_int(raw_count, "generate_polyphonic.voice_stream_counts[$(index)]")
      0 <= count <= stream_counts[index] || _invalid_generate_polyphonic_request(
        "out_of_range",
        "generate_polyphonic.voice_stream_counts[$(index)]=$(count) must be within 0..$(stream_counts[index]).",
      )
    end
  end

  ctx = get(gp, "initial_context", Any[])
  ctx isa AbstractVector || _invalid_generate_polyphonic_request(
    "invalid_type",
    "generate_polyphonic.initial_context must be an Array of steps.",
  )
  length(ctx) <= limits.initial_context_steps || _invalid_generate_polyphonic_request(
    "limit_exceeded",
    "generate_polyphonic.initial_context has $(length(ctx)) steps; limit is $(limits.initial_context_steps).",
  )

  total_notes = 0
  unit_indices = (2, 3, 4, 5, 6, 7, 8, 10, 11)
  for (step_index, step) in enumerate(ctx)
    step isa AbstractVector || _invalid_generate_polyphonic_request(
      "ragged_initial_context",
      "generate_polyphonic.initial_context[$(step_index)] must be an Array of streams.",
    )
    isempty(step) && _invalid_generate_polyphonic_request(
      "empty_initial_context_step",
      "generate_polyphonic.initial_context[$(step_index)] must contain at least one stream.",
    )
    length(step) <= limits.streams_per_step || _invalid_generate_polyphonic_request(
      "limit_exceeded",
      "generate_polyphonic.initial_context[$(step_index)] has $(length(step)) streams; limit is $(limits.streams_per_step).",
    )

    for (stream_index, stream) in enumerate(step)
      path = "generate_polyphonic.initial_context[$(step_index)][$((stream_index))]"
      stream isa AbstractVector || _invalid_generate_polyphonic_request(
        "ragged_initial_context",
        "$(path) must be an Array in the strict 11-element format.",
      )
      length(stream) == 11 || _invalid_generate_polyphonic_request(
        "invalid_stream_record",
        "$(path) must contain exactly 11 elements.",
      )

      notes = stream[1]
      notes isa AbstractVector || _invalid_generate_polyphonic_request(
        "invalid_notes",
        "$(path)[1] must be a note Array.",
      )
      isempty(notes) && _invalid_generate_polyphonic_request(
        "empty_notes",
        "$(path)[1] must contain at least one MIDI note.",
      )
      length(notes) <= limits.notes_per_stream || _invalid_generate_polyphonic_request(
        "limit_exceeded",
        "$(path)[1] has $(length(notes)) notes; per-stream limit is $(limits.notes_per_stream).",
      )
      total_notes += length(notes)
      total_notes <= limits.total_initial_notes || _invalid_generate_polyphonic_request(
        "limit_exceeded",
        "generate_polyphonic.initial_context contains more than $(limits.total_initial_notes) total notes.",
      )
      for (note_index, raw_note) in enumerate(notes)
        note = _request_finite_int(raw_note, "$(path)[1][$(note_index)]")
        Config.MIDI_NOTE_MIN <= note <= Config.MIDI_NOTE_MAX || _invalid_generate_polyphonic_request(
          "out_of_range",
          "$(path)[1][$(note_index)]=$(note) must be within MIDI $(Config.MIDI_NOTE_MIN)..$(Config.MIDI_NOTE_MAX).",
        )
      end

      for field_index in unit_indices
        value = _request_finite_float(stream[field_index], "$(path)[$(field_index)]")
        0.0 <= value <= 1.0 || _invalid_generate_polyphonic_request(
          "out_of_range",
          "$(path)[$(field_index)]=$(value) must be within 0..1.",
        )
      end
      chord_range = _request_finite_int(stream[9], "$(path)[9]")
      Config.CHORD_RANGE_VALUE_MIN <= chord_range <= Config.CHORD_RANGE_VALUE_MAX || _invalid_generate_polyphonic_request(
        "out_of_range",
        "$(path)[9]=$(chord_range) must be within $(Config.CHORD_RANGE_VALUE_MIN)..$(Config.CHORD_RANGE_VALUE_MAX).",
      )
    end
  end

  return (stream_counts=stream_counts, limits=limits)
end

function _consume_dimension_evaluations!(budget::PolyphonicEvaluationBudget, count::Integer; context::AbstractString="dimension")::Nothing
  n = max(Int(count), 0)
  next_count = budget.dimension_evaluations + n
  next_count <= budget.dimension_limit || _invalid_generate_polyphonic_request(
    "resource_budget_exceeded",
    "generate_polyphonic $(context) evaluation budget exceeded: $(next_count) > $(budget.dimension_limit).",
  )
  budget.dimension_evaluations = next_count
  return nothing
end

function _consume_note_evaluations!(budget::PolyphonicEvaluationBudget, count::Integer; context::AbstractString="note")::Nothing
  n = max(Int(count), 0)
  next_count = budget.note_evaluations + n
  next_count <= budget.note_limit || _invalid_generate_polyphonic_request(
    "resource_budget_exceeded",
    "generate_polyphonic $(context) evaluation budget exceeded: $(next_count) > $(budget.note_limit).",
  )
  budget.note_evaluations = next_count
  return nothing
end

"""Run-local stable mapping from stream IDs to synthetic global-axis slots."""
mutable struct StableStreamAxis
  capacity::Int
  id_to_slot::Dict{Int,Int}
  slot_to_id::Vector{Int}
end

function StableStreamAxis(capacity::Integer, initial_ids=Int[])
  axis = StableStreamAxis(max(Int(capacity), 1), Dict{Int,Int}(), Int[])
  _register_stream_ids!(axis, initial_ids)
  return axis
end

function _register_stream_ids!(axis::StableStreamAxis, ids)::Nothing
  for raw_id in ids
    stream_id = Int(raw_id)
    stream_id > 0 || error("Stable stream IDs must be positive; got $(stream_id).")
    haskey(axis.id_to_slot, stream_id) && continue
    length(axis.slot_to_id) < axis.capacity || error(
      "Stable stream ID $(stream_id) exceeds configured axis capacity $(axis.capacity).",
    )
    push!(axis.slot_to_id, stream_id)
    axis.id_to_slot[stream_id] = length(axis.slot_to_id)
  end
  return nothing
end

function _stream_axis_slot(axis::StableStreamAxis, stream_id::Integer)::Int
  id = Int(stream_id)
  _register_stream_ids!(axis, Int[id])
  return axis.id_to_slot[id]
end

function _encode_streamwise_row(
  axis::StableStreamAxis,
  stream_ids,
  values,
  offset::Real,
)::Vector{Float64}
  length(stream_ids) == length(values) || error(
    "Stream ID/value length mismatch: $(length(stream_ids)) IDs for $(length(values)) values.",
  )
  ids = Int[Int(id) for id in stream_ids]
  length(unique(ids)) == length(ids) || error("Duplicate stable stream IDs in global row: $(ids).")
  float(offset) > 0.0 || error("Stream-axis offset must be positive; got $(offset).")
  _register_stream_ids!(axis, ids)

  encoded_by_slot = Tuple{Int,Float64}[]
  sizehint!(encoded_by_slot, length(ids))
  for (id, value) in zip(ids, values)
    slot = axis.id_to_slot[id]
    push!(encoded_by_slot, (slot, float(value) + float(slot - 1) * float(offset)))
  end
  sort!(encoded_by_slot; by=first)
  return Float64[value for (_slot, value) in encoded_by_slot]
end

function _required_stream_axis_capacity(initial_count::Integer, stream_counts)::Int
  previous_count = max(Int(initial_count), 1)
  capacity = previous_count
  for raw_count in stream_counts
    desired_count = max(Int(raw_count), 1)
    capacity += max(desired_count - previous_count, 0)
    previous_count = desired_count
  end
  return capacity
end

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------
function _to_string_dict(raw)
  raw === nothing && return Dict{String,Any}()
  d = Dict{String,Any}()
  try
    for (k,v) in pairs(raw)
      d[string(k)] = v
    end
    return d
  catch
    return Dict{String,Any}()
  end
end

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

      timeline = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window)
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
        simple_matches = Any[]
        for e in cross_entries
          ws = e["window_size"]::Int
          q_idxs = e["q_indices"]::Vector{Int}
          db_idxs = e["db_indices"]::Vector{Int}
          for qi in q_idxs
            for dbi in db_idxs
              push!(simple_matches, Dict("q_start"=>qi, "start"=>dbi, "windowSize"=>ws))
            end
          end
        end
        simple_matches = _filter_contained_matches(simple_matches)
        match_score = _match_score(simple_matches)
        matched_result = Dict(
          "series_id" => sid,
          "series_label" => series_label,
          "source_index" => source_index,
          "match_score" => match_score,
          "timeline" => cross_entries,
          "clusters" => PolyphonicClusterManager.clusters_to_dict(manager.clusters),
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

        timeline = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window)
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

        for e in cross_entries
          ws = e["window_size"]::Int
          q_idxs = e["q_indices"]::Vector{Int}
          db_idxs = e["db_indices"]::Vector{Int}
          for qi in q_idxs
            for dbi in db_idxs
              push!(simple_matches, Dict("q_start"=>qi, "start"=>dbi, "windowSize"=>ws))
            end
          end
        end
        simple_matches = _filter_contained_matches(simple_matches)
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

function _influx_cloud_enabled()::Bool
  return _env_present("INFLUX_TOKEN") || _env_present("INFLUX_BUCKET")
end

function _influx_flux_enabled()::Bool
  return lowercase(strip(string(get(ENV, "INFLUX_QUERY_MODE", "")))) == "flux"
end

function _influx_sql_enabled()::Bool
  return lowercase(strip(string(get(ENV, "INFLUX_QUERY_MODE", "")))) == "sql"
end

function _influx_query_mode()::String
  mode = lowercase(strip(string(get(ENV, "INFLUX_QUERY_MODE", ""))))
  isempty(mode) && return "influxql"
  return mode
end

function _env_present(key::AbstractString)::Bool
  return !isempty(strip(string(get(ENV, key, ""))))
end

function _influx_v2_bucket()::String
  bucket = strip(string(get(ENV, "INFLUX_BUCKET", "")))
  isempty(bucket) && error("INFLUX_BUCKET is required for InfluxDB Cloud/v2")
  return bucket
end

function _influx_v2_token()::String
  token = strip(string(get(ENV, "INFLUX_TOKEN", "")))
  isempty(token) && error("INFLUX_TOKEN is required for InfluxDB Cloud/v2")
  return token
end

function _influx_query_database(influx_db)::String
  if _influx_cloud_enabled()
    return _influx_v1_database(influx_db)
  end
  return string(influx_db)
end

function _influx_v1_database(influx_db)::String
  explicit = strip(string(get(ENV, "INFLUX_V1_DB", "")))
  !isempty(explicit) && return explicit

  if _env_present("INFLUX_DB")
    return strip(string(get(ENV, "INFLUX_DB", "")))
  end

  return _influx_v2_bucket()
end

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

function _body_preview(body::AbstractString)::String
  s = replace(strip(String(body)), '\n' => ' ')
  length(s) <= 240 && return s
  return string(first(s, 240), "...")
end

function _push_influx_error!(errors, message::AbstractString)
  errors === nothing && return nothing
  try
    push!(errors, String(message))
  catch
  end
  return nothing
end

function _sql_identifier(s)::String
  return "\"" * replace(String(s), "\"" => "\"\"") * "\""
end

function _sql_literal(s)::String
  return "'" * replace(String(s), "'" => "''") * "'"
end

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

function _chunk_series_by_memory_budget(series_stats)::Vector{Any}
  budget_bytes = _query_memory_budget_bytes()
  bytes_per_point = max(32, _parse_int(get(ENV, "QUERY_DB_ESTIMATED_BYTES_PER_POINT", 256)))
  max_points = max(1, Int(floor(budget_bytes / bytes_per_point)))
  max_series_per_chunk = max(1, _parse_int(get(ENV, "QUERY_DB_MAX_SERIES_PER_CHUNK", "50")))

  chunks = Any[]
  current = Any[]
  current_points = 0

  for stat in series_stats
    point_count = max(1, _parse_int(get(stat, "count", 1)))
    if !isempty(current) && (current_points + point_count > max_points || length(current) >= max_series_per_chunk)
      push!(chunks, current)
      current = Any[]
      current_points = 0
    end
    push!(current, stat)
    current_points += point_count
  end

  isempty(current) || push!(chunks, current)
  return chunks
end

function _query_memory_budget_bytes()::Int
  override_mb = get(ENV, "QUERY_DB_MEMORY_BUDGET_MB", "")
  if !isempty(strip(string(override_mb)))
    return max(1, _parse_int(override_mb)) * 1024 * 1024
  end

  available = _available_memory_bytes()
  if available <= 0
    return 256 * 1024 * 1024
  end

  min_budget = 32 * 1024 * 1024
  max_budget = 512 * 1024 * 1024
  return Int(clamp(floor(available * 0.25), min_budget, max_budget))
end

function _available_memory_bytes()::Int
  sys_free = try
    Int(Sys.free_memory())
  catch
    0
  end

  cgroup_free = _cgroup_available_memory_bytes()
  if sys_free > 0 && cgroup_free > 0
    return min(sys_free, cgroup_free)
  elseif cgroup_free > 0
    return cgroup_free
  else
    return sys_free
  end
end

function _cgroup_available_memory_bytes()::Int
  v2_max = _read_memory_limit_file("/sys/fs/cgroup/memory.max")
  v2_current = _read_memory_limit_file("/sys/fs/cgroup/memory.current")
  if v2_max > 0 && v2_current >= 0
    return max(0, v2_max - v2_current)
  end

  v1_max = _read_memory_limit_file("/sys/fs/cgroup/memory/memory.limit_in_bytes")
  v1_current = _read_memory_limit_file("/sys/fs/cgroup/memory/memory.usage_in_bytes")
  if v1_max > 0 && v1_current >= 0
    return max(0, v1_max - v1_current)
  end

  return 0
end

function _read_memory_limit_file(path::AbstractString)::Int
  isfile(path) || return -1
  raw = strip(read(path, String))
  raw == "max" && return 0
  value = tryparse(Int, raw)
  value === nothing && return -1
  value > 9_000_000_000_000_000_000 && return 0
  return value
end

function _escape_influx_regex(s::AbstractString)::String
  out = IOBuffer()
  specials = Set(['\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}'])
  for c in String(s)
    if c in specials
      print(out, '\\')
    end
    print(out, c)
  end
  return String(take!(out))
end

function _match_score(matches)::Vector{Int}
  isempty(matches) && return Int[]
  counts = Dict{Int,Int}()
  for m in matches
    ws = _parse_int(get(m, "windowSize", 0))
    counts[ws] = get(counts, ws, 0) + 1
  end
  # 降順に並べたwindowSizeごとのcount列を返す（辞書式比較でソート可能）
  sorted_keys = sort(collect(keys(counts)); rev=true)
  return [counts[k] for k in sorted_keys]
end

function _match_contains(outer, inner)::Bool
  oq = _parse_int(get(outer, "q_start", 0))
  od = _parse_int(get(outer, "start", 0))
  ow = _parse_int(get(outer, "windowSize", 0))
  iq = _parse_int(get(inner, "q_start", 0))
  id = _parse_int(get(inner, "start", 0))
  iw = _parse_int(get(inner, "windowSize", 0))

  return oq <= iq &&
         od <= id &&
         iq + iw <= oq + ow &&
         id + iw <= od + ow &&
         (ow > iw || oq != iq || od != id)
end

function _filter_contained_matches(matches)::Vector{Any}
  isempty(matches) && return Any[]

  deduped = Any[]
  seen = Set{Tuple{Int,Int,Int}}()
  for m in matches
    key = (
      _parse_int(get(m, "q_start", 0)),
      _parse_int(get(m, "start", 0)),
      _parse_int(get(m, "windowSize", 0))
    )
    if !(key in seen)
      push!(seen, key)
      push!(deduped, m)
    end
  end

  kept = Any[]
  for (i, m) in enumerate(deduped)
    contained = false
    for (j, other) in enumerate(deduped)
      i == j && continue
      if _match_contains(other, m)
        contained = true
        break
      end
    end
    contained || push!(kept, m)
  end

  return sort(kept; by = m -> (
    _parse_int(get(m, "q_start", 0)),
    _parse_int(get(m, "start", 0)),
    -_parse_int(get(m, "windowSize", 0))
  ))
end

function _payload()
  raw = Requests.jsonpayload()
  if raw === nothing || isempty(raw)
    raw = Requests.params()
  end
  return _to_string_dict(raw)
end

function _subhash(d::Dict{String,Any}, key::String)
  return _to_string_dict(get(d, key, nothing))
end

_parse_float(x) = x isa Real ? float(x) : (x === nothing ? 0.0 : parse(Float64, string(x)))
function _parse_int(x)
  if x isa Integer
    return Int(x)
  elseif x isa Real
    return Int(trunc(x))
  elseif x === nothing
    return 0
  else
    s = strip(string(x))
    isempty(s) && return 0
    i = tryparse(Int, s)
    i !== nothing && return i
    f = tryparse(Float64, s)
    f !== nothing && return Int(trunc(f))
    return parse(Int, s)  # keep previous error behavior for truly invalid input
  end
end
function _parse_bool(x, default::Bool=false)::Bool
  x === nothing && return default
  x isa Bool && return x
  x isa Integer && return x != 0
  if x isa AbstractString
    s = lowercase(strip(String(x)))
    s in ("1", "true", "t", "yes", "y", "on", "enable", "enabled") && return true
    s in ("0", "false", "f", "no", "n", "off", "disable", "disabled") && return false
  end
  return default
end

function _parse_csv_ints(s::AbstractString)
  isempty(strip(s)) && return Int[]
  return [parse(Int, strip(x)) for x in split(s, ",") if !isempty(strip(x))]
end

function _parse_csv_floats(s::AbstractString)
  isempty(strip(s)) && return Float64[]
  return [parse(Float64, strip(x)) for x in split(s, ",") if !isempty(strip(x))]
end

struct ScalarMetricCalibrator
  center::Float64
  scale::Float64
  direction::Float64
end

struct ComplexityMetricCalibrator
  distance::ScalarMetricCalibrator
  quantity::ScalarMetricCalibrator
  complexity::ScalarMetricCalibrator
end

struct ExtendedMetricCalibrator
  base::ComplexityMetricCalibrator
  occurrence_intervals::ComplexityMetricCalibrator
end

const DEFAULT_COMPLEXITY_METRIC_CALIBRATOR = ComplexityMetricCalibrator(
  ScalarMetricCalibrator(0.0, 1.0, 1.0),
  ScalarMetricCalibrator(0.0, 1.0, -1.0),
  ScalarMetricCalibrator(0.0, 1.0, 1.0),
)
const DEFAULT_EXTENDED_METRIC_CALIBRATOR = ExtendedMetricCalibrator(
  DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
  DEFAULT_COMPLEXITY_METRIC_CALIBRATOR,
)

@inline function calibrate_metric(raw::Real, calibrator::ScalarMetricCalibrator)::Float64
  value = float(raw)
  isfinite(value) || return 0.5
  scale = max(abs(calibrator.scale), eps(Float64))
  z = calibrator.direction * (value - calibrator.center) / scale
  return clamp(0.5 + atan(z) / pi, 0.0, 1.0)
end

@inline function _metric_calibration_scale(
  center::Float64,
  effective_steps::Int,
  minimum_step::Float64,
)::Float64
  return max(abs(center) / float(max(effective_steps, 1)), minimum_step)
end

function _build_complexity_metric_calibrator(
  metrics,
  effective_steps::Int,
)::ComplexityMetricCalibrator
  steps = max(effective_steps, 1)
  normalized_floor = 1.0 / float(steps)
  return ComplexityMetricCalibrator(
    ScalarMetricCalibrator(
      metrics.distance,
      _metric_calibration_scale(metrics.distance, steps, normalized_floor),
      1.0,
    ),
    ScalarMetricCalibrator(
      metrics.quantity,
      _metric_calibration_scale(metrics.quantity, steps, 1.0),
      -1.0,
    ),
    ScalarMetricCalibrator(
      metrics.complexity,
      _metric_calibration_scale(metrics.complexity, steps, normalized_floor),
      1.0,
    ),
  )
end

"""Freeze all metric mappings from the committed manager state."""
function build_extended_metric_calibrator(
  mgr::PolyphonicClusterManager.Manager,
)::ExtendedMetricCalibrator
  committed = PolyphonicClusterManager.current_extended_metrics(mgr)
  effective_steps = max(length(mgr.data) - mgr.min_window_size + 1, 1)
  return ExtendedMetricCalibrator(
    _build_complexity_metric_calibrator(committed, effective_steps),
    _build_complexity_metric_calibrator(
      committed.occurrence_intervals,
      effective_steps,
    ),
  )
end

struct DissonanceCalibrator
  scale::Float64
end

function build_dissonance_calibrator(
  mgr::DissonanceStmManager.Manager,
)::DissonanceCalibrator
  committed = sort!(Float64[
    event.dissonance_current
    for event in mgr.memory
    if isfinite(event.dissonance_current) && event.dissonance_current > 0.0
  ])
  if isempty(committed)
    return DissonanceCalibrator(Config.DISSONANCE_CALIBRATION_SCALE)
  end
  center = committed[cld(length(committed), 2)]
  return DissonanceCalibrator(max(center, Config.DISSONANCE_CALIBRATION_MIN_SCALE))
end

@inline function calibrate_dissonance(
  raw::Real,
  calibrator::DissonanceCalibrator,
)::Float64
  roughness = max(isfinite(float(raw)) ? float(raw) : 0.0, 0.0)
  scale = max(calibrator.scale, Config.DISSONANCE_CALIBRATION_MIN_SCALE)
  return clamp(roughness / (roughness + scale), 0.0, 1.0)
end

function select_notes_by_single_addition_greedy(
  note_pool::Vector{Int},
  note_count::Int,
  target::Float64,
  calibrator::DissonanceCalibrator,
  evaluate_chord;
  register_center::Float64,
  register_allowance::Float64,
  tie_center::Float64,
  complexity_cost = nothing,
  complexity_cost_batch = nothing,
  complexity_weight::Real = 1.0,
  evaluation_budget = nothing,
)::Vector{Int}
  pool = sort!(unique(copy(note_pool)))
  isempty(pool) && return Int[]
  desired_count = clamp(note_count, 1, length(pool))
  selected = Int[]

  for _ in 1:desired_count
    candidate_rows = Tuple{Int,Vector{Int},Float64}[]
    nearest_register_distance = Inf
    for note in pool
      note in selected && continue
      chord = sort!(vcat(selected, Int[note]))
      anchor = float(chord[cld(length(chord), 2)])
      register_distance = abs(anchor - register_center)
      nearest_register_distance = min(nearest_register_distance, register_distance)
      push!(candidate_rows, (note, chord, register_distance))
    end

    eligible = Tuple{Int,Vector{Int},Float64}[
      row for row in candidate_rows
      if row[3] <= register_allowance + 1e-9
    ]
    if isempty(eligible)
      eligible = Tuple{Int,Vector{Int},Float64}[
        row for row in candidate_rows
        if abs(row[3] - nearest_register_distance) <= 1e-12
      ]
    end

    evaluation_budget === nothing || _consume_note_evaluations!(
      evaluation_budget,
      length(eligible);
      context="note candidate",
    )

    batch_complexity_penalties =
      complexity_cost_batch === nothing ?
        nothing :
        complexity_cost_batch(Vector{Int}[row[2] for row in eligible])
    if batch_complexity_penalties !== nothing
      length(batch_complexity_penalties) == length(eligible) || error(
        "complexity_cost_batch returned $(length(batch_complexity_penalties)) values for $(length(eligible)) chords.",
      )
    end

    best_note = eligible[1][1]
    best_key = (Inf, Inf, Inf, typemax(Int))
    for (eligible_idx, (note, chord, register_distance)) in enumerate(eligible)
      roughness01 = calibrate_dissonance(evaluate_chord(chord), calibrator)
      complexity_penalty = if batch_complexity_penalties !== nothing
        max(float(batch_complexity_penalties[eligible_idx]), 0.0)
      elseif complexity_cost !== nothing
        max(float(complexity_cost(chord)), 0.0)
      else
        0.0
      end
      primary_cost = abs(roughness01 - target) + max(float(complexity_weight), 0.0) * complexity_penalty
      key = (
        primary_cost,
        register_distance,
        abs(float(note) - tie_center),
        note,
      )
      if isless(key, best_key)
        best_key = key
        best_note = note
      end
    end
    push!(selected, best_note)
    sort!(selected)
  end

  return selected
end

struct PredictiveSuccessor
  value::PolyphonicClusterManager.PolySet
  mass::Float64
end

struct PredictiveDistribution
  successors::Vector{PredictiveSuccessor}
  peak_likelihood::Float64
  ready::Bool
end

const EMPTY_PREDICTIVE_DISTRIBUTION =
  PredictiveDistribution(PredictiveSuccessor[], 0.0, false)

@inline function _gaussian_similarity(distance::Real, bandwidth::Real)::Float64
  sigma = max(abs(float(bandwidth)), eps(Float64))
  z = max(float(distance), 0.0) / sigma
  return exp(-0.5 * z * z)
end

function _predictive_likelihood(
  mgr::PolyphonicClusterManager.Manager,
  successors::Vector{PredictiveSuccessor},
  candidate::PolyphonicClusterManager.PolySet,
)::Float64
  likelihood = 0.0
  for successor in successors
    distance = PolyphonicClusterManager.min_avg_distance(mgr, candidate, successor.value)
    likelihood += successor.mass * _gaussian_similarity(
      distance,
      Config.PREDICTIVE_SUCCESSOR_DISTANCE_BANDWIDTH,
    )
  end
  return likelihood
end

"""Build a multi-window distribution of values observed after the current suffix.

Every eligible window contributes one normalized successor distribution. Longer,
better-supported, and more cohesive suffix clusters receive more weight. Recency
changes occurrence votes inside each window without selecting a single window.
"""
function build_predictive_distribution(
  mgr::PolyphonicClusterManager.Manager,
)::PredictiveDistribution
  data_length = length(mgr.data)
  data_length <= mgr.min_window_size && return EMPTY_PREDICTIVE_DISTRIBUTION

  clusters_each = PolyphonicClusterManager.collect_clusters_each(mgr)
  max_context = min(
    data_length - 1,
    max(Config.PREDICTIVE_MAX_CONTEXT_LENGTH, mgr.min_window_size),
  )
  now_index = data_length - 1
  scale_rows = Tuple{Float64,Vector{PolyphonicClusterManager.PolySet},Vector{Float64}}[]

  for window_size in sort!(collect(keys(clusters_each)))
    window_size < mgr.min_window_size && continue
    window_size > max_context && continue
    latest_start = data_length - window_size
    latest_start < 0 && continue

    current_context = mgr.data[(latest_start + 1):data_length]
    same_window = clusters_each[window_size]
    target = nothing
    for node in values(same_window)
      if latest_start in node.si
        target = node
        break
      end
    end
    target === nothing && continue

    historical_starts = sort!(unique(Int[
      start for start in target.si
      if start < latest_start && start + window_size < data_length
    ]))
    isempty(historical_starts) && continue
    history_limit = max(Config.PREDICTIVE_HISTORY_LIMIT_PER_CONTEXT, 1)
    if length(historical_starts) > history_limit
      historical_starts = historical_starts[(end - history_limit + 1):end]
    end

    successors = PolyphonicClusterManager.PolySet[]
    occurrence_weights = Float64[]
    context_similarity_sum = 0.0
    for start in historical_starts
      past_context = mgr.data[(start + 1):(start + window_size)]
      context_distance =
        PolyphonicClusterManager.euclidean_distance(mgr, current_context, past_context) /
        sqrt(float(max(window_size, 1)))
      context_similarity = _gaussian_similarity(
        context_distance,
        Config.PREDICTIVE_CONTEXT_DISTANCE_BANDWIDTH,
      )
      successor_index = start + window_size
      occurrence_weight =
        PolyphonicClusterManager.recency_weight(mgr, now_index, successor_index) *
        context_similarity
      occurrence_weight <= 0.0 && continue
      push!(successors, copy(mgr.data[successor_index + 1]))
      push!(occurrence_weights, occurrence_weight)
      context_similarity_sum += context_similarity
    end
    isempty(successors) && continue

    occurrence_total = sum(occurrence_weights)
    occurrence_total <= 0.0 && continue
    occurrence_weights ./= occurrence_total

    support = float(length(successors))
    reliability = support / (support + Config.PREDICTIVE_SUPPORT_PRIOR)
    cohesion = context_similarity_sum / support
    scale_weight = float(window_size) * reliability * cohesion
    scale_weight <= 0.0 && continue
    push!(scale_rows, (scale_weight, successors, occurrence_weights))
  end

  isempty(scale_rows) && return EMPTY_PREDICTIVE_DISTRIBUTION
  scale_total = sum(row[1] for row in scale_rows)
  scale_total <= 0.0 && return EMPTY_PREDICTIVE_DISTRIBUTION

  masses = Dict{Tuple{Vararg{Float64}},Float64}()
  for (scale_weight, successors, occurrence_weights) in scale_rows
    normalized_scale_weight = scale_weight / scale_total
    for i in eachindex(successors)
      key = Tuple(successors[i])
      masses[key] = get(masses, key, 0.0) + normalized_scale_weight * occurrence_weights[i]
    end
  end

  combined = PredictiveSuccessor[
    PredictiveSuccessor(Float64[key...], mass)
    for (key, mass) in masses
    if mass > 0.0
  ]
  isempty(combined) && return EMPTY_PREDICTIVE_DISTRIBUTION
  sort!(combined; by=x -> Tuple(x.value))

  peak_likelihood = maximum(
    _predictive_likelihood(mgr, combined, successor.value)
    for successor in combined
  )
  peak_likelihood <= 0.0 && return EMPTY_PREDICTIVE_DISTRIBUTION
  return PredictiveDistribution(combined, peak_likelihood, true)
end

function predictive_surprise_score(
  mgr::PolyphonicClusterManager.Manager,
  distribution::PredictiveDistribution,
  candidate::PolyphonicClusterManager.PolySet,
)::Union{Nothing,Float64}
  distribution.ready || return nothing
  likelihood = _predictive_likelihood(mgr, distribution.successors, candidate)
  return clamp(1.0 - likelihood / distribution.peak_likelihood, 0.0, 1.0)
end

function predictive_surprise_scores(
  mgr::PolyphonicClusterManager.Manager,
  candidates::Vector{PolyphonicClusterManager.PolySet},
)::Vector{Float64}
  distribution = build_predictive_distribution(mgr)
  scores = Vector{Float64}(undef, length(candidates))
  for i in eachindex(candidates)
    score = predictive_surprise_score(mgr, distribution, candidates[i])
    scores[i] = score === nothing ? NaN : score
  end
  return scores
end

function _normalize_candidate_axis(
  values::Vector{Float64},
  unavailable_fallback::Vector{Float64}=Float64[],
)::Tuple{Vector{Float64},Bool}
  finite_values = Float64[value for value in values if isfinite(value)]
  isempty(finite_values) && return (zeros(Float64, length(values)), false)
  lo = minimum(finite_values)
  hi = maximum(finite_values)
  span = hi - lo
  span <= 1e-12 && return (zeros(Float64, length(values)), false)

  normalized = Vector{Float64}(undef, length(values))
  for i in eachindex(values)
    normalized[i] = if isfinite(values[i])
      clamp((values[i] - lo) / span, 0.0, 1.0)
    elseif i <= length(unavailable_fallback)
      clamp(unavailable_fallback[i], 0.0, 1.0)
    else
      Config.DEFAULT_TARGET_01
    end
  end
  return normalized, true
end

"""Score occurrence intervals with the same predictive structural model as values.

Interval quantity remains available as a diagnostic metric, but does not
participate in this score. An interval axis without candidate variation is omitted.
"""
function combine_occurrence_interval_scores(
  temporal_metrics::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics},
  unavailable_fallback::Vector{Float64},
  calibrator::ComplexityMetricCalibrator,
)::Tuple{Vector{Float64},Bool}
  n = length(unavailable_fallback)
  n == 0 && return (Float64[], false)

  prediction_raw = fill(NaN, n)
  diversity_raw = fill(NaN, n)
  shape_raw = fill(NaN, n)
  for i in 1:min(n, length(temporal_metrics))
    temporal = temporal_metrics[i]
    temporal.ready || continue
    prediction_raw[i] = temporal.prediction
    diversity_raw[i] = calibrate_metric(temporal.distance, calibrator.distance)
    shape_raw[i] = calibrate_metric(temporal.complexity, calibrator.complexity)
  end

  prediction, prediction_ready =
    _normalize_candidate_axis(prediction_raw, unavailable_fallback)
  diversity, diversity_ready = _normalize_candidate_axis(diversity_raw)
  shape, shape_ready = _normalize_candidate_axis(shape_raw)

  prediction_weight = prediction_ready ? max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0) : 0.0
  diversity_weight =
    diversity_ready ? max(Config.COMPLEXITY_DIVERSITY_WEIGHT, 0.0) : 0.0
  shape_weight = shape_ready ? max(Config.COMPLEXITY_SHAPE_WEIGHT, 0.0) : 0.0
  denominator = prediction_weight + diversity_weight + shape_weight
  denominator <= 0.0 && return (copy(unavailable_fallback), false)

  combined = Float64[
    (
      prediction_weight * prediction[i] +
      diversity_weight * diversity[i] +
      shape_weight * shape[i]
    ) / denominator
    for i in 1:n
  ]
  normalized, has_span = _normalize_candidate_axis(combined, unavailable_fallback)
  return (has_span ? normalized : combined, true)
end

"""Combine transition surprise with diversity, shape, and interval structure.

Structural axes are normalized within the current candidate set. An axis with no
candidate variation is omitted. Missing occurrence evidence falls back to the
candidate's predictive surprise instead of treating absence as simple or complex.
"""
function combine_predictive_structural_scores(
  predictive_scores::Vector{Float64},
  raw_dist::Vector{Float64},
  raw_quantity::Vector{Float64},
  raw_complexity::Vector{Float64},
  temporal_metrics::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics};
  metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  calibrator::ExtendedMetricCalibrator = DEFAULT_EXTENDED_METRIC_CALIBRATOR,
)::Vector{Float64}
  n = length(predictive_scores)
  n == 0 && return Float64[]

  diversity_raw = Float64[
    i <= length(raw_dist) ? calibrate_metric(raw_dist[i], calibrator.base.distance) : NaN
    for i in 1:n
  ]
  shape_raw = Float64[
    i <= length(raw_complexity) ?
      calibrate_metric(raw_complexity[i], calibrator.base.complexity) :
      NaN
    for i in 1:n
  ]
  mass_raw = Float64[
    i <= length(raw_quantity) ? calibrate_metric(raw_quantity[i], calibrator.base.quantity) : NaN
    for i in 1:n
  ]
  prediction, prediction_ready = _normalize_candidate_axis(predictive_scores)
  diversity, diversity_ready = _normalize_candidate_axis(diversity_raw)
  shape, shape_ready = _normalize_candidate_axis(shape_raw)
  mass, mass_ready = _normalize_candidate_axis(mass_raw)
  occurrence, occurrence_ready = combine_occurrence_interval_scores(
    temporal_metrics,
    predictive_scores,
    calibrator.occurrence_intervals,
  )

  prediction_weight = any(isfinite, predictive_scores) ? max(Config.COMPLEXITY_PREDICTION_WEIGHT, 0.0) : 0.0
  diversity_weight = diversity_ready ? max(Config.COMPLEXITY_DIVERSITY_WEIGHT * metric_weights[1], 0.0) : 0.0
  shape_weight = shape_ready ? max(Config.COMPLEXITY_SHAPE_WEIGHT * metric_weights[3], 0.0) : 0.0
  occurrence_weight = occurrence_ready ? max(Config.COMPLEXITY_OCCURRENCE_WEIGHT, 0.0) : 0.0
  mass_weight = mass_ready ? max(Config.COMPLEXITY_MASS_WEIGHT * metric_weights[2], 0.0) : 0.0
  denominator = prediction_weight + diversity_weight + shape_weight + occurrence_weight + mass_weight
  denominator <= 0.0 && return fill(Config.DEFAULT_TARGET_01, n)

  combined = Vector{Float64}(undef, n)
  for i in 1:n
    combined[i] = (
      prediction_weight * prediction[i] +
      diversity_weight * diversity[i] +
      shape_weight * shape[i] +
      occurrence_weight * occurrence[i] +
      mass_weight * mass[i]
    ) / denominator
  end

  normalized, has_span = _normalize_candidate_axis(combined)
  return has_span ? normalized : combined
end

function select_candidate_by_complexity_score(scores::Vector{Float64}, target_val::Float64)::Int
  best_index = 0
  min_diff = Inf
  for (idx0, score) in enumerate(scores)
    diff = abs(score - target_val)
    if diff < min_diff
      min_diff = diff
      best_index = idx0 - 1
    end
  end
  return best_index
end

@inline cluster_quantity_score(cluster_size::Int, window_size::Int)::Float64 = float(cluster_size * window_size)

# Initialize cache values (we compute "full" caches for stability)
function initial_calc_values!(
  manager,
  clusters_each_window_size
)
  for (window_size, same_ws) in clusters_each_window_size
    all_ids = collect(keys(same_ws))

    cache = get!(manager.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    for i in 1:length(all_ids)
      for j in (i+1):length(all_ids)
        cid1 = all_ids[i]
        cid2 = all_ids[j]
        as1 = same_ws[cid1]["as"]
        as2 = same_ws[cid2]["as"]
        key = cid1 < cid2 ? (cid1,cid2) : (cid2,cid1)
        cache[key] = PolyphonicClusterManager.euclidean_distance(manager, as1, as2)
      end
    end

    q_cache = get!(manager.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get!(manager.cluster_complexity_cache, window_size, Dict{Int,Float64}())
    for (cid, cluster) in same_ws
      si = cluster["si"]
      length(si) > 1 || continue
      q = cluster_quantity_score(length(si), window_size)
      q_cache[cid] = q
      c_cache[cid] = PolyphonicClusterManager.calculate_cluster_complexity(manager, cluster)
    end
  end

  return nothing
end

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

function analyse()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "analyse")

  raw_series = get(p, "time_series", Any[])
  data = Int[]
  for v in raw_series
    push!(data, _parse_int(v))
  end

  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", Config.DEFAULT_MERGE_THRESHOLD_RATIO))
  contextual_min_width = _parse_float(get(p, "contextual_min_width", Config.DEFAULT_CONTEXTUAL_MIN_WIDTH))
  min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE
  calculate_distance_when_added_subsequence_to_cluster = true

  manager = PolyphonicClusterManager.Manager(
    Vector{Float64}[[float(v)] for v in data],
    merge_threshold_ratio,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster;
    scale_mode = :contextual_global_halves,
    contextual_min_width = contextual_min_width
  )

  PolyphonicClusterManager.process_data!(manager)

  timeline = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window_size)
  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)
  println("analyse processing time (s): ", processing_time_s)

  return Dict(
    "clusteredSubsequences" => timeline,
    "timeSeries" => data,
    "clusters" => PolyphonicClusterManager.clusters_to_dict(manager.clusters),
    "processingTime" => processing_time_s
  )
end

function generate()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "generate")

  first_elements = _parse_csv_ints(string(get(p, "first_elements", "")))
  complexity_targets = _parse_csv_floats(string(get(p, "complexity_transition", "")))
  recency_centers = _parse_csv_floats(string(get(p, "recency_center", "")))
  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", Config.DEFAULT_MERGE_THRESHOLD_RATIO))
  contextual_min_width = _parse_float(get(p, "contextual_min_width", Config.DEFAULT_CONTEXTUAL_MIN_WIDTH))

  candidate_min_master = _parse_int(get(p, "range_min", Config.DEFAULT_RANGE_MIN))
  candidate_max_master = _parse_int(get(p, "range_max", Config.DEFAULT_RANGE_MAX))

  min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE
  calculate_distance_when_added_subsequence_to_cluster = false

  manager = PolyphonicClusterManager.Manager(
    Vector{Float64}[[float(v)] for v in first_elements],
    merge_threshold_ratio,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster;
    scale_mode = :range_fixed,
    range_min = candidate_min_master,
    range_max = candidate_max_master,
    contextual_min_width = contextual_min_width,
    recency = 0.0
  )

  PolyphonicClusterManager.process_data!(manager)

  clusters_each = PolyphonicClusterManager.transform_clusters(manager.clusters, min_window_size)
  initial_calc_values!(
    manager,
    clusters_each
  )
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

  results = copy(first_elements)

  for (step_idx, target_val) in enumerate(complexity_targets)
    candidates = collect(candidate_min_master:candidate_max_master)
    manager.recency = step_idx <= length(recency_centers) ? clamp(recency_centers[step_idx], 0.0, 1.0) : 0.0
    calibrator = build_extended_metric_calibrator(manager)
    raw_dist = Float64[]
    raw_quantity = Float64[]
    raw_complexity = Float64[]
    temporal_metrics = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
    sizehint!(raw_dist, length(candidates))
    sizehint!(raw_quantity, length(candidates))
    sizehint!(raw_complexity, length(candidates))
    sizehint!(temporal_metrics, length(candidates))

    for candidate in candidates
      metrics =
        PolyphonicClusterManager.simulate_add_and_calculate_all_extended(manager, Float64[candidate])
      push!(raw_dist, metrics.distance)
      push!(raw_quantity, metrics.quantity)
      push!(raw_complexity, metrics.complexity)
      push!(temporal_metrics, metrics.occurrence_intervals)
    end

    candidate_polysets = PolyphonicClusterManager.PolySet[
      Float64[candidate] for candidate in candidates
    ]
    predictive_scores = predictive_surprise_scores(manager, candidate_polysets)
    scores = combine_predictive_structural_scores(
      predictive_scores,
      raw_dist,
      raw_quantity,
      raw_complexity,
      temporal_metrics;
      calibrator=calibrator,
    )
    result_index = select_candidate_by_complexity_score(scores, float(target_val))
    result_value = candidates[result_index + 1]

    push!(results, result_value)
    PolyphonicClusterManager.add_data_point_permanently!(manager, Float64[result_value])
    PolyphonicClusterManager.update_caches_permanently!(manager)
  end

  timeline = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window_size)
  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)

  complexity_transition_stream = Any[missing for _ in first_elements]
  append!(complexity_transition_stream, complexity_targets)

  return Dict(
    "clusteredSubsequences" => timeline,
    "timeSeries" => results,
    "complexityTransition" => complexity_transition_stream,
    "clusters" => PolyphonicClusterManager.clusters_to_dict(manager.clusters),
    "processingTime" => processing_time_s
  )
end

# ------------------------------------------------------------
# Polyphonic helpers
# ------------------------------------------------------------

# 0-based index read (Rails compatible)
function array_param(raw::Dict{String,Any}, key::String, idx0::Int)
  raw === nothing && return nothing
  val = get(raw, key, nothing)
  val === nothing && return nothing

  if val isa AbstractVector
    isempty(val) && return nothing
    i = idx0 + 1
    if i < 1
      return val[1]
    elseif i > length(val)
      return val[end]
    else
      return val[i]
    end
  else
    return val
  end
end

# Accept JSON3.Object / Dict{Symbol,Any} etc.
function array_param(raw::AbstractDict, key::String, idx0::Int)
  return array_param(_to_string_dict(raw), key, idx0)
end

"""Read the first present parameter name, allowing canonical names to precede legacy aliases."""
function array_param_alias(raw::AbstractDict, idx0::Int, keys::AbstractString...)
  for key in keys
    value = array_param(raw, String(key), idx0)
    value === nothing || return value
  end
  return nothing
end

function _normalize_bpm_value(raw; fallback::Real=Config.POLYPHONIC_BPM)::Float64
  source = raw === nothing ? fallback : raw
  return Config.sanitize_bpm(_parse_float(source))
end

function _normalize_bpm_series(raw, expected_len::Int; fallback::Real=Config.POLYPHONIC_BPM)::Vector{Float64}
  fallback_bpm = _normalize_bpm_value(fallback; fallback=fallback)
  source = Any[]

  if raw isa AbstractVector
    append!(source, raw)
  elseif raw !== nothing
    push!(source, raw)
  end

  isempty(source) && push!(source, fallback_bpm)

  target_len = max(expected_len, 1)
  out = Float64[]
  sizehint!(out, target_len)
  last_raw = source[end]

  for i in 1:target_len
    raw_val = i <= length(source) ? source[i] : last_raw
    push!(out, _normalize_bpm_value(raw_val; fallback=fallback_bpm))
  end

  return out
end

function _step_durations_from_bpm_series(bpm_series::AbstractVector)::Vector{Float64}
  return Float64[Config.step_duration_from_bpm(bpm) for bpm in bpm_series]
end

function _step_onsets_from_durations(step_durations::AbstractVector)::Vector{Float64}
  onsets = Float64[]
  sizehint!(onsets, length(step_durations))
  current = 0.0
  for dur in step_durations
    push!(onsets, current)
    current += float(dur)
  end
  return onsets
end

function generate_centered_targets(n::Int, center::Real, spread::Real)::Vector{Float64}
  n = max(n, 1)
  if n == 1
    return [clamp(float(center), 0.0, 1.0)]
  end

  c = clamp(float(center), 0.0, 1.0)
  s = clamp(float(spread), 0.0, 1.0)

  halfw = s / 2.0
  startv = clamp(c - halfw, 0.0, 1.0)
  endv   = clamp(c + halfw, 0.0, 1.0)

  out = Vector{Float64}(undef, n)
  for i in 1:n
    t = (i - 1) / float(n - 1)
    out[i] = clamp(startv + (endv - startv) * t, 0.0, 1.0)
  end
  return out
end

struct CandidateMetric
  ordered_cand::Vector{Float64}
  global_dist::Float64
  global_qty::Float64
  global_comp::Float64
  stream_dists::Vector{Float64}
  stream_qtys::Vector{Float64}
  stream_comps::Vector{Float64}
  global_temporal::PolyphonicClusterManager.OccurrenceIntervalMetrics
  stream_temporals::Vector{PolyphonicClusterManager.OccurrenceIntervalMetrics}
  global_predictive::Float64
  stream_predictives::Vector{Float64}
  discordance::Float64
end

struct CandidateCostBreakdown
  total::Float64
  global_cost::Float64
  stream_cost::Float64
  conc_cost::Float64
  current_global::Float64
  stream_scores::Vector{Float64}
end

function _normalize_metric_weights(dw::Real, qw::Real, cw::Real)::NTuple{3,Float64}
  d = isfinite(float(dw)) ? max(float(dw), 0.0) : 0.0
  q = isfinite(float(qw)) ? max(float(qw), 0.0) : 0.0
  c = isfinite(float(cw)) ? max(float(cw), 0.0) : 0.0
  if d + q + c <= 0.0
    return (1.0, 1.0, 1.0)
  end
  return (d, q, c)
end

function _safe_simulate_add_and_calculate_all_extended(
  mgr::PolyphonicClusterManager.Manager,
  value::PolyphonicClusterManager.PolySet,
)::PolyphonicClusterManager.ExtendedClusterMetrics
  return PolyphonicClusterManager.simulate_add_and_calculate_all_extended(mgr, value)
end

function _set_generation_failure_context!(
  context::Dict{Symbol,Any};
  operation::AbstractString,
  dimension=nothing,
  stream_id=nothing,
  candidate=nothing,
)::Dict{Symbol,Any}
  context[:operation] = String(operation)
  context[:dimension] = dimension
  context[:stream_id] = stream_id
  context[:candidate] = candidate
  return context
end

function _stage_generate_polyphonic_step_state(managers, stm_mgr, stream_axis, voice_state)
  # Copy one graph so manager dictionaries keep the same staged StableStreamAxis.
  return deepcopy((
    managers=managers,
    stm_mgr=stm_mgr,
    stream_axis=stream_axis,
    voice_state=voice_state,
  ))
end

function _log_generate_polyphonic_step_failure(err, bt, step_idx::Int, context::Dict{Symbol,Any})::Nothing
  @error "generate_polyphonic step failed; staged state discarded" step=step_idx operation=get(context, :operation, nothing) dimension=get(context, :dimension, nothing) stream_id=get(context, :stream_id, nothing) candidate=get(context, :candidate, nothing) exception=(err, bt)
  return nothing
end

function _safe_corrcoef(xs::Vector{Float64}, ys::Vector{Float64})::Float64
  n = min(length(xs), length(ys))
  n <= 1 && return NaN

  mx = sum(xs[1:n]) / float(n)
  my = sum(ys[1:n]) / float(n)

  sxx = 0.0
  syy = 0.0
  sxy = 0.0
  for i in 1:n
    dx = xs[i] - mx
    dy = ys[i] - my
    sxx += dx * dx
    syy += dy * dy
    sxy += dx * dy
  end

  if sxx <= 0.0 || syy <= 0.0
    return NaN
  end
  return sxy / sqrt(sxx * syy)
end

@inline function _concordance_cost(raw_conc::Real, discordance::Real)::Float64
  conc = clamp(float(raw_conc), -1.0, 1.0)
  weight = abs(conc)
  weight <= 0.0 && return 0.0

  target_concordance = conc > 0.0 ? 1.0 : 0.0
  concord01 = 1.0 - clamp(float(discordance), 0.0, 1.0)
  return weight * abs(concord01 - target_concordance)
end

function select_best_polyphonic_candidate_unified_with_cost(
  metrics::Vector{CandidateMetric},
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  global_metric_weights::NTuple{3,Float64},
  stream_metric_weights::NTuple{3,Float64};
  use_global_score::Bool = true,
  global_calibrator::ExtendedMetricCalibrator = DEFAULT_EXTENDED_METRIC_CALIBRATOR,
  stream_calibrators::Vector{ExtendedMetricCalibrator} = ExtendedMetricCalibrator[],
)
  best_i = 1
  min_cost = Inf
  breakdowns = CandidateCostBreakdown[]
  sizehint!(breakdowns, length(metrics))

  global_predictive_scores = Float64[
    isfinite(m.global_predictive) ? m.global_predictive : NaN
    for m in metrics
  ]
  global_scores = combine_predictive_structural_scores(
    global_predictive_scores,
    Float64[m.global_dist for m in metrics],
    Float64[m.global_qty for m in metrics],
    Float64[m.global_comp for m in metrics],
    PolyphonicClusterManager.OccurrenceIntervalMetrics[m.global_temporal for m in metrics];
    metric_weights=global_metric_weights,
    calibrator=global_calibrator,
  )

  n_stream_metrics = 0
  for m in metrics
    n_stream_metrics = max(
      n_stream_metrics,
      length(m.stream_dists),
      length(m.stream_qtys),
      length(m.stream_comps),
    )
  end
  stream_norm = Vector{Vector{Float64}}(undef, n_stream_metrics)

  for s_idx in 1:n_stream_metrics
    raw_d = Float64[(s_idx <= length(m.stream_dists)) ? m.stream_dists[s_idx] : 0.0 for m in metrics]
    raw_q = Float64[(s_idx <= length(m.stream_qtys)) ? m.stream_qtys[s_idx] : 0.0 for m in metrics]
    raw_c = Float64[(s_idx <= length(m.stream_comps)) ? m.stream_comps[s_idx] : 0.0 for m in metrics]
    temporal = PolyphonicClusterManager.OccurrenceIntervalMetrics[
      (s_idx <= length(m.stream_temporals)) ?
        m.stream_temporals[s_idx] :
        PolyphonicClusterManager.EMPTY_OCCURRENCE_INTERVAL_METRICS
      for m in metrics
    ]
    stream_calibrator =
      s_idx <= length(stream_calibrators) ?
        stream_calibrators[s_idx] :
        DEFAULT_EXTENDED_METRIC_CALIBRATOR
    predictive_stream_scores = Float64[
      s_idx <= length(m.stream_predictives) && isfinite(m.stream_predictives[s_idx]) ?
        m.stream_predictives[s_idx] :
        NaN
      for m in metrics
    ]
    stream_norm[s_idx] = combine_predictive_structural_scores(
      predictive_stream_scores,
      raw_d,
      raw_q,
      raw_c,
      temporal;
      metric_weights=stream_metric_weights,
      calibrator=stream_calibrator,
    )
  end

  conc_enabled = !isempty(metrics) && length(metrics[1].ordered_cand) > 1

  for (i, m) in enumerate(metrics)
    current_global = use_global_score ? global_scores[i] : 0.0
    cost_a = use_global_score ? abs(current_global - global_target) : 0.0

    cost_b = 0.0
    stream_scores = Float64[]
    if !isempty(stream_targets)
      n = min(length(stream_targets), n_stream_metrics)
      if n > 0
        sizehint!(stream_scores, n)
        for s_idx in 1:n
          stream_score = stream_norm[s_idx][i]
          cost_b += abs(stream_score - stream_targets[s_idx])
          push!(stream_scores, stream_score)
        end
        cost_b /= float(n)
      end
    end

    cost_c = 0.0
    if conc_enabled
      cost_c = _concordance_cost(concordance_weight, m.discordance)
    end

    total = cost_a + cost_b + cost_c
    push!(breakdowns, CandidateCostBreakdown(total, cost_a, cost_b, cost_c, current_global, copy(stream_scores)))
    if total < min_cost
      min_cost = total
      best_i = i
    end
  end

  return best_i, min_cost, breakdowns
end

function select_best_chord_for_dimension_with_cost(
  mgrs::Dict{Symbol,Any},
  candidates::Vector{<:AbstractVector{<:Real}},
  stream_costs,
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  n::Int,
  range_vec::Vector{<:Real};
  global_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  stream_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  debug_prefix::Union{Nothing,String} = nothing,
  debug_top_n::Int = Config.DEFAULT_DEBUG_TOP_N,
  absolute_bases::Union{Nothing,Vector{Int}} = nothing,
  active_note_counts::Union{Nothing,Vector{Int}} = nothing,
  active_total_notes::Union{Nothing,Int} = nothing,
  max_simultaneous_notes::Int = last(Config.CHORD_SIZE_RANGE),
  preserve_stream_order::Bool = false,
  use_global_score::Bool = true
)
  max_simul = max(max_simultaneous_notes, 1)

  assignment_distance_weight::Float64 = 1.0
  assignment_complexity_weight::Float64 = 1.0

  if active_total_notes !== nothing
    total_notes = Int(active_total_notes)
    density01 = (n <= 0) ? 0.0 : clamp(total_notes / float(max_simul * n), 0.0, 1.0)

    assignment_distance_weight   = density01
    assignment_complexity_weight = 1.0 - density01
  end

  vmin = isempty(range_vec) ? 0.0 : float(minimum(range_vec))
  vmax = isempty(range_vec) ? 1.0 : float(maximum(range_vec))
  range_width = abs(vmax - vmin)
  range_width = range_width <= 0.0 ? 1.0 : range_width

  global_calibrator = build_extended_metric_calibrator(mgrs[:global])
  stream_mgr = mgrs[:stream]
  actives = MultiStreamManager.active_stream_containers(stream_mgr, n)
  stream_calibrators = ExtendedMetricCalibrator[
    build_extended_metric_calibrator(actives[i].manager)
    for i in 1:min(n, length(actives))
  ]
  global_predictor = build_predictive_distribution(mgrs[:global])
  stream_predictors = PredictiveDistribution[
    build_predictive_distribution(actives[i].manager)
    for i in 1:min(n, length(actives))
  ]
  metrics = CandidateMetric[]

  for cand_set in candidates
    ordered_polysets = if preserve_stream_order
      [Float64[float(v)] for v in cand_set]
    else
      resolved_polysets, _stream_metric = MultiStreamManager.resolve_mapping_and_score(
        mgrs[:stream],
        cand_set,
        stream_costs;
        absolute_bases=absolute_bases,
        active_note_counts=active_note_counts,
        active_total_notes=active_total_notes,
        distance_weight=assignment_distance_weight,
        complexity_weight=assignment_complexity_weight,
      )
      resolved_polysets
    end

    ordered_vals = Float64[]
    for v in ordered_polysets
      if v isa AbstractVector && !isempty(v)
        push!(ordered_vals, float(v[1]))
      else
        push!(ordered_vals, 0.0)
      end
    end

    g_offset = get(mgrs, :global_offset, 0.0)
    stream_axis = get(mgrs, :stream_axis, nothing)
    stream_axis isa StableStreamAxis || error("Missing stable stream axis for global dimension evaluation.")
    length(actives) >= length(ordered_vals) || error(
      "Only $(length(actives)) active stream identities are available for $(length(ordered_vals)) global values.",
    )
    active_ids = Int[actives[i].id for i in 1:length(ordered_vals)]
    global_vals = _encode_streamwise_row(stream_axis, active_ids, ordered_vals, g_offset)
    global_metrics =
      PolyphonicClusterManager.simulate_add_and_calculate_all_extended(mgrs[:global], global_vals)
    disc =
      if isempty(ordered_vals)
        0.0
      else
        (maximum(ordered_vals) - minimum(ordered_vals)) / range_width
      end

    stream_dists = Float64[]
    stream_qtys = Float64[]
    stream_comps = Float64[]
    stream_temporals = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
    stream_predictives = Float64[]

    for i in 1:n
      if i <= length(actives) && i <= length(ordered_polysets)
        stream_metrics =
          _safe_simulate_add_and_calculate_all_extended(actives[i].manager, ordered_polysets[i])
        push!(stream_dists, isfinite(stream_metrics.distance) ? stream_metrics.distance : 0.0)
        push!(stream_qtys, isfinite(stream_metrics.quantity) ? stream_metrics.quantity : 0.0)
        push!(stream_comps, isfinite(stream_metrics.complexity) ? stream_metrics.complexity : 0.0)
        push!(stream_temporals, stream_metrics.occurrence_intervals)
        predictive = predictive_surprise_score(
          actives[i].manager,
          stream_predictors[i],
          ordered_polysets[i],
        )
        push!(stream_predictives, predictive === nothing ? NaN : predictive)
      else
        push!(stream_dists, 0.0)
        push!(stream_qtys, 0.0)
        push!(stream_comps, 0.0)
        push!(stream_temporals, PolyphonicClusterManager.EMPTY_OCCURRENCE_INTERVAL_METRICS)
        push!(stream_predictives, NaN)
      end
    end

    global_predictive = predictive_surprise_score(
      mgrs[:global],
      global_predictor,
      global_vals,
    )

    push!(metrics, CandidateMetric(
      ordered_vals,
      global_metrics.distance,
      global_metrics.quantity,
      global_metrics.complexity,
      stream_dists,
      stream_qtys,
      stream_comps,
      global_metrics.occurrence_intervals,
      stream_temporals,
      global_predictive === nothing ? NaN : global_predictive,
      stream_predictives,
      disc,
    ))
  end

  isempty(metrics) && return (Float64[], Inf)

  best_i, best_cost, breakdowns = select_best_polyphonic_candidate_unified_with_cost(
    metrics,
    global_target,
    stream_targets,
    concordance_weight,
    global_metric_weights,
    stream_metric_weights;
    use_global_score=use_global_score,
    global_calibrator=global_calibrator,
    stream_calibrators=stream_calibrators,
  )

  best = metrics[best_i]
  return best.ordered_cand, best_cost
end

function stream_priority_order(stream_mgr, n::Int)::Vector{Int}
  actives = MultiStreamManager.active_stream_containers(stream_mgr, n)
  ranked = Tuple{Float64,Int}[]
  sizehint!(ranked, n)
  for i in 1:n
    strength = i <= length(actives) ? clamp(float(actives[i].presence_avg), 0.0, 1.0) : 0.0
    push!(ranked, (-strength, i))
  end
  sort!(ranked; by=x -> (x[1], x[2]))
  return Int[x[2] for x in ranked]
end

function select_best_values_for_dimension_greedy(
  mgrs::Dict{Symbol,Any},
  range_vec::Vector{Float64},
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  n::Int;
  global_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  stream_metric_weights::NTuple{3,Float64} = (1.0, 1.0, 1.0),
  use_global_score::Bool = true,
  priority_order::Union{Nothing,Vector{Int}} = nothing,
  trace_context::Union{Nothing,Dict{Symbol,Any}} = nothing,
  evaluation_budget = nothing
)::Vector{Float64}
  n = max(n, 1)
  isempty(range_vec) && return fill(0.0, n)

  chosen = fill(NaN, n)
  order = priority_order === nothing ? stream_priority_order(mgrs[:stream], n) : Int[i for i in priority_order if 1 <= i <= n]
  isempty(order) && (order = collect(1:n))
  actives = MultiStreamManager.active_stream_containers(mgrs[:stream], n)

  vmin = minimum(range_vec)
  vmax = maximum(range_vec)
  range_width = abs(vmax - vmin)
  range_width = range_width <= 0.0 ? 1.0 : range_width
  g_offset = float(get(mgrs, :global_offset, 0.0))
  stream_axis = get(mgrs, :stream_axis, nothing)
  stream_axis isa StableStreamAxis || error("Missing stable stream axis for global dimension evaluation.")

  for stream_idx in order
    global_calibrator = build_extended_metric_calibrator(mgrs[:global])
    stream_calibrator =
      stream_idx <= length(actives) ?
        build_extended_metric_calibrator(actives[stream_idx].manager) :
        DEFAULT_EXTENDED_METRIC_CALIBRATOR
    metrics = CandidateMetric[]
    global_predictor = build_predictive_distribution(mgrs[:global])
    stream_predictor =
      stream_idx <= length(actives) ?
        build_predictive_distribution(actives[stream_idx].manager) :
        EMPTY_PREDICTIVE_DISTRIBUTION
    sizehint!(metrics, length(range_vec))

    for cand in range_vec
      partial_vals = Tuple{Int,Float64}[]
      for i in 1:n
        if isfinite(chosen[i])
          push!(partial_vals, (i, chosen[i]))
        end
      end
      push!(partial_vals, (stream_idx, float(cand)))
      sort!(partial_vals; by=x -> x[1])

      ordered_vals = Float64[value for (_index, value) in partial_vals]
      partial_ids = Int[]
      sizehint!(partial_ids, length(partial_vals))
      for (index, _value) in partial_vals
        index <= length(actives) || error("Missing stable stream identity for active slot $(index).")
        push!(partial_ids, actives[index].id)
      end
      global_vals = _encode_streamwise_row(stream_axis, partial_ids, ordered_vals, g_offset)

      if trace_context !== nothing
        _set_generation_failure_context!(
          trace_context;
          operation="simulate_candidate",
          dimension=get(trace_context, :dimension, nothing),
          stream_id=(stream_idx <= length(actives) ? actives[stream_idx].id : nothing),
          candidate=float(cand),
        )
      end

      if evaluation_budget !== nothing
        dimension_name = trace_context === nothing ? "dimension" : string(get(trace_context, :dimension, "dimension"))
        _consume_dimension_evaluations!(evaluation_budget, 1; context="$(dimension_name) candidate")
      end

      global_metrics =
        _safe_simulate_add_and_calculate_all_extended(mgrs[:global], global_vals)
      disc = length(ordered_vals) <= 1 ? 0.0 : clamp((maximum(ordered_vals) - minimum(ordered_vals)) / range_width, 0.0, 1.0)

      stream_metrics =
        if stream_idx <= length(actives)
          _safe_simulate_add_and_calculate_all_extended(
            actives[stream_idx].manager,
            Float64[float(cand)],
          )
        else
          PolyphonicClusterManager.ExtendedClusterMetrics(
            0.0,
            0.0,
            0.0,
            PolyphonicClusterManager.EMPTY_OCCURRENCE_INTERVAL_METRICS,
          )
        end

      global_predictive = predictive_surprise_score(
        mgrs[:global],
        global_predictor,
        global_vals,
      )
      stream_predictive =
        stream_idx <= length(actives) ?
          predictive_surprise_score(
            actives[stream_idx].manager,
            stream_predictor,
            Float64[float(cand)],
          ) :
          nothing

      push!(metrics, CandidateMetric(
        ordered_vals,
        global_metrics.distance,
        global_metrics.quantity,
        global_metrics.complexity,
        Float64[stream_metrics.distance],
        Float64[stream_metrics.quantity],
        Float64[stream_metrics.complexity],
        global_metrics.occurrence_intervals,
        PolyphonicClusterManager.OccurrenceIntervalMetrics[
          stream_metrics.occurrence_intervals,
        ],
        global_predictive === nothing ? NaN : global_predictive,
        Float64[stream_predictive === nothing ? NaN : stream_predictive],
        disc,
      ))
    end

    target = stream_idx <= length(stream_targets) ? stream_targets[stream_idx] : 0.5
    best_i, _best_cost, _breakdowns = select_best_polyphonic_candidate_unified_with_cost(
      metrics,
      global_target,
      Float64[target],
      concordance_weight,
      global_metric_weights,
      stream_metric_weights;
      use_global_score=use_global_score,
      global_calibrator=global_calibrator,
      stream_calibrators=ExtendedMetricCalibrator[stream_calibrator],
    )
    chosen[stream_idx] = range_vec[best_i]
  end

  return Float64[isfinite(v) ? v : range_vec[1] for v in chosen]
end

# ------------------------------------------------------------
# generate_polyphonic (main)
# ------------------------------------------------------------
function generate_polyphonic()
  t0 = time()

  payload = _payload()
  gp = _subhash(payload, "generate_polyphonic")
  validated_request = _validate_generate_polyphonic_request!(gp)
  evaluation_budget = PolyphonicEvaluationBudget(
    0,
    0,
    validated_request.limits.dimension_evaluations,
    validated_request.limits.note_evaluations,
  )
  debug_poly = false
  try
    debug_poly = get(gp, "debug_poly", false) == true || get(gp, "debug_score", false) == true || get(ENV, "ZIP_DEBUG_POLY", "0") == "1"
  catch
    debug_poly = get(ENV, "ZIP_DEBUG_POLY", "0") == "1"
  end

  # ----------------------------------------------------------
  # Params
  # ----------------------------------------------------------
  stream_counts = copy(validated_request.stream_counts)

  voice_counts_present = Config.voicevox_enabled() && haskey(gp, "voice_stream_counts")
  voice_stream_counts = Int[]
  if voice_counts_present
    raw_voice_counts = get(gp, "voice_stream_counts", Any[])
    raw_voice_counts isa AbstractVector || error("generate_polyphonic.voice_stream_counts must be an Array.")
    for value in raw_voice_counts
      count = _parse_int(value)
      count >= 0 || error("generate_polyphonic.voice_stream_counts values must be >= 0.")
      push!(voice_stream_counts, count)
    end
    length(voice_stream_counts) == length(stream_counts) || error(
      "generate_polyphonic.voice_stream_counts must have the same length as stream_counts.",
    )
    for i in eachindex(stream_counts)
      voice_stream_counts[i] <= stream_counts[i] || error(
        "voice_stream_counts[$(i)]=$(voice_stream_counts[i]) exceeds stream_counts[$(i)]=$(stream_counts[i]).",
      )
    end
  else
    voice_stream_counts = fill(0, length(stream_counts))
  end

  strength_targets_raw = get(gp, "stream_strength_target", Any[])
  strength_spreads_raw = get(gp, "stream_strength_spread", Any[])

  strength_targets = Float64[]
  if strength_targets_raw isa AbstractVector
    for x in strength_targets_raw
      push!(strength_targets, _parse_float(x))
    end
  end

  strength_spreads = Float64[]
  if strength_spreads_raw isa AbstractVector
    for x in strength_spreads_raw
      push!(strength_spreads, _parse_float(x))
    end
  end

  bpm = _normalize_bpm_value(get(gp, "bpm", Config.POLYPHONIC_BPM))

  ctx_raw = get(gp, "initial_context", Any[])

  # Stream record (REQUIRED):
  #   strict full: [abs_notes::Vector{Int}, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range::Int, density::Float64, tie::Float64]
  #
  # initial_context MUST be a 3-level array:
  #   initial_context[step][stream] = stream_record
  results = Vector{Vector{Vector{Any}}}()

  if !(ctx_raw isa AbstractVector)
    error("generate_polyphonic.initial_context must be an Array of steps; each step is an Array of streams; each stream must be strict [abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, tie].")
  end

  for step in ctx_raw
    step isa AbstractVector || error("generate_polyphonic.initial_context: each step must be an Array of streams.")
    streams = Vector{Vector{Any}}()
    for st in step
      st isa AbstractVector || error("generate_polyphonic.initial_context: each stream must be an Array in strict format.")
      push!(streams, Any[st...])
    end
    push!(results, streams)
  end

  # Defaults
  if isempty(results)
    push!(results, [Any[
      [Int(Config.abs_pitch_min())],
      Config.UNIT_MAX,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.UNIT_MID,
      Config.CHORD_RANGE_VALUE_MIN,
      Config.UNIT_MIN,
      Config.UNIT_MIN
    ]])
  end

  initial_context_bpm = _normalize_bpm_series(get(gp, "initial_context_bpm", nothing), length(results); fallback=bpm)
  future_bpm = _normalize_bpm_series(get(gp, "future_bpm", nothing), length(stream_counts); fallback=bpm)
  function _normalize_unit_series(raw, n::Int; fallback::Float64=0.0)::Vector{Float64}
    target_len = max(n, 0)
    target_len == 0 && return Float64[]
    vals = Float64[]
    if raw isa AbstractVector
      for x in raw
        push!(vals, clamp(_parse_float(x), 0.0, 1.0))
      end
    elseif raw !== nothing
      push!(vals, clamp(_parse_float(raw), 0.0, 1.0))
    end
    isempty(vals) && push!(vals, clamp(fallback, 0.0, 1.0))
    out = Float64[]
    fallback_val = vals[end]
    for i in 1:target_len
      push!(out, i <= length(vals) ? vals[i] : fallback_val)
    end
    return out
  end
  function _normalize_signed_unit_series(raw, n::Int; fallback::Float64=0.0)::Vector{Float64}
    target_len = max(n, 0)
    target_len == 0 && return Float64[]
    vals = Float64[]
    if raw isa AbstractVector
      for x in raw
        push!(vals, clamp(_parse_float(x), -1.0, 1.0))
      end
    elseif raw !== nothing
      push!(vals, clamp(_parse_float(raw), -1.0, 1.0))
    end
    isempty(vals) && push!(vals, clamp(fallback, -1.0, 1.0))
    out = Float64[]
    fallback_val = vals[end]
    for i in 1:target_len
      push!(out, i <= length(vals) ? vals[i] : fallback_val)
    end
    return out
  end

  tie_cluster_param_keys = (
    "tie_global_complexity_target",
    "tie_stream_complexity_center",
    "tie_stream_complexity_span",
    "tie_concordance",
    "tie_value_target",
    "tie_value_radius",
    "tie_rate_target", # backward-compatible alias for tie_value_target
  )
  clustered_tie_enabled = any(haskey(gp, key) for key in tie_cluster_param_keys)

  # Legacy requests retain deterministic center±spread/2 distribution. New
  # Canonical tie parameters opt into clustered three-level generation.
  tie_center_raw = get(gp, "tie_center", nothing)
  tie_spread_raw = get(gp, "tie_spread", nothing)
  tie_center_series = _normalize_unit_series(tie_center_raw, length(stream_counts); fallback=0.0)
  tie_spread_series = _normalize_unit_series(tie_spread_raw, length(stream_counts); fallback=0.0)
  tie_global_complexity_series = _normalize_unit_series(get(gp, "tie_global_complexity_target", nothing), length(stream_counts); fallback=0.0)
  tie_stream_center_series = _normalize_unit_series(get(gp, "tie_stream_complexity_center", nothing), length(stream_counts); fallback=0.0)
  tie_stream_span_series = _normalize_unit_series(get(gp, "tie_stream_complexity_span", nothing), length(stream_counts); fallback=0.0)
  tie_concordance_series = _normalize_signed_unit_series(get(gp, "tie_concordance", nothing), length(stream_counts); fallback=0.0)
  voice_global_complexity_series = _normalize_unit_series(get(gp, "voice_token_global_complexity_target", nothing), length(stream_counts); fallback=0.0)
  voice_stream_center_series = _normalize_unit_series(get(gp, "voice_token_stream_complexity_center", nothing), length(stream_counts); fallback=0.0)
  voice_stream_span_series = _normalize_unit_series(get(gp, "voice_token_stream_complexity_span", nothing), length(stream_counts); fallback=0.0)
  voice_concordance_series = _normalize_signed_unit_series(get(gp, "voice_token_concordance", nothing), length(stream_counts); fallback=0.0)
  voice_transition_series = _normalize_unit_series(get(gp, "voice_transition_weight", nothing), length(stream_counts); fallback=0.0)
  initial_step_durations = _step_durations_from_bpm_series(initial_context_bpm)
  future_step_durations = _step_durations_from_bpm_series(future_bpm)
  initial_step_onsets = _step_onsets_from_durations(initial_step_durations)
  future_step_onsets = _step_onsets_from_durations(future_step_durations)
  base_onset = isempty(initial_step_durations) ? 0.0 : sum(initial_step_durations)
  future_step_onsets = Float64[base_onset + onset for onset in future_step_onsets]
  bpm_series = vcat(initial_context_bpm, future_bpm)
  step_durations = vcat(initial_step_durations, future_step_durations)

  # Indices for NEW format
  note_abs_idx    = 1
  vol_idx         = 2
  brightness_idx  = 3
  noise_idx = 4
  harmonicity_idx   = 5
  attack_idx   = 6
  decay_sustain_idx = 7
  release_idx = 8
  chord_range_idx = 9
  density_idx     = 10
  tie_idx         = 11

  # --- MIDI range (keep consistent across AREA/tmp_anchor and NOTE) ---
  ABS_MIN = Int(Config.abs_pitch_min())
  ABS_MAX = Int(Config.abs_pitch_max())

  BAND_SIZE = Config.AREA_BAND_SIZE
  BAND_LOW_MIN = Config.area_band_low_min()
  BAND_LOW_MAX = Config.area_band_low_max()
  BAND_WIDTH  = max(float(BAND_LOW_MAX - BAND_LOW_MIN), 1.0)
  CHORD_RANGE_MIN = Config.CHORD_RANGE_VALUE_MIN
  CHORD_RANGE_MAX = Config.CHORD_RANGE_VALUE_MAX

  function _canonical_dim_key(raw_key)::Union{Nothing,String}
    s = lowercase(strip(string(raw_key)))
    s in ("area",) && return "area"
    s in ("chord_range",) && return "chord_range"
    s in ("density",) && return "density"
    s in ("vol",) && return "vol"
    s in ("brightness",) && return "brightness"
    s in ("noise",) && return "noise"
    s in ("harmonicity",) && return "harmonicity"
    s in ("attack",) && return "attack"
    s in ("decay_sustain",) && return "decay_sustain"
    s in ("release",) && return "release"
    return nothing
  end

  function _normalize_fixed_value_for_dim(key::String, raw)
    if key == "chord_range"
      return float(clamp(_parse_int(raw), CHORD_RANGE_MIN, CHORD_RANGE_MAX))
    elseif key == "area" || key == "density" || key == "vol" || key == "brightness" || key == "noise" || key == "harmonicity" || key == "attack" || key == "decay_sustain" || key == "release"
      return clamp(_parse_float(raw), 0.0, 1.0)
    else
      return _parse_float(raw)
    end
  end

  managed_dims = ["area", "chord_range", "density", "vol", "brightness", "noise", "harmonicity", "attack", "decay_sustain", "release"]
  dim_accept = Dict{String,Bool}()
  dim_fixed = Dict{String,Float64}()
  dim_fixed_source = Dict{String,String}()

  function _normalize_fixed_value_source(raw)::String
    s = lowercase(strip(string(raw)))
    s in ("initial_context_last_step", "initial_context", "context_last_step", "last_step", "last-step") && return "initial_context_last_step"
    return "manual_input"
  end

  # Internal default policy:
  # - sound/timbre dimensions: disabled by default to reduce clustering/search cost in pitch-focused experiments
  # - others: enabled
  default_dim_policy = Dict{String,Dict{String,Any}}(
    "area" => Dict("accept_params" => false,  "fixed_value" => 0.5),
    "chord_range" => Dict("accept_params" => false, "fixed_value" => 0.0),
    "density" => Dict("accept_params" => false, "fixed_value" => 0.0),
    "vol" => Dict("accept_params" => true, "fixed_value" => 1.0),
    "brightness" => Dict("accept_params" => false, "fixed_value" => 0.5),
    "noise" => Dict("accept_params" => false, "fixed_value" => 0.5),
    "harmonicity" => Dict("accept_params" => false, "fixed_value" => 0.5),
    "attack" => Dict("accept_params" => false, "fixed_value" => 0.5),
    "decay_sustain" => Dict("accept_params" => false, "fixed_value" => 0.5),
    "release" => Dict("accept_params" => false, "fixed_value" => 0.5),
  )
  for key in managed_dims
    d = default_dim_policy[key]
    dim_accept[key] = _parse_bool(get(d, "accept_params", true), true)
    dim_fixed[key] = _normalize_fixed_value_for_dim(key, get(d, "fixed_value", 0.0))
    dim_fixed_source[key] = "manual_input"
  end

  # Optional request-time override:
  # generate_polyphonic.dimension_policy = {
  #   vol: { accept_params: false, fixed_value: 1.0 }, cr: {...}, den: {...}, ...
  # }
  # generate_polyphonic.default_dim_policy also works as an alias.
  raw_dim_policy_src = get(gp, "dimension_policy", get(gp, "default_dim_policy", nothing))
  raw_dim_policy = _to_string_dict(raw_dim_policy_src)
  for (raw_key, raw_val) in raw_dim_policy
    key = _canonical_dim_key(raw_key)
    key === nothing && continue

    if raw_val isa AbstractDict
      p = _to_string_dict(raw_val)
      accept_src =
        haskey(p, "accept_params") ? p["accept_params"] :
        haskey(p, "receive_params") ? p["receive_params"] :
        haskey(p, "enabled") ? p["enabled"] :
        haskey(p, "use_user_params") ? p["use_user_params"] : nothing
      source_src =
        haskey(p, "fixed_value_source") ? p["fixed_value_source"] :
        haskey(p, "fixed_source") ? p["fixed_source"] :
        haskey(p, "value_source") ? p["value_source"] : nothing
      fixed_src =
        haskey(p, "fixed_value") ? p["fixed_value"] :
        haskey(p, "fallback_value") ? p["fallback_value"] :
        haskey(p, "value") ? p["value"] : nothing

      if accept_src !== nothing
        dim_accept[key] = _parse_bool(accept_src, dim_accept[key])
      end
      if source_src !== nothing
        dim_fixed_source[key] = _normalize_fixed_value_source(source_src)
      end
      if fixed_src !== nothing
        dim_fixed[key] = _normalize_fixed_value_for_dim(key, fixed_src)
      end
    elseif raw_val isa Bool
      dim_accept[key] = raw_val
    elseif raw_val !== nothing
      dim_fixed[key] = _normalize_fixed_value_for_dim(key, raw_val)
    end
  end

  function _anchor_from_stream(st::Vector{Any})::Int
    if length(st) >= note_abs_idx && st[note_abs_idx] isa AbstractVector
      abs_notes = Int[]
      for v in st[note_abs_idx]
        push!(abs_notes, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
      end
      if !isempty(abs_notes)
        sort!(abs_notes)
        return abs_notes[cld(length(abs_notes), 2)]
      end
    end
    return Int(Config.abs_pitch_min())
  end

  function _fixed_area_band_low_for_stream(stream_idx::Int)::Int
    if get(dim_fixed_source, "area", "manual_input") == "initial_context_last_step"
      last_step = isempty(results) ? Vector{Vector{Any}}() : results[end]
      if 1 <= stream_idx <= length(last_step)
        anchor = _anchor_from_stream(last_step[stream_idx])
        return Config.area_band_low(anchor)
      end
    end

    v01 = clamp(dim_fixed["area"], 0.0, 1.0)
    n_bins = max(Int(fld(BAND_LOW_MAX - BAND_LOW_MIN, BAND_SIZE)), 0)
    idx = clamp(round(Int, v01 * n_bins), 0, n_bins)
    return clamp(BAND_LOW_MIN + (idx * BAND_SIZE), BAND_LOW_MIN, BAND_LOW_MAX)
  end

  function _resolved_fixed_value_for_stream(key::String, stream_idx::Int)::Float64
    if get(dim_fixed_source, key, "manual_input") != "initial_context_last_step"
      return dim_fixed[key]
    end

    if key == "area"
      band_low = _fixed_area_band_low_for_stream(stream_idx)
      n_bins = max(Int(fld(BAND_LOW_MAX - BAND_LOW_MIN, BAND_SIZE)), 0)
      n_bins <= 0 && return 0.0
      idx = clamp(Int(fld(band_low - BAND_LOW_MIN, BAND_SIZE)), 0, n_bins)
      return clamp(float(idx) / float(n_bins), 0.0, 1.0)
    end

    idx =
      key == "vol" ? vol_idx :
      key == "brightness" ? brightness_idx :
      key == "noise" ? noise_idx :
      key == "harmonicity" ? harmonicity_idx :
      key == "attack" ? attack_idx :
      key == "decay_sustain" ? decay_sustain_idx :
      key == "release" ? release_idx :
      key == "chord_range" ? chord_range_idx :
      key == "density" ? density_idx : 0

    if idx == 0
      return dim_fixed[key]
    end

    last_step = isempty(results) ? Vector{Vector{Any}}() : results[end]
    if !(1 <= stream_idx <= length(last_step))
      return dim_fixed[key]
    end

    st = last_step[stream_idx]
    if length(st) < idx
      return dim_fixed[key]
    end

    return _normalize_fixed_value_for_dim(key, st[idx])
  end

  function _apply_fixed_dimension_values!(st::Vector{Any}, stream_idx::Int)
    if !get(dim_accept, "vol", true)
      st[vol_idx] = _resolved_fixed_value_for_stream("vol", stream_idx)
    end
    if !get(dim_accept, "brightness", true)
      st[brightness_idx] = _resolved_fixed_value_for_stream("brightness", stream_idx)
    end
    if !get(dim_accept, "noise", true)
      st[noise_idx] = _resolved_fixed_value_for_stream("noise", stream_idx)
    end
    if !get(dim_accept, "harmonicity", true)
      st[harmonicity_idx] = _resolved_fixed_value_for_stream("harmonicity", stream_idx)
    end
    if !get(dim_accept, "attack", true)
      st[attack_idx] = _resolved_fixed_value_for_stream("attack", stream_idx)
    end
    if !get(dim_accept, "decay_sustain", true)
      st[decay_sustain_idx] = _resolved_fixed_value_for_stream("decay_sustain", stream_idx)
    end
    if !get(dim_accept, "release", true)
      st[release_idx] = _resolved_fixed_value_for_stream("release", stream_idx)
    end
    if !get(dim_accept, "chord_range", true)
      st[chord_range_idx] = Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", stream_idx), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX))))
    end
    if !get(dim_accept, "density", true)
      st[density_idx] = _resolved_fixed_value_for_stream("density", stream_idx)
    end
    return st
  end


  function _normalize_abs_notes(x)::Vector{Int}
    out = Int[]
    if x isa AbstractVector
      for v in x
        v === nothing && continue
        push!(out, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
      end
    elseif x === nothing
      # noop
    else
      push!(out, clamp(_parse_int(x), ABS_MIN, ABS_MAX))
    end
    sort!(out)
    isempty(out) && push!(out, Int(Config.abs_pitch_min()))
    return out
  end
  function _normalize_stream!(st::Vector{Any})
    length(st) == 11 || error("generate_polyphonic.initial_context stream record must contain exactly 11 elements.")

    st[1] isa AbstractVector || error("generate_polyphonic.initial_context stream record must start with abs_notes.")
    abs_notes = _normalize_abs_notes(st[1])
    vol = clamp(_parse_float(st[2]), 0.0, 1.0)
    brightness = clamp(_parse_float(st[3]), 0.0, 1.0)
    noise = clamp(_parse_float(st[4]), 0.0, 1.0)
    harmonicity = clamp(_parse_float(st[5]), 0.0, 1.0)
    attack = clamp(_parse_float(st[6]), 0.0, 1.0)
    decay_sustain = clamp(_parse_float(st[7]), 0.0, 1.0)
    release = clamp(_parse_float(st[8]), 0.0, 1.0)
    cr = max(_parse_int(st[9]), 0)
    den = clamp(_parse_float(st[10]), 0.0, 1.0)
    tie = clamp(_parse_float(st[tie_idx]), 0.0, 1.0)

    empty!(st)
    push!(st, abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, cr, den, tie)
    return st
  end

  function _tie_render_compatible(previous::Vector{Any}, current::Vector{Any})::Bool
    previous_notes = _normalize_abs_notes(previous[note_abs_idx])
    current_notes = _normalize_abs_notes(current[note_abs_idx])
    previous_notes == current_notes || return false
    isempty(current_notes) && return false

    previous_vol = clamp(_parse_float(previous[vol_idx]), 0.0, 1.0)
    current_vol = clamp(_parse_float(current[vol_idx]), 0.0, 1.0)
    previous_vol > Config.SC_MIN_AUDIBLE_VOLUME || return false
    current_vol > Config.SC_MIN_AUDIBLE_VOLUME || return false

    # The renderer retains these controls from the first event in a tied run.
    # Only sustain/release may change because it is updated at the run tail.
    for idx in (vol_idx, brightness_idx, noise_idx, harmonicity_idx, attack_idx, decay_sustain_idx)
      isapprox(_parse_float(previous[idx]), _parse_float(current[idx]); atol=1e-9, rtol=0.0) || return false
    end
    return true
  end

  function _quantize_tie_value(raw)::Float64
    value = clamp(_parse_float(raw), 0.0, 1.0)
    return Config.TIE_STEPS[argmin(abs.(Config.TIE_STEPS .- value))]
  end

  for step in results
    for st in step
      _normalize_stream!(st)
    end
  end

  initial_context_steps = length(results)
  result_stream_ids = Vector{Int}[
    Int[stream_idx for stream_idx in 1:length(step)]
    for step in results
  ]

  # Clustered tie history contains eligible boundaries only. Initial records are
  # quantized to the three-level output here so an ineligible context boundary cannot
  # be rendered as a continuation or seed the tie managers as an ordinary OFF.
  initial_tie_stream_history = Dict{Int,Vector{Float64}}()
  initial_tie_global_history = Vector{Vector{Float64}}()
  if clustered_tie_enabled
    previous_initial_by_id = Dict{Int,Vector{Any}}()
    for step_idx in 1:length(results)
      current_initial_by_id = Dict{Int,Vector{Any}}()
      eligible_bits = Float64[]
      for (slot, stream_id) in enumerate(result_stream_ids[step_idx])
        slot <= length(results[step_idx]) || continue
        current = results[step_idx][slot]
        raw_value = _quantize_tie_value(current[tie_idx])
        previous = get(previous_initial_by_id, stream_id, nothing)
        if previous !== nothing && _tie_render_compatible(previous, current)
          current[tie_idx] = raw_value
          push!(get!(initial_tie_stream_history, stream_id, Float64[]), raw_value)
          push!(eligible_bits, raw_value)
        else
          current[tie_idx] = 0.0
        end
        current_initial_by_id[stream_id] = current
      end
      if !isempty(eligible_bits)
        push!(initial_tie_global_history, Float64[sum(eligible_bits) / float(length(eligible_bits))])
      end
      previous_initial_by_id = current_initial_by_id
    end
  end

  function _note_pool_geometry(band_low_raw::Integer, chord_range_raw::Integer)::Tuple{Int,Int,Int}
    band_low = clamp(Int(band_low_raw), BAND_LOW_MIN, BAND_LOW_MAX)
    band_high = min(band_low + (BAND_SIZE - 1), ABS_MAX)
    chord_range = clamp(Int(chord_range_raw), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
    low = clamp(band_low - chord_range, ABS_MIN, ABS_MAX)
    high = clamp(band_high + chord_range, ABS_MIN, ABS_MAX)
    return (low, high, max(high - low + 1, 1))
  end

  function _note_count_from_density(density_raw::Real, slot_count::Integer)::Int
    slots = max(Int(slot_count), 1)
    density = clamp(float(density_raw), 0.0, 1.0)
    return clamp(Int(round(density * float(slots))), 1, slots)
  end

  function _infer_chord_range_and_density_controls(abs_notes_raw)::Tuple{Int,Float64}
    notes = sort(unique(_normalize_abs_notes(abs_notes_raw)))
    isempty(notes) && return (0, 0.0)

    anchor = notes[cld(length(notes), 2)]
    band_low = Config.area_band_low(anchor)
    band_high = min(band_low + (BAND_SIZE - 1), ABS_MAX)
    chord_range = clamp(
      max(band_low - first(notes), last(notes) - band_high, 0),
      CHORD_RANGE_MIN,
      CHORD_RANGE_MAX,
    )
    _low, _high, slot_count = _note_pool_geometry(band_low, chord_range)
    target_note_count = clamp(length(notes), 1, slot_count)
    density = clamp(float(target_note_count) / float(slot_count), 0.0, 1.0)
    return (chord_range, density)
  end

  # CR/DEN are canonical per-stream generation controls. The frontend does not
  # expose them in initial-context rows, so infer compatible seed controls from
  # the notes while preserving the strict 11-element record contract.
  for step_idx in 1:initial_context_steps
    step = results[step_idx]
    for st in step
      abs_notes = _normalize_abs_notes(st[note_abs_idx])
      st[note_abs_idx] = abs_notes
      inferred_cr, inferred_den = _infer_chord_range_and_density_controls(abs_notes)
      st[chord_range_idx] = inferred_cr
      st[density_idx] = inferred_den
    end
  end

  merge_threshold_ratio = _parse_float(get(gp, "merge_threshold_ratio", Config.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO))
  min_window = Config.POLYPHONIC_MIN_WINDOW_SIZE

  function pad_history!(mat, fallback_row)
    if length(mat) < (min_window + 1)
      last_row = !isempty(mat) ? deepcopy(mat[end]) : deepcopy(fallback_row)
      for _ in 1:((min_window + 1) - length(mat))
        push!(mat, deepcopy(last_row))
      end
    end
    return mat
  end

  function pad_series!(ser::Vector{Vector{Float64}}, fallback::Vector{Float64})
    if length(ser) < (min_window + 1)
      last_row = !isempty(ser) ? deepcopy(ser[end]) : deepcopy(fallback)
      for _ in 1:((min_window + 1) - length(ser))
        push!(ser, deepcopy(last_row))
      end
    end
    return ser
  end

  function _anchor_from_abs(abs_notes)::Int
    if abs_notes isa AbstractVector && !isempty(abs_notes)
      s = sort(Int[_parse_int(x) for x in abs_notes])
      return clamp(s[cld(length(s), 2)], ABS_MIN, ABS_MAX)
    else
      return Int(Config.abs_pitch_min())
    end
  end

  function _restrict_area_anchors_by_register_window(
    anchors::Vector{Int},
    register_center::Float64,
    allowance::Float64
  )::Vector{Int}
    isempty(anchors) && return Int[]

    filtered = Int[]
    best_anchor = anchors[1]
    best_distance = Inf
    band_center_offset = float(BAND_SIZE - 1) / 2.0

    for anchor in anchors
      dist = abs((float(anchor) + band_center_offset) - register_center)
      if dist < best_distance - 1e-12
        best_distance = dist
        best_anchor = anchor
      end
      if dist <= allowance + 1e-9
        push!(filtered, anchor)
      end
    end

    if isempty(filtered)
      return Int[best_anchor]
    end

    return filtered
  end

  function _global_anchor_from_step(step)::Int
    alln = Int[]
    for st in step
      abs_notes = st[note_abs_idx]
      if abs_notes isa AbstractVector
        for v in abs_notes
          push!(alln, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
        end
      end
    end
    isempty(alln) && push!(alln, Int(Config.abs_pitch_min()))
    sort!(alln)
    return alln[cld(length(alln), 2)]
  end

  # ----------------------------------------------------------
  # Histories
  # ----------------------------------------------------------
  function matrix_for_idx(idx::Int)
    return [ [ (length(st) >= idx ? st[idx] : 0) for st in step ] for step in results ]
  end

  hist_vol          = matrix_for_idx(vol_idx)
  hist_brightness   = matrix_for_idx(brightness_idx)
  hist_noise = matrix_for_idx(noise_idx)
  hist_harmonicity    = matrix_for_idx(harmonicity_idx)
  hist_attack    = matrix_for_idx(attack_idx)
  hist_decay_sustain  = matrix_for_idx(decay_sustain_idx)
  hist_release  = matrix_for_idx(release_idx)
  hist_cr           = matrix_for_idx(chord_range_idx)
  hist_den          = matrix_for_idx(density_idx)

  hist_note_anchor = Vector{Vector{Int}}()
  note_global_series = Vector{Vector{Float64}}()

  for step in results
    row = Int[]
    for st in step
      push!(row, _anchor_from_abs(st[note_abs_idx]))
    end
    push!(hist_note_anchor, row)
    push!(note_global_series, Float64[float(_global_anchor_from_step(step))])
  end

    # area(tmp_anchor) history: 4-semitone band base (0..124)
  hist_area_tmp_anchor = Vector{Vector{Int}}()
  for row in hist_note_anchor
    tmp = Int[]
    for a in row
      push!(tmp, Config.area_band_low(a))
    end
    push!(hist_area_tmp_anchor, tmp)
  end


  initial_stream_count = 1
  for step in results
    initial_stream_count = max(initial_stream_count, length(step))
  end
  first_streams = initial_stream_count
  history_stream_ids = deepcopy(result_stream_ids)

  pad_history!(hist_vol,          [1.0 for _ in 1:first_streams])
  pad_history!(hist_brightness,   [0.5 for _ in 1:first_streams])
  pad_history!(hist_noise, [0.5 for _ in 1:first_streams])
  pad_history!(hist_harmonicity,    [0.5 for _ in 1:first_streams])
  pad_history!(hist_attack,    [0.5 for _ in 1:first_streams])
  pad_history!(hist_decay_sustain,  [0.5 for _ in 1:first_streams])
  pad_history!(hist_release,  [0.5 for _ in 1:first_streams])
  pad_history!(hist_cr,           [0   for _ in 1:first_streams])
  pad_history!(hist_den,          [0.0 for _ in 1:first_streams])
  pad_history!(hist_note_anchor, [Int(Config.abs_pitch_min()) for _ in 1:first_streams])
  pad_history!(hist_area_tmp_anchor, [Config.area_band_low(Config.abs_pitch_min()) for _ in 1:first_streams])
  pad_history!(history_stream_ids, collect(1:first_streams))

  pad_series!(note_global_series, Float64[float(Config.abs_pitch_min())])

  max_streams = initial_stream_count
  if !isempty(stream_counts)
    max_streams = max(max_streams, maximum(stream_counts))
  end

  stream_axis_capacity = _required_stream_axis_capacity(initial_stream_count, stream_counts)
  initial_axis_ids = Int[]
  for ids in result_stream_ids
    append!(initial_axis_ids, ids)
  end
  stream_axis = StableStreamAxis(stream_axis_capacity, initial_axis_ids)

  voice_inventory = nothing
  voice_state = nothing
  if any(count -> count > 0, voice_stream_counts)
    inventory_id = strip(string(get(gp, "voice_inventory_id", "ja_voicevox_all")))
    occursin(r"^[A-Za-z0-9_-]+$", inventory_id) || error(
      "generate_polyphonic.voice_inventory_id may contain only letters, digits, underscore, and hyphen.",
    )
    inventory_dir = normpath(joinpath(@__DIR__, "..", "..", "config", "voice_inventories"))
    inventory_path = joinpath(inventory_dir, "$(inventory_id).json")
    voice_inventory = VoiceTokenGeneration.load_inventory(inventory_path)
    voice_inventory.id == inventory_id || error(
      "Voice inventory id $(voice_inventory.id) does not match requested id $(inventory_id).",
    )
    voice_state = VoiceTokenGeneration.VoiceTokenState(
      voice_inventory,
      unique(initial_axis_ids),
      merge_threshold_ratio,
      min_window,
    )
  end

  voice_plan = Vector{Vector{Any}}()
  initial_voice_plan = get(gp, "initial_context_voice_plan", Any[])
  for (step_idx, ids) in enumerate(result_stream_ids)
    step_plan = Any[]
    for (slot, stream_id) in enumerate(ids)
      notes = slot <= length(results[step_idx]) ? copy(results[step_idx][slot][note_abs_idx]) : Int[]
      initial_voice_entry = nothing
      if step_idx <= initial_context_steps && initial_voice_plan isa AbstractVector && step_idx <= length(initial_voice_plan)
        for raw_entry in initial_voice_plan[step_idx]
          try
            entry = _to_string_dict(raw_entry)
            Int(entry["streamId"]) == stream_id || continue
            initial_voice_entry = entry
            break
          catch
          end
        end
      end
      raw_initial_text = initial_voice_entry === nothing ? nothing : get(initial_voice_entry, "text", nothing)
      # A JSON null must remain an empty lyric. `string(nothing)` is the
      # literal "nothing", which was incorrectly marked as a voice token.
      initial_text = raw_initial_text === nothing ? "" : strip(string(raw_initial_text))
      lowercase(initial_text) == "nothing" && (initial_text = "")
      initial_mode = isempty(initial_text) ? "synth" : "voice"
      push!(step_plan, Dict(
        "streamId" => stream_id,
        "mode" => initial_mode,
        "token" => nothing,
        "text" => isempty(initial_text) ? nothing : initial_text,
        "phones" => String[],
        "carrierNote" => nothing,
        "notes" => notes,
      ))
    end
    push!(voice_plan, step_plan)
  end
  # Initial lyrics must seed the token managers; otherwise they are only
  # echoed in the response and have no effect on subsequent generation.
  voice_state !== nothing && VoiceTokenGeneration.seed_initial_tokens!(voice_state, voice_plan)

  # ----------------------------------------------------------
  # Managers
  # ----------------------------------------------------------
  managers = Dict{String,Dict{Symbol,Any}}()

  function _safe_width(vmin::Real, vmax::Real)::Float64
    width = abs(float(vmax) - float(vmin))
    return width <= 0.0 ? 1.0 : width
  end

  function offset_for_range(vmin::Real, vmax::Real)::Float64
    return _safe_width(vmin, vmax) + 1.0
  end

  function global_series_from_matrix(mat, id_rows, axis::StableStreamAxis, offset::Real)
    length(mat) == length(id_rows) || error(
      "Global history has $(length(mat)) value rows but $(length(id_rows)) stable-ID rows.",
    )
    series = Vector{Vector{Float64}}()
    sizehint!(series, length(mat))
    for row_idx in eachindex(mat)
      row = mat[row_idx]
      ids = id_rows[row_idx]
      length(row) == length(ids) || error(
        "Global history row $(row_idx) has $(length(row)) values but $(length(ids)) stable IDs.",
      )
      push!(series, _encode_streamwise_row(axis, ids, row, offset))
    end
    return series
  end

  function _setup_dimension_manager!(
    key::String,
    history,
    value_range;
    value_min::Real,
    value_max::Real,
    global_capacity::Int,
    track_presence::Bool=false,
  )
    offset = offset_for_range(value_min, value_max)
    observed_global_row_width = 1
    for row in history
      observed_global_row_width = max(observed_global_row_width, length(row))
    end
    global_row_width = max(Int(global_capacity), 1)
    observed_global_row_width <= global_row_width || error(
      "$(key) global history width $(observed_global_row_width) exceeds configured row capacity $(global_row_width).",
    )

    s_mgr = MultiStreamManager.Manager(
      history,
      merge_threshold_ratio,
      min_window;
      use_complexity_mapping=true,
      value_range=value_range,
      track_presence=track_presence,
      recency=0.0
    )
    encoded_max = float(value_max) + (float(stream_axis.capacity - 1) * offset)
    g_mgr = PolyphonicClusterManager.Manager(
      global_series_from_matrix(history, history_stream_ids, stream_axis, offset),
      merge_threshold_ratio,
      min_window;
      use_streamwise_surface_average=true,
      stream_axis_offset=offset,
      stream_axis_capacity=stream_axis.capacity,
      value_min=float(value_min),
      value_max=encoded_max,
      range_min=float(value_min),
      range_max=encoded_max,
      max_set_size=global_row_width,
      recency=0.0
    )
    PolyphonicClusterManager.process_data!(g_mgr)
    PolyphonicClusterManager.update_caches_permanently(g_mgr)
    managers[key] = Dict(
      :global => g_mgr,
      :stream => s_mgr,
      :global_offset => offset,
      :global_capacity => global_row_width,
      :stream_axis => stream_axis,
    )
  end

  for (key, history, track_presence) in (
    ("vol", hist_vol, true),
    ("brightness", hist_brightness, false),
    ("noise", hist_noise, false),
    ("harmonicity", hist_harmonicity, false),
    ("attack", hist_attack, false),
    ("decay_sustain", hist_decay_sustain, false),
    ("release", hist_release, false)
  )
    if get(dim_accept, key, true)
      _setup_dimension_manager!(
        key,
        history,
        key == "vol" ? Config.VOL_STEPS : Config.FLOAT_STEPS;
        value_min=0.0,
        value_max=1.0,
        global_capacity=max_streams,
        track_presence=track_presence
      )
    end
  end

  cr_values = collect(Config.CHORD_RANGE_SEARCH_RANGE)
  cr_min = float(first(Config.CHORD_RANGE_SEARCH_RANGE))
  cr_max = float(last(Config.CHORD_RANGE_SEARCH_RANGE))
  if get(dim_accept, "chord_range", true)
    _setup_dimension_manager!(
      "chord_range",
      hist_cr,
      cr_values;
      value_min=cr_min,
      value_max=cr_max,
      global_capacity=max_streams,
      track_presence=true
    )
  end

  if get(dim_accept, "density", true)
    _setup_dimension_manager!(
      "density",
      hist_den,
      Config.FLOAT_STEPS;
      value_min=0.0,
      value_max=1.0,
      global_capacity=max_streams,
      track_presence=true
    )
  end

  if clustered_tie_enabled
    tie_global_history = deepcopy(initial_tie_global_history)
    pad_series!(tie_global_history, Float64[0.0])

    tie_initial_stream_count = isempty(result_stream_ids) ? first_streams : max(length(result_stream_ids[1]), 1)
    tie_seed_history = Vector{Float64}[
      fill(0.0, tie_initial_stream_count)
      for _ in 1:(min_window + 1)
    ]
    tie_stream_mgr = MultiStreamManager.Manager(
      tie_seed_history,
      merge_threshold_ratio,
      min_window;
      use_complexity_mapping=true,
      value_range=Config.TIE_STEPS,
      track_presence=false,
      recency=0.0,
    )
    for container in tie_stream_mgr.stream_pool
      eligible_values = get(initial_tie_stream_history, container.id, Float64[])
      eligible_series = Vector{Float64}[Float64[value] for value in eligible_values]
      pad_series!(eligible_series, Float64[0.0])
      container.manager = MultiStreamManager.build_stream_manager(
        eligible_series,
        float(merge_threshold_ratio),
        min_window;
        value_min=0.0,
        value_max=1.0,
        max_set_size=1,
        recency=0.0,
      )
      container.last_value = copy(eligible_series[end])
    end
    tie_global_mgr = PolyphonicClusterManager.Manager(
      tie_global_history,
      merge_threshold_ratio,
      min_window;
      value_min=0.0,
      value_max=1.0,
      range_min=0.0,
      range_max=1.0,
      max_set_size=1,
      recency=0.0,
    )
    PolyphonicClusterManager.process_data!(tie_global_mgr)
    PolyphonicClusterManager.update_caches_permanently(tie_global_mgr)
    managers["tie"] = Dict(
      :global => tie_global_mgr,
      :stream => tie_stream_mgr,
      :global_scalar => true,
    )
  end

  area_min = float(BAND_LOW_MIN)
  area_max = float(BAND_LOW_MAX)
  _setup_dimension_manager!(
    "area",
    hist_area_tmp_anchor,
    collect(BAND_LOW_MIN:BAND_SIZE:BAND_LOW_MAX);
    value_min=area_min,
    value_max=area_max,
    global_capacity=max_streams,
    track_presence=true
  )

  # note (global: scalar anchor, stream: anchor per stream)
  note_min = float(ABS_MIN)
  note_max = float(ABS_MAX)
  s_note = MultiStreamManager.Manager(
    hist_note_anchor,
    merge_threshold_ratio,
    min_window;
    use_complexity_mapping=true,
    value_range=collect(ABS_MIN:ABS_MAX),
    track_presence=true,
    recency=0.0
  )
  g_note = PolyphonicClusterManager.Manager(
    note_global_series,
    merge_threshold_ratio,
    min_window;
    value_min=note_min,
    value_max=note_max,
    range_min=note_min,
    range_max=note_max,
    max_set_size=1,
    recency=0.0
  )
  PolyphonicClusterManager.process_data!(g_note)
  PolyphonicClusterManager.update_caches_permanently(g_note)
  managers["note"] = Dict(:global => g_note, :stream => s_note)

  function _apply_step_recency!(idx0::Int, desired_stream_count::Int)
    recency_center = clamp(_parse_float(array_param(gp, "recency_center", idx0)), 0.0, 1.0)
    recency_spread = clamp(_parse_float(array_param(gp, "recency_spread", idx0)), 0.0, 1.0)
    stream_recencies = generate_centered_targets(desired_stream_count, recency_center, recency_spread)
    global_recency = isempty(stream_recencies) ? recency_center : clamp(sum(stream_recencies) / float(length(stream_recencies)), 0.0, 1.0)

    for (_key, mgrs) in managers
      g_mgr = get(mgrs, :global, nothing)
      if g_mgr !== nothing
        g_mgr.recency = global_recency
      end

      s_mgr = get(mgrs, :stream, nothing)
      if s_mgr !== nothing
        s_mgr.recency = global_recency
        actives = MultiStreamManager.active_stream_containers(s_mgr, desired_stream_count)
        for c in s_mgr.stream_pool
          c.manager.recency = global_recency
        end
        for (i, c) in enumerate(actives)
          r = i <= length(stream_recencies) ? stream_recencies[i] : global_recency
          c.manager.recency = clamp(r, 0.0, 1.0)
        end
      end
    end

    return nothing
  end

  # ----------------------------------------------------------
  # Dissonance STM seed
  # ----------------------------------------------------------
  stm_mgr = DissonanceStmManager.Manager(
    memory_span=Config.DISSONANCE_STM_MEMORY_SPAN,
    memory_weight=Config.DISSONANCE_STM_MEMORY_WEIGHT,
    n_partials=Config.DISSONANCE_STM_N_PARTIALS,
    amp_profile=Config.DISSONANCE_STM_AMP_PROFILE
  )

  for (i, step) in enumerate(results)
    midi_notes = Int[]
    amps = Float64[]
    for st in step
      abs_notes = _normalize_abs_notes(st[note_abs_idx])
      vol = clamp(_parse_float(st[vol_idx]), 0.0, 1.0)
      a_each = isempty(abs_notes) ? vol : (vol / float(length(abs_notes)))
      for n in abs_notes
        push!(midi_notes, n)
        push!(amps, a_each)
      end
    end
    onset = i <= length(initial_step_onsets) ? initial_step_onsets[i] : base_onset
    DissonanceStmManager.commit!(stm_mgr, midi_notes, amps, onset)
  end

  function _tie_concordance_cost(values::Vector{Float64}, raw_concordance::Real)::Float64
    m = length(values)
    m < 2 && return 0.0
    pairwise_distance = 0.0
    pair_count = 0
    for i in 1:(m - 1), j in (i + 1):m
      pairwise_distance += abs(values[i] - values[j])
      pair_count += 1
    end
    disagreement01 = pair_count > 0 ? clamp(pairwise_distance / float(pair_count), 0.0, 1.0) : 0.0
    concordance = clamp(float(raw_concordance), -1.0, 1.0)
    if concordance > 0.0
      return concordance * disagreement01
    elseif concordance < 0.0
      return abs(concordance) * (1.0 - disagreement01)
    end
    return 0.0
  end

  previous_step_by_id = Dict{Int,Vector{Any}}()
  if clustered_tie_enabled
    for step_idx in 1:length(results)
      current_by_id = Dict{Int,Vector{Any}}()
      ids = result_stream_ids[step_idx]
      for (slot, stream_id) in enumerate(ids)
        slot <= length(results[step_idx]) || continue
        current = results[step_idx][slot]
        current_by_id[stream_id] = current
        previous = get(previous_step_by_id, stream_id, nothing)
        if previous !== nothing && _tie_render_compatible(previous, current)
          current[tie_idx] = _quantize_tie_value(current[tie_idx])
        end
      end
      previous_step_by_id = current_by_id
    end
  elseif !isempty(results)
    previous_step_by_id = Dict{Int,Vector{Any}}(
      stream_id => results[end][slot]
      for (slot, stream_id) in enumerate(result_stream_ids[end])
      if slot <= length(results[end])
    )
  end

  steps_to_generate = length(stream_counts)
  base_step_index = length(results)
  flush(stdout)

  function _recent_register_center_for_stream(note_stream_mgr, stream_id::Int)::Float64
    stream = get(note_stream_mgr.containers_by_id, stream_id, nothing)
    stream === nothing && error("Active note stream ID $(stream_id) has no container.")
    anchors = Int[]
    recent_steps = max(Int(Config.NOTE_REGISTER_MEMORY_STEPS), 1)
    data_len = length(stream.manager.data)
    start_idx = max(data_len - recent_steps + 1, 1)

    for i in start_idx:data_len
      value = stream.manager.data[i]
      isempty(value) && continue
      push!(anchors, clamp(round(Int, value[1]), ABS_MIN, ABS_MAX))
    end

    if isempty(anchors)
      return isempty(stream.last_value) ? float(ABS_MIN) : clamp(float(stream.last_value[1]), float(ABS_MIN), float(ABS_MAX))
    end

    sort!(anchors)
    return float(anchors[cld(length(anchors), 2)])
  end

  function _restrict_candidates_with_target_window(
    key::String,
    search_values::Vector{Float64},
    idx0::Int
  )::Vector{Float64}
    if !(key == "vol" || key == "brightness" || key == "noise" || key == "harmonicity" || key == "attack" || key == "decay_sustain" || key == "release" || key == "chord_range" || key == "density" || key == "tie")
      return search_values
    end

    isempty(search_values) && return search_values

    target_raw = array_param_alias(
      gp,
      idx0,
      "$(key)_value_target",
      "$(key)_target",
    )
    if key == "tie" && target_raw === nothing
      # Old params.json files used rate terminology. Treat that value as the
      # canonical three-level value target when loading them.
      target_raw = array_param(gp, "tie_rate_target", idx0)
    end
    spread_raw = array_param_alias(
      gp,
      idx0,
      "$(key)_value_radius",
      "$(key)_target_spread",
    )
    if key == "tie" && spread_raw === nothing && haskey(gp, "tie_rate_target")
      spread_raw = 0.0
    end
    if target_raw === nothing && spread_raw === nothing
      return search_values
    end

    vmin = minimum(search_values)
    vmax = maximum(search_values)
    default_target = (vmin + vmax) / 2.0
    default_spread = (vmax - vmin)

    target = clamp(_parse_float(target_raw === nothing ? default_target : target_raw), vmin, vmax)
    spread = abs(_parse_float(spread_raw === nothing ? default_spread : spread_raw))

    low = clamp(target - spread, vmin, vmax)
    high = clamp(target + spread, vmin, vmax)

    filtered = Float64[v for v in search_values if v >= (low - 1e-9) && v <= (high + 1e-9)]
    if !isempty(filtered)
      return filtered
    end

    nearest_idx = 1
    nearest_dist = Inf
    for (i, v) in enumerate(search_values)
      d = abs(v - target)
      if d < nearest_dist
        nearest_dist = d
        nearest_idx = i
      end
    end
    return Float64[search_values[nearest_idx]]
  end

  function _metric_weights_for_dimension(
    key::String,
    idx0::Int,
    scope::String
  )::NTuple{3,Float64}
    scope_l = lowercase(scope)
    scope_l in ("global", "stream") || error("scope must be global or stream")

    d_raw = array_param(gp, "$(key)_$(scope_l)_dist_weight", idx0)
    q_raw = array_param(gp, "$(key)_$(scope_l)_qty_weight", idx0)
    c_raw = array_param(gp, "$(key)_$(scope_l)_comp_weight", idx0)

    d_raw === nothing && (d_raw = array_param(gp, "$(key)_$(scope_l)_distance_weight", idx0))
    q_raw === nothing && (q_raw = array_param(gp, "$(key)_$(scope_l)_quantity_weight", idx0))
    c_raw === nothing && (c_raw = array_param(gp, "$(key)_$(scope_l)_complexity_weight", idx0))

    d_raw === nothing && (d_raw = array_param(gp, "$(scope_l)_dist_weight", idx0))
    q_raw === nothing && (q_raw = array_param(gp, "$(scope_l)_qty_weight", idx0))
    c_raw === nothing && (c_raw = array_param(gp, "$(scope_l)_comp_weight", idx0))

    d_raw === nothing && (d_raw = array_param(gp, "$(scope_l)_distance_weight", idx0))
    q_raw === nothing && (q_raw = array_param(gp, "$(scope_l)_quantity_weight", idx0))
    c_raw === nothing && (c_raw = array_param(gp, "$(scope_l)_complexity_weight", idx0))

    d = d_raw === nothing ? 1.0 : _parse_float(d_raw)
    q = q_raw === nothing ? 1.0 : _parse_float(q_raw)
    c = c_raw === nothing ? 1.0 : _parse_float(c_raw)

    return _normalize_metric_weights(d, q, c)
  end

  # ----------------------------------------------------------
  # Main generation loop
  # ----------------------------------------------------------
  for step_idx in 1:steps_to_generate
    committed_step_state = (
      managers=managers,
      stm_mgr=stm_mgr,
      stream_axis=stream_axis,
      voice_state=voice_state,
    )
    staged_step_state = _stage_generate_polyphonic_step_state(managers, stm_mgr, stream_axis, voice_state)
    managers = staged_step_state.managers
    stm_mgr = staged_step_state.stm_mgr
    stream_axis = staged_step_state.stream_axis
    voice_state = staged_step_state.voice_state

    results_len_before_step = length(results)
    stream_ids_len_before_step = length(result_stream_ids)
    voice_plan_len_before_step = length(voice_plan)
    previous_step_by_id_before = deepcopy(previous_step_by_id)
    failure_context = Dict{Symbol,Any}(
      :operation => "step_setup",
      :dimension => nothing,
      :stream_id => nothing,
      :candidate => nothing,
    )

    try
    desired_stream_count = max(stream_counts[step_idx], 1)
    desired_stream_count <= max_streams || error(
      "Requested $(desired_stream_count) streams exceeds global capacity $(max_streams).",
    )

    st_target = step_idx <= length(strength_targets) ? strength_targets[step_idx] : Config.DEFAULT_TARGET_01
    st_spread = step_idx <= length(strength_spreads) ? strength_spreads[step_idx] : Config.DEFAULT_SPREAD_01

    lifecycle_mgr = haskey(managers, "vol") ? managers["vol"][:stream] : managers["note"][:stream]
    _set_generation_failure_context!(failure_context; operation="lifecycle_plan")
    plan = MultiStreamManager.build_stream_lifecycle_plan(lifecycle_mgr, desired_stream_count; target=st_target, spread=st_spread)
    length(plan.active_ids) == desired_stream_count || error(
      "Lifecycle planned $(length(plan.active_ids)) active streams; expected $(desired_stream_count).",
    )
    length(unique(plan.active_ids)) == length(plan.active_ids) || error(
      "Lifecycle returned duplicate active stream IDs: $(plan.active_ids).",
    )
    _register_stream_ids!(stream_axis, plan.active_ids)

    # Apply one canonical ID order to every dimension before any recency,
    # candidate evaluation, or commit. Inspect active_ids directly here because
    # active_stream_containers() may resize that list as part of its API.
    for (manager_key, mgrs) in managers
      stream_mgr = mgrs[:stream]
      _set_generation_failure_context!(
        failure_context;
        operation="lifecycle_apply",
        dimension=manager_key,
      )
      MultiStreamManager.apply_stream_lifecycle_plan!(stream_mgr, plan)
      stream_mgr.active_ids == plan.active_ids || error(
        "$(manager_key) active stream IDs $(stream_mgr.active_ids) do not match lifecycle IDs $(plan.active_ids).",
      )
      missing_ids = Int[id for id in plan.active_ids if !haskey(stream_mgr.containers_by_id, id)]
      isempty(missing_ids) || error(
        "$(manager_key) has no containers for active stream IDs $(missing_ids).",
      )
    end
    idx0 = step_idx - 1
    _set_generation_failure_context!(failure_context; operation="apply_recency")
    _apply_step_recency!(idx0, desired_stream_count)
    step_stream_order = stream_priority_order(lifecycle_mgr, desired_stream_count)
    requested_voice_count = voice_stream_counts[step_idx]
    voice_ids = Int[]
    if voice_state !== nothing
      VoiceTokenGeneration.apply_lifecycle!(voice_state, plan)
      voice_ids = VoiceTokenGeneration.select_voice_ids!(
        voice_state,
        copy(plan.active_ids),
        requested_voice_count,
        step_stream_order,
      )
    end
    tie_values = if clustered_tie_enabled
      fill(0.0, desired_stream_count)
    else
      tie_center = step_idx <= length(tie_center_series) ? tie_center_series[step_idx] : 0.0
      tie_spread = step_idx <= length(tie_spread_series) ? tie_spread_series[step_idx] : 0.0
      [_quantize_tie_value(value) for value in generate_centered_targets(desired_stream_count, tie_center, tie_spread)]
    end

    current_step_values = [
      Any[
        Int[],
        clamp(_resolved_fixed_value_for_stream("vol", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("brightness", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("noise", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("harmonicity", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("attack", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("decay_sustain", s_i), 0.0, 1.0),
        clamp(_resolved_fixed_value_for_stream("release", s_i), 0.0, 1.0),
        Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", s_i), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))),
        clamp(_resolved_fixed_value_for_stream("density", s_i), 0.0, 1.0),
        tie_values[s_i]
      ] for s_i in 1:desired_stream_count
    ]
    step_decisions = Dict{String,Any}()

    vol_search_values = Float64[float(v) for v in Config.VOL_STEPS]
    density_search_values = Float64[float(v) for v in Config.FLOAT_STEPS]
    chord_range_search_values = Float64[float(v) for v in cr_values]

    dim_order = [
      ("vol",         vol_search_values,         vol_idx),
      ("chord_range", chord_range_search_values, chord_range_idx),
      ("density",     density_search_values,     density_idx),
      ("brightness",   Float64[float(v) for v in Config.FLOAT_STEPS], brightness_idx),
      ("noise", Float64[float(v) for v in Config.FLOAT_STEPS], noise_idx),
      ("harmonicity",    Float64[float(v) for v in Config.FLOAT_STEPS], harmonicity_idx),
      ("attack",    Float64[float(v) for v in Config.FLOAT_STEPS], attack_idx),
      ("decay_sustain",  Float64[float(v) for v in Config.FLOAT_STEPS], decay_sustain_idx),
      ("release",  Float64[float(v) for v in Config.FLOAT_STEPS], release_idx),
    ]

    for (key, range_vec, out_idx) in dim_order
      _set_generation_failure_context!(
        failure_context;
        operation="dimension_prepare",
        dimension=key,
      )
      if !get(dim_accept, key, true)
        fixed_vals = Float64[]
        sizehint!(fixed_vals, desired_stream_count)
        for s_i in 1:desired_stream_count
          fixed_v =
            if key == "chord_range"
              float(Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", s_i), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))))
            else
                clamp(_resolved_fixed_value_for_stream(key, s_i), 0.0, 1.0)
              end
          push!(fixed_vals, float(fixed_v))
        end
        step_decisions[key] = fixed_vals
        for s_i in 1:desired_stream_count
          if key == "chord_range"
            current_step_values[s_i][out_idx] = Int(round(fixed_vals[s_i]))
          else
            current_step_values[s_i][out_idx] = fixed_vals[s_i]
          end
        end
        continue
      end

      mgrs = get(managers, key, nothing)
      mgrs === nothing && error("managers[\"$(key)\"] is missing while the dimension is enabled.")

      g_target = clamp(_parse_float(array_param_alias(gp, idx0, "$(key)_global_complexity_target", "$(key)_global")), 0.0, 1.0)
      s_center = clamp(_parse_float(array_param_alias(gp, idx0, "$(key)_stream_complexity_center", "$(key)_center")), 0.0, 1.0)
      s_spread = clamp(_parse_float(array_param_alias(gp, idx0, "$(key)_stream_complexity_span", "$(key)_spread")), 0.0, 1.0)
      conc_w   = _parse_float(array_param_alias(gp, idx0, "$(key)_concordance", "$(key)_conc"))
      global_metric_weights = _metric_weights_for_dimension(key, idx0, "global")
      stream_metric_weights = _metric_weights_for_dimension(key, idx0, "stream")

      stream_targets = generate_centered_targets(desired_stream_count, s_center, s_spread)

      restricted_range = _restrict_candidates_with_target_window(key, range_vec, idx0)
      isempty(restricted_range) && (restricted_range = range_vec)

      use_global_score = !(key == "vol" && desired_stream_count > 1)

      best_vals = select_best_values_for_dimension_greedy(
        mgrs,
        Float64[float(v) for v in restricted_range],
        g_target,
        stream_targets,
        conc_w,
        desired_stream_count;
        global_metric_weights=global_metric_weights,
        stream_metric_weights=stream_metric_weights,
        use_global_score=use_global_score,
        priority_order=step_stream_order,
        trace_context=failure_context,
        evaluation_budget=evaluation_budget,
      )

      # Commit the canonical stable-ID global row used by candidate evaluation.
      g_offset = get(mgrs, :global_offset, 0.0)
      global_vals = _encode_streamwise_row(stream_axis, plan.active_ids, best_vals, g_offset)
      _set_generation_failure_context!(failure_context; operation="commit_global", dimension=key, candidate=copy(best_vals))
      PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], global_vals)
      _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension=key, candidate=copy(best_vals))
      PolyphonicClusterManager.update_caches_permanently(mgrs[:global])

      _set_generation_failure_context!(failure_context; operation="commit_streams", dimension=key, candidate=copy(best_vals))
      if key == "vol"
        MultiStreamManager.commit_state!(mgrs[:stream], best_vals, (target=st_target, spread=st_spread))
      else
        MultiStreamManager.commit_state!(mgrs[:stream], best_vals)
      end
      _set_generation_failure_context!(failure_context; operation="commit_stream_caches", dimension=key, candidate=copy(best_vals))
      MultiStreamManager.update_caches_permanently!(mgrs[:stream])

      step_decisions[key] = best_vals

      for s_i in 1:desired_stream_count
        if key == "chord_range"
          current_step_values[s_i][out_idx] = Int(trunc(best_vals[s_i]))
        else
          current_step_values[s_i][out_idx] = clamp(float(best_vals[s_i]), 0.0, 1.0)
        end
      end
    end

    # --------------------------------------------------------
    # NOTE generation (AREA tmp_anchor manager -> chord_range/density -> dissonance)
    #   - Evaluate/commit AREA using tmp_anchor clusters (managers["area"])
    #   - Then decide realized notes per stream by dissonance within the allowed band expanded by chord_range/density
    # --------------------------------------------------------
    area_mgrs = get(managers, "area", nothing)
    area_mgrs === nothing && error("managers[\"area\"] is missing. Please add AREA(tmp_anchor) managers before the main loop.")
    note_mgrs = managers["note"]

    # ---- AREA targets (same style as other dims) ----

    area_enabled = get(dim_accept, "area", true)
    area_fixed_target = clamp(dim_fixed["area"], 0.0, 1.0)
    area_global_target = area_enabled ? clamp(_parse_float(array_param(gp, "area_global", idx0)), 0.0, 1.0) : area_fixed_target
    area_center        = area_enabled ? clamp(_parse_float(array_param(gp, "area_center", idx0)), 0.0, 1.0) : area_fixed_target
    area_spread        = area_enabled ? clamp(_parse_float(array_param(gp, "area_spread", idx0)), 0.0, 1.0) : 0.0
    area_conc_w        = area_enabled ? _parse_float(array_param(gp, "area_conc", idx0)) : 1.0

    area_stream_targets = generate_centered_targets(desired_stream_count, area_center, area_spread)
    # Output slots follow plan.active_ids. Resolve each AREA container directly by
    # stable ID; do not use stream_pool position or a mutating active-list helper.
    stream_pool = [
      area_mgrs[:stream].containers_by_id[id]
      for id in plan.active_ids
    ]
    note_register_freedom_raw = array_param(gp, "note_register_freedom", idx0)
    note_register_freedom = clamp(_parse_float(note_register_freedom_raw === nothing ? 1.0 : note_register_freedom_raw), 0.0, 1.0)
    register_centers = Float64[]
    sizehint!(register_centers, desired_stream_count)
    for s in 1:desired_stream_count
      push!(register_centers, _recent_register_center_for_stream(note_mgrs[:stream], plan.active_ids[s]))
    end
    register_allowance = if note_register_freedom >= 1.0 - 1e-9
      float(ABS_MAX - ABS_MIN)
    elseif note_register_freedom <= 1e-9
      0.0
    else
      min_allow = float(Config.NOTE_REGISTER_MIN_ALLOWANCE)
      max_allow = float(Config.NOTE_REGISTER_MAX_ALLOWANCE)
      min_allow + (max_allow - min_allow) * note_register_freedom
    end

    # AREA is an intermediate decision (4-semitone band base). If we base the next AREA on realized notes,
    # dissonance/chord_range/density can "drag" the anchor and collapse AREA complexity.
    prev_tmp_anchors = Int[]
    sizehint!(prev_tmp_anchors, desired_stream_count)
    for s in 1:desired_stream_count
      if s <= length(stream_pool)
        lv = stream_pool[s].last_value
        a = isempty(lv) ? float(BAND_LOW_MIN) : lv[1]
        push!(prev_tmp_anchors, clamp(trunc(Int, a), BAND_LOW_MIN, BAND_LOW_MAX))
      else
        push!(prev_tmp_anchors, BAND_LOW_MIN)
      end
    end

  # ---- helper: build bin-derived tmp_anchor candidates (skip out-of-range; NO clamp-to-edge) ----
  # tmp_anchor is band_low (4-semitone band base)
  per_stream_anchor_candidates = Vector{Vector{Int}}()
  sizehint!(per_stream_anchor_candidates, desired_stream_count)

  for s in 1:desired_stream_count
    pa = prev_tmp_anchors[s]
    cand = Int[]
    seen = Set{Int}()
    for (lo, hi) in Config.AREA_MOVE_BINS
      for d in lo:hi
        a = pa + d
        # skip deltas that go out of configured MIDI range (no clamp, no sticking)
        (a < ABS_MIN || a > ABS_MAX) && continue

        # quantize to AREA band base
        band_low = Config.area_band_low(a)
        if !(band_low in seen)
          push!(cand, band_low)
          push!(seen, band_low)
        end
      end
    end

    if isempty(cand)
      # fallback: stay at current anchor's band
      push!(cand, Config.area_band_low(pa))
    end

    sort!(cand)
    if note_register_freedom < 1.0 - 1e-9
      cand = _restrict_area_anchors_by_register_window(cand, register_centers[s], register_allowance)
    end
    push!(per_stream_anchor_candidates, cand)
  end


# ---- Stage 1: prune each stream's bins using AGREEMENT of (d,q,c) ----

# NOTE:
# - Stage1 は「候補枝刈り」なので、multi-stream なら TOP>=3 を推奨
# - 1stream だけなら TOP=1 でもOK
top_bins_per_stream =
  desired_stream_count == 1 ?
  Config.AREA_TOP_BINS_PER_STREAM_SINGLE :
  Config.AREA_TOP_BINS_PER_STREAM_MULTI

per_stream_comp01 = Vector{Dict{Int,Float64}}()
top_anchors = Vector{Vector{Int}}()
sizehint!(per_stream_comp01, desired_stream_count)
sizehint!(top_anchors, desired_stream_count)

for s in 1:desired_stream_count
  sm = stream_pool[s].manager
  anchors = per_stream_anchor_candidates[s]
  stream_calibrator = build_extended_metric_calibrator(sm)
  stream_predictor = build_predictive_distribution(sm)

  raw_d = Float64[]  # avg_dist (complex when larger)
  raw_q = Float64[]  # quantity (complex when smaller)
  raw_c = Float64[]  # complexity (complex when larger)
  temporal_metrics = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
  sizehint!(raw_d, length(anchors))
  sizehint!(raw_q, length(anchors))
  sizehint!(raw_c, length(anchors))
  sizehint!(temporal_metrics, length(anchors))

  pa = prev_tmp_anchors[s]

  for a in anchors
    _consume_dimension_evaluations!(evaluation_budget, 1; context="area stage-1 candidate")
    _set_generation_failure_context!(
      failure_context;
      operation="simulate_candidate",
      dimension="area",
      stream_id=(s <= length(plan.active_ids) ? plan.active_ids[s] : nothing),
      candidate=a,
    )
    metrics =
      PolyphonicClusterManager.simulate_add_and_calculate_all_extended(sm, Float64[float(a)])

    dval = isfinite(metrics.distance) ? metrics.distance : 0.0
    qval = isfinite(metrics.quantity) ? metrics.quantity : 0.0
    cval = isfinite(metrics.complexity) ? metrics.complexity : 0.0

    push!(raw_d, dval)
    push!(raw_q, qval)
    push!(raw_c, cval)
    push!(temporal_metrics, metrics.occurrence_intervals)
  end

  predictive_scores = Float64[]
  sizehint!(predictive_scores, length(anchors))
  for (i, anchor) in enumerate(anchors)
    predictive = predictive_surprise_score(sm, stream_predictor, Float64[float(anchor)])
    push!(predictive_scores, predictive === nothing ? NaN : predictive)
  end
  scores = combine_predictive_structural_scores(
    predictive_scores,
    raw_d,
    raw_q,
    raw_c,
    temporal_metrics;
    calibrator=stream_calibrator,
  )

  m = Dict{Int,Float64}()
  for (i, a) in enumerate(anchors)
    m[a] = clamp(scores[i], 0.0, 1.0)
  end
  push!(per_stream_comp01, m)

  # rank by |score - target|
  t = area_stream_targets[s]
  prefer_big_jump = t >= 0.5

  ranked = Vector{Tuple{Float64,Float64,Int}}()  # (cost, tiebreak, anchor)
  sizehint!(ranked, length(anchors))

  for a in anchors
    cost = abs(m[a] - t)
    jump = abs(float(a) - float(pa))          # 実ジャンプ量
    tb   = prefer_big_jump ? -jump : jump     # target高いなら大ジャンプ優先
    push!(ranked, (cost, tb, a))
  end
  sort!(ranked, by=x->(x[1], x[2], x[3]))

  keep = Int[]
  for i in 1:min(top_bins_per_stream, length(ranked))
    push!(keep, ranked[i][3])
  end
  isempty(keep) && push!(keep, anchors[1])
  sort!(keep)
  push!(top_anchors, keep)

end

    # ---- Stage 2: decide AREA anchors greedily by stream priority ----
    area_gl = area_mgrs[:global]
    area_offset = float(get(area_mgrs, :global_offset, offset_for_range(area_min, area_max)))
    area_axis = get(area_mgrs, :stream_axis, nothing)
    area_axis isa StableStreamAxis || error("Missing stable stream axis for AREA global evaluation.")
    chosen_area = fill(typemin(Int), desired_stream_count)
    area_order = step_stream_order
    area_global_calibrator = build_extended_metric_calibrator(area_gl)
    area_global_predictor = build_predictive_distribution(area_gl)

    for stream_idx in area_order
      anchors = top_anchors[stream_idx]
      global_raw_d = Float64[]
      global_raw_q = Float64[]
      global_raw_c = Float64[]
      global_temporal = PolyphonicClusterManager.OccurrenceIntervalMetrics[]
      global_candidates = PolyphonicClusterManager.PolySet[]
      sizehint!(global_raw_d, length(anchors))
      sizehint!(global_raw_q, length(anchors))
      sizehint!(global_raw_c, length(anchors))
      sizehint!(global_temporal, length(anchors))

      for cand_anchor in anchors
        _consume_dimension_evaluations!(evaluation_budget, 1; context="area stage-2 candidate")
        partial_ids = Int[]
        partial_values = Float64[]
        for i in 1:desired_stream_count
          if chosen_area[i] != typemin(Int)
            push!(partial_ids, plan.active_ids[i])
            push!(partial_values, float(chosen_area[i]))
          end
        end
        push!(partial_ids, plan.active_ids[stream_idx])
        push!(partial_values, float(cand_anchor))
        enc = _encode_streamwise_row(area_axis, partial_ids, partial_values, area_offset)
        push!(global_candidates, enc)

        _set_generation_failure_context!(
          failure_context;
          operation="simulate_candidate",
          dimension="area",
          stream_id=plan.active_ids[stream_idx],
          candidate=cand_anchor,
        )
        metrics = _safe_simulate_add_and_calculate_all_extended(area_gl, enc)
        push!(global_raw_d, isfinite(metrics.distance) ? metrics.distance : 0.0)
        push!(global_raw_q, isfinite(metrics.quantity) ? metrics.quantity : 0.0)
        push!(global_raw_c, isfinite(metrics.complexity) ? metrics.complexity : 0.0)
        push!(global_temporal, metrics.occurrence_intervals)
      end

      global_predictive_scores = Float64[]
      sizehint!(global_predictive_scores, length(global_candidates))
      for i in eachindex(global_candidates)
        predictive = predictive_surprise_score(
          area_gl,
          area_global_predictor,
          global_candidates[i],
        )
        push!(global_predictive_scores, predictive === nothing ? NaN : predictive)
      end
      global_scores = combine_predictive_structural_scores(
        global_predictive_scores,
        global_raw_d,
        global_raw_q,
        global_raw_c,
        global_temporal;
        calibrator=area_global_calibrator,
      )
      prefer_big_jump = ((area_global_target + area_stream_targets[stream_idx]) / 2.0) >= 0.5
      best_anchor = anchors[1]
      best_area_cost = Inf
      best_area_tiebreak = prefer_big_jump ? -Inf : Inf

      for (i, cand_anchor) in enumerate(anchors)
        g_cost = abs(global_scores[i] - area_global_target)
        s_cost = abs(get(per_stream_comp01[stream_idx], cand_anchor, 0.0) - area_stream_targets[stream_idx])

        decided_vals = Float64[]
        for j in 1:desired_stream_count
          if chosen_area[j] != typemin(Int)
            push!(decided_vals, float(chosen_area[j]))
          end
        end
        push!(decided_vals, float(cand_anchor))

        conc_cost = 0.0
        if length(decided_vals) >= 2 && abs(area_conc_w) > 1e-12
          dist_sum = 0.0
          cnt = 0
          for a_i in 1:(length(decided_vals)-1)
            for b_i in (a_i+1):length(decided_vals)
              dist_sum += abs(decided_vals[a_i] - decided_vals[b_i])
              cnt += 1
            end
          end
          spread01 = cnt == 0 ? 0.0 : clamp((dist_sum / float(cnt)) / BAND_WIDTH, 0.0, 1.0)
          conc_cost = area_conc_w > 0 ? abs(area_conc_w) * spread01 : abs(area_conc_w) * (1.0 - spread01)
        end

        register_cost = 0.0
        if note_register_freedom < 1.0 - 1e-9
          candidate_center = float(cand_anchor) + (float(BAND_SIZE - 1) / 2.0)
          excess = max(0.0, abs(candidate_center - register_centers[stream_idx]) - register_allowance)
          register_cost = (excess / max(float(ABS_MAX - ABS_MIN), 1.0)) * (1.0 - note_register_freedom)
        end

        total = g_cost + s_cost + conc_cost + register_cost
        jump = abs(float(cand_anchor) - float(prev_tmp_anchors[stream_idx]))
        tie_ok = prefer_big_jump ? (jump > best_area_tiebreak + 1e-12) : (jump < best_area_tiebreak - 1e-12)
        if (total < best_area_cost - 1e-12) || (abs(total - best_area_cost) <= 1e-12 && tie_ok)
          best_area_cost = total
          best_anchor = cand_anchor
          best_area_tiebreak = jump
        end
      end

      chosen_area[stream_idx] = best_anchor
    end

    if !area_enabled
      chosen_area = Int[_fixed_area_band_low_for_stream(s_i) for s_i in 1:desired_stream_count]
    end

    # ---- Commit AREA(tmp_anchor) managers (NOW consistent with evaluation) ----
    # global: stable-ID stream-axis encoding
    enc_best = _encode_streamwise_row(area_axis, plan.active_ids, chosen_area, area_offset)
    _set_generation_failure_context!(failure_context; operation="commit_global", dimension="area", candidate=copy(chosen_area))
    PolyphonicClusterManager.add_data_point_permanently(area_gl, enc_best)
    _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension="area", candidate=copy(chosen_area))
    PolyphonicClusterManager.update_caches_permanently(area_gl)

    # stream: commit per-stream anchors
    chosen_area_f = Float64[float(chosen_area[s]) for s in 1:desired_stream_count]
    _set_generation_failure_context!(failure_context; operation="commit_streams", dimension="area", candidate=copy(chosen_area))
    MultiStreamManager.commit_state!(area_mgrs[:stream], chosen_area_f)
    _set_generation_failure_context!(failure_context; operation="commit_stream_caches", dimension="area", candidate=copy(chosen_area))
    MultiStreamManager.update_caches_permanently!(area_mgrs[:stream])

    # ---- Decide realized notes per stream (within band + chord_range, size by density, choose by dissonance LAST) ----
    onset = step_idx <= length(future_step_onsets) ? future_step_onsets[step_idx] : base_onset

    dis_target_raw = array_param(gp, "dissonance_target", idx0)
    target01 = dis_target_raw === nothing ? Config.DEFAULT_TARGET_01 : clamp(_parse_float(dis_target_raw), 0.0, 1.0)

    # vols for amplitude (already decided in dim_order)
    vols = Float64[clamp(_parse_float(current_step_values[s][vol_idx]), 0.0, 1.0) for s in 1:desired_stream_count]
    stream_note_pools = Vector{Vector{Int}}(undef, desired_stream_count)
    stream_note_counts = Vector{Int}(undef, desired_stream_count)
    selected_chords = [Int[] for _ in 1:desired_stream_count]

    for s in 1:desired_stream_count
      band_low = chosen_area[s]
      chord_range_val = clamp(Int(trunc(step_decisions["chord_range"][s])), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
      density_val = clamp(float(step_decisions["density"][s]), 0.0, 1.0)
      low, high, slot_count = _note_pool_geometry(band_low, chord_range_val)

      stream_note_pools[s] = collect(low:high)
      stream_note_counts[s] = _note_count_from_density(density_val, slot_count)
      if plan.active_ids[s] in voice_ids
        voice_low = max(low, Config.VOICE_NOTE_MIN)
        voice_high = min(high, Config.VOICE_NOTE_MAX)
        if voice_low <= voice_high
          stream_note_pools[s] = collect(voice_low:voice_high)
        else
          # Keep the complete singer range when AREA/CR do not overlap it.
          # A singleton fallback would force low registers to VOICE_NOTE_MIN.
          stream_note_pools[s] = collect(Config.VOICE_NOTE_MIN:Config.VOICE_NOTE_MAX)
        end
        stream_note_counts[s] = min(stream_note_counts[s], length(stream_note_pools[s]))
        stream_note_counts[s] = max(stream_note_counts[s], 1)
      end
    end

    # Dissonance selection is done on pitch-class-normalized MIDI notes so octave distance
    # does not dominate roughness ranking.
    function _pc_normalized_notes(midi_notes::Vector{Int})
      out = Int[]
      sizehint!(out, length(midi_notes))
      for n in midi_notes
        pc = mod(n, Config.STEPS_PER_OCTAVE)
        push!(out, Config.MIDI_C4 + pc)
      end
      return out
    end

    # Decide global dissonance greedily by stream priority. Each stream is
    # evaluated one added note at a time against STM plus earlier streams.
    chosen_note_flags = fill(false, desired_stream_count)
    note_order = step_stream_order
    dissonance_calibrator = build_dissonance_calibrator(stm_mgr)
    note_global_calibrator = build_extended_metric_calibrator(note_mgrs[:global])
    note_global_predictor = build_predictive_distribution(note_mgrs[:global])
    note_stream_containers = MultiStreamManager.active_stream_containers(note_mgrs[:stream], desired_stream_count)
    note_stream_calibrators = ExtendedMetricCalibrator[
      build_extended_metric_calibrator(note_stream_containers[i].manager)
      for i in 1:min(desired_stream_count, length(note_stream_containers))
    ]
    note_stream_predictors = PredictiveDistribution[
      build_predictive_distribution(note_stream_containers[i].manager)
      for i in 1:min(desired_stream_count, length(note_stream_containers))
    ]

    for stream_idx in note_order
      note_pool = stream_note_pools[stream_idx]
      if isempty(note_pool)
        selected_chords[stream_idx] = Int[chosen_area[stream_idx]]
        chosen_note_flags[stream_idx] = true
        continue
      end

      function evaluate_partial_chord(cand::Vector{Int})::Float64
        partial = Vector{Vector{Int}}()
        partial_vols = Float64[]
        for s in 1:desired_stream_count
          if chosen_note_flags[s]
            push!(partial, selected_chords[s])
            push!(partial_vols, vols[s])
          end
        end
        push!(partial, cand)
        push!(partial_vols, vols[stream_idx])

        midi_notes_all = Int[]
        amps_all = Float64[]
        for (i, chord) in enumerate(partial)
          v = partial_vols[i]
          a_each = isempty(chord) ? v : (v / float(length(chord)))
          for n in chord
            push!(midi_notes_all, n)
            push!(amps_all, a_each)
          end
        end

        eval_notes = _pc_normalized_notes(midi_notes_all)
        return float(DissonanceStmManager.evaluate(stm_mgr, eval_notes, amps_all, onset))
      end

      function evaluate_note_complexity_cost_batch(chords::Vector{Vector{Int}})::Vector{Float64}
        global_candidates = PolyphonicClusterManager.PolySet[]
        stream_candidates = PolyphonicClusterManager.PolySet[]
        global_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]
        stream_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]

        for cand in chords
          cand_anchor = float(_anchor_from_abs(cand))
        _set_generation_failure_context!(
          failure_context;
          operation="simulate_candidate",
          dimension="note",
          stream_id=(stream_idx <= length(plan.active_ids) ? plan.active_ids[stream_idx] : nothing),
          candidate=copy(cand),
        )
          partial_anchors = Float64[]
          for s in 1:desired_stream_count
            if chosen_note_flags[s]
              push!(partial_anchors, float(_anchor_from_abs(selected_chords[s])))
            end
          end
          push!(partial_anchors, cand_anchor)
          sort!(partial_anchors)
          global_anchor = partial_anchors[cld(length(partial_anchors), 2)]
          global_candidate = Float64[global_anchor]
          stream_candidate = Float64[cand_anchor]
          push!(global_candidates, global_candidate)
          push!(stream_candidates, stream_candidate)
          push!(
            global_metrics,
            _safe_simulate_add_and_calculate_all_extended(note_mgrs[:global], global_candidate),
          )
          if stream_idx <= length(note_stream_containers)
            push!(
              stream_metrics,
              _safe_simulate_add_and_calculate_all_extended(
                note_stream_containers[stream_idx].manager,
                stream_candidate,
              ),
            )
          end
        end

        predictive_global_scores = Float64[]
        for i in eachindex(global_candidates)
          predictive = predictive_surprise_score(
            note_mgrs[:global],
            note_global_predictor,
            global_candidates[i],
          )
          push!(
            predictive_global_scores,
            predictive === nothing ? NaN : predictive,
          )
        end
        global_scores = combine_predictive_structural_scores(
          predictive_global_scores,
          Float64[m.distance for m in global_metrics],
          Float64[m.quantity for m in global_metrics],
          Float64[m.complexity for m in global_metrics],
          PolyphonicClusterManager.OccurrenceIntervalMetrics[
            m.occurrence_intervals for m in global_metrics
          ];
          calibrator=note_global_calibrator,
        )

        stream_scores = fill(Config.DEFAULT_TARGET_01, length(chords))
        if stream_idx <= length(note_stream_containers)
          stream_calibrator = note_stream_calibrators[stream_idx]
          predictive_stream_scores = Float64[]
          for i in eachindex(stream_candidates)
            predictive = predictive_surprise_score(
              note_stream_containers[stream_idx].manager,
              note_stream_predictors[stream_idx],
              stream_candidates[i],
            )
            push!(
              predictive_stream_scores,
              predictive === nothing ? NaN : predictive,
            )
          end
          stream_scores = combine_predictive_structural_scores(
            predictive_stream_scores,
            Float64[m.distance for m in stream_metrics],
            Float64[m.quantity for m in stream_metrics],
            Float64[m.complexity for m in stream_metrics],
            PolyphonicClusterManager.OccurrenceIntervalMetrics[
              m.occurrence_intervals for m in stream_metrics
            ];
            calibrator=stream_calibrator,
          )
        end

        stream_target =
          stream_idx <= length(area_stream_targets) ?
            area_stream_targets[stream_idx] :
            area_center
        return Float64[
          abs(global_scores[i] - area_global_target) +
          abs(stream_scores[i] - stream_target)
          for i in eachindex(chords)
        ]
      end

      selected_chords[stream_idx] = select_notes_by_single_addition_greedy(
        note_pool,
        stream_note_counts[stream_idx],
        target01,
        dissonance_calibrator,
        evaluate_partial_chord;
        register_center=register_centers[stream_idx],
        register_allowance=register_allowance,
        tie_center=float(chosen_area[stream_idx]) + float(BAND_SIZE - 1) / 2.0,
        complexity_cost_batch=evaluate_note_complexity_cost_batch,
        complexity_weight=1.0,
        evaluation_budget=evaluation_budget,
      )
      chosen_note_flags[stream_idx] = true
    end

    for s in 1:desired_stream_count
      best_chord = copy(selected_chords[s])
      sort!(best_chord)
      current_step_values[s][note_abs_idx] = best_chord
    end

    # ---- Commit STM using realized notes across all streams (NOT area tmp) ----
    midi_notes_all = Int[]
    amps_all = Float64[]
    for s in 1:desired_stream_count
      ns = current_step_values[s][note_abs_idx]
      v = vols[s]
      a_each = isempty(ns) ? v : (v / float(length(ns)))
      for n in ns
        push!(midi_notes_all, n)
        push!(amps_all, a_each)
      end
    end
    _set_generation_failure_context!(failure_context; operation="commit_stm", dimension="note", candidate=copy(midi_notes_all))
    DissonanceStmManager.commit!(stm_mgr, midi_notes_all, amps_all, onset)

    # ---- Commit NOTE managers using realized anchors (global scalar + per-stream) ----
    global_anchor_note = _global_anchor_from_step(current_step_values)

    _set_generation_failure_context!(failure_context; operation="commit_global", dimension="note", candidate=global_anchor_note)
    PolyphonicClusterManager.add_data_point_permanently(note_mgrs[:global], Float64[float(global_anchor_note)])
    _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension="note", candidate=global_anchor_note)
    PolyphonicClusterManager.update_caches_permanently(note_mgrs[:global])

    stream_anchors = Float64[]
    sizehint!(stream_anchors, desired_stream_count)
    for s in 1:desired_stream_count
      push!(stream_anchors, float(_anchor_from_abs(current_step_values[s][note_abs_idx])))
    end
    _set_generation_failure_context!(failure_context; operation="commit_streams", dimension="note", candidate=copy(stream_anchors))
    MultiStreamManager.commit_state!(note_mgrs[:stream], stream_anchors)
    _set_generation_failure_context!(failure_context; operation="commit_stream_caches", dimension="note", candidate=copy(stream_anchors))
    MultiStreamManager.update_caches_permanently!(note_mgrs[:stream])

    if clustered_tie_enabled
      tie_mgrs = managers["tie"]
      tie_global_mgr = tie_mgrs[:global]
      tie_stream_mgr = tie_mgrs[:stream]
      global_target = tie_global_complexity_series[step_idx]
      stream_center = tie_stream_center_series[step_idx]
      stream_span = tie_stream_span_series[step_idx]
      concordance = tie_concordance_series[step_idx]
      stream_targets = generate_centered_targets(desired_stream_count, stream_center, stream_span)

      eligible_slots = Int[]
      for slot in 1:desired_stream_count
        stream_id = plan.active_ids[slot]
        previous = get(previous_step_by_id, stream_id, nothing)
        current = current_step_values[slot]
        if previous !== nothing && _tie_render_compatible(previous, current)
          push!(eligible_slots, slot)
        else
          current[tie_idx] = 0.0
        end
      end

      chosen_ties = Dict{Int,Float64}()
      global_calibrator = build_extended_metric_calibrator(tie_global_mgr)
      global_predictor = build_predictive_distribution(tie_global_mgr)
      for slot in step_stream_order
        slot in eligible_slots || continue
        stream_id = plan.active_ids[slot]
        container = tie_stream_mgr.containers_by_id[stream_id]
        stream_calibrator = build_extended_metric_calibrator(container.manager)
        stream_predictor = build_predictive_distribution(container.manager)
        candidate_bits = _restrict_candidates_with_target_window(
          "tie",
          Float64[float(value) for value in Config.TIE_STEPS],
          step_idx - 1,
        )
        isempty(candidate_bits) && (candidate_bits = Float64[float(value) for value in Config.TIE_STEPS])

        global_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]
        stream_metrics = PolyphonicClusterManager.ExtendedClusterMetrics[]
        for bit in candidate_bits
          _consume_dimension_evaluations!(evaluation_budget, 1; context="tie candidate")
          _set_generation_failure_context!(
            failure_context;
            operation="simulate_candidate",
            dimension="tie",
            stream_id=stream_id,
            candidate=bit,
          )
          partial_bits = Float64[chosen_ties[s] for s in sort!(collect(keys(chosen_ties)))]
          push!(partial_bits, bit)
          projected_global = sum(partial_bits) / float(length(partial_bits))
          push!(global_metrics, _safe_simulate_add_and_calculate_all_extended(tie_global_mgr, Float64[projected_global]))
          push!(stream_metrics, _safe_simulate_add_and_calculate_all_extended(container.manager, Float64[bit]))
        end

        global_scores = fill(NaN, length(candidate_bits))
        stream_scores = fill(NaN, length(candidate_bits))
        for (candidate_idx, bit) in enumerate(candidate_bits)
          partial_bits = Float64[chosen_ties[s] for s in sort!(collect(keys(chosen_ties)))]
          push!(partial_bits, bit)
          projected_global = sum(partial_bits) / float(length(partial_bits))
          global_predictive = predictive_surprise_score(
            tie_global_mgr,
            global_predictor,
            Float64[projected_global],
          )
          stream_predictive = predictive_surprise_score(
            container.manager,
            stream_predictor,
            Float64[bit],
          )
          global_predictive !== nothing && (global_scores[candidate_idx] = global_predictive)
          stream_predictive !== nothing && (stream_scores[candidate_idx] = stream_predictive)
        end
        global_scores = combine_predictive_structural_scores(
          global_scores,
          Float64[m.distance for m in global_metrics],
          Float64[m.quantity for m in global_metrics],
          Float64[m.complexity for m in global_metrics],
          PolyphonicClusterManager.OccurrenceIntervalMetrics[
            m.occurrence_intervals for m in global_metrics
          ];
          calibrator=global_calibrator,
        )
        stream_scores = combine_predictive_structural_scores(
          stream_scores,
          Float64[m.distance for m in stream_metrics],
          Float64[m.quantity for m in stream_metrics],
          Float64[m.complexity for m in stream_metrics],
          PolyphonicClusterManager.OccurrenceIntervalMetrics[
            m.occurrence_intervals for m in stream_metrics
          ];
          calibrator=stream_calibrator,
        )

        best_bit = 0.0
        best_cost = Inf
        for (candidate_idx, bit) in enumerate(candidate_bits)
          partial_bits = Float64[chosen_ties[s] for s in sort!(collect(keys(chosen_ties)))]
          push!(partial_bits, bit)
          cost =
            abs(global_scores[candidate_idx] - global_target) +
            abs(stream_scores[candidate_idx] - stream_targets[slot]) +
            _tie_concordance_cost(partial_bits, concordance)
          if cost < best_cost - 1e-12
            best_cost = cost
            best_bit = bit
          end
        end
        chosen_ties[slot] = best_bit
        current_step_values[slot][tie_idx] = best_bit
      end

      if !isempty(eligible_slots)
        committed_bits = Float64[current_step_values[slot][tie_idx] for slot in eligible_slots]
        global_tie_value = sum(committed_bits) / float(length(committed_bits))
        _set_generation_failure_context!(failure_context; operation="commit_global", dimension="tie", candidate=global_tie_value)
        PolyphonicClusterManager.add_data_point_permanently(tie_global_mgr, Float64[global_tie_value])
        _set_generation_failure_context!(failure_context; operation="commit_global_cache", dimension="tie", candidate=global_tie_value)
        PolyphonicClusterManager.update_caches_permanently!(tie_global_mgr)

        for slot in eligible_slots
          stream_id = plan.active_ids[slot]
          bit = Float64(current_step_values[slot][tie_idx])
          container = tie_stream_mgr.containers_by_id[stream_id]
          _set_generation_failure_context!(failure_context; operation="commit_stream", dimension="tie", stream_id=stream_id, candidate=bit)
          PolyphonicClusterManager.add_data_point_permanently(container.manager, Float64[bit])
          _set_generation_failure_context!(failure_context; operation="commit_stream_cache", dimension="tie", stream_id=stream_id, candidate=bit)
          PolyphonicClusterManager.update_caches_permanently!(container.manager)
          container.last_value = Float64[bit]
        end
      end
      step_decisions["tie"] = Float64[current_step_values[slot][tie_idx] for slot in 1:desired_stream_count]
    end

    generated_voice_tokens = Dict{Int,VoiceTokenGeneration.VoiceToken}()
    if voice_state !== nothing && !isempty(voice_ids)
      voice_targets = generate_centered_targets(
        length(voice_ids),
        voice_stream_center_series[step_idx],
        voice_stream_span_series[step_idx],
      )
      targets_by_id = Dict{Int,Float64}(
        stream_id => voice_targets[i] for (i, stream_id) in enumerate(voice_ids)
      )
      recency = clamp(_parse_float(array_param(gp, "recency_center", step_idx - 1)), 0.0, 1.0)
      forced_voice_tokens = Dict{Int,VoiceTokenGeneration.VoiceToken}()
      for stream_id in voice_ids
        previous = get(previous_step_by_id, stream_id, nothing)
        current_slot = findfirst(id -> id == stream_id, plan.active_ids)
        current_slot === nothing && continue
        previous === nothing && continue
        previous_voice_plan = isempty(voice_plan) ? Any[] : voice_plan[end]
        previous_voice = nothing
        for entry in previous_voice_plan
          try
            Int(entry["streamId"]) == stream_id || continue
            lowercase(string(get(entry, "mode", "synth"))) == "voice" || break
            previous_voice = entry
            break
          catch
          end
        end
        previous_voice === nothing && continue
        current = current_step_values[current_slot]
        same_notes = length(previous[note_abs_idx]) == length(current[note_abs_idx]) &&
          all(previous[note_abs_idx][i] == current[note_abs_idx][i] for i in eachindex(previous[note_abs_idx], current[note_abs_idx]))
        same_notes || continue
        _parse_float(current[tie_idx]) >= 1.0 || continue
        continuation = VoiceTokenGeneration.continuation_token(voice_state, stream_id)
        continuation === nothing || (forced_voice_tokens[stream_id] = continuation)
      end
      _set_generation_failure_context!(
        failure_context;
        operation="generate_tokens",
        dimension="voice_token",
        candidate=copy(voice_ids),
      )
      generated_voice_tokens = VoiceTokenGeneration.generate_tokens!(
        voice_state,
        voice_ids;
        global_target=voice_global_complexity_series[step_idx],
        stream_targets=targets_by_id,
        concordance=voice_concordance_series[step_idx],
        transition_weight=voice_transition_series[step_idx],
        recency=recency,
        forced_tokens=forced_voice_tokens,
      )
    end

    current_voice_plan = Any[]
    for (slot, stream_id) in enumerate(plan.active_ids)
      notes = Int[Int(note) for note in current_step_values[slot][note_abs_idx]]
      token = get(generated_voice_tokens, stream_id, nothing)
      if token === nothing
        push!(current_voice_plan, Dict(
          "streamId" => stream_id,
          "mode" => "synth",
          "token" => nothing,
          "text" => nothing,
          "phones" => String[],
          "carrierNote" => nothing,
          "notes" => notes,
        ))
      else
        carrier_note = isempty(notes) ? nothing : notes[cld(length(notes), 2)]
        push!(current_voice_plan, Dict(
          "streamId" => stream_id,
          "mode" => "voice",
          "token" => token.id,
          "text" => token.text,
          "phones" => copy(token.phones),
          "carrierNote" => carrier_note,
          "notes" => notes,
        ))
      end
    end
    push!(voice_plan, current_voice_plan)
    @info "Voice token decisions" step=step_idx bpm=future_bpm[step_idx] step_duration=future_step_durations[step_idx] decisions=[(stream_id=entry["streamId"], mode=entry["mode"], text=entry["text"], notes=entry["notes"], vol=current_step_values[slot][vol_idx]) for (slot, entry) in enumerate(current_voice_plan)]

    # store decisions
    step_decisions["area_tmp_anchor"] = chosen_area
    step_decisions["note_anchor"] = global_anchor_note

    push!(result_stream_ids, copy(plan.active_ids))
    previous_step_by_id = Dict{Int,Vector{Any}}(
      stream_id => current_step_values[slot]
      for (slot, stream_id) in enumerate(plan.active_ids)
      if slot <= length(current_step_values)
    )
    push!(results, current_step_values)
    elapsed = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)
    println("[generate_polyphonic] step $(step_idx)/$(steps_to_generate) elapsed=$(elapsed)s")
    flush(stdout)
    catch err
      managers = committed_step_state.managers
      stm_mgr = committed_step_state.stm_mgr
      stream_axis = committed_step_state.stream_axis
      voice_state = committed_step_state.voice_state
      resize!(results, results_len_before_step)
      resize!(result_stream_ids, stream_ids_len_before_step)
      resize!(voice_plan, voice_plan_len_before_step)
      previous_step_by_id = previous_step_by_id_before
      _log_generate_polyphonic_step_failure(err, catch_backtrace(), step_idx, failure_context)
      rethrow()
    end
  end

  # ----------------------------------------------------------
  # Post-process / clamp
  # ----------------------------------------------------------
  for (step_idx, step) in enumerate(results)
    is_generated_step = step_idx > base_step_index
    for (stream_idx, vec) in enumerate(step)
      vec[note_abs_idx] = _normalize_abs_notes(vec[note_abs_idx])
      vec[vol_idx] = (!get(dim_accept, "vol", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("vol", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[vol_idx]), 0.0, 1.0)
      vec[brightness_idx] = (!get(dim_accept, "brightness", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("brightness", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[brightness_idx]), 0.0, 1.0)
      vec[noise_idx] = (!get(dim_accept, "noise", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("noise", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[noise_idx]), 0.0, 1.0)
      vec[harmonicity_idx] = (!get(dim_accept, "harmonicity", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("harmonicity", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[harmonicity_idx]), 0.0, 1.0)
      vec[attack_idx] = (!get(dim_accept, "attack", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("attack", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[attack_idx]), 0.0, 1.0)
      vec[decay_sustain_idx] = (!get(dim_accept, "decay_sustain", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("decay_sustain", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[decay_sustain_idx]), 0.0, 1.0)
      vec[release_idx] = (!get(dim_accept, "release", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("release", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[release_idx]), 0.0, 1.0)
      vec[chord_range_idx] = (!get(dim_accept, "chord_range", true) && is_generated_step) ? Int(round(clamp(_resolved_fixed_value_for_stream("chord_range", stream_idx), float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))) : clamp(_parse_int(vec[chord_range_idx]), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
      vec[density_idx] = (!get(dim_accept, "density", true) && is_generated_step) ? clamp(_resolved_fixed_value_for_stream("density", stream_idx), 0.0, 1.0) : clamp(_parse_float(vec[density_idx]), 0.0, 1.0)
      vec[tie_idx] = _quantize_tie_value(vec[tie_idx])
    end
  end

  processing_time_s = round(time() - t0; digits=Config.PROCESSING_TIME_DIGITS)

  timbre_series = Dict(
    "brightness" => Any[
      Float64[clamp(_parse_float(st[brightness_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "noise" => Any[
      Float64[clamp(_parse_float(st[noise_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "harmonicity" => Any[
      Float64[clamp(_parse_float(st[harmonicity_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "attack" => Any[
      Float64[clamp(_parse_float(st[attack_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "decay_sustain" => Any[
      Float64[clamp(_parse_float(st[decay_sustain_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "release" => Any[
      Float64[clamp(_parse_float(st[release_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "tie" => Any[
      Float64[clamp(_parse_float(st[tie_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
  )

  cluster_payload = Dict{String,Any}()
  for key in ["note", "area", "vol", "brightness", "noise", "harmonicity", "attack", "decay_sustain", "release", "chord_range", "density", "tie"]
    mgrs = get(managers, key, nothing)
    mgrs === nothing && continue

    g_mgr = mgrs[:global]
    s_mgr = mgrs[:stream]

    global_timeline = PolyphonicClusterManager.clusters_to_timeline(g_mgr.clusters, min_window)

    streams_hash = Dict{Int,Any}()
    for container in s_mgr.stream_pool
      streams_hash[container.id] = PolyphonicClusterManager.clusters_to_timeline(container.manager.clusters, min_window)
    end

    cluster_payload[key] = Dict(
      "global" => global_timeline,
      "streams" => streams_hash,
    )
  end
  if voice_state !== nothing
    cluster_payload["voice_token"] = VoiceTokenGeneration.clusters_payload(voice_state, min_window)
  end

  return Dict(
    "timeSeries" => results,
    "streamIds" => result_stream_ids,
    "voicePlan" => voice_plan,
    "voiceStreamCounts" => voice_stream_counts,
    "voiceInventory" => voice_inventory === nothing ? nothing : Dict(
      "id" => voice_inventory.id,
      "modelId" => voice_inventory.model_id,
      "featureVersion" => voice_inventory.feature_version,
      "source" => voice_inventory.source,
      "dimensions" => voice_inventory.dimensions,
    ),
    "clusters" => cluster_payload,
    "processingTime" => processing_time_s,
    "streamStrengths" => nothing,
    "timbreSeries" => timbre_series,
    "bpm" => isempty(future_bpm) ? bpm : future_bpm[1],
    "stepDuration" => isempty(future_step_durations) ? Config.step_duration_from_bpm(bpm) : future_step_durations[1],
    "initialContextBpm" => initial_context_bpm,
    "futureBpm" => future_bpm,
    "bpmSeries" => bpm_series,
    "stepDurations" => step_durations
  )
end

# ------------------------------------------------------------
# GitHub Actions workflow_dispatch integration
# ------------------------------------------------------------
function _env_required(key::AbstractString)
  val = get(ENV, key, "")
  isempty(val) && error("Missing required environment variable: $(key)")
  return val
end

function _github_headers()
  token = _env_required("GITHUB_TOKEN")
  return [
    "Authorization" => "Bearer $(token)",
    "Accept" => "application/vnd.github+json",
    "User-Agent" => "TimeseriesClusteringAPI",
    "X-GitHub-Api-Version" => "2022-11-28",
    "Content-Type" => "application/json",
  ]
end

function _github_repo_base(owner::AbstractString, repo::AbstractString)
  return "https://api.github.com/repos/$(owner)/$(repo)"
end

function _github_dispatch_workflow!(; workflow::AbstractString, ref::AbstractString, inputs::Dict{String,String})
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/dispatches"
  body = JSON3.write(Dict("ref" => ref, "inputs" => inputs))
  res = HTTP.request("POST", url, _github_headers(); body=body)
  return res
end

function _github_list_workflow_runs(; workflow::AbstractString, ref::AbstractString, per_page::Int=Config.GITHUB_WORKFLOW_RUNS_PER_PAGE)
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/runs?event=workflow_dispatch&branch=$(ref)&per_page=$(per_page)"
  res = HTTP.request("GET", url, _github_headers())
  res.status == 200 || return nothing
  return JSON3.read(String(res.body))
end

function _gzip_base64encode(payload::AbstractString)::String
  compressed = transcode(GzipCompressor, Vector{UInt8}(codeunits(payload)))
  return base64encode(compressed)
end

function _find_new_run_after(obj, dispatched_at_utc::DateTime)
  obj === nothing && return nothing
  runs = get(obj, "workflow_runs", Any[])
  for r in runs
    created = get(r, "created_at", "")
    isempty(created) && continue
    created_dt = try
      DateTime(created[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
    catch
      continue
    end
    if created_dt >= (dispatched_at_utc - Dates.Second(Config.GITHUB_WORKFLOW_DISPATCH_TOLERANCE_SECONDS))
      return r
    end
  end
  return nothing
end

function dispatch_generate_polyphonic()
  payload = _payload()
  payload_dict = _to_string_dict(payload)
  gp = get(payload_dict, "generate_polyphonic", Dict{String,Any}())
  gp_dict = _to_string_dict(gp)

  if !Config.voicevox_enabled()
    for key in (
      "voice_stream_counts",
      "voice_inventory_id",
      "voice_token_global_complexity_target",
      "voice_token_stream_complexity_center",
      "voice_token_stream_complexity_span",
      "voice_token_concordance",
      "voice_transition_weight",
    )
      pop!(gp_dict, key, nothing)
    end
  end

  _validate_generate_polyphonic_request!(gp_dict)

  request_id = string(get(gp_dict, "job_id", uuid4()))
  gp_dict["job_id"] = request_id
  payload_dict["generate_polyphonic"] = gp_dict

  workflow = _env_required("GITHUB_WORKFLOW")
  ref = _env_required("GITHUB_REF")

  params_json = JSON3.write(payload_dict)
  params_b64 = _gzip_base64encode(params_json)
  if length(params_b64) > Config.GITHUB_WORKFLOW_PARAMS_B64_MAX_CHARS
    return Dict(
      "ok" => false,
      "error" => "Compressed workflow input is still too large: $(length(params_b64)) chars (limit $(Config.GITHUB_WORKFLOW_PARAMS_B64_MAX_CHARS)).",
      "request_id" => request_id,
      "params_json_bytes" => ncodeunits(params_json),
      "params_b64_chars" => length(params_b64),
    )
  end

  dispatched_at = now(UTC)

  res = try
    _github_dispatch_workflow!(workflow=workflow, ref=ref, inputs=Dict(
      "request_id" => request_id,
      "params_b64" => params_b64,
    ))
  catch e
    return Dict("ok" => false, "error" => string(e))
  end

  run_id = nothing
  run_url = nothing
  html_url = nothing

  if res.status == 200 && !isempty(String(res.body))
    try
      body = JSON3.read(String(res.body))
      run_id = get(body, "workflow_run_id", nothing)
      run_url = get(body, "run_url", nothing)
      html_url = get(body, "html_url", nothing)
    catch
    end
  end

  workflow_page_url = "https://github.com/$(_env_required("GITHUB_OWNER"))/$(_env_required("GITHUB_REPO"))/actions/workflows/$(workflow)"

  if html_url === nothing
    for _ in 1:8
      obj = _github_list_workflow_runs(workflow=workflow, ref=ref, per_page=Config.GITHUB_WORKFLOW_RUNS_PER_PAGE)
      r = _find_new_run_after(obj, dispatched_at)
      if r !== nothing
        run_id = get(r, "id", run_id)
        html_url = get(r, "html_url", html_url)
        run_url = get(r, "url", run_url)
        break
      end
      sleep(Config.GITHUB_WORKFLOW_POLL_INTERVAL_SECONDS)
    end
  end

  return Dict(
    "ok" => (res.status == 204 || res.status == 200),
    "request_id" => request_id,
    "workflow" => workflow,
    "ref" => ref,
    "workflow_page_url" => workflow_page_url,
    "run_id" => run_id,
    "run_url" => run_url,
    "run_html_url" => html_url,
    "http_status" => res.status,
    "params_json_bytes" => ncodeunits(params_json),
    "params_b64_chars" => length(params_b64),
  )
end

# ------------------------------------------------------------
# XML file serving and SVG coordinate mapping
# ------------------------------------------------------------
function get_xml()
    payload = _payload()
    p = haskey(payload, "xml") ? _subhash(payload, "xml") : payload

    composer = string(get(p, "composer", ""))
    folder = string(get(p, "folder", ""))
    xml_score = string(get(p, "xml_score", ""))
    series_id = strip(string(get(p, "series_id", "")))
    part = strip(string(get(p, "part", "")))
    staff = strip(string(get(p, "staff", "1")))
    voice = strip(string(get(p, "voice", "1")))
    match = get(p, "match", nothing)
    matches = match === nothing ? get(p, "matches", Any[]) : Any[match]

    if isempty(composer) || isempty(folder) || isempty(xml_score)
        return Dict("error" => "composer, folder, and xml_score are required")
    end

    file_path = _xml_file_path(composer, folder, xml_score)

    # Security check - ensure path is within dataset directory
    dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "..", "data", "asap-dataset")))
    if !startswith(normpath(file_path), normpath(dataset_dir))
        return Dict("error" => "Invalid path")
    end

    if !isfile(file_path)
        return Dict("error" => "File not found: $(file_path)")
    end

    xml_content = _safe_read_file(file_path)
    if xml_content === nothing
        return Dict("error" => "Could not read file")
    end

    if isempty(series_id)
        return Dict("error" => "series_id is required to render a phrase score")
    end

    phrase_bounds = _phrase_bounds_for_series(series_id)
    if phrase_bounds === nothing
        return Dict("error" => "Phrase range was not found for series_id=$(series_id)")
    end

    match_ranges = _matched_point_index_ranges(matches, phrase_bounds)
    if isempty(match_ranges)
        return Dict("error" => "Matched point range was not found for series_id=$(series_id)")
    end

    xmls = Any[]
    for range in match_ranges
        point_indices = range["point_indices"]::Set{Int}
        matched_measures = _measures_for_point_indices(phrase_bounds, point_indices)
        phrase_xml = _musicxml_for_phrase(xml_content, matched_measures, part, staff, voice, point_indices, phrase_bounds)
        phrase_xml === nothing && continue
        push!(xmls, Dict(
            "xml" => phrase_xml,
            "db_start" => range["db_start"],
            "window_size" => range["window_size"],
            "matched_point_indices" => sort(collect(point_indices)),
        ))
    end
    if isempty(xmls)
        return Dict("error" => "Could not slice MusicXML for series_id=$(series_id)")
    end

    return Dict(
        "xml" => xmls[1]["xml"],
        "xmls" => xmls,
        "composer" => composer,
        "folder" => folder,
        "xml_score" => xml_score,
        "series_id" => series_id,
        "phrase_bounds" => phrase_bounds
    )
end

function _xml_file_path(composer::AbstractString, folder::AbstractString, xml_score::AbstractString)
    # ASAP datasetの絶対パスを解決。git submoduleの場所を指す。
    dataset_dir = get(ENV, "ASAP_DATASET_DIR", "/app/data/asap-dataset")
    if !isdir(dataset_dir)
        dataset_dir = joinpath(@__DIR__, "..", "..", "data", "asap-dataset")
    end

    composer_clean = replace(composer, ".." => "", "/" => "")
    folder_clean = replace(folder, ".." => "")
    xml_score_clean = basename(xml_score)

    if startswith(folder_clean, composer_clean * "/") || folder_clean == composer_clean
        return normpath(joinpath(dataset_dir, folder_clean, xml_score_clean))
    else
        return normpath(joinpath(dataset_dir, composer_clean, folder_clean, xml_score_clean))
    end
end

function _safe_read_file(path::AbstractString)::Union{String, Nothing}
    try
        return read(path, String)
    catch e
        println("Failed to read file $(path): $(e)")
        return nothing
    end
end

function _xml_child_elements(node, name::AbstractString)
    out = Any[]
    for child in EzXML.eachelement(node)
        EzXML.nodename(child) == name && push!(out, child)
    end
    return out
end

function _xml_attr(node, name::AbstractString, default::AbstractString="")
    try
        return String(node[name])
    catch
        return String(default)
    end
end

function _xml_to_string(doc)::String
    io = IOBuffer()
    try
        EzXML.prettyprint(io, doc)
    catch
        print(io, doc)
    end
    return String(take!(io))
end

function _phrase_bounds_for_series(series_id::AbstractString)
    measurement = string(get(ENV, "INFLUX_MEASUREMENT", "timeseries"))
    influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
    influx_db = string(get(ENV, "INFLUX_DB", "timeseries"))
    q = "SELECT \"measure\", \"measure_tick\", \"score_tick\", \"point_index\" FROM \"$(measurement)\" WHERE \"series_id\" = $(_influxql_string_literal(series_id)) ORDER BY time"
    resp = try
        _influx_query_get(influx_url, influx_db, q)
    catch e
        println("Failed to query phrase bounds for series_id=$(series_id): ", e)
        return nothing
    end

    body = String(resp.body)
    parsed = try
        JSON3.read(body)
    catch e
        println("Phrase bounds query returned non-JSON: ", e, " body=", _body_preview(body))
        return nothing
    end

    measures = String[]
    point_indices = Int[]
    score_ticks = Int[]
    points = Vector{Dict{String,Any}}()
    try
        s = parsed["results"][1]["series"][1]
        columns = s["columns"]
        measure_idx = _column_index(columns, "measure")
        measure_tick_idx = _column_index(columns, "measure_tick")
        point_idx = _column_index(columns, "point_index")
        score_tick_idx = _column_index(columns, "score_tick")
        measure_idx <= 0 && return nothing
        for row in s["values"]
            measure = strip(string(row[measure_idx]))
            isempty(measure) || push!(measures, measure)
            point_index = point_idx > 0 ? _parse_int(row[point_idx]) : length(point_indices)
            measure_tick = measure_tick_idx > 0 ? _parse_int(row[measure_tick_idx]) : 0
            score_tick = score_tick_idx > 0 ? _parse_int(row[score_tick_idx]) : 0
            point_idx > 0 && push!(point_indices, point_index)
            score_tick_idx > 0 && push!(score_ticks, score_tick)
            push!(points, Dict{String,Any}(
                "measure" => measure,
                "measure_tick" => measure_tick,
                "score_tick" => score_tick,
                "point_index" => point_index,
            ))
        end
    catch e
        println("Phrase bounds query returned unexpected shape: ", e, " body=", _body_preview(body))
        return nothing
    end

    isempty(measures) && return nothing
    unique_measures = unique(measures)
    return Dict{String,Any}(
        "measures" => unique_measures,
        "start_measure" => first(unique_measures),
        "end_measure" => last(unique_measures),
        "start_point_index" => isempty(point_indices) ? nothing : minimum(point_indices),
        "end_point_index" => isempty(point_indices) ? nothing : maximum(point_indices),
        "start_score_tick" => isempty(score_ticks) ? nothing : minimum(score_ticks),
        "end_score_tick" => isempty(score_ticks) ? nothing : maximum(score_ticks),
        "points" => points,
    )
end

function _matched_point_index_ranges(matches, phrase_bounds)::Vector{Dict{String,Any}}
    points = get(phrase_bounds, "points", Any[])
    valid_indices = Set{Int}(_parse_int(get(point, "point_index", -1)) for point in points)
    ranges = Vector{Dict{String,Any}}()

    if matches isa AbstractVector
        for match in Iterators.take(matches, 1)
            m = _to_string_dict(match)
            window_size = max(0, _parse_int(get(m, "windowSize", get(m, "len", 0))))
            db_starts = get(m, "db_starts", Any[])
            if !(db_starts isa AbstractVector)
                db_starts = Any[get(m, "start", get(m, "db_start", nothing))]
            end
            for raw_start in db_starts
                raw_start === nothing && continue
                start_idx = _parse_int(raw_start)
                selected = Set{Int}()
                for idx in start_idx:(start_idx + window_size - 1)
                    idx in valid_indices && push!(selected, idx)
                end
                isempty(selected) && continue
                push!(ranges, Dict{String,Any}(
                    "db_start" => start_idx,
                    "window_size" => window_size,
                    "point_indices" => selected,
                ))
            end
        end
    end

    return ranges
end

function _measures_for_point_indices(phrase_bounds, point_indices::Set{Int})::Set{String}
    measures = Set{String}()
    for point in get(phrase_bounds, "points", Any[])
        idx = _parse_int(get(point, "point_index", -1))
        idx in point_indices || continue
        measure = strip(string(get(point, "measure", "")))
        isempty(measure) || push!(measures, measure)
    end
    return measures
end

function _musicxml_for_phrase(
    xml_content::AbstractString,
    keep_measures::Set{String},
    target_part::AbstractString,
    target_staff::AbstractString,
    target_voice::AbstractString,
    keep_point_indices::Set{Int},
    phrase_bounds
)::Union{String,Nothing}
    text_xml = _musicxml_for_phrase_text(xml_content, keep_measures, target_part, target_staff, target_voice, keep_point_indices, phrase_bounds)
    text_xml === nothing || return text_xml

    return nothing
end

function _regex_literal(s::AbstractString)::String
    out = IOBuffer()
    specials = Set(['\\', '.', '^', '$', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}'])
    for c in String(s)
        if c in specials
            print(out, '\\')
        end
        print(out, c)
    end
    return String(take!(out))
end

function _musicxml_for_phrase_text(
    xml_content::AbstractString,
    keep_measures::Set{String},
    target_part::AbstractString,
    target_staff::AbstractString,
    target_voice::AbstractString,
    keep_point_indices::Set{Int},
    phrase_bounds
)::Union{String,Nothing}
    isempty(keep_measures) && return nothing

    xml = _remove_score_credits(String(xml_content))
    part_re = r"(?s)<part\b[^>]*\bid\s*=\s*(['\"])(.*?)\1[^>]*>.*?</part>"
    part_matches = collect(eachmatch(part_re, xml))
    isempty(part_matches) && return nothing

    target_part = strip(String(target_part))
    target_staff = isempty(strip(String(target_staff))) ? "1" : strip(String(target_staff))
    target_voice = isempty(strip(String(target_voice))) ? "1" : strip(String(target_voice))
    phrase_points_by_measure = _points_by_measure(phrase_bounds)
    out = IOBuffer()
    cursor = firstindex(xml)
    kept_any = false
    kept_part_ids = Set{String}()

    for m in part_matches
        part_start = m.offset
        part_end = m.offset + ncodeunits(m.match) - 1
        part_id = String(m.captures[2])

        if cursor < part_start
            print(out, xml[cursor:prevind(xml, part_start)])
        end
        cursor = nextind(xml, part_end)

        if !isempty(target_part) && part_id != target_part
            continue
        end

        sliced_part = _slice_part_measures(m.match, keep_measures, target_staff, target_voice, keep_point_indices, phrase_points_by_measure)
        if sliced_part !== nothing
            print(out, sliced_part)
            push!(kept_part_ids, part_id)
            kept_any = true
        end
    end
    if cursor <= lastindex(xml)
        print(out, xml[cursor:end])
    end

    kept_any || return nothing
    result = String(take!(out))
    if !isempty(target_part)
        result = _filter_part_list_entries(result, kept_part_ids)
    end
    return result
end

function _slice_part_measures(
    part_xml::AbstractString,
    keep_measures::Set{String},
    target_staff::AbstractString,
    target_voice::AbstractString,
    keep_point_indices::Set{Int},
    phrase_points_by_measure::Dict{String,Vector{Tuple{Int,Int}}}
)::Union{String,Nothing}
    part_text = String(part_xml)
    measure_re = r"(?s)<measure\b[^>]*\bnumber\s*=\s*(['\"])(.*?)\1[^>]*>.*?</measure>"
    measure_matches = collect(eachmatch(measure_re, part_text))
    isempty(measure_matches) && return nothing

    out = IOBuffer()
    first_measure = measure_matches[1]
    if firstindex(part_text) < first_measure.offset
        print(out, part_text[firstindex(part_text):prevind(part_text, first_measure.offset)])
    end

    kept_any = false
    for m in measure_matches
        measure_number = String(m.captures[2])
        if measure_number in keep_measures
            measure_points = get(phrase_points_by_measure, measure_number, Tuple{Int,Int}[])
            print(out, _color_measure_notes(m.match, measure_points, target_staff, target_voice, keep_point_indices))
            kept_any = true
        end
    end

    last_measure = measure_matches[end]
    last_end = last_measure.offset + ncodeunits(last_measure.match) - 1
    suffix_start = nextind(part_text, last_end)
    if suffix_start <= lastindex(part_text)
        print(out, part_text[suffix_start:end])
    end

    kept_any || return nothing
    return String(take!(out))
end

function _points_by_measure(phrase_bounds)::Dict{String,Vector{Tuple{Int,Int}}}
    grouped = Dict{String,Vector{Tuple{Int,Int}}}()
    for point in get(phrase_bounds, "points", Any[])
        measure = strip(string(get(point, "measure", "")))
        isempty(measure) && continue
        measure_tick = _parse_int(get(point, "measure_tick", 0))
        point_index = _parse_int(get(point, "point_index", -1))
        push!(get!(grouped, measure, Tuple{Int,Int}[]), (measure_tick, point_index))
    end
    for (_, xs) in grouped
        sort!(xs, by = x -> (x[1], x[2]))
    end
    return grouped
end

function _remove_score_credits(xml::AbstractString)::String
    result = String(xml)
    result = replace(result, r"(?s)<work-title>.*?</work-title>" => "")
    result = replace(result, r"(?s)<movement-title>.*?</movement-title>" => "")
    result = replace(result, r"(?s)<creator\b[^>]*>.*?</creator>" => "")
    result = replace(result, r"(?s)<credit\b[^>]*>.*?</credit>" => "")
    result = replace(result, r"(?s)<rights\b[^>]*>.*?</rights>" => "")
    return result
end

function _color_measure_notes(
    measure_xml::AbstractString,
    measure_points::Vector{Tuple{Int,Int}},
    target_staff::AbstractString,
    target_voice::AbstractString,
    keep_point_indices::Set{Int}
)::String
    measure_text = String(measure_xml)
    color_note_ordinals = _highest_note_ordinals_for_points(
        measure_text,
        measure_points,
        target_staff,
        target_voice,
        keep_point_indices,
    )
    isempty(color_note_ordinals) && return measure_text

    note_re = r"(?s)<note\b[^>]*>.*?</note>"
    note_matches = collect(eachmatch(note_re, measure_text))

    out = IOBuffer()
    cursor = firstindex(measure_text)
    note_ordinal = 0

    for m in note_matches
        start_idx = m.offset
        end_idx = m.offset + ncodeunits(m.match) - 1
        if cursor < start_idx
            print(out, measure_text[cursor:prevind(measure_text, start_idx)])
        end

        note_xml = m.match
        note_ordinal += 1
        if note_ordinal in color_note_ordinals
            print(out, _color_note_xml(note_xml))
        else
            print(out, note_xml)
        end

        cursor = nextind(measure_text, end_idx)
    end

    if cursor <= lastindex(measure_text)
        print(out, measure_text[cursor:end])
    end

    return String(take!(out))
end

function _highest_note_ordinals_for_points(
    measure_text::AbstractString,
    measure_points::Vector{Tuple{Int,Int}},
    target_staff::AbstractString,
    target_voice::AbstractString,
    keep_point_indices::Set{Int}
)::Set{Int}
    token_re = r"(?s)<(note|backup|forward)\b[^>]*>.*?</(?:note|backup|forward)>"
    cursor_tick = 0
    last_note_start = 0
    note_ordinal = 0
    start_order = Int[]
    highest_by_start = Dict{Int,Tuple{Int,Int}}()
    point_index_by_tick = Dict{Int,Int}()
    for (measure_tick, point_index) in measure_points
        point_index_by_tick[measure_tick] = point_index
    end

    for m in eachmatch(token_re, String(measure_text))
        token_name = String(m.captures[1])
        token_xml = String(m.match)
        if token_name == "backup"
            cursor_tick = max(0, cursor_tick - _musicxml_duration_from_string(token_xml))
            continue
        elseif token_name == "forward"
            cursor_tick += _musicxml_duration_from_string(token_xml)
            continue
        end

        note_ordinal += 1
        duration = _musicxml_duration_from_string(token_xml)
        duration <= 0 && continue

        is_chord = occursin(r"(?s)<chord\b", token_xml)
        note_start = is_chord ? last_note_start : cursor_tick

        pitch = _musicxml_midi_pitch_from_note_string(token_xml)
        if pitch !== nothing
            staff = _xml_child_text_from_string(token_xml, "staff", "1")
            voice = _xml_child_text_from_string(token_xml, "voice", "1")
            if staff == target_staff && voice == target_voice
                if !haskey(highest_by_start, note_start)
                    push!(start_order, note_start)
                    highest_by_start[note_start] = (pitch, note_ordinal)
                else
                    existing_pitch, _ = highest_by_start[note_start]
                    if pitch > existing_pitch
                        highest_by_start[note_start] = (pitch, note_ordinal)
                    end
                end
            end
        end

        if !is_chord
            last_note_start = note_start
            cursor_tick += duration
        end
    end

    out = Set{Int}()
    for start_tick in start_order
        haskey(point_index_by_tick, start_tick) || continue
        point_index = point_index_by_tick[start_tick]
        point_index in keep_point_indices || continue
        _, ordinal = highest_by_start[start_tick]
        push!(out, ordinal)
    end
    return out
end

function _musicxml_duration_from_string(xml::AbstractString)::Int
    raw = _xml_child_text_from_string(xml, "duration", "0")
    parsed = tryparse(Int, raw)
    return parsed === nothing ? 0 : parsed
end

function _musicxml_midi_pitch_from_note_string(note_xml::AbstractString)::Union{Int,Nothing}
    occursin(r"(?s)<pitch\b", note_xml) || return nothing
    step = _xml_child_text_from_string(note_xml, "step", "")
    octave_txt = _xml_child_text_from_string(note_xml, "octave", "")
    (isempty(step) || isempty(octave_txt)) && return nothing
    base = Dict("C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11)
    haskey(base, step) || return nothing
    octave = tryparse(Int, octave_txt)
    octave === nothing && return nothing
    alter = tryparse(Int, _xml_child_text_from_string(note_xml, "alter", "0"))
    return (octave + Config.OCTAVE_TO_MIDI_C_OFFSET) * Config.STEPS_PER_OCTAVE + base[step] + (alter === nothing ? 0 : alter)
end

function _color_note_xml(note_xml::AbstractString)::String
    note = String(note_xml)
    if occursin(r"^<note\b[^>]*\bcolor\s*=", note)
        return replace(note, r"^<note\b([^>]*)\bcolor\s*=\s*(['\"])(.*?)\2([^>]*)>" => s"<note\1color=\"#d32f2f\"\4>")
    end
    return replace(note, r"^<note\b" => "<note color=\"#d32f2f\""; count=1)
end

function _normalize_single_staff_measure(measure_xml::AbstractString, target_staff::AbstractString)::String
    measure = String(measure_xml)
    measure = replace(measure, r"(?s)<staves\b[^>]*>.*?</staves>" => "<staves>1</staves>")
    measure = _filter_numbered_elements_for_staff(measure, "clef", target_staff)
    measure = _filter_numbered_elements_for_staff(measure, "staff-details", target_staff)
    measure = _filter_numbered_elements_for_staff(measure, "staff-layout", target_staff)
    return measure
end

function _filter_numbered_elements_for_staff(xml::AbstractString, element_name::AbstractString, target_staff::AbstractString)::String
    text = String(xml)
    pattern = Regex("(?s)<" * _regex_literal(element_name) * "\\b([^>]*)>.*?</" * _regex_literal(element_name) * ">")
    matches = collect(eachmatch(pattern, text))
    isempty(matches) && return text

    out = IOBuffer()
    cursor = firstindex(text)
    for m in matches
        start_idx = m.offset
        end_idx = m.offset + ncodeunits(m.match) - 1
        if cursor < start_idx
            print(out, text[cursor:prevind(text, start_idx)])
        end

        attrs = String(m.captures[1])
        number_match = match(r"\bnumber\s*=\s*(['\"])(.*?)\1", attrs)
        if number_match === nothing
            print(out, m.match)
        elseif String(number_match.captures[2]) == target_staff
            print(out, replace(m.match, r"\s+number\s*=\s*(['\"])(.*?)\1" => ""))
        end
        cursor = nextind(text, end_idx)
    end
    if cursor <= lastindex(text)
        print(out, text[cursor:end])
    end
    return String(take!(out))
end

function _xml_child_text_from_string(xml::AbstractString, child_name::AbstractString, default::AbstractString="")::String
    pattern = Regex("(?s)<" * _regex_literal(child_name) * "\\b[^>]*>(.*?)</" * _regex_literal(child_name) * ">")
    m = match(pattern, String(xml))
    m === nothing && return String(default)
    return strip(String(m.captures[1]))
end

function _filter_part_list_entries(xml::AbstractString, keep_part_ids::Set{String})::String
    isempty(keep_part_ids) && return String(xml)
    text = String(xml)
    score_part_re = r"(?s)<score-part\b[^>]*\bid\s*=\s*(['\"])(.*?)\1[^>]*>.*?</score-part>"
    matches = collect(eachmatch(score_part_re, text))
    isempty(matches) && return text

    out = IOBuffer()
    cursor = firstindex(text)
    for m in matches
        start_idx = m.offset
        end_idx = m.offset + ncodeunits(m.match) - 1
        if cursor < start_idx
            print(out, text[cursor:prevind(text, start_idx)])
        end
        part_id = String(m.captures[2])
        part_id in keep_part_ids && print(out, m.match)
        cursor = nextind(text, end_idx)
    end
    if cursor <= lastindex(text)
        print(out, text[cursor:end])
    end
    return String(take!(out))
end

function _parse_note_positions_from_xml(xml_content::AbstractString)
    try
        doc = EzXML.readxml(String(xml_content))
        root = EzXML.root(doc)

        note_positions = Dict{String, Any}()

        # Parse parts
        for part in EzXML.eachelement(root, "part")
            part_id = EzXML.nodeattribute(part, "id", "P1")
            part_key = "part_$(part_id)"
            part_data = Dict{String, Any}()

            for measure in EzXML.eachelement(part, "measure")
                measure_number = EzXML.nodeattribute(measure, "number", "1")
                measure_key = "measure_$(measure_number)"
                measure_data = Vector{Dict{String, Any}}()

                current_time = 0
                for element in EzXML.eachelement(measure)
                    name = EzXML.nodename(element)

                    if name == "note"
                        # Check for rest
                        if EzXML.hasnode(element, "rest")
                            duration = tryparse(Int, EzXML.nodecontent(EzXML.findfirst(element, "duration")))
                            duration = duration === nothing ? 0 : duration
                            current_time += duration
                            continue
                        end

                        # Check for chord (same start time as previous note)
                        is_chord = EzXML.hasnode(element, "chord")

                        # Get pitch
                        pitch_element = EzXML.findfirst(element, "pitch")
                        if pitch_element !== nothing
                            step = EzXML.nodecontent(EzXML.findfirst(pitch_element, "step"))
                            octave = EzXML.nodecontent(EzXML.findfirst(pitch_element, "octave"))
                            alter_elem = EzXML.findfirst(pitch_element, "alter")
                            alter = alter_elem !== nothing ? tryparse(Int, EzXML.nodecontent(alter_elem)) : 0
                            alter = alter === nothing ? 0 : alter

                            # Get staff and voice
                            staff = EzXML.hasnode(element, "staff") ? EzXML.nodecontent(EzXML.findfirst(element, "staff")) : "1"
                            voice = EzXML.hasnode(element, "voice") ? EzXML.nodecontent(EzXML.findfirst(element, "voice")) : "1"

                            # Get duration
                            duration = tryparse(Int, EzXML.nodecontent(EzXML.findfirst(element, "duration")))
                            duration = duration === nothing ? 0 : duration

                            # Create note info
                            note_info = Dict{String, Any}(
                                "step" => step,
                                "octave" => octave,
                                "alter" => alter,
                                "staff" => staff,
                                "voice" => voice,
                                "start_time" => current_time,
                                "duration" => duration,
                                "is_chord" => is_chord
                            )

                            push!(measure_data, note_info)

                            if !is_chord
                                current_time += duration
                            end
                        end
                    elseif name == "backup"
                        duration = tryparse(Int, EzXML.nodecontent(EzXML.findfirst(element, "duration")))
                        duration = duration === nothing ? 0 : duration
                        current_time -= duration
                        current_time = max(current_time, 0)
                    elseif name == "forward"
                        duration = tryparse(Int, EzXML.nodecontent(EzXML.findfirst(element, "duration")))
                        duration = duration === nothing ? 0 : duration
                        current_time += duration
                    end
                end

                part_data[measure_key] = measure_data
            end

            note_positions[part_key] = part_data
        end

        return note_positions
    catch e
        println("Failed to parse XML: $(e)")
        return Dict()
    end
end

function get_note_positions()
    payload = _payload()
    p = _subhash(payload, "note_positions")

    composer = string(get(p, "composer", ""))
    folder = string(get(p, "folder", ""))
    xml_score = string(get(p, "xml_score", ""))

    if isempty(composer) || isempty(folder) || isempty(xml_score)
        return Dict("error" => "composer, folder, and xml_score are required")
    end

    file_path = _xml_file_path(composer, folder, xml_score)

    # Security check
    dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "..", "data", "asap-dataset")))
    if !startswith(normpath(file_path), normpath(dataset_dir))
        return Dict("error" => "Invalid path")
    end

    if !isfile(file_path)
        return Dict("error" => "File not found: $(file_path)")
    end

    xml_content = _safe_read_file(file_path)
    if xml_content === nothing
        return Dict("error" => "Could not read file")
    end

    note_positions = _parse_note_positions_from_xml(xml_content)

    return Dict(
        "note_positions" => note_positions,
        "composer" => composer,
        "folder" => folder,
        "xml_score" => xml_score
    )
end

# Map DB point indices to note positions for SVG highlighting
function map_note_positions_to_db_points()
    payload = _payload()
    p = _subhash(payload, "map")

    composer = string(get(p, "composer", ""))
    folder = string(get(p, "folder", ""))
    xml_score = string(get(p, "xml_score", ""))
    part = string(get(p, "part", ""))
    staff = string(get(p, "staff", ""))
    voice = string(get(p, "voice", ""))
    phrase_index = _parse_int(get(p, "phrase_index", 0))
    db_point_indices = get(p, "db_point_indices", Int[])

    if isempty(composer) || isempty(folder) || isempty(xml_score)
        return Dict("error" => "composer, folder, and xml_score are required")
    end

    file_path = _xml_file_path(composer, folder, xml_score)

    # Security check
    dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "..", "data", "asap-dataset")))
    if !startswith(normpath(file_path), normpath(dataset_dir))
        return Dict("error" => "Invalid path")
    end

    if !isfile(file_path)
        return Dict("error" => "File not found: $(file_path)")
    end

    xml_content = _safe_read_file(file_path)
    if xml_content === nothing
        return Dict("error" => "Could not read file")
    end

    # Get note positions
    note_positions = _parse_note_positions_from_xml(xml_content)

    # Filter for specific part, staff, voice
    part_key = "part_$(part)"
    if !haskey(note_positions, part_key)
        return Dict("error" => "Part not found: $(part)")
    end

    part_data = note_positions[part_key]

    # Collect all notes from this part, filter by staff and voice
    all_notes = Vector{Dict{String, Any}}()
    for (measure_key, measure_notes) in part_data
        for note in measure_notes
            if string(note["staff"]) == staff && string(note["voice"]) == voice
                push!(all_notes, merge(note, Dict("measure" => replace(measure_key, "measure_" => ""))))
            end
        end
    end

    # Sort notes by start_time
    sort!(all_notes, by = n -> n["start_time"])

    # Group into phrases based on large gaps (simplified version)
    phrases = Vector{Vector{Dict{String, Any}}}()
    current_phrase = Vector{Dict{String, Any}}()

    for i in 1:length(all_notes)
        note = all_notes[i]

        if !isempty(current_phrase)
            prev_note = current_phrase[end]
            gap = note["start_time"] - (prev_note["start_time"] + prev_note["duration"])

            # Simple phrase splitting: gap > 4 quarter notes (assuming 240 divisions per quarter)
            if gap > 960  # 4 * 240
                push!(phrases, copy(current_phrase))
                empty!(current_phrase)
            end
        end

        push!(current_phrase, note)
    end

    !isempty(current_phrase) && push!(phrases, current_phrase)

    # Get notes for the requested phrase
    if phrase_index <= 0 || phrase_index > length(phrases)
        return Dict("error" => "phrase_index out of range: $(phrase_index) (available: 1-$(length(phrases)))")
    end

    phrase_notes = phrases[phrase_index]

    # Map DB point indices to note positions
    mapped_notes = Vector{Dict{String, Any}}()
    for db_idx in db_point_indices
        if 1 <= db_idx <= length(phrase_notes)
            note = phrase_notes[db_idx]
            push!(mapped_notes, Dict(
                "db_point_index" => db_idx,
                "step" => note["step"],
                "octave" => note["octave"],
                "alter" => note["alter"],
                "measure" => note["measure"],
                "start_time" => note["start_time"],
                "duration" => note["duration"],
                "is_chord" => note["is_chord"]
            ))
        end
    end

    return Dict(
        "mapped_notes" => mapped_notes,
        "total_notes_in_phrase" => length(phrase_notes),
        "phrase_index" => phrase_index,
        "num_phrases" => length(phrases)
    )
end

end # module
