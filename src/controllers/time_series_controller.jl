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
import ..MusicAnalysis

const _POLYPHONIC_DIMENSION_CONTRACT_PATH = normpath(joinpath(
  @__DIR__, "..", "..", "config", "polyphonic_dimensions.json",
))
const _POLYPHONIC_DIMENSION_CONTRACT = JSON3.read(
  read(_POLYPHONIC_DIMENSION_CONTRACT_PATH, String),
  Dict{String,Dict{String,Any}},
)

struct GeneratePolyphonicRequestError <: Exception
  code::String
  message::String
end

Base.showerror(io::IO, err::GeneratePolyphonicRequestError) = print(io, err.message)

struct GenerateRequestError <: Exception
  code::String
  message::String
end

Base.showerror(io::IO, err::GenerateRequestError) = print(io, err.message)

struct AnalyseMusicRequestError <: Exception
  code::String
  message::String
end

Base.showerror(io::IO, err::AnalyseMusicRequestError) = print(io, err.message)

@noinline function _invalid_generate_polyphonic_request(code::AbstractString, message::AbstractString)
  throw(GeneratePolyphonicRequestError(String(code), String(message)))
end

@noinline function _invalid_generate_request(code::AbstractString, message::AbstractString)
  throw(GenerateRequestError(String(code), String(message)))
end

mutable struct PolyphonicEvaluationBudget
  dimension_evaluations::Int
  note_evaluations::Int
  dimension_limit::Int
  note_limit::Int
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

include(joinpath(@__DIR__, "time_series", "generate_polyphonic_validation.jl"))
include(joinpath(@__DIR__, "time_series", "influx_config.jl"))
include(joinpath(@__DIR__, "time_series", "influx_transport.jl"))
include(joinpath(@__DIR__, "time_series", "influx_dbrp.jl"))
include(joinpath(@__DIR__, "time_series", "influx_sql.jl"))
include(joinpath(@__DIR__, "time_series", "influx_flux.jl"))
include(joinpath(@__DIR__, "time_series", "influx_repository.jl"))
include(joinpath(@__DIR__, "time_series", "query_memory_budget.jl"))
include(joinpath(@__DIR__, "time_series", "query_match_filter.jl"))
include(joinpath(@__DIR__, "time_series", "similarity_search.jl"))
include(joinpath(@__DIR__, "time_series", "generation_scoring.jl"))
include(joinpath(@__DIR__, "time_series", "analyse_music_source.jl"))
include(joinpath(@__DIR__, "time_series", "analyse_music_action.jl"))


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


# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------



include(joinpath(@__DIR__, "time_series", "analyse_music_jobs.jl"))
include(joinpath(@__DIR__, "time_series", "scalar_actions.jl"))
include(joinpath(@__DIR__, "time_series", "polyphonic_generation.jl"))



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
