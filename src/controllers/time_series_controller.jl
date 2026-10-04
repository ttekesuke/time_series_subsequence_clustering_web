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
include(joinpath(@__DIR__, "time_series", "github_dispatch.jl"))
include(joinpath(@__DIR__, "time_series", "musicxml_response.jl"))





end # module
