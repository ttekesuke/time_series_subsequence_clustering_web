module SupercollidersController

using Genie.Requests
using UUIDs
using Base64
using Dates
using Printf
import ..Config

const RENDER_POLYPHONIC_TEMPLATE_PATH = normpath(joinpath(@__DIR__, "..", "supercollider", "render_polyphonic.scd.tpl"))

function _read_render_polyphonic_template()::String
  return read(RENDER_POLYPHONIC_TEMPLATE_PATH, String)
end

function _sc_string_escape(s::AbstractString)::String
  return replace(String(s), "\\" => "\\\\", "\"" => "\\\"")
end

function build_score_events_scd(
  time_series, step_durations::AbstractVector{<:Real},
  outfile::String,
  tail_pad_seconds::Float64
)::String
  io = IOBuffer()
  mix_bus = Config.SC_MIX_BUS

  # ---------- Parse input and generate note events ----------
  current_time = 0.0
  node_id = Config.SC_INITIAL_NODE_ID
  midi_to_freq(m) = Config.A4_FREQ * 2.0^((m - float(Config.MIDI_A4)) / float(Config.STEPS_PER_OCTAVE))

    # Parse one stream entry in the strict timbre format.
  # Returns: (abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release)
  # New strict shape:
  #   [abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release]
  #   [abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release, chord_range, density]
  function _parse_stream(s)::Tuple{Vector{Int},Float64,Float64,Float64,Float64,Float64,Float64,Float64}
    default_stream = (
      Int[],
      Config.SC_DEFAULT_VOLUME,
      Config.SC_DEFAULT_BRIGHTNESS,
      Config.SC_DEFAULT_NOISE,
      Config.SC_DEFAULT_HARMONICITY,
      Config.SC_DEFAULT_ATTACK,
      Config.SC_DEFAULT_DECAY,
      Config.SC_DEFAULT_SUSTAIN_RELEASE
    )
    s isa AbstractVector || return default_stream
    isempty(s) && return default_stream

    if length(s) >= 1 && s[1] isa AbstractVector
      abs_notes = Int[]
      for v in s[1]
        v === nothing && continue
        push!(abs_notes, clamp(_parse_int(v), Config.abs_pitch_min(), Config.abs_pitch_max()))
      end
      sort!(abs_notes)
      unique!(abs_notes)

      vol = clamp(length(s) >= 2 ? _parse_float(s[2]) : Config.SC_DEFAULT_VOLUME, Config.UNIT_MIN, Config.UNIT_MAX)
      brightness = clamp(length(s) >= 3 ? _parse_float(s[3]) : Config.SC_DEFAULT_BRIGHTNESS, Config.UNIT_MIN, Config.UNIT_MAX)
      noise = clamp(length(s) >= 4 ? _parse_float(s[4]) : Config.SC_DEFAULT_NOISE, Config.UNIT_MIN, Config.UNIT_MAX)
      harmonicity = clamp(length(s) >= 5 ? _parse_float(s[5]) : Config.SC_DEFAULT_HARMONICITY, Config.UNIT_MIN, Config.UNIT_MAX)
      attack = clamp(length(s) >= 6 ? _parse_float(s[6]) : Config.SC_DEFAULT_ATTACK, Config.UNIT_MIN, Config.UNIT_MAX)
      decay = clamp(length(s) >= 7 ? _parse_float(s[7]) : Config.SC_DEFAULT_DECAY, Config.UNIT_MIN, Config.UNIT_MAX)
      sustain_release = clamp(length(s) >= 8 ? _parse_float(s[8]) : Config.SC_DEFAULT_SUSTAIN_RELEASE, Config.UNIT_MIN, Config.UNIT_MAX)
      return (abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release)
    end

    return default_stream
  end

  Event = NamedTuple{
    (:time, :freq, :dur, :amp, :brightness, :noise, :harmonicity, :attack, :decay, :sustain_release),
    Tuple{Float64,Float64,Float64,Float64,Float64,Float64,Float64,Float64,Float64,Float64}
  }
  StepVoice = NamedTuple{
    (:stream_idx, :abs_notes, :vol, :brightness, :noise, :harmonicity, :attack, :decay, :sustain_release),
    Tuple{Int,Vector{Int},Float64,Float64,Float64,Float64,Float64,Float64,Float64}
  }
  events = Event[]
  base_voice_gain = Config.SC_BASE_VOICE_GAIN

  for (step_idx, step_streams) in enumerate(time_series isa AbstractVector ? time_series : Any[])
    step_duration = float(step_durations[clamp(step_idx, 1, length(step_durations))])
    step_voices = StepVoice[]

    @printf("Step %d: step_duration=%.3f\n", step_idx, step_duration)
    if step_streams isa AbstractVector
      @printf("Processing step %d with %d streams, step_duration=%.3f\n", step_idx, length(step_streams), step_duration)
      for (stream_idx, s) in enumerate(step_streams)
        s === nothing && continue
        abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release = _parse_stream(s)
        (vol > Config.SC_MIN_AUDIBLE_VOLUME && !isempty(abs_notes)) || continue
        push!(step_voices, (
          stream_idx = stream_idx,
          abs_notes = abs_notes,
          vol = vol,
          brightness = brightness,
          noise = noise,
          harmonicity = harmonicity,
          attack = attack,
          decay = decay,
          sustain_release = sustain_release
        ))
      end

      # Compute step_note_mass defensively to avoid "reducing over an empty collection"
      step_note_mass = 0.0
      for v in step_voices
        step_note_mass += float(v.vol) * float(length(v.abs_notes))
      end
      step_gain = step_note_mass > 0 ? (1.0 / sqrt(step_note_mass)) : 1.0
      step_gain = clamp(step_gain, Config.SC_STEP_GAIN_MIN, Config.UNIT_MAX)

      for voice in step_voices
        @printf("Step %d, Stream %d: vol=%.3f, notes=%s, bri=%.2f, noi=%.2f, har=%.2f, atk=%.2f, dec=%.2f, sr=%.2f\n",
          step_idx, voice.stream_idx, voice.vol, string(voice.abs_notes), voice.brightness, voice.noise, voice.harmonicity, voice.attack, voice.decay, voice.sustain_release)
        amp_each = (voice.vol / length(voice.abs_notes)) * base_voice_gain * step_gain

        for midi_note in voice.abs_notes
          freq = midi_to_freq(midi_note)
          push!(events, (
            time = current_time,
            freq = freq,
            dur  = step_duration,
            amp  = amp_each,
            brightness = voice.brightness,
            noise = voice.noise,
            harmonicity = voice.harmonicity,
            attack = voice.attack,
            decay = voice.decay,
            sustain_release = voice.sustain_release
          ))
        end
      end
    end

    current_time += step_duration
  end

  for (event_idx, ev) in enumerate(events)
    suffix = event_idx < length(events) ? "," : ""
    println(io, @sprintf(
      "  [%.6f, ['/s_new', \\polySynth, %d, 0, 0, \\freq, %.6f, \\dur, %.6f, \\amp, %.6f, \\brightness, %.6f, \\noise, %.6f, \\harmonicity, %.6f, \\attack, %.6f, \\decay, %.6f, \\sustainRelease, %.6f, \\outBus, %d]]%s",
      ev.time, node_id, ev.freq, ev.dur, ev.amp, ev.brightness, ev.noise, ev.harmonicity, ev.attack, ev.decay, ev.sustain_release, mix_bus, suffix
    ))
    node_id += 1
  end

  total_duration = current_time
  total_duration_pad = total_duration + max(0.0, tail_pad_seconds)
  score_events = String(take!(io))
  template = _read_render_polyphonic_template()
  default_step_duration = isempty(step_durations) ? Config.step_duration_from_bpm(Config.POLYPHONIC_BPM) : float(step_durations[1])

  return replace(
    template,
    "{{SCORE_EVENTS}}" => chomp(score_events),
    "{{SOUND_FILE_PATH}}" => _sc_string_escape(outfile),
    "{{STEP_DURATION}}" => @sprintf("%.6f", default_step_duration),
    "{{TOTAL_DURATION_PAD}}" => @sprintf("%.6f", total_duration_pad),
  )
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

function _payload()::Dict{String,Any}
  jp = Requests.jsonpayload()
  if jp !== nothing
    return Dict{String,Any}(string(k) => v for (k, v) in pairs(jp))
  end
  return Dict{String,Any}()
end

_parse_float(x) = x isa Real ? float(x) : (x === nothing ? 0.0 : parse(Float64, string(x)))
_parse_int(x) = x isa Integer ? Int(x) : (x === nothing ? 0 : parse(Int, string(x)))

function _normalize_bpm_value(raw; fallback=Config.POLYPHONIC_BPM)::Float64
  bpm = try
    _parse_float(raw)
  catch
    float(fallback)
  end
  return Config.sanitize_bpm(bpm)
end

function _normalize_bpm_series(raw, expected_len::Int; fallback=Config.POLYPHONIC_BPM, align_tail::Bool=false)::Vector{Float64}
  target_len = max(expected_len, 1)
  source = raw isa AbstractVector ? collect(raw) : (raw === nothing ? Any[] : Any[raw])

  normalized = Float64[]
  for item in source
    push!(normalized, _normalize_bpm_value(item; fallback=fallback))
  end

  isempty(normalized) && return fill(_normalize_bpm_value(fallback; fallback=fallback), target_len)

  if length(normalized) >= target_len
    start_idx = align_tail ? (length(normalized) - target_len + 1) : 1
    return normalized[start_idx:(start_idx + target_len - 1)]
  end

  fallback_bpm = normalized[end]
  out = copy(normalized)
  while length(out) < target_len
    push!(out, fallback_bpm)
  end
  return out
end

function _step_durations_from_bpm_series(bpm_series::AbstractVector{<:Real})::Vector{Float64}
  return [Config.step_duration_from_bpm(float(bpm)) for bpm in bpm_series]
end

function _combine_bpm_series(initial_raw, future_raw, expected_len::Int; fallback=Config.POLYPHONIC_BPM)::Union{Nothing,Vector{Float64}}
  if initial_raw === nothing && future_raw === nothing
    return nothing
  end

  initial_len = initial_raw isa AbstractVector ? length(initial_raw) : (initial_raw === nothing ? 0 : 1)
  future_len = future_raw isa AbstractVector ? length(future_raw) : (future_raw === nothing ? 0 : 1)

  initial_series = initial_len > 0 ? _normalize_bpm_series(initial_raw, initial_len; fallback=fallback) : Float64[]
  future_series = future_len > 0 ? _normalize_bpm_series(future_raw, future_len; fallback=fallback) : Float64[]
  return _normalize_bpm_series(vcat(initial_series, future_series), expected_len; fallback=fallback, align_tail=true)
end

function _safe_tmp_path(prefix::AbstractString, suffix::AbstractString)
  return joinpath("/tmp", "$(prefix)_$(uuid4())$(suffix)")
end

function _render_timeout_seconds(render_duration::Real)::Float64
  estimated = float(render_duration) * Config.SC_RENDER_TIMEOUT_DURATION_MULTIPLIER + Config.SC_RENDER_TIMEOUT_EXTRA_SECONDS
  return clamp(estimated, Config.SC_RENDER_TIMEOUT_MIN_SECONDS, Config.SC_RENDER_TIMEOUT_MAX_SECONDS)
end

function _run_sclang_with_timeout(scd_path::AbstractString, timeout_seconds::Real)
  cmd = `env QT_QPA_PLATFORM=offscreen sclang $scd_path`
  proc = run(pipeline(cmd; stdin=devnull, stdout=devnull, stderr=devnull); wait=false)
  wait_task = @async wait(proc)
  status = timedwait(() -> istaskdone(wait_task), float(timeout_seconds); pollint=0.1)

  if status == :timed_out
    try
      kill(proc)
    catch
    end
    try
      wait(proc)
    catch
    end
    return (
      ok = false,
      timed_out = true,
      exit_code = nothing,
      timeout_seconds = float(timeout_seconds),
      command = string(cmd),
    )
  end

  return (
    ok = success(proc),
    timed_out = false,
    exit_code = proc.exitcode,
    timeout_seconds = float(timeout_seconds),
    command = string(cmd),
  )
end

function _is_safe_tmp_file(path::AbstractString)
  p = abspath(path)
  return startswith(p, "/tmp/")
end

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------
function render_polyphonic()
  payload = _payload()
  time_series_any = get(payload, "time_series", Any[])
  # Sanitize incoming time_series to avoid empty/invalid entries that can
  # cause downstream reducers (like `maximum`/`minimum`) to error.
  function _sanitize_time_series(raw)
    out = Any[]
    for step in (raw isa AbstractVector ? raw : Any[])
      if !(step isa AbstractVector)
        push!(out, Any[])
        continue
      end
      step_out = Any[]
      for s in step
        try
          s === nothing && continue

          # new strict: [abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release]
          # new strict full: [abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release, chord_range, density]
          if length(s) >= 1 && s[1] isa AbstractVector
            abs_notes = Int[]
            for v in s[1]
              v === nothing && continue
              push!(abs_notes, clamp(_parse_int(v), Config.abs_pitch_min(), Config.abs_pitch_max()))
            end
            vol = clamp(length(s) >= 2 ? _parse_float(s[2]) : Config.SC_DEFAULT_VOLUME, Config.UNIT_MIN, Config.UNIT_MAX)
            # skip near-zero volume or empty chords
            if vol > Config.SC_SANITIZE_MIN_AUDIBLE_VOLUME && !isempty(abs_notes)
              push!(step_out, [
                abs_notes,
                vol,
                length(s) >= 3 ? _parse_float(s[3]) : Config.SC_DEFAULT_BRIGHTNESS,
                length(s) >= 4 ? _parse_float(s[4]) : Config.SC_DEFAULT_NOISE,
                length(s) >= 5 ? _parse_float(s[5]) : Config.SC_DEFAULT_HARMONICITY,
                length(s) >= 6 ? _parse_float(s[6]) : Config.SC_DEFAULT_ATTACK,
                length(s) >= 7 ? _parse_float(s[7]) : Config.SC_DEFAULT_DECAY,
                length(s) >= 8 ? _parse_float(s[8]) : Config.SC_DEFAULT_SUSTAIN_RELEASE
              ])
            end
          end
        catch
          # ignore malformed voice entries
          continue
        end
      end
      push!(out, step_out)
    end
    return out
  end

  time_series_any = _sanitize_time_series(time_series_any)
  gp = _to_string_dict(get(payload, "generate_polyphonic", nothing))
  raw_bpm = get(payload, "bpm", nothing)
  if raw_bpm === nothing
    raw_bpm = get(gp, "bpm", nothing)
  end
  raw_bpm_series = get(payload, "bpm_series", get(payload, "future_bpm", nothing))
  if raw_bpm_series === nothing
    raw_bpm_series = get(gp, "future_bpm", get(gp, "bpm_series", nothing))
  end
  bpm = _normalize_bpm_value(raw_bpm === nothing ? Config.POLYPHONIC_BPM : raw_bpm)
  step_count = length(time_series_any)
  combined_bpm_series = _combine_bpm_series(get(payload, "initial_context_bpm", nothing), get(payload, "future_bpm", nothing), step_count; fallback=bpm)
  if combined_bpm_series === nothing
    combined_bpm_series = _combine_bpm_series(get(gp, "initial_context_bpm", nothing), get(gp, "future_bpm", nothing), step_count; fallback=bpm)
  end
  bpm_series = if raw_bpm_series !== nothing
    _normalize_bpm_series(raw_bpm_series, step_count; fallback=bpm, align_tail=true)
  elseif combined_bpm_series !== nothing
    combined_bpm_series
  else
    _normalize_bpm_series(nothing, step_count; fallback=bpm, align_tail=true)
  end
  step_durations = _step_durations_from_bpm_series(bpm_series)
  raw_tail_pad_seconds = get(payload, "tail_pad_seconds", get(gp, "tail_pad_seconds", Config.SC_DEFAULT_TAIL_PAD_SECONDS))
  tail_pad_seconds = clamp(_parse_float(raw_tail_pad_seconds), Config.UNIT_MIN, Config.SC_MAX_TAIL_PAD_SECONDS)

  scd_path = _safe_tmp_path("supercollider_render_polyphonic", ".scd")
  wav_path = _safe_tmp_path("supercollider_render_polyphonic", ".wav")

  try
    scd_text = build_score_events_scd(time_series_any, step_durations, wav_path, tail_pad_seconds)
    open(scd_path, "w") do f
      write(f, scd_text)
    end

    render_duration = sum(step_durations) + tail_pad_seconds
    timeout_seconds = _render_timeout_seconds(render_duration)
    sclang_result = _run_sclang_with_timeout(scd_path, timeout_seconds)

    if !sclang_result.ok
      return Dict(
        "error" => sclang_result.timed_out ? "SuperCollider render timed out" : "SuperCollider render failed",
        "scd_file_path" => scd_path,
        "sound_file_path" => wav_path,
        "sc_exit_code" => sclang_result.exit_code,
        "sc_timed_out" => sclang_result.timed_out,
        "sc_timeout_seconds" => sclang_result.timeout_seconds,
        "bpm" => (isempty(bpm_series) ? bpm : bpm_series[1]),
        "bpmSeries" => bpm_series,
        "stepDuration" => (isempty(step_durations) ? Config.step_duration_from_bpm(bpm) : step_durations[1]),
        "stepDurations" => step_durations,
        "tailPadSeconds" => tail_pad_seconds,
      )
    end

    if !isfile(wav_path)
      return Dict(
        "error" => "wav file not generated",
        "scd_file_path" => scd_path,
        "sound_file_path" => wav_path,
      )
    end

    audio_b64 = base64encode(read(wav_path))
    return Dict(
      "audio_data" => "data:audio/wav;base64,$audio_b64",
      "scd_file_path" => scd_path,
      "sound_file_path" => wav_path,
      "bpm" => (isempty(bpm_series) ? bpm : bpm_series[1]),
      "bpmSeries" => bpm_series,
      "stepDuration" => (isempty(step_durations) ? Config.step_duration_from_bpm(bpm) : step_durations[1]),
      "stepDurations" => step_durations,
      "tailPadSeconds" => tail_pad_seconds,
    )
  catch e
    bt = catch_backtrace()
    io = IOBuffer()
    try
      showerror(io, e, bt)
    catch
      # fallback to simple string if showerror fails
      write(io, string(e))
    end
    bt_str = String(take!(io))
    return Dict(
      "error" => bt_str,
      "scd_file_path" => scd_path,
      "sound_file_path" => wav_path,
      "bpm" => (isempty(bpm_series) ? bpm : bpm_series[1]),
      "bpmSeries" => bpm_series,
      "stepDuration" => (isempty(step_durations) ? Config.step_duration_from_bpm(bpm) : step_durations[1]),
      "stepDurations" => step_durations,
      "tailPadSeconds" => tail_pad_seconds,
    )
  end
end

function cleanup()
  payload = _payload()
  cleanup_payload = _to_string_dict(get(payload, "cleanup", payload))
  scd_path = string(get(cleanup_payload, "scd_file_path", ""))
  wav_path = string(get(cleanup_payload, "sound_file_path", ""))

  deleted = String[]

  for p in (scd_path, wav_path)
    if !isempty(p) && _is_safe_tmp_file(p) && isfile(p)
      try
        rm(p; force=true)
        push!(deleted, p)
      catch
        # ignore
      end
    end
  end

  return Dict("ok" => true, "deleted" => deleted)
end

end # module
