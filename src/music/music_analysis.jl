module MusicAnalysis

using EzXML
using ..Config
using ..PolyphonicClusterManager
using ..DissonanceStmManager

struct RequestError <: Exception
  code::String
  message::String
end
Base.showerror(io::IO, err::RequestError) = print(io, err.message)

const MAX_RHYTHM_DENOMINATOR = 60
const MAX_XML_BYTES = 10_000_000
const MAX_ANALYSIS_STEPS = 200_000
const DEFAULT_DYNAMIC = 0.65
const DEFAULT_TEMPO = 120.0

const DYNAMIC_VALUES = Dict(
  "pppp" => 0.08,
  "ppp" => 0.15,
  "pp" => 0.25,
  "p" => 0.35,
  "mp" => 0.50,
  "mf" => 0.65,
  "f" => 0.78,
  "ff" => 0.90,
  "fff" => 1.00,
  "ffff" => 1.00,
)

struct NoteEvent
  stream_key::Tuple{String,String,String}
  part_id::String
  start_q::Rational{Int}
  end_q::Rational{Int}
  pitch::Int
  tie_start::Bool
  tie_stop::Bool
end

struct DynamicEvent
  part_id::String
  time_q::Rational{Int}
  value::Float64
end

struct WedgeEvent
  part_id::String
  start_q::Rational{Int}
  end_q::Rational{Int}
  kind::String
end

struct TempoEvent
  time_q::Rational{Int}
  bpm::Float64
end

struct ParsedScore
  notes::Vector{NoteEvent}
  dynamics::Vector{DynamicEvent}
  wedges::Vector{WedgeEvent}
  tempos::Vector{TempoEvent}
  part_names::Dict{String,String}
  total_q::Rational{Int}
end

function _child_elements(node, name::AbstractString)
  out = Any[]
  for child in EzXML.eachelement(node)
    EzXML.nodename(child) == name && push!(out, child)
  end
  return out
end

function _first_child(node, name::AbstractString)
  xs = _child_elements(node, name)
  return isempty(xs) ? nothing : xs[1]
end

function _child_text(node, name::AbstractString, default::AbstractString="")
  child = _first_child(node, name)
  child === nothing && return String(default)
  return strip(EzXML.nodecontent(child))
end

_has_child(node, name::AbstractString) = _first_child(node, name) !== nothing

function _attr(node, name::AbstractString, default::AbstractString="")
  try
    return String(node[name])
  catch
    return String(default)
  end
end

function _parse_int_text(node, name::AbstractString, default::Int=0)::Int
  txt = _child_text(node, name, "")
  isempty(txt) && return default
  parsed = tryparse(Int, txt)
  return parsed === nothing ? default : parsed
end

function _parse_float_text(node, name::AbstractString, default::Float64=0.0)::Float64
  txt = _child_text(node, name, "")
  isempty(txt) && return default
  parsed = tryparse(Float64, txt)
  return parsed === nothing ? default : parsed
end

function _midi_pitch(note)::Union{Int,Nothing}
  pitch = _first_child(note, "pitch")
  pitch === nothing && return nothing
  step = uppercase(_child_text(pitch, "step", ""))
  octave_txt = _child_text(pitch, "octave", "")
  isempty(step) && return nothing
  octave = tryparse(Int, octave_txt)
  octave === nothing && return nothing
  base = Dict("C"=>0, "D"=>2, "E"=>4, "F"=>5, "G"=>7, "A"=>9, "B"=>11)
  haskey(base, step) || return nothing
  alter = _parse_float_text(pitch, "alter", 0.0)
  return clamp((octave + 1) * 12 + base[step] + round(Int, alter), 0, 127)
end

function _parse_part_names(score)::Dict{String,String}
  names = Dict{String,String}()
  for part_list in _child_elements(score, "part-list")
    for score_part in _child_elements(part_list, "score-part")
      id = _attr(score_part, "id", "")
      isempty(id) && continue
      name = _child_text(score_part, "part-name", id)
      names[id] = isempty(name) ? id : name
    end
  end
  return names
end

function _tie_flags(note)::Tuple{Bool,Bool}
  tie_start = false
  tie_stop = false
  for tie in _child_elements(note, "tie")
    t = lowercase(_attr(tie, "type", ""))
    t == "start" && (tie_start = true)
    t == "stop" && (tie_stop = true)
  end
  for notations in _child_elements(note, "notations")
    for tied in _child_elements(notations, "tied")
      t = lowercase(_attr(tied, "type", ""))
      t == "start" && (tie_start = true)
      t == "stop" && (tie_stop = true)
    end
  end
  return tie_start, tie_stop
end

function _dynamic_from_direction(direction)::Union{Nothing,Float64}
  sound = _first_child(direction, "sound")
  if sound !== nothing
    raw = strip(_attr(sound, "dynamics", ""))
    if !isempty(raw)
      parsed = tryparse(Float64, raw)
      parsed === nothing || return clamp(parsed / 100.0, 0.0, 1.0)
    end
  end
  for direction_type in _child_elements(direction, "direction-type")
    dyn = _first_child(direction_type, "dynamics")
    dyn === nothing && continue
    for mark in EzXML.eachelement(dyn)
      key = lowercase(EzXML.nodename(mark))
      haskey(DYNAMIC_VALUES, key) && return DYNAMIC_VALUES[key]
    end
  end
  return nothing
end

function _tempo_from_direction(direction)::Union{Nothing,Float64}
  sound = _first_child(direction, "sound")
  sound === nothing && return nothing
  raw = strip(_attr(sound, "tempo", ""))
  isempty(raw) && return nothing
  parsed = tryparse(Float64, raw)
  parsed === nothing && return nothing
  return parsed > 0 ? parsed : nothing
end

function _wedge_specs(direction)
  out = Tuple{String,String}[]
  for direction_type in _child_elements(direction, "direction-type")
    for wedge in _child_elements(direction_type, "wedge")
      push!(out, (lowercase(_attr(wedge, "type", "")), _attr(wedge, "number", "1")))
    end
  end
  return out
end

function _parse_document(doc)::ParsedScore
  score = EzXML.root(doc)
  EzXML.nodename(score) == "score-partwise" || throw(RequestError(
    "unsupported_musicxml_type",
    "Only score-partwise MusicXML is supported.",
  ))

  part_names = _parse_part_names(score)
  notes = NoteEvent[]
  dynamics = DynamicEvent[]
  wedges = WedgeEvent[]
  tempos = TempoEvent[]
  open_wedges = Dict{Tuple{String,String},Tuple{Rational{Int},String}}()
  total_q = 0 // 1

  for part in _child_elements(score, "part")
    part_id = _attr(part, "id", "P")
    divisions = 1
    part_time = 0 // 1

    for measure in _child_elements(part, "measure")
      cursor = part_time
      max_cursor = cursor
      last_note_start = cursor

      for element in EzXML.eachelement(measure)
        name = EzXML.nodename(element)
        if name == "attributes"
          div = _parse_int_text(element, "divisions", divisions)
          div > 0 && (divisions = div)
        elseif name == "backup"
          duration = _parse_int_text(element, "duration", 0)
          cursor -= duration // max(divisions, 1)
          cursor < part_time && (cursor = part_time)
        elseif name == "forward"
          duration = _parse_int_text(element, "duration", 0)
          cursor += duration // max(divisions, 1)
          max_cursor = max(max_cursor, cursor)
        elseif name == "direction"
          offset = _parse_int_text(element, "offset", 0)
          direction_time = cursor + offset // max(divisions, 1)
          dyn = _dynamic_from_direction(element)
          dyn === nothing || push!(dynamics, DynamicEvent(part_id, direction_time, dyn))
          tempo = _tempo_from_direction(element)
          tempo === nothing || push!(tempos, TempoEvent(direction_time, tempo))

          for (typ, number) in _wedge_specs(element)
            key = (part_id, number)
            if typ == "crescendo" || typ == "diminuendo"
              open_wedges[key] = (direction_time, typ)
            elseif typ == "stop" && haskey(open_wedges, key)
              start_q, kind = open_wedges[key]
              direction_time > start_q && push!(wedges, WedgeEvent(part_id, start_q, direction_time, kind))
              delete!(open_wedges, key)
            end
          end
        elseif name == "note"
          _has_child(element, "grace") && continue
          duration_raw = _parse_int_text(element, "duration", 0)
          duration_raw <= 0 && continue
          duration_q = duration_raw // max(divisions, 1)
          is_chord = _has_child(element, "chord")
          start_q = is_chord ? last_note_start : cursor
          end_q = start_q + duration_q

          if !_has_child(element, "rest")
            pitch = _midi_pitch(element)
            if pitch !== nothing
              staff = _child_text(element, "staff", "1")
              voice = _child_text(element, "voice", "1")
              tie_start, tie_stop = _tie_flags(element)
              push!(notes, NoteEvent((part_id, staff, voice), part_id, start_q, end_q, pitch, tie_start, tie_stop))
            end
          end

          if !is_chord
            last_note_start = start_q
            cursor += duration_q
            max_cursor = max(max_cursor, cursor)
          else
            max_cursor = max(max_cursor, end_q)
          end
        end
      end

      part_time = max_cursor
      total_q = max(total_q, part_time)
    end
  end

  sort!(notes; by=e -> (e.start_q, e.stream_key, e.pitch, e.end_q))
  sort!(dynamics; by=e -> (e.time_q, e.part_id))
  sort!(wedges; by=e -> (e.start_q, e.part_id))
  sort!(tempos; by=e -> e.time_q)
  isempty(notes) && throw(RequestError("empty_score", "MusicXML contains no pitched notes."))
  total_q > 0 || throw(RequestError("empty_score", "MusicXML has no positive duration."))
  return ParsedScore(notes, dynamics, wedges, tempos, part_names, total_q)
end

function parse_musicxml_text(xml_text::AbstractString)::ParsedScore
  sizeof(xml_text) <= MAX_XML_BYTES || throw(RequestError(
    "musicxml_too_large",
    "MusicXML is larger than $(MAX_XML_BYTES) bytes.",
  ))
  isempty(strip(xml_text)) && throw(RequestError("empty_musicxml", "MusicXML text is empty."))
  try
    return mktemp() do path, io
      write(io, xml_text)
      close(io)
      _parse_document(EzXML.readxml(path))
    end
  catch err
    err isa RequestError && rethrow()
    throw(RequestError("invalid_musicxml", "MusicXML could not be parsed: $(err)"))
  end
end

function _checked_lcm(current::Int, value::Int)::Int
  value <= 0 && return current
  next = div(current, gcd(current, value)) * value
  next <= MAX_RHYTHM_DENOMINATOR || throw(RequestError(
    "rhythm_resolution_exceeded",
    "Exact rhythmic grid denominator $(next) exceeds the supported maximum $(MAX_RHYTHM_DENOMINATOR).",
  ))
  return next
end

function rhythm_denominator(parsed::ParsedScore)::Int
  den = 1
  for event in parsed.notes
    den = _checked_lcm(den, denominator(event.start_q))
    den = _checked_lcm(den, denominator(event.end_q))
  end
  for event in parsed.dynamics
    den = _checked_lcm(den, denominator(event.time_q))
  end
  for event in parsed.wedges
    den = _checked_lcm(den, denominator(event.start_q))
    den = _checked_lcm(den, denominator(event.end_q))
  end
  for event in parsed.tempos
    den = _checked_lcm(den, denominator(event.time_q))
  end
  return den
end

function _base_dynamic_at(parsed::ParsedScore, part_id::String, t::Rational{Int})::Float64
  value = DEFAULT_DYNAMIC
  for event in parsed.dynamics
    event.part_id == part_id || continue
    event.time_q <= t || continue
    value = event.value
  end
  return value
end

function _next_dynamic_after(parsed::ParsedScore, part_id::String, t::Rational{Int})
  candidates = DynamicEvent[e for e in parsed.dynamics if e.part_id == part_id && e.time_q > t]
  isempty(candidates) && return nothing
  sort!(candidates; by=e -> e.time_q)
  return candidates[1]
end

function dynamic_at(parsed::ParsedScore, part_id::String, t::Rational{Int})::Float64
  base = _base_dynamic_at(parsed, part_id, t)
  for wedge in parsed.wedges
    wedge.part_id == part_id || continue
    wedge.start_q <= t <= wedge.end_q || continue
    start_value = _base_dynamic_at(parsed, part_id, wedge.start_q)
    target_event = _next_dynamic_after(parsed, part_id, wedge.start_q)
    target = if target_event !== nothing && target_event.time_q <= wedge.end_q
      target_event.value
    elseif wedge.kind == "crescendo"
      clamp(start_value + 0.20, 0.0, 1.0)
    else
      clamp(start_value - 0.20, 0.0, 1.0)
    end
    span = float(wedge.end_q - wedge.start_q)
    span <= 0 && return target
    ratio = clamp(float(t - wedge.start_q) / span, 0.0, 1.0)
    return clamp(start_value + (target - start_value) * ratio, 0.0, 1.0)
  end
  return base
end

function tempo_at(parsed::ParsedScore, t::Rational{Int})::Float64
  bpm = DEFAULT_TEMPO
  for event in parsed.tempos
    event.time_q <= t && (bpm = event.bpm)
  end
  return bpm
end

function seconds_at(parsed::ParsedScore, t::Rational{Int})::Float64
  t <= 0 && return 0.0
  events = sort(copy(parsed.tempos); by=e -> e.time_q)
  elapsed = 0.0
  cursor = 0 // 1
  bpm = DEFAULT_TEMPO
  for event in events
    if event.time_q <= cursor
      bpm = event.bpm
      continue
    end
    event.time_q >= t && break
    elapsed += float(event.time_q - cursor) * 60.0 / bpm
    cursor = event.time_q
    bpm = event.bpm
  end
  elapsed += float(t - cursor) * 60.0 / bpm
  return elapsed
end

function _median_note(notes::Vector{Int})::Union{Nothing,Float64}
  isempty(notes) && return nothing
  sorted = sort(unique(notes))
  return float(sorted[cld(length(sorted), 2)])
end

function _concordance(values::Vector{Float64}, width::Float64)
  length(values) < 2 && return nothing
  denom = max(abs(width), eps(Float64))
  total = 0.0
  count = 0
  for i in 1:(length(values)-1), j in (i+1):length(values)
    total += clamp(abs(values[i] - values[j]) / denom, 0.0, 1.0)
    count += 1
  end
  count == 0 && return nothing
  return clamp(1.0 - total / float(count), 0.0, 1.0)
end

function _csv_rows(path::AbstractString)
  rows = Vector{Vector{String}}()
  for raw in eachline(path)
    fields = String[]
    buf = IOBuffer()
    quoted = false
    i = firstindex(raw)
    while i <= lastindex(raw)
      c = raw[i]
      if c == '"'
        if quoted && i < lastindex(raw) && raw[nextind(raw, i)] == '"'
          print(buf, '"')
          i = nextind(raw, i)
        else
          quoted = !quoted
        end
      elseif c == ',' && !quoted
        push!(fields, String(take!(buf)))
      else
        print(buf, c)
      end
      i = nextind(raw, i)
    end
    push!(fields, String(take!(buf)))
    push!(rows, fields)
  end
  return rows
end

function list_asap_sources(dataset_dir::AbstractString)
  metadata_path = joinpath(dataset_dir, "metadata.csv")
  isfile(metadata_path) || throw(RequestError(
    "asap_dataset_missing",
    "ASAP metadata.csv was not found. Run git submodule update --init --recursive.",
  ))
  rows = _csv_rows(metadata_path)
  isempty(rows) && return Any[]
  header = Dict(name => idx for (idx, name) in enumerate(rows[1]))
  required = ["composer", "title", "folder", "xml_score"]
  all(haskey(header, key) for key in required) || throw(RequestError(
    "asap_metadata_invalid",
    "ASAP metadata.csv is missing required columns.",
  ))
  out = Any[]
  seen = Set{String}()
  for row in rows[2:end]
    length(row) < length(rows[1]) && continue
    xml_score = strip(row[header["xml_score"]])
    isempty(xml_score) && continue
    lowercase(splitext(xml_score)[2]) in (".xml", ".musicxml") || continue
    xml_score in seen && continue
    push!(seen, xml_score)
    push!(out, Dict(
      "composer" => strip(row[header["composer"]]),
      "title" => strip(row[header["title"]]),
      "folder" => strip(row[header["folder"]]),
      "xml_score" => xml_score,
    ))
  end
  return out
end

function _make_poly_series(values)::Vector{Vector{Float64}}
  return Vector{Float64}[value === nothing ? Float64[] : Float64[float(value)] for value in values]
end

function _analyse_manager(
  series::Vector{Vector{Float64}},
  scoring;
  range_min::Float64,
  range_max::Float64,
  merge_threshold_ratio::Float64,
  metric_weights::NTuple{3,Float64},
  max_set_size::Int=1,
  streamwise::Bool=false,
  stream_axis_offset::Float64=1.0,
  stream_axis_capacity::Int=1,
)
  n = length(series)
  min_window = Config.POLYPHONIC_MIN_WINDOW_SIZE
  axes = Dict(
    "prediction" => Any[nothing for _ in 1:n],
    "diversity" => Any[nothing for _ in 1:n],
    "shape" => Any[nothing for _ in 1:n],
    "occurrence" => Any[nothing for _ in 1:n],
    "mass" => Any[nothing for _ in 1:n],
    "combined" => Any[nothing for _ in 1:n],
  )
  raw = Dict(
    "distance" => Any[nothing for _ in 1:n],
    "quantity" => Any[nothing for _ in 1:n],
    "complexity" => Any[nothing for _ in 1:n],
    "occurrenceDistance" => Any[nothing for _ in 1:n],
    "occurrenceQuantity" => Any[nothing for _ in 1:n],
    "occurrenceComplexity" => Any[nothing for _ in 1:n],
  )
  n < min_window && return Dict("axes"=>axes, "raw"=>raw, "clusters"=>Any[])

  seed = Vector{Float64}[copy(series[i]) for i in 1:min_window]
  manager = PolyphonicClusterManager.Manager(
    seed,
    merge_threshold_ratio,
    min_window,
    false;
    range_min=range_min,
    range_max=range_max,
    max_set_size=max(max_set_size, 1),
    use_streamwise_surface_average=streamwise,
    stream_axis_offset=stream_axis_offset,
    stream_axis_capacity=max(stream_axis_capacity, 1),
    recency=0.0,
  )
  PolyphonicClusterManager.process_data!(manager)
  scoring.initial_calc_values!(manager, PolyphonicClusterManager.transform_clusters(manager.clusters, min_window))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

  if n > min_window
    for index in (min_window + 1):n
      observed = scoring.evaluate_observed_complexity!(manager, series[index]; metric_weights=metric_weights)
      for key in keys(axes)
        axes[key][index] = get(observed, key, nothing)
      end
      raw_metrics = get(observed, "raw", Dict{String,Any}())
      raw["distance"][index] = get(raw_metrics, "distance", nothing)
      raw["quantity"][index] = get(raw_metrics, "quantity", nothing)
      raw["complexity"][index] = get(raw_metrics, "complexity", nothing)
      raw["occurrenceDistance"][index] = get(raw_metrics, "occurrenceDistance", nothing)
      raw["occurrenceQuantity"][index] = get(raw_metrics, "occurrenceQuantity", nothing)
      raw["occurrenceComplexity"][index] = get(raw_metrics, "occurrenceComplexity", nothing)
    end
  end

  return Dict(
    "axes" => axes,
    "raw" => raw,
    "clusters" => PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window),
  )
end

function analyse_music_payload(params, scoring)
  parsed = parse_musicxml_text(string(get(params, "musicxml_text", "")))

  grid_den = rhythm_denominator(parsed)
  total_steps_r = parsed.total_q * grid_den
  denominator(total_steps_r) == 1 || throw(RequestError(
    "rhythm_grid_internal_error",
    "MusicXML event boundaries did not align to the exact grid.",
  ))
  step_count = Int(total_steps_r)
  step_count > 0 || throw(RequestError("empty_score", "MusicXML has no analysable duration."))
  step_count <= MAX_ANALYSIS_STEPS || throw(RequestError(
    "score_too_large",
    "Exact grid would require $(step_count) steps; maximum is $(MAX_ANALYSIS_STEPS).",
  ))

  stream_keys = Tuple{String,String,String}[]
  seen_keys = Set{Tuple{String,String,String}}()
  for event in parsed.notes
    if !(event.stream_key in seen_keys)
      push!(stream_keys, event.stream_key)
      push!(seen_keys, event.stream_key)
    end
  end
  stream_ids = collect(1:length(stream_keys))
  id_by_key = Dict(key => idx for (idx, key) in enumerate(stream_keys))
  key_by_id = Dict(idx => key for (idx, key) in enumerate(stream_keys))

  notes_by_stream = Dict(id => [Int[] for _ in 1:step_count] for id in stream_ids)
  onsets_by_stream = Dict(id => [Set{Int}() for _ in 1:step_count] for id in stream_ids)

  for event in parsed.notes
    id = id_by_key[event.stream_key]
    start_r = event.start_q * grid_den
    end_r = event.end_q * grid_den
    denominator(start_r) == 1 || throw(RequestError("rhythm_grid_internal_error", "Note onset does not align to exact grid."))
    denominator(end_r) == 1 || throw(RequestError("rhythm_grid_internal_error", "Note ending does not align to exact grid."))
    start_index = clamp(Int(start_r) + 1, 1, step_count + 1)
    end_exclusive = clamp(Int(end_r) + 1, 1, step_count + 1)
    for step in start_index:(end_exclusive - 1)
      push!(notes_by_stream[id][step], event.pitch)
    end
    if 1 <= start_index <= step_count && !event.tie_stop
      push!(onsets_by_stream[id][start_index], event.pitch)
    end
  end

  for id in stream_ids, step in 1:step_count
    sort!(notes_by_stream[id][step])
    unique!(notes_by_stream[id][step])
  end

  stream_labels = Dict{Int,String}()
  part_by_stream = Dict{Int,String}()
  for id in stream_ids
    part_id, staff, voice = key_by_id[id]
    part_name = get(parsed.part_names, part_id, part_id)
    stream_labels[id] = "$(part_name) / staff $(staff) / voice $(voice)"
    part_by_stream[id] = part_id
  end

  volumes = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)
  ties = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)
  notes_anchor = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)
  areas = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)
  chord_ranges = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)
  densities = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)
  dissonances = Dict(id => Any[nothing for _ in 1:step_count] for id in stream_ids)

  stream_dissonance_mgrs = Dict(id => DissonanceStmManager.Manager() for id in stream_ids)
  global_dissonance_mgr = DissonanceStmManager.Manager()
  global_dissonance = Any[nothing for _ in 1:step_count]
  stream_count = Any[nothing for _ in 1:step_count]
  sounding_note_count = Int[]
  tempo_series = Float64[]

  for step in 1:step_count
    t_q = (step - 1) // grid_den
    onset_seconds = seconds_at(parsed, t_q)
    push!(tempo_series, tempo_at(parsed, t_q))
    active_ids = Int[]
    global_notes = Int[]
    global_amps = Float64[]

    for id in stream_ids
      current_notes = notes_by_stream[id][step]
      is_active = !isempty(current_notes)
      is_active && push!(active_ids, id)

      vol = is_active ? dynamic_at(parsed, part_by_stream[id], t_q) : 0.0
      volumes[id][step] = vol
      prev_notes = step > 1 ? notes_by_stream[id][step - 1] : Int[]
      onset_set = onsets_by_stream[id][step]
      continued = Int[n for n in current_notes if (n in prev_notes) && !(n in onset_set)]
      ties[id][step] = if isempty(current_notes)
        0.0
      elseif !isempty(prev_notes) && Set(current_notes) == Set(prev_notes) && length(continued) == length(current_notes)
        1.0
      elseif !isempty(continued)
        0.5
      else
        0.0
      end

      anchor = _median_note(current_notes)
      notes_anchor[id][step] = anchor
      if anchor === nothing
        areas[id][step] = nothing
        chord_ranges[id][step] = nothing
        densities[id][step] = nothing
      else
        areas[id][step] = float(Config.area_band_low(round(Int, anchor)))
        cr, den = scoring.infer_chord_range_and_density_controls(current_notes)
        chord_ranges[id][step] = float(cr)
        densities[id][step] = den
      end

      if is_active
        each_amp = vol / float(max(length(current_notes), 1))
        amps = fill(each_amp, length(current_notes))
        calibrator = scoring.build_dissonance_calibrator(stream_dissonance_mgrs[id])
        raw_dissonance = DissonanceStmManager.commit!(stream_dissonance_mgrs[id], copy(current_notes), amps, onset_seconds)
        dissonances[id][step] = scoring.calibrate_dissonance(raw_dissonance, calibrator)
        append!(global_notes, current_notes)
        append!(global_amps, amps)
      else
        DissonanceStmManager.prune!(stream_dissonance_mgrs[id], onset_seconds)
        dissonances[id][step] = 0.0
      end
    end

    stream_count[step] = float(length(active_ids))
    push!(sounding_note_count, length(global_notes))
    global_calibrator = scoring.build_dissonance_calibrator(global_dissonance_mgr)
    if isempty(global_notes)
      DissonanceStmManager.prune!(global_dissonance_mgr, onset_seconds)
      global_dissonance[step] = 0.0
    else
      raw_global_dissonance = DissonanceStmManager.commit!(global_dissonance_mgr, global_notes, global_amps, onset_seconds)
      global_dissonance[step] = scoring.calibrate_dissonance(raw_global_dissonance, global_calibrator)
    end
  end

  scalar_streams = Dict(
    "note" => notes_anchor,
    "area" => areas,
    "chord_range" => chord_ranges,
    "density" => densities,
    "vol" => volumes,
    "tie" => ties,
    "dissonance" => dissonances,
  )
  dimension_ranges = Dict(
    "note" => (0.0, 127.0),
    "area" => (0.0, 127.0),
    "chord_range" => (0.0, float(Config.CHORD_RANGE_VALUE_MAX)),
    "density" => (0.0, 1.0),
    "vol" => (0.0, 1.0),
    "tie" => (0.0, 1.0),
    "dissonance" => (0.0, 1.0),
    "stream_count" => (0.0, float(max(length(stream_ids), 1))),
  )
  merge_threshold_ratio = clamp(
    try float(get(params, "merge_threshold_ratio", Config.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO)) catch; Config.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO end,
    0.0,
    1.0,
  )

  dimensions = Dict{String,Any}()
  dimension_order = ["note", "area", "chord_range", "density", "vol", "tie", "dissonance", "stream_count"]
  all_notes_by_step = [
    sort!(unique(vcat((notes_by_stream[id][step] for id in stream_ids)...)))
    for step in 1:step_count
  ]

  for dim in dimension_order
    range_min, range_max = dimension_ranges[dim]
    global_display = Any[nothing for _ in 1:step_count]
    concordance = Any[nothing for _ in 1:step_count]
    stream_values_payload = Dict{String,Any}()
    stream_analysis_payload = Dict{String,Any}()
    stream_clusters_payload = Dict{String,Any}()

    if dim == "stream_count"
      global_series = _make_poly_series(stream_count)
      global_display = copy(stream_count)
      analysed_global = _analyse_manager(global_series, scoring;
        range_min=range_min, range_max=range_max,
        merge_threshold_ratio=merge_threshold_ratio,
        metric_weights=Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS)
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance),
        "analysis"=>Dict("global"=>Dict("axes"=>analysed_global["axes"], "raw"=>analysed_global["raw"]), "streams"=>stream_analysis_payload),
        "clusters"=>Dict("global"=>analysed_global["clusters"], "streams"=>stream_clusters_payload))
      continue
    end

    stream_source = scalar_streams[dim]
    for id in stream_ids
      stream_values_payload[string(id)] = stream_source[id]
      analysed_stream = _analyse_manager(_make_poly_series(stream_source[id]), scoring;
        range_min=range_min, range_max=range_max,
        merge_threshold_ratio=merge_threshold_ratio,
        metric_weights=Config.POLYPHONIC_STREAM_METRIC_WEIGHTS)
      stream_analysis_payload[string(id)] = Dict("axes"=>analysed_stream["axes"], "raw"=>analysed_stream["raw"])
      stream_clusters_payload[string(id)] = analysed_stream["clusters"]
    end

    if dim == "note"
      for step in 1:step_count
        global_display[step] = _median_note(all_notes_by_step[step])
        vals = Float64[float(stream_source[id][step]) for id in stream_ids if stream_source[id][step] !== nothing]
        concordance[step] = _concordance(vals, range_max - range_min)
      end
      analysed_global = _analyse_manager(_make_poly_series(global_display), scoring;
        range_min=range_min, range_max=range_max,
        merge_threshold_ratio=merge_threshold_ratio,
        metric_weights=Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS)
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance),
        "analysis"=>Dict("global"=>Dict("axes"=>analysed_global["axes"], "raw"=>analysed_global["raw"]), "streams"=>stream_analysis_payload),
        "clusters"=>Dict("global"=>analysed_global["clusters"], "streams"=>stream_clusters_payload))
      continue
    end

    if dim == "tie" || dim == "dissonance"
      if dim == "dissonance"
        global_display = copy(global_dissonance)
      end
      for step in 1:step_count
        active_vals = Float64[float(stream_source[id][step]) for id in stream_ids if !isempty(notes_by_stream[id][step])]
        if dim == "tie"
          global_display[step] = isempty(active_vals) ? 0.0 : sum(active_vals) / float(length(active_vals))
        end
        concordance[step] = _concordance(active_vals, 1.0)
      end
      analysed_global = _analyse_manager(_make_poly_series(global_display), scoring;
        range_min=0.0, range_max=1.0,
        merge_threshold_ratio=merge_threshold_ratio,
        metric_weights=Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS)
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance),
        "analysis"=>Dict("global"=>Dict("axes"=>analysed_global["axes"], "raw"=>analysed_global["raw"]), "streams"=>stream_analysis_payload),
        "clusters"=>Dict("global"=>analysed_global["clusters"], "streams"=>stream_clusters_payload))
      continue
    end

    offset = max(range_max - range_min + 1.0, 1.0)
    axis = scoring.StableStreamAxis(max(length(stream_ids), 1), stream_ids)
    global_series = Vector{Vector{Float64}}()
    for step in 1:step_count
      ids = Int[]
      vals = Float64[]
      display_vals = Float64[]
      for id in stream_ids
        value = stream_source[id][step]
        include_value = dim == "vol" || !isempty(notes_by_stream[id][step])
        if include_value && value !== nothing
          push!(ids, id)
          push!(vals, float(value))
          push!(display_vals, float(value))
        end
      end
      push!(global_series, scoring._encode_streamwise_row(axis, ids, vals, offset))
      global_display[step] = isempty(display_vals) ? (dim == "vol" ? 0.0 : nothing) : sum(display_vals) / float(length(display_vals))
      concordance[step] = _concordance(display_vals, range_max - range_min)
    end
    encoded_max = range_max + offset * float(max(length(stream_ids) - 1, 0))
    analysed_global = _analyse_manager(global_series, scoring;
      range_min=range_min, range_max=encoded_max,
      merge_threshold_ratio=merge_threshold_ratio,
      metric_weights=Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS,
      max_set_size=max(length(stream_ids), 1),
      streamwise=true,
      stream_axis_offset=offset,
      stream_axis_capacity=max(length(stream_ids), 1))
    dimensions[dim] = Dict(
      "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance),
      "analysis"=>Dict("global"=>Dict("axes"=>analysed_global["axes"], "raw"=>analysed_global["raw"]), "streams"=>stream_analysis_payload),
      "clusters"=>Dict("global"=>analysed_global["clusters"], "streams"=>stream_clusters_payload))
  end

  piano_streams = Any[
    Any[isempty(notes_by_stream[id][step]) ? nothing : copy(notes_by_stream[id][step]) for step in 1:step_count]
    for id in stream_ids
  ]
  piano_velocities = Any[Any[float(volumes[id][step]) for step in 1:step_count] for id in stream_ids]

  return Dict(
    "metadata" => Dict(
      "sourceType"=>string(get(params, "source_type", "upload")),
      "filename"=>string(get(params, "filename", "")),
      "composer"=>string(get(params, "composer", "")),
      "title"=>string(get(params, "title", "")),
      "folder"=>string(get(params, "folder", "")),
      "xmlScore"=>string(get(params, "xml_score", ""))),
    "timing" => Dict(
      "exact"=>true,
      "gridDenominator"=>grid_den,
      "quarterUnit"=>"1/$(grid_den)",
      "stepCount"=>step_count,
      "totalQuarterLength"=>float(parsed.total_q),
      "tempoSeries"=>tempo_series),
    "streams" => Any[
      Dict("id"=>id, "label"=>stream_labels[id], "partId"=>key_by_id[id][1], "staff"=>key_by_id[id][2], "voice"=>key_by_id[id][3])
      for id in stream_ids
    ],
    "pianoRoll" => Dict(
      "streams"=>piano_streams,
      "velocities"=>piano_velocities,
      "streamIds"=>stream_ids,
      "streamLabels"=>[stream_labels[id] for id in stream_ids]),
    "dimensionOrder"=>dimension_order,
    "dimensions"=>dimensions,
    "streamCountSeries"=>stream_count,
    "soundingNoteCountSeries"=>sounding_note_count,
  )
end

end # module
