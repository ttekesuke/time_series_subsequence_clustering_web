module MusicXmlEvents

using EzXML

struct TimedNote
  part_id::String
  staff::String
  voice::String
  start_q::Rational{Int}
  end_q::Rational{Int}
  pitch::Int
  measure_number::String
  measure_start_q::Rational{Int}
  tie_start::Bool
  tie_stop::Bool
end

struct ParsedEvents
  notes::Vector{TimedNote}
  measure_starts::Vector{Tuple{String,Rational{Int},String}}
  part_names::Dict{String,String}
  total_q::Rational{Int}
  tick_scale::BigInt
end

function child_elements(node, name::AbstractString)
  out = Any[]
  for child in EzXML.eachelement(node)
    EzXML.nodename(child) == name && push!(out, child)
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
  return strip(EzXML.nodecontent(child))
end

has_child(node, name::AbstractString) = first_child(node, name) !== nothing

function attr(node, name::AbstractString, default::AbstractString="")
  try
    return String(node[name])
  catch
    return String(default)
  end
end

function parse_int_text(node, name::AbstractString, default::Int=0)::Int
  parsed = tryparse(Int, child_text(node, name))
  return parsed === nothing ? default : parsed
end

function midi_pitch(note)::Union{Int,Nothing}
  pitch = first_child(note, "pitch")
  pitch === nothing && return nothing
  step = uppercase(child_text(pitch, "step"))
  octave = tryparse(Int, child_text(pitch, "octave"))
  octave === nothing && return nothing
  base = get(Dict("C"=>0, "D"=>2, "E"=>4, "F"=>5, "G"=>7, "A"=>9, "B"=>11), step, nothing)
  base === nothing && return nothing
  alter = tryparse(Float64, child_text(pitch, "alter", "0"))
  semitone = alter === nothing ? 0 : round(Int, alter)
  return clamp((octave + 1) * 12 + base + semitone, 0, 127)
end

function tie_flags(note)::Tuple{Bool,Bool}
  tie_start = false
  tie_stop = false
  for tie in child_elements(note, "tie")
    typ = lowercase(attr(tie, "type"))
    typ == "start" && (tie_start = true)
    typ == "stop" && (tie_stop = true)
  end
  for notations in child_elements(note, "notations"), tied in child_elements(notations, "tied")
    typ = lowercase(attr(tied, "type"))
    typ == "start" && (tie_start = true)
    typ == "stop" && (tie_stop = true)
  end
  return tie_start, tie_stop
end

function part_names(score)::Dict{String,String}
  names = Dict{String,String}()
  for part_list in child_elements(score, "part-list"), score_part in child_elements(part_list, "score-part")
    id = attr(score_part, "id")
    isempty(id) && continue
    name = child_text(score_part, "part-name", id)
    names[id] = isempty(name) ? id : name
  end
  return names
end

"""Extract source voices and exact quarter-note times once for analysis and DB seed.

`on_direction` receives `(part_id, cursor_q, divisions, element)` in XML order,
so direction processing observes the same cursor as the note extractor.
"""
function parse_document(doc; on_direction=(part_id, cursor, divisions, element) -> nothing)::ParsedEvents
  score = EzXML.root(doc)
  EzXML.nodename(score) == "score-partwise" || throw(ArgumentError("Only score-partwise MusicXML is supported."))
  notes = TimedNote[]
  measure_starts = Tuple{String,Rational{Int},String}[]
  total_q = 0 // 1
  tick_scale = big(1)

  for part in child_elements(score, "part")
    part_id = attr(part, "id", "P")
    divisions = 1
    part_time = 0 // 1
    for (measure_index, measure) in enumerate(child_elements(part, "measure"))
      measure_number = attr(measure, "number", string(measure_index))
      push!(measure_starts, (part_id, part_time, measure_number))
      cursor = part_time
      max_cursor = cursor
      last_note_start = cursor

      for element in EzXML.eachelement(measure)
        name = EzXML.nodename(element)
        if name == "attributes"
          div = parse_int_text(element, "divisions", divisions)
          if div > 0
            divisions = div
            tick_scale = lcm(tick_scale, big(div))
          end
        elseif name == "backup"
          cursor = max(part_time, cursor - parse_int_text(element, "duration") // divisions)
        elseif name == "forward"
          cursor += parse_int_text(element, "duration") // divisions
          max_cursor = max(max_cursor, cursor)
        elseif name == "direction"
          on_direction(part_id, cursor, divisions, element)
        elseif name == "note"
          has_child(element, "grace") && continue
          duration_raw = parse_int_text(element, "duration")
          duration_raw > 0 || continue
          duration_q = duration_raw // divisions
          is_chord = has_child(element, "chord")
          start_q = is_chord ? last_note_start : cursor
          end_q = start_q + duration_q

          if !has_child(element, "rest")
            pitch = midi_pitch(element)
            if pitch !== nothing
              tie_start, tie_stop = tie_flags(element)
              push!(notes, TimedNote(part_id, child_text(element, "staff", "1"),
                child_text(element, "voice", "1"), start_q, end_q, pitch,
                measure_number, part_time, tie_start, tie_stop))
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
  return ParsedEvents(notes, measure_starts, part_names(score), total_q, tick_scale)
end

end # module
