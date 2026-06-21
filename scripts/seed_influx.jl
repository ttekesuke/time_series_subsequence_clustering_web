using Dates
using EzXML
using HTTP
using JSON3
using SHA

const influx_url = get(ENV, "INFLUX_URL", "http://influxdb:8086")
const influx_db = get(ENV, "INFLUX_DB", "timeseries")
const influx_bucket = get(ENV, "INFLUX_BUCKET", "")
const influx_token = get(ENV, "INFLUX_TOKEN", "")
const measurement = get(ENV, "INFLUX_MEASUREMENT", "timeseries") # measurement name
const note_field = get(ENV, "INFLUX_NOTE_FIELD", "note") # field name for pitch
const dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "data", "asap-dataset")))
const measure_gap_threshold_measures = parse(Int, get(ENV, "ASAP_MEASURE_GAP_THRESHOLD_MEASURES", "1"))
const phrase_max_measures = parse(Int, get(ENV, "ASAP_PHRASE_MAX_MEASURES", "8"))
const max_scores = parse(Int, get(ENV, "ASAP_MAX_SCORES", "0"))
const write_batch_lines = parse(Int, get(ENV, "INFLUX_WRITE_BATCH_LINES", "5000"))
const reset_measurement = lowercase(strip(get(ENV, "SEED_RESET_MEASUREMENT", "true"))) in ("1", "true", "yes", "on")

struct ScoreInfo
  composer::String
  title::String
  folder::String
  xml_score::String
end

struct NoteEvent
  start_tick::Int
  duration::Int
  pitch::Int
  measure_number::String
  measure_tick::Int
end

influx_v2_enabled() = !isempty(strip(influx_token)) || !isempty(strip(influx_bucket))

function strip_trailing_slashes(s)
  out = String(s)
  while endswith(out, "/")
    out = chop(out)
  end
  return out
end

function ping_influx(url)
  try
    resp = HTTP.request("GET", string(strip_trailing_slashes(url), "/ping"))
    return resp.status == 204
  catch
    return false
  end
end

function influx_v2_org_query()
  org_id = strip(get(ENV, "INFLUX_ORG_ID", ""))
  !isempty(org_id) && return Dict("orgID" => org_id)
  org = strip(get(ENV, "INFLUX_ORG", ""))
  !isempty(org) && return Dict("org" => org)
  return Dict{String,String}()
end

function influx_v2_headers()
  return [
    "Authorization" => "Token $(influx_token)",
    "Content-Type" => "text/plain; charset=utf-8",
  ]
end

function influx_v2_json_headers()
  return [
    "Authorization" => "Token $(influx_token)",
    "Content-Type" => "application/json",
  ]
end

function write_influx(body)
  if influx_v2_enabled()
    url = string(strip_trailing_slashes(influx_url), "/api/v2/write")
    query = merge(Dict("bucket" => influx_bucket, "precision" => "s"), influx_v2_org_query())
    return HTTP.post(url, influx_v2_headers(), body; query=query)
  else
    return HTTP.post(string(strip_trailing_slashes(influx_url), "/write"), [], body; query=Dict("db" => influx_db, "precision" => "s"))
  end
end

function influx_query(q::AbstractString)
  headers = Pair{String,String}[]
  if influx_v2_enabled()
    push!(headers, "Authorization" => "Token $(influx_token)")
  end
  query = Dict("q" => String(q), "db" => influx_db)
  rp = strip(get(ENV, "INFLUX_RP", ""))
  !isempty(rp) && (query["rp"] = rp)
  return HTTP.get(string(strip_trailing_slashes(influx_url), "/query"), headers; query=query)
end

function reset_influx_measurement()
  reset_measurement || return
  println("Resetting measurement: ", measurement)
  try
    resp = influx_query("DROP MEASUREMENT \"$(replace(measurement, "\"" => "\\\""))\"")
    println("DROP MEASUREMENT status ", resp.status)
    return
  catch e
    println("DROP MEASUREMENT failed, trying v2 delete if configured: ", e)
  end

  influx_v2_enabled() || return
  try
    url = string(strip_trailing_slashes(influx_url), "/api/v2/delete")
    query = merge(Dict("bucket" => influx_bucket), influx_v2_org_query())
    body = JSON3.write(Dict(
      "start" => "1970-01-01T00:00:00Z",
      "stop" => "2100-01-01T00:00:00Z",
      "predicate" => "_measurement=\"$(replace(measurement, "\"" => "\\\""))\"",
    ))
    resp = HTTP.post(url, influx_v2_json_headers(), body; query=query)
    println("v2 delete status ", resp.status)
  catch e
    println("v2 delete failed; continuing with overwrite-only seed: ", e)
  end
end

if influx_v2_enabled()
  isempty(strip(influx_bucket)) && error("INFLUX_BUCKET is required for InfluxDB Cloud/v2")
  isempty(strip(influx_token)) && error("INFLUX_TOKEN is required for InfluxDB Cloud/v2")
  println("Using InfluxDB Cloud/v2 bucket: ", influx_bucket)
else
  println("Waiting for InfluxDB at ", influx_url)
  for _ in 1:60
    ping_influx(influx_url) && (println("InfluxDB is up"); break)
    sleep(1)
  end
  try
    resp = HTTP.get(string(strip_trailing_slashes(influx_url), "/query"), query=Dict("q" => "CREATE DATABASE \"$(influx_db)\""))
    println("Created DB (or already exists): ", influx_db, " status ", resp.status)
  catch e
    println("DB create failed: ", e)
  end
end

function csv_rows(path::AbstractString)
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

function load_scores()
  metadata_path = joinpath(dataset_dir, "metadata.csv")
  isfile(metadata_path) || error("ASAP metadata.csv was not found at $(metadata_path). Run `git submodule update --init --recursive`.")

  rows = csv_rows(metadata_path)
  isempty(rows) && return ScoreInfo[]
  header = Dict(name => idx for (idx, name) in enumerate(rows[1]))
  required = ["composer", "title", "folder", "xml_score"]
  missing = filter(col -> !haskey(header, col), required)
  isempty(missing) || error("ASAP metadata.csv is missing columns: $(join(missing, ", "))")

  seen = Set{String}()
  scores = ScoreInfo[]
  for row in rows[2:end]
    length(row) < length(rows[1]) && continue
    xml_score = strip(row[header["xml_score"]])
    isempty(xml_score) && continue
    xml_score in seen && continue
    push!(seen, xml_score)
    push!(scores, ScoreInfo(
      strip(row[header["composer"]]),
      strip(row[header["title"]]),
      strip(row[header["folder"]]),
      xml_score,
    ))
  end
  if max_scores > 0 && length(scores) > max_scores
    return scores[1:max_scores]
  end
  return scores
end

function child_elements(node, name::AbstractString)
  out = Any[]
  for child in eachelement(node)
    nodename(child) == name && push!(out, child)
  end
  return out
end

function first_child(node, name::AbstractString)
  xs = child_elements(node, name)
  return isempty(xs) ? nothing : xs[1]
end

function child_text(node, name::AbstractString, default::AbstractString="")
  child = first_child(node, name)
  child === nothing && return String(default)
  return strip(nodecontent(child))
end

function has_child(node, name::AbstractString)::Bool
  return first_child(node, name) !== nothing
end

function attr(node, name::AbstractString, default::AbstractString="")
  try
    return String(node[name])
  catch
    return String(default)
  end
end

function parse_int_text(node, name::AbstractString, default::Int=0)::Int
  txt = child_text(node, name, "")
  isempty(txt) && return default
  return parse(Int, txt)
end

function midi_pitch(note)::Union{Int,Nothing}
  pitch = first_child(note, "pitch")
  pitch === nothing && return nothing
  step = child_text(pitch, "step", "")
  octave_txt = child_text(pitch, "octave", "")
  (isempty(step) || isempty(octave_txt)) && return nothing
  base = Dict("C" => 0, "D" => 2, "E" => 4, "F" => 5, "G" => 7, "A" => 9, "B" => 11)
  haskey(base, step) || return nothing
  alter = parse_int_text(pitch, "alter", 0)
  octave = parse(Int, octave_txt)
  return (octave + 1) * 12 + base[step] + alter
end

function stream_key(part_id::AbstractString, staff::AbstractString, voice::AbstractString)
  return (String(part_id), String(staff), String(voice))
end

function parse_part_names(score::EzXML.Node)::Dict{String,String}
  names = Dict{String,String}()
  for part_list in child_elements(score, "part-list")
    for score_part in child_elements(part_list, "score-part")
      id = attr(score_part, "id", "")
      isempty(id) && continue
      for pn in child_elements(score_part, "part-name")
        names[id] = strip(nodecontent(pn))
        break
      end
    end
  end
  return names
end

function parse_musicxml(score_path::AbstractString)
  doc = readxml(score_path)
  score = root(doc)
  streams = Dict{Tuple{String,String,String}, Vector{NoteEvent}}()
  # measure_starts: (start_tick, measure_number)
  measure_starts = Vector{Tuple{Int,String}}()
  part_names = parse_part_names(score)

  for part in child_elements(score, "part")
    part_id = attr(part, "id", "P")
    part_time = 0
    for measure in child_elements(part, "measure")
      measure_number = attr(measure, "number", string(length(measure_starts) + 1))
      push!(measure_starts, (part_time, measure_number)) # Record the start tick of this measure
      cursor = part_time # Current position in ticks for this measure
      max_cursor = cursor
      last_note_start = cursor

      for element in eachelement(measure)
        name = nodename(element)
        if name == "backup"
          cursor -= parse_int_text(element, "duration", 0)
          cursor < part_time && (cursor = part_time)
        elseif name == "forward"
          cursor += parse_int_text(element, "duration", 0)
          max_cursor = max(max_cursor, cursor)
        elseif name == "note"
          has_child(element, "grace") && continue
          duration = parse_int_text(element, "duration", 0)
          duration <= 0 && continue

          is_chord = has_child(element, "chord") # If true, this note starts at the same time as the previous non-chord note
          current_note_start_tick = is_chord ? last_note_start : cursor
          staff = child_text(element, "staff", "1")
          voice = child_text(element, "voice", "1")
          pitch = has_child(element, "rest") ? nothing : midi_pitch(element)

          if pitch !== nothing
            key = stream_key(part_id, staff, voice)
            push!(get!(streams, key, NoteEvent[]), NoteEvent(current_note_start_tick, duration, pitch, measure_number, current_note_start_tick - part_time))
          end

          if !is_chord
            last_note_start = current_note_start_tick # For subsequent chord notes
            cursor += duration
            max_cursor = max(max_cursor, cursor)
          end # if !is_chord
        end # if name == "note"
      end # for element in eachelement(measure)
      part_time = max_cursor # Update part_time for the next measure
    end # for measure in child_elements(part, "measure")
  end # for part in child_elements(score, "part")

  # Sort all events within each stream by start_tick
  for (key, events) in streams
    sort!(events, by = e -> e.start_tick)
  end

  unique!(measure_starts)
  sort!(measure_starts, by = x -> x[1])
  return streams, measure_starts, part_names
end

function measure_at(measure_starts::Vector{Tuple{Int,String}}, tick::Int)
  isempty(measure_starts) && return ("", tick)
  idx = searchsortedlast([m[1] for m in measure_starts], tick)
  idx <= 0 && return (measure_starts[1][2], tick - measure_starts[1][1])
  start_tick, number = measure_starts[idx]
  return (number, tick - start_tick) # Returns (measure_number_string, tick_within_measure)
end

function collapse_to_highest_notes(events::Vector{NoteEvent})::Vector{NoteEvent}
  isempty(events) && return NoteEvent[]

  grouped = Dict{Int, NoteEvent}()
  for event in events
    existing = get(grouped, event.start_tick, nothing)
    if existing === nothing || event.pitch > existing.pitch
      grouped[event.start_tick] = event
    elseif event.pitch == existing.pitch && event.duration > existing.duration
      grouped[event.start_tick] = event
    elseif event.duration > existing.duration
      grouped[event.start_tick] = NoteEvent(
        existing.start_tick,
        event.duration,
        existing.pitch,
        existing.measure_number,
        existing.measure_tick,
      )
    end
  end

  collapsed = collect(values(grouped))
  sort!(collapsed, by = e -> e.start_tick)
  return collapsed
end

function get_average_measure_duration_ticks(measure_starts::Vector{Tuple{Int,String}})::Int
    if length(measure_starts) < 2
        # Fallback to a reasonable default if not enough measures to calculate
        # MusicXML divisions per quarter note is often 240, so a 4/4 measure would be 4 * 240 = 960
        return 960 # Default to 4/4 measure in 240 divisions per quarter
    end
    total_duration = 0
    count = 0
    for i in 1:(length(measure_starts) - 1)
        duration = measure_starts[i+1][1] - measure_starts[i][1]
        if duration > 0
            total_duration += duration
            count += 1
        end
    end
    return count > 0 ? floor(Int, total_duration / count) : 960 # Fallback if no valid durations
end

function split_phrase_events(events::Vector{NoteEvent}, measure_starts::Vector{Tuple{Int,String}})
  phrases = Vector{Vector{NoteEvent}}()
  isempty(events) && return phrases

  current_phrase = NoteEvent[]
  phrase_start_measure = ""

  measure_duration_threshold_ticks = get_average_measure_duration_ticks(measure_starts) * measure_gap_threshold_measures

  for i in 1:length(events)
    event = events[i]
    if isempty(current_phrase)
      push!(current_phrase, event)
      phrase_start_measure = event.measure_number
      continue
    end

    previous_event = current_phrase[end]
    previous_note_end_tick = previous_event.start_tick + previous_event.duration
    gap = event.start_tick - previous_note_end_tick

    # 休符によるフレーズ区切り
    if gap >= measure_duration_threshold_ticks
      push!(phrases, current_phrase)
      current_phrase = NoteEvent[event]
      phrase_start_measure = event.measure_number
      continue
    end

    # 小節数による強制区切り
    if phrase_max_measures > 0
      start_m = tryparse(Int, phrase_start_measure)
      cur_m   = tryparse(Int, event.measure_number)
      if start_m !== nothing && cur_m !== nothing && (cur_m - start_m) >= phrase_max_measures
        push!(phrases, current_phrase)
        current_phrase = NoteEvent[event]
        phrase_start_measure = event.measure_number
        continue
      end
    end

    push!(current_phrase, event)
  end

  !isempty(current_phrase) && push!(phrases, current_phrase)
  return phrases
end

function materialize_phrase_points(events::Vector{NoteEvent}, measure_starts::Vector{Tuple{Int,String}})
  points = NamedTuple[]
  isempty(events) && return points

  phrase_start_tick = events[1].start_tick

  for (point_idx, event) in enumerate(events)
    # Each note event becomes a single point
    measure_number, measure_tick = measure_at(measure_starts, event.start_tick)
    push!(points, (
      note = event.pitch, # Only pitch field
      score_tick = event.start_tick,
        measure_number = measure_number,
        measure_tick = measure_tick,
      point_index = point_idx - 1, # 0-indexed point within the phrase
      ))
  end

  return points
end

function phrase_points(events::Vector{NoteEvent}, measure_starts::Vector{Tuple{Int,String}})
  phrases_data = Vector{NamedTuple{(:points,), Tuple{Vector{NamedTuple}}}}()
  highest_events = collapse_to_highest_notes(events)
  for phrase_events in split_phrase_events(highest_events, measure_starts)
    points = materialize_phrase_points(phrase_events, measure_starts)
    isempty(points) && continue
    push!(phrases_data, (points = points,))
  end
  return phrases_data
end

function lp_escape_tag(s::AbstractString)
  return replace(String(s), "\\" => "\\\\", "," => "\\,", " " => "\\ ", "=" => "\\=")
end

function lp_escape_measurement(s::AbstractString)
  return replace(String(s), "\\" => "\\\\", "," => "\\,", " " => "\\ ")
end

function lp_escape_string_field(s::AbstractString)
  return "\"" * replace(String(s), "\\" => "\\\\", "\"" => "\\\"") * "\""
end

function stable_id(parts::AbstractString...)
  return bytes2hex(sha1(join(parts, "\u001f")))[1:16]
end

function seed_start_unix_s()
  override = strip(get(ENV, "SEED_START_UNIX_S", ""))
  if !isempty(override)
    return parse(Int, override)
  end
  return floor(Int, time())
end

function line_for_point(score::ScoreInfo, series_id::String, part_id::String, part_name::String, staff::String, voice::String, phrase_index::Int, point, timestamp_s::Int)
  pname = isempty(strip(part_name)) ? part_id : part_name
  tags = [
    "series_id=$(lp_escape_tag(series_id))",
    "composer=$(lp_escape_tag(score.composer))",
    "title=$(lp_escape_tag(score.title))",
    "folder=$(lp_escape_tag(score.folder))",
    "xml_score=$(lp_escape_tag(score.xml_score))",
    "part=$(lp_escape_tag(part_id))",
    "part_name=$(lp_escape_tag(pname))",
    "staff=$(lp_escape_tag(staff))",
    "voice=$(lp_escape_tag(voice))",
    "phrase_index=$(phrase_index)",
  ]
  fields = [
    "$(lp_escape_tag(note_field))=$(point.note)i", # Only pitch field
    "measure=$(lp_escape_string_field(point.measure_number))",
    "measure_tick=$(point.measure_tick)i",
    "score_tick=$(point.score_tick)i",
    "point_index=$(point.point_index)i",
    "unit_ticks=1i", # Fixed to 1 as each note is a single point
  ]
  return "$(lp_escape_measurement(measurement)),$(join(tags, ",")) $(join(fields, ",")) $(timestamp_s)"
end

function flush_lines!(lines::Vector{String})
  isempty(lines) && return
  body = join(lines, "\n") * "\n"
  resp = write_influx(body)
  println("Wrote ", length(lines), " points -> status ", resp.status)
  empty!(lines)
end

function main()
  isdir(dataset_dir) || error("ASAP dataset directory was not found: $(dataset_dir)")
  scores = load_scores()
  println("Loaded ASAP scores: ", length(scores), " from ", dataset_dir)
  reset_influx_measurement()
  timestamp_base_s = seed_start_unix_s()

  lines = String[]
  total_points = 0
  total_phrases = 0

  for (score_index, score) in enumerate(scores)
    score_path = joinpath(dataset_dir, score.xml_score)
    if !isfile(score_path)
      println("Skipping missing MusicXML: ", score.xml_score)
      continue
    end

    streams, measure_starts, part_names = try
      parse_musicxml(score_path)
    catch e
      println("Skipping unparsable MusicXML $(score.xml_score): ", e)
      continue
    end

    for ((part_id, staff, voice), events) in sort(collect(streams), by = x -> x[1])
      isempty(events) && continue # Skip empty streams
      part_name = get(part_names, part_id, part_id)
      phrases_data = phrase_points(events, measure_starts) # Get phrases data
      for (phrase_index, phrase) in enumerate(phrases_data) # Iterate over phrases_data
        points = phrase.points
        isempty(points) && continue
        series_id = stable_id(score.xml_score, part_id, staff, voice, string(phrase_index))
      total_phrases += 1
      for point in points
        timestamp_s = timestamp_base_s + total_points
        push!(lines, line_for_point(score, series_id, part_id, part_name, staff, voice, phrase_index, point, timestamp_s))
        total_points += 1
        length(lines) >= write_batch_lines && flush_lines!(lines)
        end
      end
    end

    println("Processed score $(score_index)/$(length(scores)): $(score.composer) - $(score.title)")
  end

  flush_lines!(lines)
  println("Seeding complete: phrases=$(total_phrases), points=$(total_points)")
end

if abspath(PROGRAM_FILE) == @__FILE__
  main()
end
