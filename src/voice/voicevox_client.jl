module VoicevoxClient

using Base64
using HTTP
using JSON3
using UUIDs

_string_dict(raw) = Dict{String,Any}(string(k) => v for (k, v) in pairs(raw))

function _find_plan_entry(raw_step_plan, stream_id::Int)
  raw_step_plan isa AbstractVector || return nothing
  for raw in raw_step_plan
    try
      item = _string_dict(raw)
      Int(item["streamId"]) == stream_id || continue
      return item
    catch
    end
  end
  return nothing
end

function _stream_tuple_by_id(step, ids, stream_id::Int)
  step isa AbstractVector && ids isa AbstractVector || return nothing
  for (slot, raw_id) in enumerate(ids)
    try
      Int(raw_id) == stream_id || continue
      return slot <= length(step) ? step[slot] : nothing
    catch
    end
  end
  return nothing
end

function _voice_item(step_idx::Int, stream_id::Int, time_series, stream_ids, voice_plan)
  step_idx <= length(voice_plan) || return nothing
  plan = _find_plan_entry(voice_plan[step_idx], stream_id)
  plan !== nothing && lowercase(string(get(plan, "mode", "synth"))) == "voice" || return nothing
  raw_text = get(plan, "text", get(plan, "token", nothing))
  # JSON null is decoded as Julia `nothing`. Converting it with string(...) to
  # "nothing" produces an invalid Song lyric; treat it as a normal synth step.
  raw_text === nothing && return nothing
  text = strip(string(raw_text))
  lowercase(text) == "nothing" && return nothing
  isempty(text) && return nothing
  tuple = _stream_tuple_by_id(time_series[step_idx], stream_ids[step_idx], stream_id)
  tuple isa AbstractVector && length(tuple) == 11 || return nothing
  return (text=text, tuple=tuple)
end

function build_stem_requests(time_series, stream_ids, voice_plan, step_durations)
  steps = time_series isa AbstractVector ? length(time_series) : 0
  steps == length(step_durations) || error("step durations must match time series length")
  voice_plan isa AbstractVector && length(voice_plan) == steps || return (Any[], Set{Tuple{Int,Int}}())
  stream_ids isa AbstractVector && length(stream_ids) == steps || return (Any[], Set{Tuple{Int,Int}}())
  all_ids = sort!(unique(Int[Int(id) for ids in stream_ids if ids isa AbstractVector for id in ids]))
  offsets = zeros(Float64, steps)
  for i in 2:steps
    offsets[i] = offsets[i - 1] + float(step_durations[i - 1])
  end
  requests = Any[]
  voice_keys = Set{Tuple{Int,Int}}()
  for stream_id in all_ids
    segments = Any[]
    controls = Any[]
    for step_idx in 1:steps
      item = _voice_item(step_idx, stream_id, time_series, stream_ids, voice_plan)
      item === nothing && continue
      push!(voice_keys, (step_idx, stream_id))
      push!(segments, Dict("text" => item.text, "duration" => float(step_durations[step_idx])))
      tuple = item.tuple
      notes = Int[note for note in tuple[1] if note isa Real]
      carrier_note = isempty(notes) ? nothing : notes[cld(length(notes), 2)]
      push!(controls, Dict(
        "time" => offsets[step_idx], "amp" => clamp(float(tuple[2]), 0.0, 1.0),
        "duration" => float(step_durations[step_idx]), "carrier_note" => carrier_note,
        "brightness" => clamp(float(tuple[3]), 0.0, 1.0), "noise" => clamp(float(tuple[4]), 0.0, 1.0),
        "harmonicity" => clamp(float(tuple[5]), 0.0, 1.0), "attack" => clamp(float(tuple[6]), 0.0, 1.0),
        "decay" => clamp(float(tuple[7]), 0.0, 1.0), "sustain_release" => clamp(float(tuple[8]), 0.0, 1.0)))
    end
    isempty(segments) || push!(requests, Dict(
      "stream_id" => stream_id,
      "start_time" => float(controls[1]["time"]),
      "segments" => segments,
      "controls" => controls,
    ))
  end
  @info "VOICEVOX stem requests built" steps=steps stream_ids=all_ids request_count=length(requests) voice_key_count=length(voice_keys) request_stream_ids=[request["stream_id"] for request in requests] segments=[(stream_id=request["stream_id"], text=segment["text"], start_time=control["time"], duration=segment["duration"], carrier_note=control["carrier_note"], vol=control["amp"]) for request in requests for (segment, control) in zip(request["segments"], request["controls"])]
  return requests, voice_keys
end

function render_stems(requests; worker_url::AbstractString=get(ENV, "VOICEVOX_URL", "http://voicevox-worker:9120"))
  isempty(requests) && return Any[]
  response = HTTP.post(rstrip(String(worker_url), '/') * "/render", ["Content-Type" => "application/json"], JSON3.write(Dict("stems" => requests)); readtimeout=600, status_exception=false)
  response.status == 200 || error("VOICEVOX worker returned HTTP $(response.status): $(String(response.body))")
  result = _string_dict(JSON3.read(String(response.body)))
  controls_by_id = Dict(Int(request["stream_id"]) => request["controls"] for request in requests)
  stems = Any[]
  for raw in get(result, "stems", Any[])
    item = _string_dict(raw)
    stream_id = Int(item["stream_id"])
    wav_b64 = string(get(item, "audio_base64", ""))
    isempty(wav_b64) && error("VOICEVOX worker returned an empty stem for stream $(stream_id)")
    path = joinpath("/tmp", "voicevox_stem_$(uuid4()).wav")
    open(path, "w") do io; write(io, base64decode(wav_b64)); end
    push!(stems, Dict("stream_id" => stream_id, "path" => path, "controls" => get(controls_by_id, stream_id, Any[]), "backend" => string(get(item, "backend", get(result, "backend", "voicevox")))))
  end
  length(stems) == length(requests) || error("VOICEVOX worker returned $(length(stems)) stems; expected $(length(requests))")
  @info "VOICEVOX stems rendered" request_count=length(requests) stem_count=length(stems) stem_stream_ids=[stem["stream_id"] for stem in stems]
  return stems
end

function cleanup_stems!(stems)
  for stem in stems
    path = try string(stem["path"]) catch; "" end
    startswith(abspath(path), "/tmp/") && isfile(path) && rm(path; force=true)
  end
  return nothing
end

export build_stem_requests, render_stems, cleanup_stems!
end
