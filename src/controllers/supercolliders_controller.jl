module SupercollidersController

using Genie.Requests
using UUIDs
using Base64
using Dates
using Printf
import ..PolyphonicConfig

function build_score_events_scd(
  time_series, step_duration::Float64,
  outfile::String,
  sub_gain::Float64
)::String

  io = IOBuffer()

  # ---------- Server definition ----------
  println(io, "var server = Server(\\nrt,")
  println(io, "    options: ServerOptions.new")
  println(io, "    .numOutputBusChannels_(2)")
  println(io, "    .numInputBusChannels_(2)")
  println(io, "    .sampleRate_(44100)")
  println(io, ");")
  println(io, "")

  mix_bus = 16
  master_node_id = 900

  # ---------- SynthDef (polySynth) with only brightness, hardness, texture ----------
  println(io, "a = Score([")
  println(io, "  [0.0, ['/d_recv',")
  println(io, "    SynthDef(\\polySynth, {")
  println(io, @sprintf(
    "        |outBus=%d, freq=440, dur=%.6f, amp=0.18,",
    mix_bus,
    step_duration
  ))
  println(io, "         brightness=0.5, hardness=0.5, texture=0.0, sustain=0.0, subGain=1.0|")
  println(io, "")
  println(io, "        var sig, env, transientEnv, body, tone, sub, noise, click;")
  println(io, "        var legato, fullLegato, attack, hold, release;")
  println(io, "        var bri, hrd, tex, f0, vibRate, vibDepth, vibrato;")
  println(io, "        var stringOsc, brassOsc, fmOsc, shimmerOsc, percNoise;")
  println(io, "        var stringAmt, brassAmt, fmAmt, percAmt, den;")
  println(io, "        var cutoff, rq, drive, left, right, air, safeGain, timbreComp, levelerTarget, levelerDur;")
  println(io, "")
  println(io, "        // --- controls ---")
  println(io, "        bri = brightness.clip(0.0, 1.0);")
  println(io, "        hrd = hardness.clip(0.0, 1.0);")
  println(io, "        tex = texture.clip(0.0, 1.0);")
  println(io, "")
  println(io, "        // --- envelope (hardness controls attack / body) ---")
  println(io, "        legato = sustain.clip(0.0, 1.0);")
  println(io, "        fullLegato = (legato >= 0.999);")
  println(io, "        attack = (1.0 - hrd).linexp(0.0, 1.0, 0.001, 0.2);")
  println(io, "        attack = attack.min((dur * (0.34 - (legato * 0.14))).max(0.0015));")
  println(io, "        attack = (attack * (1 - fullLegato)) + (((dur * (0.18 + tex * 0.08)).clip(0.008, 0.07)) * fullLegato);")
  println(io, "        hold = (dur - attack).max(0.002);")
  println(io, "        release = (dur * (0.35 + (legato * 1.20) + ((1.0 - hrd) * 0.30) + (tex * 0.15))).max(0.01);")
  println(io, "        release = (release * (1 - fullLegato)) + (((dur * 0.08).max(0.02)) * fullLegato);")
  println(io, "        env = EnvGen.ar(Env.linen(attack, hold, release, 1.0, -4), doneAction: 2);")
  println(io, "        transientEnv = EnvGen.ar(Env.perc(0.0008, (0.012 + (1.0 - hrd) * 0.05), curve: -6));")
  println(io, "")
  println(io, "        // --- subtle movement (string-like softness at low hardness/texture) ---")
  println(io, "        vibRate = 4.0 + (1.0 - hrd) * 1.5 + (1.0 - tex) * 1.0;")
  println(io, "        vibDepth = (1.0 - hrd) * (1.0 - tex * 0.7) * 0.012;")
  println(io, "        vibrato = SinOsc.kr(vibRate, 0, vibDepth, 1.0);")
  println(io, "        f0 = freq * vibrato * (1.0 + Rand(-0.003, 0.003));")
  println(io, "")
  println(io, "        // --- source A: string-ish (detuned saw stack) ---")
  println(io, "        stringOsc = Mix([Saw.ar(f0 * 0.997), Saw.ar(f0), Saw.ar(f0 * 1.003)]) * 0.33;")
  println(io, "        stringOsc = LPF.ar(stringOsc, (800 + (bri * 5200) + ((1.0 - tex) * 1600)).clip(120, 12000));")
  println(io, "        stringOsc = stringOsc * (0.75 + (1.0 - hrd) * 0.35);")
  println(io, "")
  println(io, "        // --- source B: brass-ish (pulse/saw with drive) ---")
  println(io, "        brassOsc = Pulse.ar(f0, (0.42 + tex * 0.24).clip(0.08, 0.92)) * 0.65 + Saw.ar(f0 * 2.0) * 0.35;")
  println(io, "        brassOsc = RLPF.ar(brassOsc, (300 + (bri * 3800) + (hrd * 2400)).clip(100, 14000), (0.7 - hrd * 0.35).clip(0.08, 0.95));")
  println(io, "        brassOsc = tanh(brassOsc * (1.3 + hrd * 1.8));")
  println(io, "")
  println(io, "        // --- source C: shimmer / metallic FM ---")
  println(io, "        fmOsc = SinOsc.ar(f0 + (SinOsc.ar(f0 * (1.3 + bri * 3.4)) * f0 * (0.08 + tex * 1.55)));")
  println(io, "        shimmerOsc = BPF.ar(fmOsc, (1400 + bri * 9000).clip(300, 16000), (0.22 + tex * 0.25).clip(0.08, 0.9));")
  println(io, "        shimmerOsc = HPF.ar(shimmerOsc, (300 + bri * 1500).clip(150, 8000));")
  println(io, "")
  println(io, "        // --- noise / percussive layer ---")
  println(io, "        noise = LPF.ar(PinkNoise.ar(), 12000) * (0.02 + tex * 0.14);")
  println(io, "        percNoise = BPF.ar(WhiteNoise.ar(), (1200 + bri * 9000).clip(400, 16000), (0.18 + hrd * 0.35).clip(0.08, 0.95));")
  println(io, "        click = percNoise * transientEnv * (0.18 + hrd * 0.55) * (0.25 + tex * 0.5);")
  println(io, "")
  println(io, "        // --- low-end body ---")
  println(io, "        sub = SinOsc.ar(f0 * 0.5) * (0.22 + (1.0 - bri) * 0.42);")
  println(io, "        sub = sub + (LFTri.ar(f0 * 0.5) * (0.10 + (1.0 - tex) * 0.18));")
  println(io, "        sub = LPF.ar(sub, (170 + (1.0 - bri) * 260).clip(90, 700));")
  println(io, "        sub = sub * subGain.clip(0.0, 1.0);")
  println(io, "")
  println(io, "        // --- morph by texture/hardness ---")
  println(io, "        stringAmt = ((1.0 - tex) * (1.0 - hrd * 0.55)).clip(0.0, 1.0);")
  println(io, "        brassAmt = ((1.0 - (tex - 0.45).abs * 2.0).clip(0.0, 1.0) * (0.45 + hrd * 0.55)).clip(0.0, 1.0);")
  println(io, "        fmAmt = (tex * (0.25 + bri * 0.75)).clip(0.0, 1.0);")
  println(io, "        percAmt = (tex * (0.35 + hrd * 0.65)).clip(0.0, 1.0);")
  println(io, "        den = (stringAmt + brassAmt + fmAmt + 0.001);")
  println(io, "        tone = ((stringOsc * stringAmt) + (brassOsc * brassAmt) + (shimmerOsc * fmAmt)) / den;")
  println(io, "        body = tone + sub + noise + (click * percAmt);")
  println(io, "        air = HPF.ar(body, (3500 + bri * 5200).clip(1200, 14000)) * (bri * (0.05 + tex * 0.20));")
  println(io, "        sig = body + air;")
  println(io, "")
  println(io, "        // --- global tone shaping by brightness ---")
  println(io, "        cutoff = (140 + ((bri * bri) * 15500) + (hrd * 900)).clip(90, 17000);")
  println(io, "        rq = (0.92 - (bri * 0.45) + (tex * 0.08)).clip(0.12, 0.95);")
  println(io, "        sig = RLPF.ar(sig, cutoff, rq);")
  println(io, "        sig = BLowShelf.ar(sig, 140, 0.8, ((1.0 - bri) * 6.0 + (1.0 - tex) * 2.0) - 2.5);")
  println(io, "        sig = BHiShelf.ar(sig, 3200, 0.9, (bri * 9.0 + tex * 3.0) - 5.0);")
  println(io, "")
  println(io, "        // --- hardness => drive / punch ---")
  println(io, "        drive = 1.0 + (hrd * 2.2) + (tex * 1.0);")
  println(io, "        sig = tanh(sig * drive);")
  println(io, "        // intense timbre area is auto-attenuated to avoid silent failure by overload")
  println(io, "        safeGain = (1.0 - (tex * 0.22) - (hrd * 0.12)).clip(0.55, 1.0);")
  println(io, "        sig = sig * safeGain;")
  println(io, "        // timbre-dependent loudness compensation (keep vol perceptually consistent)")
  println(io, "        timbreComp = (1.18 - (tex * 0.34) - (hrd * 0.22) - (bri * 0.08)).clip(0.65, 1.18);")
  println(io, "        sig = sig * timbreComp;")
  println(io, "        // gentle per-voice leveling before applying vol amp")
  println(io, "        levelerTarget = 0.38;")
  println(io, "        levelerDur = 0.015;")
  println(io, "        sig = Normalizer.ar(sig, levelerTarget, levelerDur);")
  println(io, "        sig = HPF.ar(sig, 18);")
  println(io, "        sig = LPF.ar(sig, 18000);")
  println(io, "        sig = sig.clip2(1.2);")
  println(io, "        sig = CompanderD.ar(sig, thresh: 0.55, slopeBelow: 1.0, slopeAbove: 0.62, clampTime: 0.002, relaxTime: 0.08);")
  println(io, "        sig = Limiter.ar(sig, 0.95, 0.003);")
  println(io, "")
  println(io, "        sig = LeakDC.ar(sig);")
  println(io, "        sig = sig * env * amp;")
  println(io, "")
  println(io, "        left = sig;")
  println(io, "        right = DelayC.ar(sig, 0.03, (0.0015 + tex * 0.007 + (1.0 - hrd) * 0.002).clip(0.0, 0.03));")
  println(io, "        Out.ar(outBus, [left, right]);")
  println(io, "    }).asBytes;")
  println(io, "  ]],")
  println(io, "")

  # ---------- Master output SynthDef ----------
  println(io, "  [0.0, ['/d_recv',")
  println(io, "    SynthDef(\\masterOut, {")
  println(io, @sprintf("        |inBus=%d, out=0, masterGain=0.92|", mix_bus))
  println(io, "        var sig;")
  println(io, "        sig = In.ar(inBus, 2);")
  println(io, "        sig = LeakDC.ar(sig);")
  println(io, "        sig = CompanderD.ar(sig, thresh: 0.65, slopeBelow: 1.0, slopeAbove: 0.5, clampTime: 0.003, relaxTime: 0.10);")
  println(io, "        sig = Limiter.ar(sig, 0.92, 0.005);")
  println(io, "        Out.ar(out, sig * masterGain);")
  println(io, "    }).asBytes;")
  println(io, "  ]],")
  println(io, @sprintf("  [0.0, ['/s_new', \\masterOut, %d, 1, 0, \\inBus, %d, \\out, 0, \\masterGain, 0.92]],", master_node_id, mix_bus))
  println(io, "")

  # ---------- Parse input and generate note events ----------
  current_time = 0.0
  node_id = 1000
  midi_to_freq(m) = 440.0 * 2.0^((m - 69.0) / 12.0)

  # Parse one stream entry (legacy or strict)
  # Returns: (abs_notes, vol, bri, hrd, tex, sustain)
  # Note: chord_range and density are ignored for sound synthesis.
  function _parse_stream(s)::Tuple{Vector{Int},Float64,Float64,Float64,Float64,Float64}
    s isa AbstractVector || return (Int[], 0.0, 0.0, 0.0, 0.0, 0.0)
    isempty(s) && return (Int[], 0.0, 0.0, 0.0, 0.0, 0.0)

    # strict: [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain]
    if length(s) >= 1 && s[1] isa AbstractVector
      abs_notes = Int[]
      for v in s[1]
        v === nothing && continue
        push!(abs_notes, clamp(_parse_int(v), PolyphonicConfig.abs_pitch_min(), PolyphonicConfig.abs_pitch_max()))
      end
      sort!(abs_notes)
      unique!(abs_notes)

      vol = clamp(length(s) >= 2 ? _parse_float(s[2]) : 0.0, 0.0, 1.0)
      bri = clamp(length(s) >= 3 ? _parse_float(s[3]) : 0.0, 0.0, 1.0)
      hrd = clamp(length(s) >= 4 ? _parse_float(s[4]) : 0.0, 0.0, 1.0)
      tex = clamp(length(s) >= 5 ? _parse_float(s[5]) : 0.0, 0.0, 1.0)
      # skip chord_range (index 6) and density (index 7)
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
    abs_notes = Int[clamp(base_c_midi + pc, PolyphonicConfig.abs_pitch_min(), PolyphonicConfig.abs_pitch_max()) for pc in pcs]
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
  StepVoice = NamedTuple{
    (:stream_idx, :abs_notes, :vol, :bri, :hrd, :tex, :sustain),
    Tuple{Int,Vector{Int},Float64,Float64,Float64,Float64,Float64}
  }
  events = Event[]
  base_voice_gain = 0.30
  active_ties = Dict{Tuple{Int,Int},Int}()

  for step_streams in (time_series isa AbstractVector ? time_series : Any[])
    next_active_ties = Dict{Tuple{Int,Int},Int}()
    step_voices = StepVoice[]

    if step_streams isa AbstractVector
      for (stream_idx, s) in enumerate(step_streams)
        s === nothing && continue
        abs_notes, vol, bri, hrd, tex, sustain = _parse_stream(s)
        (vol > 0.01 && !isempty(abs_notes)) || continue
        push!(step_voices, (
          stream_idx = stream_idx,
          abs_notes = abs_notes,
          vol = vol,
          bri = bri,
          hrd = hrd,
          tex = tex,
          sustain = sustain
        ))
      end

      step_note_mass = sum(v.vol * length(v.abs_notes) for v in step_voices)
      step_gain = step_note_mass > 0 ? (1.0 / sqrt(step_note_mass)) : 1.0
      step_gain = clamp(step_gain, 0.20, 1.0)

      for voice in step_voices
        tie_mode = voice.sustain >= 0.999
        legato_gain = 1.0 - (0.25 * voice.sustain)
        amp_each = (voice.vol / length(voice.abs_notes)) * base_voice_gain * step_gain * legato_gain

        if tie_mode
          for midi_note in voice.abs_notes
            key = (voice.stream_idx, midi_note)
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
                bri  = voice.bri,
                hrd  = voice.hrd,
                tex  = voice.tex,
                sus  = 1.0
              ))
              next_active_ties[key] = length(events)
            end
          end
        else
          note_dur = step_duration * (0.98 + (1.22 * voice.sustain))
          for midi_note in voice.abs_notes
            freq = midi_to_freq(midi_note)
            push!(events, (
              time = current_time,
              freq = freq,
              dur  = note_dur,
              amp  = amp_each,
              bri  = voice.bri,
              hrd  = voice.hrd,
              tex  = voice.tex,
              sus  = voice.sustain
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
      "  [%.6f, ['/s_new', \\polySynth, %d, 0, 0, \\freq, %.6f, \\dur, %.6f, \\amp, %.6f, \\brightness, %.6f, \\hardness, %.6f, \\texture, %.6f, \\sustain, %.6f, \\subGain, %.6f, \\outBus, %d]],",
      ev.time, node_id, ev.freq, ev.dur, ev.amp, ev.bri, ev.hrd, ev.tex, ev.sus, sub_gain, mix_bus
    ))
    node_id += 1
  end

  total_duration = current_time
  total_duration_pad = total_duration + 2.0

  println(io, "]);")
  println(io, "")

  # ---------- NRT recording ----------
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
  p = abspath(path)
  return startswith(p, "/tmp/")
end

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------
function render_polyphonic()
  payload = _payload()
  time_series_any = get(payload, "time_series", Any[])
  raw_sub_gain = get(payload, "sub_gain", 0.0)
  raw_bpm = get(payload, "bpm", nothing)
  if raw_bpm === nothing
    gp = _to_string_dict(get(payload, "generate_polyphonic", nothing))
    raw_bpm = get(gp, "bpm", nothing)
  end
  bpm = PolyphonicConfig.sanitize_bpm(_parse_float(raw_bpm === nothing ? PolyphonicConfig.POLYPHONIC_BPM : raw_bpm))
  step_duration = PolyphonicConfig.step_duration_from_bpm(bpm)
  sub_gain = clamp(_parse_float(raw_sub_gain), 0.0, 1.0)

  scd_path = _safe_tmp_path("supercollider_render_polyphonic", ".scd")
  wav_path = _safe_tmp_path("supercollider_render_polyphonic", ".wav")

  try
    scd_text = build_score_events_scd(time_series_any, step_duration, wav_path, sub_gain)
    open(scd_path, "w") do f
      write(f, scd_text)
    end

    # Run sclang headless (QT offscreen)
    cmd = `bash -c "QT_QPA_PLATFORM=offscreen sclang $(scd_path)"`
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
      "bpm" => bpm,
      "stepDuration" => step_duration,
      "subGain" => sub_gain,
    )
  catch e
    return Dict(
      "error" => string(e),
      "scd_file_path" => scd_path,
      "sound_file_path" => wav_path,
      "bpm" => bpm,
      "stepDuration" => step_duration,
      "subGain" => sub_gain,
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
