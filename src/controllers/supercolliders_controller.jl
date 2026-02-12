module SupercollidersController

"""SuperCollider (audio rendering) controller

Rails 旧システムの `Api::Web::SupercollidersController` と互換の API を提供する。

- POST   /api/web/supercolliders/render_polyphonic
- DELETE /api/web/supercolliders/cleanup

このコントローラは `sclang` を外部プロセスとして起動し、
一時ファイルに生成した .scd を実行して .wav を生成する。
"""

using Genie.Requests
using UUIDs
using Base64
using Dates
using Printf
import ..PolyphonicConfig

using Printf

function build_score_events_scd(
  time_series, step_duration::Float64,
  outfile::String
)::String

  # time_series supports:
  # - legacy: [oct, notePCS(Array or scalar), vol, bri, hrd, tex, sustain?]
  # - strict: [abs_notes(Int[]), vol, bri, hrd, tex, chord_range, density, sustain]

  io = IOBuffer()

  println(io, "var server = Server(\\nrt,")
  println(io, "    options: ServerOptions.new")
  println(io, "    .numOutputBusChannels_(2)")
  println(io, "    .numInputBusChannels_(2)")
  println(io, "    .sampleRate_(44100)")
  println(io, ");")
  println(io, "")

  println(io, "a = Score([")
  println(io, "  [0.0, ['/d_recv',")
  println(io, "    SynthDef(\\polySynth, {")
  println(io, "        |out=0, freq=440, dur=0.125, amp=0.5,")
  println(io, "         brightness=0.5, hardness=0.5, texture=0.0, sustain=0.0, resonance=0.2|")
  println(io, "")
  println(io, "        var sig, env, core, sub;")
  println(io, "        var attackTime, holdTime, releaseTime, cutoff, rq, feedback, pulseWidth, noiseSig, legato, fullLegato;")
  println(io, "")
  println(io, "        legato = sustain.clip(0.0, 1.0);")
  println(io, "        fullLegato = (legato >= 0.999);")
  println(io, "        attackTime = (1.0 - hardness).linexp(0.0, 1.0, 0.001, 0.16);")
  println(io, "        attackTime = attackTime.min((dur * (0.35 - (legato * 0.15))).max(0.002));")
  println(io, "        attackTime = (attackTime * (1 - fullLegato)) + (((dur * 0.20).clip(0.01, 0.06)) * fullLegato);")
  println(io, "        holdTime = (dur - attackTime).max(0.002);")
  println(io, "        releaseTime = (dur * (0.45 + (legato * 1.10) + (resonance * 0.35))).max(0.01);")
  println(io, "        releaseTime = (releaseTime * (1 - fullLegato)) + (((dur * 0.08).max(0.02)) * fullLegato);")
  println(io, "        env = EnvGen.ar(Env.linen(attackTime, holdTime, releaseTime, 1.0, -4), doneAction: 2);")
  println(io, "")
  println(io, "        feedback = texture.linlin(0.0, 1.0, 0.0, 2.5);")
  println(io, "        core = SinOscFB.ar(freq, feedback);")
  println(io, "")
  println(io, "        pulseWidth = 0.5 + (texture * 0.4);")
  println(io, "        core = core * (1.0 - (texture * 0.5)) + (Pulse.ar(freq, pulseWidth) * (texture * 0.5));")
  println(io, "")
  println(io, "        noiseSig = PinkNoise.ar() * (texture - 0.7).max(0) * 0.5;")
  println(io, "        sub = SinOsc.ar(freq) * (1.0 - texture).max(0.2) * 0.5;")
  println(io, "        sig = core + noiseSig + sub;")
  println(io, "")
  println(io, "        cutoff = freq * (1 + (brightness * 20));")
  println(io, "        cutoff = cutoff.clip(20, 20000);")
  println(io, "")
  println(io, "        rq = (1.0 - (resonance * 0.95)).clip(0.02, 1.0);")
  println(io, "")
  println(io, "        sig = RLPF.ar(sig, cutoff, rq);")
  println(io, "        sig = BHiShelf.ar(sig, 3000, 1.0, (brightness - 0.5) * 12);")
  println(io, "")
  println(io, "        sig = sig * env * amp;")
  println(io, "        sig = sig.tanh;")
  println(io, "")
  println(io, "        Out.ar(out, sig ! 2);")
  println(io, "    }).asBytes;")
  println(io, "  ]],")
  println(io, "")

  current_time = 0.0
  node_id = 1000

  # helper: midi -> freq
  # SCに直接渡すので Julia側で計算する
  midi_to_freq(m) = 440.0 * 2.0^((m - 69.0) / 12.0)

  function _parse_stream_legacy_or_strict(s)::Tuple{Vector{Int},Float64,Float64,Float64,Float64,Float64}
    s isa AbstractVector || return (Int[], 0.0, 0.0, 0.0, 0.0, 0.0)
    isempty(s) && return (Int[], 0.0, 0.0, 0.0, 0.0, 0.0)

    # strict: [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain]
    if s[1] isa AbstractVector
      abs_notes = Int[]
      for v in s[1]
        v === nothing && continue
        push!(abs_notes, clamp(_parse_int(v), 0, 127))
      end
      sort!(abs_notes)
      unique!(abs_notes)

      vol = clamp(length(s) >= 2 ? _parse_float(s[2]) : 0.0, 0.0, 1.0)
      bri = clamp(length(s) >= 3 ? _parse_float(s[3]) : 0.0, 0.0, 1.0)
      hrd = clamp(length(s) >= 4 ? _parse_float(s[4]) : 0.0, 0.0, 1.0)
      tex = clamp(length(s) >= 5 ? _parse_float(s[5]) : 0.0, 0.0, 1.0)
      sus = clamp(length(s) >= 8 ? _parse_float(s[8]) : 0.0, 0.0, 1.0)
      sus = clamp(round(sus * 4.0) / 4.0, 0.0, 1.0)
      return (abs_notes, vol, bri, hrd, tex, sus)
    end

    # legacy: [oct, pcs, vol, bri, hrd, tex, sustain?]
    oct = _parse_int(length(s) >= 1 ? s[1] : 4)
    note_val = length(s) >= 2 ? s[2] : 0

    pcs = if note_val isa AbstractVector
      [_parse_int(x) % 12 for x in note_val if x !== nothing]
    else
      [_parse_int(note_val) % 12]
    end
    isempty(pcs) && (pcs = [0])

    base_c_midi = (oct + 1) * 12
    abs_notes = Int[clamp(base_c_midi + pc, 0, 127) for pc in pcs]
    sort!(abs_notes)
    unique!(abs_notes)

    vol = clamp(length(s) >= 3 ? _parse_float(s[3]) : 0.0, 0.0, 1.0)
    bri = clamp(length(s) >= 4 ? _parse_float(s[4]) : 0.0, 0.0, 1.0)
    hrd = clamp(length(s) >= 5 ? _parse_float(s[5]) : 0.0, 0.0, 1.0)
    tex = clamp(length(s) >= 6 ? _parse_float(s[6]) : 0.0, 0.0, 1.0)
    sus = clamp(length(s) >= 7 ? _parse_float(s[7]) : 0.0, 0.0, 1.0)
    sus = clamp(round(sus * 4.0) / 4.0, 0.0, 1.0)

    return (abs_notes, vol, bri, hrd, tex, sus)
  end

  Event = NamedTuple{
    (:time, :freq, :dur, :amp, :bri, :hrd, :tex, :sus),
    Tuple{Float64,Float64,Float64,Float64,Float64,Float64,Float64,Float64}
  }
  events = Event[]

  # key: (stream_index, midi_note) => index in `events`
  active_ties = Dict{Tuple{Int,Int},Int}()

  for step_streams in (time_series isa AbstractVector ? time_series : Any[])
    next_active_ties = Dict{Tuple{Int,Int},Int}()

    if step_streams isa AbstractVector
      for (stream_idx, s) in enumerate(step_streams)
        s === nothing && continue

        abs_notes, vol, bri, hrd, tex, sustain = _parse_stream_legacy_or_strict(s)
        (vol > 0.01 && !isempty(abs_notes)) || continue

        # sustain=1.0: tie mode (no retrigger on same stream+pitch between steps)
        tie_mode = sustain >= 0.999
        amp_each = (vol / length(abs_notes)) * (0.5 / (1.0 + (0.35 * sustain)))

        if tie_mode
          for midi_note in abs_notes
            key = (stream_idx, midi_note)

            if haskey(active_ties, key)
              ev_idx = active_ties[key]
              ev = events[ev_idx]
              events[ev_idx] = (
                time = ev.time,
                freq = ev.freq,
                dur  = ev.dur + step_duration,
                amp  = ev.amp,
                bri  = ev.bri,
                hrd  = ev.hrd,
                tex  = ev.tex,
                sus  = 1.0
              )
              next_active_ties[key] = ev_idx
            else
              freq = midi_to_freq(midi_note)
              push!(events, (
                time = current_time,
                freq = freq,
                dur  = step_duration,
                amp  = amp_each,
                bri  = bri,
                hrd  = hrd,
                tex  = tex,
                sus  = 1.0
              ))
              next_active_ties[key] = length(events)
            end
          end
        else
          # sustain<1.0: normal per-step note events
          note_dur = step_duration * (0.98 + (1.22 * sustain))
          for midi_note in abs_notes
            freq = midi_to_freq(midi_note)
            push!(events, (
              time = current_time,
              freq = freq,
              dur  = note_dur,
              amp  = amp_each,
              bri  = bri,
              hrd  = hrd,
              tex  = tex,
              sus  = sustain
            ))
          end
        end
      end
    end

    active_ties = next_active_ties
    current_time += step_duration
  end

  for ev in events
    println(io, @sprintf(
      "  [%.6f, ['/s_new', \\polySynth, %d, 0, 0, \\freq, %.6f, \\dur, %.6f, \\amp, %.6f, \\brightness, %.6f, \\hardness, %.6f, \\texture, %.6f, \\sustain, %.6f, \\resonance, 0.2]],",
      ev.time, node_id, ev.freq, ev.dur, ev.amp, ev.bri, ev.hrd, ev.tex, ev.sus
    ))
    node_id += 1
  end

  total_duration = current_time
  total_duration_pad = total_duration + 2.0

  println(io, "]);")
  println(io, "")

  # ✅ ここが超重要：最後に必ず終了させる
  println(io, "a.recordNRT(")
  println(io, "    outputFilePath: " * repr(outfile) * ",")
  println(io, "    headerFormat: \"wav\",")
  println(io, "    sampleFormat: \"int16\",")
  println(io, "    options: server.options,")
  println(io, @sprintf("    duration: %.6f,", total_duration_pad))
  println(io, "    action: { \"done\".postln; 0.exit; }")
  println(io, ");")
  println(io, "")
  println(io, "server.remove;")

  return String(take!(io))
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
    # Dict{Symbol,Any} でも Dict{String,Any} でも確実に String キーに揃える
    return Dict{String,Any}(string(k) => v for (k, v) in pairs(jp))
  end
  return Dict{String,Any}()
end


_parse_float(x) = x isa Real ? float(x) : (x === nothing ? 0.0 : parse(Float64, string(x)))
_parse_int(x) = x isa Integer ? Int(x) : (x === nothing ? 0 : parse(Int, string(x)))

function _safe_tmp_path(prefix::AbstractString, suffix::AbstractString)
  return joinpath("/tmp", "$(prefix)_$(uuid4())$(suffix)")
end

function _is_safe_tmp_file(path::AbstractString)
  # /tmp 下のみ許可 (任意ファイル削除防止)
  p = abspath(path)
  return startswith(p, "/tmp/")
end

# ------------------------------------------------------------
# SC code generator
# ------------------------------------------------------------
"""Convert a (octave, pitchclass) pair to MIDI note in this project"""
@inline function _to_midi_note(octave::Int, pc::Int)::Int
  return PolyphonicConfig.base_c_midi(octave) + (pc % PolyphonicConfig.STEPS_PER_OCTAVE)
end

@inline function _midi_to_freq(midi::Int)::Float64
  return 440.0 * 2.0^((float(midi) - 69.0) / 12.0)
end

function _as_int_vec(x)::Vector{Int}
  if x isa AbstractVector
    return [Int(v) for v in x]
  else
    return [Int(x)]
  end
end

"""Build events for SuperCollider script.

Each event is a 4-tuple: (time_sec, freq_hz, amp, pan)
"""
function _build_events(time_series_any, step_duration::Float64)
  # time_series: Vector{Any} (timestep) -> Vector{Any} (stream) -> Vector{Any} (dims)
  events = Vector{NTuple{4,Float64}}()

  # determine maximum stream count across steps (for panning)
  max_streams = 0
  if time_series_any isa AbstractVector
    for step in time_series_any
      if step isa AbstractVector
        max_streams = max(max_streams, length(step))
      end
    end
  end

  # pan mapping
  function pan_for(i::Int, n::Int)::Float64
    n <= 1 && return 0.0
    return -0.8 + (float(i - 1) / float(n - 1)) * 1.6
  end

  # conservative amp scale (avoid clipping when many streams/chords)
  amp_scale = 0.18

  # build events
  t = 0.0
  for step in (time_series_any isa AbstractVector ? time_series_any : Any[])
    if !(step isa AbstractVector)
      t += step_duration
      continue
    end
    for (stream_idx, stream_vec) in enumerate(step)
      if !(stream_vec isa AbstractVector) || length(stream_vec) < 3
        continue
      end
      octave = _parse_int(stream_vec[1])
      pcs = _as_int_vec(stream_vec[2])
      vol = _parse_float(stream_vec[3])
      vol = clamp(vol, 0.0, 1.0)

      chord_n = max(1, length(pcs))
      amp_each = (vol * amp_scale) / chord_n
      pan = pan_for(stream_idx, max_streams)

      for pc in pcs
        midi = _to_midi_note(octave, Int(pc))
        freq = _midi_to_freq(midi)
        push!(events, (t, freq, amp_each, pan))
      end
    end
    t += step_duration
  end

  return (events, t) # events, total_duration
end

function _events_to_sc_array(events::Vector{NTuple{4,Float64}})::String
  sort!(events, by = e -> e[1])

  io = IOBuffer()
  for (idx, (t, f, a, p)) in enumerate(events)
    line = @sprintf("[%.6f, %.3f, %.5f, %.4f]", t, f, a, p)
    if idx < length(events)
      println(io, "  ", line, ",")
    else
      println(io, "  ", line)
    end
  end

  return String(take!(io))
end
"""Generate the SuperCollider .scd script for polyphonic playback."""


# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------
function render_polyphonic()
  payload = _payload()
  time_series_any = get(payload, "time_series", Any[])
  step_duration = _parse_float(get(payload, "step_duration", 0.125))
  step_duration <= 0 && (step_duration = 0.125)

  scd_path = _safe_tmp_path("supercollider_render_polyphonic", ".scd")
  wav_path = _safe_tmp_path("supercollider_render_polyphonic", ".wav")

  try
    scd_text = build_score_events_scd(time_series_any, step_duration, wav_path)
    open(scd_path, "w") do f
      write(f, scd_text)
    end

    # Run sclang headless (QT offscreen)
    # NOTE: sclang の起動には Qt が絡むため offscreen を明示
    cmd = `bash -lc $("QT_QPA_PLATFORM=offscreen sclang \"$(scd_path)\"")`

    # In case SuperCollider fails, we still want a readable error in logs.
    # We don't capture stdout to avoid memory bloat with long logs.
    run(cmd)

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
    )
  catch e
    return Dict(
      "error" => string(e),
      "scd_file_path" => scd_path,
      "sound_file_path" => wav_path,
    )
  end
end

function cleanup()
  payload = _payload()
  scd_path = string(get(payload, "scd_file_path", ""))
  wav_path = string(get(payload, "sound_file_path", ""))

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
