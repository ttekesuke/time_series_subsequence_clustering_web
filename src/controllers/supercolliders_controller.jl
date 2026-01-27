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

  # time_series: [step][stream] = [oct, notePCS(Array or scalar), vol, bri, hrd, tex]
  # Rails版の構造をそのまま踏襲する

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
  println(io, "        |out=0, freq=440, dur=0.25, amp=0.5,")
  println(io, "         brightness=0.5, hardness=0.5, texture=0.0, resonance=0.2|")
  println(io, "")
  println(io, "        var sig, env, core, sub;")
  println(io, "        var attackTime, releaseTime, cutoff, rq, feedback, pulseWidth, noiseSig;")
  println(io, "")
  println(io, "        attackTime = (1.0 - hardness).linexp(0.0, 1.0, 0.001, 0.2).min(dur * 0.5);")
  println(io, "        releaseTime = dur * (1.0 + (resonance * 2.0));")
  println(io, "        env = EnvGen.ar(Env.perc(attackTime, releaseTime, 1.0, -4), doneAction: 2);")
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

  for step_streams in time_series
    step_streams === nothing && continue

    for s in step_streams
      s === nothing && continue

      oct = Int(s[1])  # 1-basedに見える場合は調整
      note_val = s[2]

      pcs = if note_val isa AbstractVector
        [Int(x) % 12 for x in note_val if x !== nothing]
      else
        [Int(note_val) % 12]
      end
      isempty(pcs) && (pcs = [0])

      vol = Float64(s[3])
      bri = Float64(s[4])
      hrd = Float64(s[5])
      tex = Float64(s[6])

      base_c_midi = (oct + 1) * 12
      amp_each = (vol / length(pcs)) * 0.5

      if vol > 0.01
        for pc in pcs
          midi_note = base_c_midi + pc
          freq = midi_to_freq(midi_note)

          println(io, @sprintf(
            "  [%.6f, ['/s_new', \\polySynth, %d, 0, 0, \\freq, %.6f, \\dur, %.6f, \\amp, %.6f, \\brightness, %.6f, \\hardness, %.6f, \\texture, %.6f, \\resonance, 0.2]],",
            current_time, node_id, freq, step_duration, amp_each, bri, hrd, tex
          ))

          node_id += 1
        end
      end
    end

    current_time += step_duration
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
function render_polyphonic_from_series(time_series_any, step_duration::Float64)
  step_duration = float(step_duration)
  step_duration <= 0 && (step_duration = 0.25)

  scd_path = _safe_tmp_path("supercollider_render_polyphonic", ".scd")
  wav_path = _safe_tmp_path("supercollider_render_polyphonic", ".wav")

  try
    scd_text = build_score_events_scd(time_series_any, step_duration, wav_path)
    open(scd_path, "w") do f
      write(f, scd_text)
    end

    # Run sclang headless (QT offscreen)
    # NOTE: sclang の起動には Qt が絡むため offscreen を明示
    cmd_str = "QT_QPA_PLATFORM=offscreen sclang \"$(scd_path)\""
    cmd = `bash -lc $cmd_str`

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

function render_polyphonic()
  payload = _payload()
  time_series_any = get(payload, "time_series", Any[])
  step_duration = _parse_float(get(payload, "step_duration", 0.25))
  return render_polyphonic_from_series(time_series_any, step_duration)
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
