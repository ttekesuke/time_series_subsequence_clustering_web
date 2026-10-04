module MusicAnalysis

using EzXML
using ..Config
using ..PolyphonicClusterManager
using ..DissonanceStmManager
using ..MusicXmlEvents

struct RequestError <: Exception
  code::String
  message::String
end
Base.showerror(io::IO, err::RequestError) = print(io, err.message)

struct AnalysisCancelled <: Exception end
Base.showerror(io::IO, ::AnalysisCancelled) = print(io, "Music analysis was cancelled.")

@inline function _check_analysis_cancel(cancel_check)::Nothing
  if cancel_check !== nothing && cancel_check() === true
    throw(AnalysisCancelled())
  end
  return nothing
end

function _notify_analysis_progress(progress_callback, payload::Dict{String,Any})::Nothing
  progress_callback === nothing || progress_callback(payload)
  return nothing
end

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

const _child_elements = MusicXmlEvents.child_elements
const _first_child = MusicXmlEvents.first_child
const _child_text = MusicXmlEvents.child_text
const _attr = MusicXmlEvents.attr
const _parse_int_text = MusicXmlEvents.parse_int_text

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

  dynamics = DynamicEvent[]
  wedges = WedgeEvent[]
  tempos = TempoEvent[]
  open_wedges = Dict{Tuple{String,String},Tuple{Rational{Int},String}}()
  parsed = MusicXmlEvents.parse_document(doc; on_direction=(part_id, cursor, divisions, element) -> begin
    offset = _parse_int_text(element, "offset", 0)
    direction_time = cursor + offset // divisions
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
  end)
  notes = NoteEvent[NoteEvent((event.part_id, event.staff, event.voice), event.part_id,
    event.start_q, event.end_q, event.pitch, event.tie_start, event.tie_stop)
    for event in parsed.notes]

  sort!(notes; by=e -> (e.start_q, e.stream_key, e.pitch, e.end_q))
  sort!(dynamics; by=e -> (e.time_q, e.part_id))
  sort!(wedges; by=e -> (e.start_q, e.part_id))
  sort!(tempos; by=e -> e.time_q)
  isempty(notes) && throw(RequestError("empty_score", "MusicXML contains no pitched notes."))
  parsed.total_q > 0 || throw(RequestError("empty_score", "MusicXML has no positive duration."))
  return ParsedScore(notes, dynamics, wedges, tempos, parsed.part_names, parsed.total_q)
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
  den = _checked_lcm(1, denominator(parsed.total_q))
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

# The parser has already sorted events by time. Keep their original order within
# equal-time groups: the last tempo/dynamic wins, while the first active wedge
# wins when wedges overlap.
struct IndexedWedge
  event::WedgeEvent
  start_value::Float64
  target_value::Float64
end

struct PartEventIndex
  dynamics::Vector{DynamicEvent}
  dynamic_times::Vector{Rational{Int}}
  wedges::Vector{IndexedWedge}
  wedge_starts::Vector{Rational{Int}}
  wedge_prefix_max_end::Vector{Rational{Int}}
end

struct ScoreEventIndex
  tempo_events::Vector{TempoEvent}
  tempo_times::Vector{Rational{Int}}
  segment_starts::Vector{Rational{Int}}
  segment_seconds::Vector{Float64}
  segment_bpms::Vector{Float64}
  parts::Dict{String,PartEventIndex}
end

function _base_dynamic_at(dynamics::Vector{DynamicEvent},
    times::Vector{Rational{Int}}, t::Rational{Int})::Float64
  pos = searchsortedlast(times, t)
  return pos == 0 ? DEFAULT_DYNAMIC : dynamics[pos].value
end

function _score_event_index(parsed::ParsedScore)::ScoreEventIndex
  tempo_times = Rational{Int}[event.time_q for event in parsed.tempos]
  segment_starts = Rational{Int}[0 // 1]
  segment_seconds = Float64[0.0]
  segment_bpms = Float64[]
  bpm = DEFAULT_TEMPO
  i = 1
  while i <= length(parsed.tempos) && parsed.tempos[i].time_q <= 0
    bpm = parsed.tempos[i].bpm
    i += 1
  end
  push!(segment_bpms, bpm)
  cursor = 0 // 1
  elapsed = 0.0
  while i <= length(parsed.tempos)
    boundary = parsed.tempos[i].time_q
    elapsed += float(boundary - cursor) * 60.0 / bpm
    push!(segment_starts, boundary)
    push!(segment_seconds, elapsed)
    while i <= length(parsed.tempos) && parsed.tempos[i].time_q == boundary
      bpm = parsed.tempos[i].bpm
      i += 1
    end
    push!(segment_bpms, bpm)
    cursor = boundary
  end

  dynamics_by_part = Dict{String,Vector{DynamicEvent}}()
  wedges_by_part = Dict{String,Vector{WedgeEvent}}()
  for event in parsed.dynamics
    push!(get!(dynamics_by_part, event.part_id, DynamicEvent[]), event)
  end
  for event in parsed.wedges
    push!(get!(wedges_by_part, event.part_id, WedgeEvent[]), event)
  end
  parts = Dict{String,PartEventIndex}()
  for part_id in union(keys(dynamics_by_part), keys(wedges_by_part))
    dynamics = get(dynamics_by_part, part_id, DynamicEvent[])
    dynamic_times = Rational{Int}[event.time_q for event in dynamics]
    wedges = IndexedWedge[]
    starts = Rational{Int}[]
    prefix_max_end = Rational{Int}[]
    max_end = 0 // 1
    for event in get(wedges_by_part, part_id, WedgeEvent[])
      start_value = _base_dynamic_at(dynamics, dynamic_times, event.start_q)
      next_pos = searchsortedlast(dynamic_times, event.start_q) + 1
      target = if next_pos <= length(dynamics) && dynamics[next_pos].time_q <= event.end_q
        dynamics[next_pos].value
      elseif event.kind == "crescendo"
        clamp(start_value + 0.20, 0.0, 1.0)
      else
        clamp(start_value - 0.20, 0.0, 1.0)
      end
      push!(wedges, IndexedWedge(event, start_value, target))
      push!(starts, event.start_q)
      max_end = isempty(prefix_max_end) ? event.end_q : max(max_end, event.end_q)
      push!(prefix_max_end, max_end)
    end
    parts[part_id] = PartEventIndex(dynamics, dynamic_times, wedges, starts, prefix_max_end)
  end
  return ScoreEventIndex(parsed.tempos, tempo_times, segment_starts,
    segment_seconds, segment_bpms, parts)
end

function _seconds_at(index::ScoreEventIndex, t::Rational{Int}, segment_pos::Int=0)::Float64
  t <= 0 && return 0.0
  pos = segment_pos > 0 ? segment_pos : searchsortedlast(index.segment_starts, t)
  return index.segment_seconds[pos] +
    float(t - index.segment_starts[pos]) * 60.0 / index.segment_bpms[pos]
end

function _tempo_at(index::ScoreEventIndex, t::Rational{Int})::Float64
  pos = searchsortedlast(index.tempo_times, t)
  return pos == 0 ? DEFAULT_TEMPO : index.tempo_events[pos].bpm
end

function _dynamic_at(index::ScoreEventIndex, part_id::String, t::Rational{Int},
    dynamic_pos::Int=0, started_wedges::Int=-1)::Float64
  part = get(index.parts, part_id, nothing)
  part === nothing && return DEFAULT_DYNAMIC
  pos = dynamic_pos > 0 ? dynamic_pos : searchsortedlast(part.dynamic_times, t)
  base = pos == 0 ? DEFAULT_DYNAMIC : part.dynamics[pos].value
  started = started_wedges >= 0 ? started_wedges : searchsortedlast(part.wedge_starts, t)
  if started == 0 || part.wedge_prefix_max_end[started] < t
    return base
  end
  first_active = searchsortedfirst(part.wedge_prefix_max_end, t)
  wedge = part.wedges[first_active]
  span = float(wedge.event.end_q - wedge.event.start_q)
  span <= 0 && return wedge.target_value
  ratio = clamp(float(t - wedge.event.start_q) / span, 0.0, 1.0)
  return clamp(wedge.start_value + (wedge.target_value - wedge.start_value) * ratio, 0.0, 1.0)
end

mutable struct PartEventCursor
  last_t::Union{Nothing,Rational{Int}}
  dynamic_pos::Int
  started_wedges::Int
end

mutable struct ScoreEventCursor
  last_t::Union{Nothing,Rational{Int}}
  tempo_pos::Int
  segment_pos::Int
  parts::Dict{String,PartEventCursor}
end
ScoreEventCursor() = ScoreEventCursor(nothing, 0, 1, Dict{String,PartEventCursor}())

function _step_timing!(index::ScoreEventIndex, cursor::ScoreEventCursor, t::Rational{Int})
  if cursor.last_t !== nothing && t < cursor.last_t
    return _seconds_at(index, t), _tempo_at(index, t)
  end
  while cursor.tempo_pos < length(index.tempo_times) &&
      index.tempo_times[cursor.tempo_pos + 1] <= t
    cursor.tempo_pos += 1
  end
  while cursor.segment_pos < length(index.segment_starts) &&
      index.segment_starts[cursor.segment_pos + 1] <= t
    cursor.segment_pos += 1
  end
  cursor.last_t = t
  bpm = cursor.tempo_pos == 0 ? DEFAULT_TEMPO : index.tempo_events[cursor.tempo_pos].bpm
  return _seconds_at(index, t, cursor.segment_pos), bpm
end

function _dynamic_at!(index::ScoreEventIndex, cursor::ScoreEventCursor,
    part_id::String, t::Rational{Int})::Float64
  part = get(index.parts, part_id, nothing)
  part === nothing && return DEFAULT_DYNAMIC
  state = get!(cursor.parts, part_id) do
    PartEventCursor(nothing, 0, 0)
  end
  if state.last_t !== nothing && t < state.last_t
    return _dynamic_at(index, part_id, t)
  end
  while state.dynamic_pos < length(part.dynamic_times) &&
      part.dynamic_times[state.dynamic_pos + 1] <= t
    state.dynamic_pos += 1
  end
  while state.started_wedges < length(part.wedge_starts) &&
      part.wedge_starts[state.started_wedges + 1] <= t
    state.started_wedges += 1
  end
  state.last_t = t
  return _dynamic_at(index, part_id, t, state.dynamic_pos, state.started_wedges)
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

# A MusicXML voice number is a source identifier, not a staff-local lane number.
# Keep each source voice intact, and share an analysis lane only when the entire
# source voices have no overlapping sounding notes on the same staff.
function _voices_overlap(a::Vector{NoteEvent}, b::Vector{NoteEvent})::Bool
  i = 1
  j = 1
  while i <= length(a) && j <= length(b)
    left = a[i]
    right = b[j]
    if left.start_q < right.end_q && right.start_q < left.end_q
      return true
    end
    if left.end_q <= right.end_q
      i += 1
    else
      j += 1
    end
  end
  return false
end

function _analysis_stream_lanes(notes::Vector{NoteEvent})
  source_events = Dict{Tuple{String,String,String},Vector{NoteEvent}}()
  for event in notes
    push!(get!(source_events, event.stream_key, NoteEvent[]), event)
  end
  staff_groups = Dict{Tuple{String,String},Vector{Tuple{String,String,String}}}()
  for key in keys(source_events)
    push!(get!(staff_groups, (key[1], key[2]), Tuple{String,String,String}[]), key)
  end

  lane_by_source = Dict{Tuple{String,String,String},Tuple{String,String,String}}()
  source_voices_by_lane = Dict{Tuple{String,String,String},Vector{String}}()
  for ((part_id, staff), voice_keys) in staff_groups
    # Preserve the most established voices first; occasional voices fill idle lanes.
    sort!(voice_keys; by=key -> (-length(source_events[key]), source_events[key][1].start_q, key[3]))
    lanes = Vector{Vector{Tuple{String,String,String}}}()
    for key in voice_keys
      lane_index = findfirst(lane -> all(other ->
        !_voices_overlap(source_events[key], source_events[other]), lane), lanes)
      if lane_index === nothing
        push!(lanes, Tuple{String,String,String}[])
        lane_index = length(lanes)
      end
      push!(lanes[lane_index], key)
      lane_key = (part_id, staff, string(lane_index))
      lane_by_source[key] = lane_key
      push!(get!(source_voices_by_lane, lane_key, String[]), key[3])
    end
  end
  return lane_by_source, source_voices_by_lane
end

function _csv_rows_from_text(csv_text::AbstractString)
  rows = Vector{Vector{String}}()
  for raw in eachline(IOBuffer(csv_text))
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

function list_asap_sources_from_csv_text(csv_text::AbstractString)
  rows = _csv_rows_from_text(csv_text)
  isempty(rows) && return Any[]
  header = Dict(strip(name) => idx for (idx, name) in enumerate(rows[1]))
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

function list_asap_sources(dataset_dir::AbstractString)
  metadata_path = joinpath(dataset_dir, "metadata.csv")
  isfile(metadata_path) || throw(RequestError(
    "asap_dataset_missing",
    "ASAP metadata.csv was not found locally.",
  ))
  return list_asap_sources_from_csv_text(read(metadata_path, String))
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
  compact_cluster_view::Bool=false,
  log_label::AbstractString="",
  progress_callback=nothing,
  cancel_check=nothing,
)
  _check_analysis_cancel(cancel_check)
  n = length(series)
  min_window = Config.POLYPHONIC_MIN_WINDOW_SIZE
  log_started_at = time()
  _notify_analysis_progress(progress_callback, Dict{String,Any}(
    "phase" => "clustering",
    "label" => String(log_label),
    "processed" => 0,
    "total" => max(n - min_window, 0),
    "percent" => 0,
  ))
  if !isempty(log_label)
    empty_steps = count(isempty, series)
    zero_steps = count(row -> !isempty(row) && all(iszero, row), series)
    @info "[analyse_music] clustering start" label=String(log_label) steps=n min_window=min_window empty_steps=empty_steps zero_steps=zero_steps
  end
  axes = Dict(
    "prediction" => Any[nothing for _ in 1:n],
    "diversity" => Any[nothing for _ in 1:n],
    "shape" => Any[nothing for _ in 1:n],
    "mass" => Any[nothing for _ in 1:n],
  )
  raw = Dict(
    "distance" => Any[nothing for _ in 1:n],
    "quantity" => Any[nothing for _ in 1:n],
    "complexity" => Any[nothing for _ in 1:n],
  )
  if n < min_window
    !isempty(log_label) && @info "[analyse_music] clustering skipped" label=String(log_label) reason="series shorter than min window" steps=n
    return Dict("axes"=>axes, "raw"=>raw, "clusters"=>Any[], "compressedClusters"=>Any[])
  end

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
    enable_occurrence_intervals=false,
  )
  PolyphonicClusterManager.process_data!(manager)
  scoring.initial_calc_values!(manager, PolyphonicClusterManager.transform_clusters(manager))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
  # The metrics returned after each committed append are exactly the next
  # step's calibrator prestate. Keep them instead of scanning all clusters.
  committed_metrics_ref = Ref(PolyphonicClusterManager.current_extended_metrics(manager))
  # Keep the exact pair-distance total for each window without retaining
  # every pair. Representative changes are subtracted and added incrementally.
  distance_sums = Dict(window => sum(values(cache))
    for (window, cache) in manager.cluster_distance_cache)
  empty!(manager.cluster_distance_cache)
  quantity_totals = PolyphonicClusterManager.observed_quantity_totals(manager)

  if n > min_window
    total_observed_steps = n - min_window
    progress_interval = max(cld(total_observed_steps, 10), 1)
    phase_timings = Dict{Symbol,Float64}(
      :calibrator => 0.0,
      :prediction => 0.0,
      :metrics => 0.0,
      :metrics_aggregate => 0.0,
      :metrics_rebase => 0.0,
      :commit => 0.0,
      :cache => 0.0,
      :cache_collect => 0.0,
      :cache_distance => 0.0,
      :cache_quantity => 0.0,
      :cache_occurrence => 0.0,
      :cache_windows => 0.0,
      :cache_distance_pairs => 0.0,
      :cache_distance_revised_pairs => 0.0,
      :cache_distance_prefix_hits => 0.0,
      :cache_distance_new_full_pairs => 0.0,
      :cache_distance_new_full_rows => 0.0,
      :cache_distance_old_full_rows => 0.0,
      :cache_distance_new_full_s => 0.0,
      :cache_distance_new_prefix_s => 0.0,
      :cache_distance_old_full_s => 0.0,
      :cache_distance_old_full_pairs => 0.0,
      :cache_distance_old_prefix_s => 0.0,
      :cache_distance_old_prefix_hits => 0.0,
      :cache_distance_old_prefix_check_s => 0.0,
      :cache_complexity_evals => 0.0,
      :cache_complexity_prefix_hits => 0.0,
      :cache_complexity_full_rows => 0.0,
      :cache_complexity_full_s => 0.0,
      :cache_complexity_prefix_s => 0.0,
      :cache_occurrence_targets => 0.0,
    )
    last_progress_time = time()
    last_progress_steps = 0
    for index in (min_window + 1):n
      _check_analysis_cancel(cancel_check)
      observed = scoring.evaluate_observed_complexity!(manager, series[index];
        metric_weights=metric_weights, phase_timings=phase_timings,
        committed_metrics_ref=committed_metrics_ref,
        observed_distance_sums=distance_sums,
        observed_quantity_totals=quantity_totals)
      for key in keys(axes)
        axes[key][index] = get(observed, key, nothing)
      end
      raw_metrics = get(observed, "raw", Dict{String,Any}())
      raw["distance"][index] = get(raw_metrics, "distance", nothing)
      raw["quantity"][index] = get(raw_metrics, "quantity", nothing)
      raw["complexity"][index] = get(raw_metrics, "complexity", nothing)

      processed = index - min_window
      if !isempty(log_label) && (processed == total_observed_steps || processed % progress_interval == 0)
        percent = round(Int, 100 * processed / total_observed_steps)
        now = time()
        interval_s = now - last_progress_time
        interval_steps = processed - last_progress_steps
        measured_s = sum(phase_timings[phase] for phase in (:calibrator, :prediction, :metrics, :commit, :cache))
        @info "[analyse_music] clustering progress" label=String(log_label) progress="$(percent)%" processed=processed total=total_observed_steps elapsed_s=round(now - log_started_at; digits=2) interval_s=round(interval_s; digits=2) ms_per_step=round(1000 * interval_s / interval_steps; digits=1) calibrator_s=round(phase_timings[:calibrator]; digits=2) prediction_s=round(phase_timings[:prediction]; digits=2) metrics_s=round(phase_timings[:metrics]; digits=2) commit_s=round(phase_timings[:commit]; digits=2) cache_s=round(phase_timings[:cache]; digits=2) other_s=round(max(interval_s - measured_s, 0.0); digits=2) active_tasks=length(manager.tasks)
        @info "[analyse_music] cache breakdown" label=String(log_label) progress="$(percent)%" collect_s=round(phase_timings[:cache_collect]; digits=2) distance_s=round(phase_timings[:cache_distance]; digits=2) quantity_s=round(phase_timings[:cache_quantity]; digits=2) occurrence_s=round(phase_timings[:cache_occurrence]; digits=2) windows=Int(phase_timings[:cache_windows]) distance_pairs=Int(phase_timings[:cache_distance_pairs]) distance_revised_pairs=Int(phase_timings[:cache_distance_revised_pairs]) distance_prefix_hits=Int(phase_timings[:cache_distance_prefix_hits]) complexity_evals=Int(phase_timings[:cache_complexity_evals]) complexity_prefix_hits=Int(phase_timings[:cache_complexity_prefix_hits]) occurrence_targets=Int(phase_timings[:cache_occurrence_targets])
        distance_measured = sum(phase_timings[key] for key in (:cache_distance_new_full_s, :cache_distance_new_prefix_s, :cache_distance_old_full_s, :cache_distance_old_prefix_s))
        @info "[analyse_music] distance detail" label=String(log_label) progress="$(percent)%" new_full_s=round(phase_timings[:cache_distance_new_full_s]; digits=2) new_full_pairs=Int(phase_timings[:cache_distance_new_full_pairs]) new_full_rows=Int(phase_timings[:cache_distance_new_full_rows]) new_prefix_s=round(phase_timings[:cache_distance_new_prefix_s]; digits=2) new_prefix_pairs=Int(phase_timings[:cache_distance_prefix_hits]) old_full_s=round(phase_timings[:cache_distance_old_full_s]; digits=2) old_full_pairs=Int(phase_timings[:cache_distance_old_full_pairs]) old_full_rows=Int(phase_timings[:cache_distance_old_full_rows]) old_prefix_s=round(phase_timings[:cache_distance_old_prefix_s]; digits=2) old_prefix_pairs=Int(phase_timings[:cache_distance_old_prefix_hits]) old_prefix_check_s=round(phase_timings[:cache_distance_old_prefix_check_s]; digits=2) revised_pairs=Int(phase_timings[:cache_distance_revised_pairs]) loop_s=round(max(phase_timings[:cache_distance] - distance_measured, 0.0); digits=2)
        complexity_measured = phase_timings[:cache_complexity_full_s] + phase_timings[:cache_complexity_prefix_s]
        @info "[analyse_music] quantity detail" label=String(log_label) progress="$(percent)%" complexity_full_s=round(phase_timings[:cache_complexity_full_s]; digits=2) complexity_full_rows=Int(phase_timings[:cache_complexity_full_rows]) complexity_prefix_s=round(phase_timings[:cache_complexity_prefix_s]; digits=2) complexity_prefix_hits=Int(phase_timings[:cache_complexity_prefix_hits]) other_quantity_s=round(max(phase_timings[:cache_quantity] - complexity_measured, 0.0); digits=2)
        @info "[analyse_music] metrics aggregation" label=String(log_label) progress="$(percent)%" aggregate_s=round(phase_timings[:metrics_aggregate]; digits=3) rebase_s=round(phase_timings[:metrics_rebase]; digits=3) quantity_windows=length(quantity_totals.quantities) complexity_windows=length(quantity_totals.complexities) quantity_entries=sum(length, values(manager.cluster_quantity_cache)) complexity_entries=sum(length, values(manager.cluster_complexity_cache))
        _notify_analysis_progress(progress_callback, Dict{String,Any}(
          "phase" => "clustering",
          "label" => String(log_label),
          "processed" => processed,
          "total" => total_observed_steps,
          "percent" => percent,
        ))
        for phase in keys(phase_timings)
          phase_timings[phase] = 0.0
        end
        last_progress_time = now
        last_progress_steps = processed
      end
    end
  end

  _check_analysis_cancel(cancel_check)
  !isempty(log_label) && @info "[analyse_music] clustering done" label=String(log_label) elapsed_s=round(time() - log_started_at; digits=2)
  _notify_analysis_progress(progress_callback, Dict{String,Any}(
    "phase" => "clustering",
    "label" => String(log_label),
    "processed" => max(n - min_window, 0),
    "total" => max(n - min_window, 0),
    "percent" => 100,
  ))
  payload_started_at = time()
  clusters_payload = compact_cluster_view ? Any[] : PolyphonicClusterManager.clusters_to_timeline(manager)
  timeline_s = time() - payload_started_at
  compressed_payload = PolyphonicClusterManager.compressed_clusters_payload(manager)
  if !isempty(log_label)
    @info "[analyse_music] cluster payload ready" label=String(log_label) timeline_s=round(timeline_s; digits=2) compressed_s=round(time() - payload_started_at - timeline_s; digits=2)
  end
  return Dict(
    "axes" => axes,
    "raw" => raw,
    "clusters" => clusters_payload,
    "compressedClusters" => compressed_payload,
  )
end

function analyse_music_payload(
  params,
  scoring;
  progress_callback=nothing,
  cancel_check=nothing,
)
  analysis_started_at = time()
  _check_analysis_cancel(cancel_check)
  _notify_analysis_progress(progress_callback, Dict{String,Any}(
    "phase" => "parsing",
    "label" => "MusicXML",
    "processed" => 0,
    "total" => 1,
    "percent" => 0,
  ))
  compact_cluster_view = get(params, "compact_cluster_view", false) == true
  xml_text = string(get(params, "musicxml_text", ""))
  @info "[analyse_music] parsing MusicXML" source_type=string(get(params, "source_type", "upload")) xml_bytes=sizeof(xml_text)
  parsed = parse_musicxml_text(xml_text)
  _check_analysis_cancel(cancel_check)
  @info "[analyse_music] MusicXML parsed" note_events=length(parsed.notes) total_quarters=float(parsed.total_q) parts=length(parsed.part_names)
  _notify_analysis_progress(progress_callback, Dict{String,Any}(
    "phase" => "parsing",
    "label" => "MusicXML",
    "processed" => 1,
    "total" => 1,
    "percent" => 100,
  ))

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

  lane_by_source, source_voices_by_lane = _analysis_stream_lanes(parsed.notes)
  stream_keys = Tuple{String,String,String}[]
  seen_keys = Set{Tuple{String,String,String}}()
  for event in parsed.notes
    lane_key = lane_by_source[event.stream_key]
    if !(lane_key in seen_keys)
      push!(stream_keys, lane_key)
      push!(seen_keys, lane_key)
    end
  end
  stream_ids = collect(1:length(stream_keys))
  @info "[analyse_music] exact grid ready" grid_denominator=grid_den step_count=step_count source_voices=length(lane_by_source) streams=length(stream_ids)
  id_by_key = Dict(key => idx for (idx, key) in enumerate(stream_keys))
  key_by_id = Dict(idx => key for (idx, key) in enumerate(stream_keys))

  notes_by_stream = Dict(id => [Int[] for _ in 1:step_count] for id in stream_ids)
  onsets_by_stream = Dict(id => [Set{Int}() for _ in 1:step_count] for id in stream_ids)

  for event in parsed.notes
    id = id_by_key[lane_by_source[event.stream_key]]
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
    part_id, staff, lane = key_by_id[id]
    part_name = get(parsed.part_names, part_id, part_id)
    voices = source_voices_by_lane[key_by_id[id]]
    stream_labels[id] = "$(part_name) / staff $(staff) / lane $(lane) (voices $(join(voices, ", ")))"
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
  event_index = _score_event_index(parsed)
  event_cursor = ScoreEventCursor()
  dynamic_at_step = Dict{String,Float64}()

  @info "[analyse_music] extracting score dimensions" steps=step_count streams=length(stream_ids)
  extraction_started_at = time()
  extraction_progress_interval = max(cld(step_count, 10), 1)
  for step in 1:step_count
    _check_analysis_cancel(cancel_check)
    t_q = (step - 1) // grid_den
    onset_seconds, bpm = _step_timing!(event_index, event_cursor, t_q)
    push!(tempo_series, bpm)
    empty!(dynamic_at_step)
    active_ids = Int[]
    global_notes = Int[]
    global_amps = Float64[]

    for id in stream_ids
      current_notes = notes_by_stream[id][step]
      is_active = !isempty(current_notes)
      is_active && push!(active_ids, id)

      vol = 0.0
      if is_active
        part_id = part_by_stream[id]
        vol = get!(dynamic_at_step, part_id) do
          _dynamic_at!(event_index, event_cursor, part_id, t_q)
        end
      end
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

    if step == step_count || step % extraction_progress_interval == 0
      percent = round(Int, 100 * step / step_count)
      @info "[analyse_music] dimension extraction progress" progress="$(percent)%" processed=step total=step_count elapsed_s=round(time() - extraction_started_at; digits=2)
      _notify_analysis_progress(progress_callback, Dict{String,Any}(
        "phase" => "extracting",
        "label" => "score dimensions",
        "processed" => step,
        "total" => step_count,
        "percent" => percent,
      ))
    end
  end
  _check_analysis_cancel(cancel_check)
  @info "[analyse_music] score dimensions extracted" elapsed_s=round(time() - extraction_started_at; digits=2)

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

  for (dim_index, dim) in enumerate(dimension_order)
    _check_analysis_cancel(cancel_check)
    dimension_started_at = time()
    @info "[analyse_music] dimension analysis start" dimension=dim position="$(dim_index)/$(length(dimension_order))"
    _notify_analysis_progress(progress_callback, Dict{String,Any}(
      "phase" => "dimension",
      "label" => dim,
      "processed" => dim_index - 1,
      "total" => length(dimension_order),
      "percent" => round(Int, 100 * (dim_index - 1) / length(dimension_order)),
    ))
    range_min, range_max = dimension_ranges[dim]
    global_display = Any[nothing for _ in 1:step_count]
    concordance = Any[nothing for _ in 1:step_count]
    stream_values_payload = Dict{String,Any}()
    stream_analysis_payload = Dict{String,Any}()
    stream_clusters_payload = Dict{String,Any}()
    stream_compressed_payload = Dict{String,Any}()

    if dim == "stream_count"
      global_display = copy(stream_count)
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance))
      @info "[analyse_music] dimension values ready" dimension=dim elapsed_s=round(time() - dimension_started_at; digits=2)
      continue
    end

    stream_source = scalar_streams[dim]
    if dim == "dissonance"
      global_display = copy(global_dissonance)
      for id in stream_ids
        stream_values_payload[string(id)] = stream_source[id]
      end
      for step in 1:step_count
        active_vals = Float64[float(stream_source[id][step]) for id in stream_ids if !isempty(notes_by_stream[id][step])]
        concordance[step] = _concordance(active_vals, 1.0)
      end
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance))
      @info "[analyse_music] dimension values ready" dimension=dim elapsed_s=round(time() - dimension_started_at; digits=2)
      continue
    end

    if dim in ("chord_range", "density", "tie")
      for id in stream_ids
        stream_values_payload[string(id)] = stream_source[id]
      end
      for step in 1:step_count
        active_vals = Float64[float(stream_source[id][step]) for id in stream_ids if !isempty(notes_by_stream[id][step])]
        global_display[step] = isempty(active_vals) ? (dim == "tie" ? 0.0 : nothing) : sum(active_vals) / float(length(active_vals))
        concordance[step] = _concordance(active_vals, range_max - range_min)
      end
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance))
      @info "[analyse_music] dimension values ready" dimension=dim elapsed_s=round(time() - dimension_started_at; digits=2)
      continue
    end

    for id in stream_ids
      stream_values_payload[string(id)] = stream_source[id]
      analysed_stream = _analyse_manager(_make_poly_series(stream_source[id]), scoring;
        range_min=range_min, range_max=range_max,
        merge_threshold_ratio=merge_threshold_ratio,
        metric_weights=Config.POLYPHONIC_STREAM_METRIC_WEIGHTS,
        compact_cluster_view=compact_cluster_view, log_label="$(dim)/stream=$(id):$(stream_labels[id])",
        progress_callback=progress_callback, cancel_check=cancel_check)
      stream_analysis_payload[string(id)] = Dict("axes"=>analysed_stream["axes"], "raw"=>analysed_stream["raw"])
      stream_clusters_payload[string(id)] = analysed_stream["clusters"]
      stream_compressed_payload[string(id)] = analysed_stream["compressedClusters"]
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
        metric_weights=Config.POLYPHONIC_GLOBAL_METRIC_WEIGHTS,
        compact_cluster_view=compact_cluster_view, log_label="$(dim)/global",
        progress_callback=progress_callback, cancel_check=cancel_check)
      dimensions[dim] = Dict(
        "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance),
        "analysis"=>Dict("global"=>Dict("axes"=>analysed_global["axes"], "raw"=>analysed_global["raw"]), "streams"=>stream_analysis_payload),
        "clusters"=>Dict("global"=>analysed_global["clusters"], "streams"=>stream_clusters_payload),
        "compressedClusters"=>Dict("global"=>analysed_global["compressedClusters"], "streams"=>stream_compressed_payload))
      @info "[analyse_music] dimension analysis done" dimension=dim elapsed_s=round(time() - dimension_started_at; digits=2)
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
      stream_axis_capacity=max(length(stream_ids), 1),
      compact_cluster_view=compact_cluster_view, log_label="$(dim)/global")
    dimensions[dim] = Dict(
      "values"=>Dict("global"=>global_display, "streams"=>stream_values_payload, "concordance"=>concordance),
      "analysis"=>Dict("global"=>Dict("axes"=>analysed_global["axes"], "raw"=>analysed_global["raw"]), "streams"=>stream_analysis_payload),
      "clusters"=>Dict("global"=>analysed_global["clusters"], "streams"=>stream_clusters_payload),
      "compressedClusters"=>Dict("global"=>analysed_global["compressedClusters"], "streams"=>stream_compressed_payload))
    @info "[analyse_music] dimension analysis done" dimension=dim elapsed_s=round(time() - dimension_started_at; digits=2)
  end

  if compact_cluster_view
    for dimension in values(dimensions)
      delete!(dimension, "clusters")
    end
  end
  _check_analysis_cancel(cancel_check)
  @info "[analyse_music] all dimensions analysed" elapsed_s=round(time() - analysis_started_at; digits=2)
  _notify_analysis_progress(progress_callback, Dict{String,Any}(
    "phase" => "finalizing",
    "label" => "result",
    "processed" => length(dimension_order),
    "total" => length(dimension_order),
    "percent" => 100,
  ))
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
      Dict("id"=>id, "label"=>stream_labels[id], "partId"=>key_by_id[id][1], "staff"=>key_by_id[id][2], "voice"=>join(source_voices_by_lane[key_by_id[id]], ","), "lane"=>key_by_id[id][3], "sourceVoices"=>source_voices_by_lane[key_by_id[id]])
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
