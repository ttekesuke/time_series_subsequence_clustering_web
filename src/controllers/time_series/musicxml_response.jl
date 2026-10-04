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
    dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "..", "..", "data", "asap-dataset")))
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
        dataset_dir = joinpath(@__DIR__, "..", "..", "..", "data", "asap-dataset")
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
    dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "..", "..", "data", "asap-dataset")))
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
    dataset_dir = normpath(get(ENV, "ASAP_DATASET_DIR", joinpath(@__DIR__, "..", "..", "..", "data", "asap-dataset")))
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
