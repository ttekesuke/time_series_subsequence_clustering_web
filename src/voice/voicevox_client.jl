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
      if item === nothing
        continue
      end
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

function _process_peak_rss_bytes()::Int
  status_path = "/proc/self/status"
  isfile(status_path) || return 0
  try
    for line in eachline(status_path)
      startswith(line, "VmHWM:") || continue
      fields = split(strip(line))
      length(fields) >= 2 || return 0
      kb = tryparse(Int, fields[2])
      return kb === nothing ? 0 : kb * 1024
    end
  catch
  end
  return 0
end

function _response_header(response, name::AbstractString, fallback::AbstractString="")
  wanted = lowercase(String(name))
  for (key, value) in response.headers
    lowercase(String(key)) == wanted && return String(value)
  end
  return String(fallback)
end

function _write_binary_stem(response, request; output_dir::AbstractString=tempdir())
  response.status == 200 ||
    error("VOICEVOX worker returned HTTP $(response.status): $(String(response.body))")

  content_type = lowercase(_response_header(response, "Content-Type"))
  startswith(content_type, "audio/wav") ||
    error("VOICEVOX worker returned unexpected content type: $(content_type)")

  bytes = response.body
  isempty(bytes) && error("VOICEVOX worker returned an empty binary stem")

  stream_id = Int(request["stream_id"])
  response_stream_id = _response_header(response, "X-Voicevox-Stream-Id")
  if !isempty(response_stream_id)
    parsed = tryparse(Int, response_stream_id)
    parsed == stream_id ||
      error("VOICEVOX worker returned stream $(response_stream_id); expected $(stream_id)")
  end

  path = joinpath(output_dir, "voicevox_stem_$(uuid4()).wav")
  try
    open(path, "w") do io
      write(io, bytes)
    end
  catch
    isfile(path) && rm(path; force=true)
    rethrow()
  end

  audio_bytes_header = tryparse(Int, _response_header(response, "X-Voicevox-Audio-Bytes"))
  worker_peak_rss = tryparse(Int, _response_header(response, "X-Voicevox-Peak-Rss-Bytes"))
  return Dict(
    "stream_id" => stream_id,
    "path" => path,
    "controls" => get(request, "controls", Any[]),
    "backend" => _response_header(response, "X-Voicevox-Backend", "voicevox"),
    "audio_bytes" => (audio_bytes_header === nothing ? length(bytes) : audio_bytes_header),
    "worker_peak_rss_bytes" => (worker_peak_rss === nothing ? 0 : worker_peak_rss),
    "julia_peak_rss_bytes" => _process_peak_rss_bytes(),
  )
end

function render_stems(
  requests;
  worker_url::AbstractString=get(ENV, "VOICEVOX_URL", "http://voicevox-worker:9120"),
  output_dir::AbstractString=tempdir(),
  post_fn=HTTP.post,
)
  isempty(requests) && return Any[]
  stems = Any[]
  endpoint = rstrip(String(worker_url), '/') * "/render-stem"
  try
    for request in requests
      response = post_fn(
        endpoint,
        ["Content-Type" => "application/json"],
        JSON3.write(Dict("stems" => [request]));
        readtimeout=600,
        status_exception=false,
      )
      push!(stems, _write_binary_stem(response, request; output_dir=output_dir))
    end
    length(stems) == length(requests) ||
      error("VOICEVOX worker returned $(length(stems)) stems; expected $(length(requests))")
    @info "VOICEVOX stems rendered" request_count=length(requests) stem_count=length(stems) stem_stream_ids=[stem["stream_id"] for stem in stems] total_audio_bytes=sum(Int(get(stem, "audio_bytes", 0)) for stem in stems) worker_peak_rss_bytes=maximum([Int(get(stem, "worker_peak_rss_bytes", 0)) for stem in stems]; init=0) julia_peak_rss_bytes=_process_peak_rss_bytes()
    return stems
  catch
    cleanup_stems!(stems)
    rethrow()
  end
end

function _decode_stems(result, requests; output_dir::AbstractString=tempdir())
  controls_by_id = Dict(Int(request["stream_id"]) => request["controls"] for request in requests)
  stems = Any[]
  try
    for raw in get(result, "stems", Any[])
      item = _string_dict(raw)
      stream_id = Int(item["stream_id"])
      wav_b64 = string(get(item, "audio_base64", ""))
      isempty(wav_b64) && error("VOICEVOX worker returned an empty stem for stream $(stream_id)")
      bytes = base64decode(wav_b64)
      isempty(bytes) && error("VOICEVOX worker returned an empty decoded stem for stream $(stream_id)")
      path = joinpath(output_dir, "voicevox_stem_$(uuid4()).wav")
      try
        open(path, "w") do io; write(io, bytes); end
      catch
        isfile(path) && rm(path; force=true)
        rethrow()
      end
      push!(stems, Dict("stream_id" => stream_id, "path" => path, "controls" => get(controls_by_id, stream_id, Any[]), "backend" => string(get(item, "backend", get(result, "backend", "voicevox")))))
    end
    length(stems) == length(requests) || error("VOICEVOX worker returned $(length(stems)) stems; expected $(length(requests))")
    @info "VOICEVOX stems rendered" request_count=length(requests) stem_count=length(stems) stem_stream_ids=[stem["stream_id"] for stem in stems]
    return stems
  catch
    cleanup_stems!(stems)
    rethrow()
  end
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
