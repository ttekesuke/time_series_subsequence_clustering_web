module SupercollidersController

using Genie.Requests
using UUIDs
using Base64
using Dates
using Printf
import ..PolyphonicConfig

function build_score_events_scd(
  time_series, step_durations::AbstractVector{<:Real},
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
  default_step_duration = isempty(step_durations) ? PolyphonicConfig.step_duration_from_bpm(PolyphonicConfig.POLYPHONIC_BPM) : float(step_durations[1])

  # ---------- SynthDef (polySynth) with brightness, articulation, tonalness, resonance ----------
  println(io, "a = Score([")
  println(io, "  [0.0, ['/d_recv',")
  println(io, "    SynthDef(\\polySynth, {")
  println(io, @sprintf(
    "        |outBus=%d, freq=440, dur=%.6f, amp=0.18,",
    mix_bus,
    default_step_duration
  ))
  println(io, "         brightness=0.5, articulation=0.5, tonalness=0.5, resonance=0.5, sustain=0.0, subGain=1.0|")
  println(io, "")
  println(io, "        var sig, env, transientEnv, kickEnv, snareEnv, snareSnapEnv, snareTailEnv, hatEnv, toneEnv, clickEnv;")
  println(io, "        var gate01, fullLegato, attack, hold, release;")
  println(io, "        var bri, art, ton, res, basePitch, vibRate, vibDepth, vibrato;")
  println(io, "        var kickSweep, snareSweep, whiteBurst, pinkBurst, click, air;")
  println(io, "        var kickBody, snareBody, snareNoise, hatNoise, tonalBody, sub;")
  println(io, "        var kickMix, snareMix, snarePureMix, hatMix, tonalMix, lowWeight, cutoff, rq, spread, drive, left, right;")
  println(io, "")
  println(io, "        // --- controls ---")
  println(io, "        bri = brightness.clip(0.0, 1.0);")
  println(io, "        art = articulation.clip(0.0, 1.0);")
  println(io, "        ton = tonalness.clip(0.0, 1.0);")
  println(io, "        res = resonance.clip(0.0, 1.0);")
  println(io, "")
  println(io, "        // --- envelope (sustain = gate length, 1.0 = tie / no retrigger) ---")
  println(io, "        gate01 = sustain.clip(0.0, 1.0);")
  println(io, "        fullLegato = (gate01 >= 0.999);")
  println(io, "        attack = (0.002 + ((1.0 - art) * 0.06) + ((1.0 - ton) * 0.015)).clip(0.001, 0.08);")
  println(io, "        attack = attack.min((dur * (0.22 + (1.0 - gate01) * 0.18)).max(0.001));")
  println(io, "        hold = (dur - attack).max(0.002);")
  println(io, "        release = (dur * (0.08 + res * 0.85 + ton * 0.12)).clip(0.01, 0.7);")
  println(io, "        release = (release * (1 - fullLegato)) + (((dur * 0.08).max(0.02)) * fullLegato);")
  println(io, "        env = EnvGen.ar(Env.linen(attack, hold, release, 1.0, -4), doneAction: 2);")
  println(io, "        transientEnv = EnvGen.ar(Env.perc(0.0004, (0.006 + (1.0 - art) * 0.020), curve: -7));")
  println(io, "        kickEnv = EnvGen.ar(Env.perc(0.0008, (0.05 + res * 0.18 + ton * 0.08), curve: -6));")
  println(io, "        snareEnv = EnvGen.ar(Env.perc(0.0005, (0.11 + res * 0.22 + (1.0 - ton) * 0.08), curve: -5));")
  println(io, "        snareSnapEnv = EnvGen.ar(Env([0.0, 1.0, 0.0], [0.005 + (1.0 - art) * 0.003, 0.12 + res * 0.28 + (1.0 - ton) * 0.10], [-3, -7]));")
  println(io, "        snareTailEnv = EnvGen.ar(Env.perc(0.001, (0.04 + res * 0.12 + bri * 0.03), curve: -6));")
  println(io, "        hatEnv = EnvGen.ar(Env.perc(0.0003, (0.015 + bri * 0.05 + res * 0.12), curve: -8));")
  println(io, "        toneEnv = EnvGen.ar(Env.perc(0.001, (0.05 + ton * 0.12 + res * 0.12), curve: -4));")
  println(io, "        clickEnv = EnvGen.ar(Env.perc(0.0002, (0.003 + art * 0.008), curve: -9));")
  println(io, "")
  println(io, "        // --- continuous pitch behavior ---")
  println(io, "        vibRate = 3.5 + (1.0 - art) * 2.5;")
  println(io, "        vibDepth = ton * (1.0 - art) * 0.01;")
  println(io, "        vibrato = SinOsc.kr(vibRate, 0, vibDepth, 1.0);")
  println(io, "        basePitch = freq.clip(24, 12000);")
  println(io, "        kickSweep = XLine.kr((basePitch * (2.2 - bri * 0.35)).clip(28, 5000), (basePitch * (0.70 + ton * 0.16)).clip(22, 2500), (0.025 + (1.0 - art) * 0.02 + res * 0.03));")
  println(io, "        snareSweep = XLine.kr((basePitch * (1.35 - ton * 0.12)).clip(90, 6000), basePitch.clip(70, 3200), (0.012 + (1.0 - art) * 0.015));")
  println(io, "")
  println(io, "        whiteBurst = WhiteNoise.ar();")
  println(io, "        pinkBurst = PinkNoise.ar();")
  println(io, "        click = HPF.ar(whiteBurst, (1500 + bri * 9000).clip(500, 17000)) * clickEnv * (0.03 + art * 0.12);")
  println(io, "        click = click + BPF.ar(whiteBurst, (900 + bri * 7000).clip(300, 12000), 0.35) * transientEnv * (0.04 + art * 0.12);")
  println(io, "")
  println(io, "        tonalBody = Mix([")
  println(io, "          SinOsc.ar(basePitch * vibrato),")
  println(io, "          VarSaw.ar(basePitch * (1.0 + art * 0.015), 0, (0.60 - art * 0.20).clip(0.12, 0.95)) * 0.18")
  println(io, "        ]) * toneEnv;")
  println(io, "        tonalBody = LPF.ar(tonalBody, (220 + bri * 7000 + ton * 1800).clip(120, 12000));")
  println(io, "")
  println(io, "        kickBody = SinOsc.ar(kickSweep, 0, kickEnv * (0.58 + ton * 0.26));")
  println(io, "        kickBody = kickBody + SinOsc.ar((kickSweep * 0.50).clip(20, 1800), 0, kickEnv * (0.10 + (1.0 - bri) * 0.16));")
  println(io, "        kickBody = LPF.ar(kickBody, (180 + (1.0 - bri) * 320 + ton * 120).clip(80, 900));")
  println(io, "")
  println(io, "        snareBody = SinOsc.ar(snareSweep, 0, snareEnv * (0.08 + ton * 0.14));")
  println(io, "        snareBody = snareBody + SinOsc.ar((snareSweep * 1.8).clip(120, 8000), 0, snareEnv * 0.04);")
  println(io, "        snareBody = BPF.ar(snareBody, (150 + basePitch * 0.82 + ton * 80).clip(110, 2200), 0.40);")
  println(io, "")
  println(io, "        snareNoise = WhiteNoise.ar(snareSnapEnv);")
  println(io, "        snareNoise = snareNoise + (WhiteNoise.ar(snareSnapEnv) * (0.55 + (1.0 - ton) * 0.30));")
  println(io, "        snareNoise = (snareNoise * (0.65 + (1.0 - ton) * 0.45)) + (BPF.ar(WhiteNoise.ar(snareTailEnv), (2500 + bri * 1800).clip(1400, 6000), 0.65) * (0.18 + bri * 0.14));")
  println(io, "        snareNoise = snareNoise + (HPF.ar(PinkNoise.ar(snareTailEnv), (1400 + bri * 1200).clip(900, 4200)) * (0.08 + bri * 0.06));")
  println(io, "")
  println(io, "        hatNoise = HPF.ar(WhiteNoise.ar(1), (7000 + bri * 9000).clip(4000, 17000));")
  println(io, "        hatNoise = hatNoise * hatEnv;")
  println(io, "        hatNoise = hatNoise + BPF.ar(WhiteNoise.ar(1), (9500 + bri * 6500).clip(5500, 18000), 0.22) * hatEnv * (0.18 + bri * 0.22);")
  println(io, "")
  println(io, "        sub = SinOsc.ar((basePitch * (0.50 + ton * 0.18)).clip(20, 3000)) * (0.08 + ton * 0.20 + res * 0.08 + (1.0 - bri) * 0.08);")
  println(io, "        sub = sub * subGain.clip(0.0, 1.0);")
  println(io, "        sub = LPF.ar(sub, (110 + (1.0 - bri) * 220 + ton * 120).clip(50, 700));")
  println(io, "")
  println(io, "        kickMix = ((1.0 - bri) * (0.35 + ton * 0.65)).clip(0.0, 1.0);")
  println(io, "        snareMix = ((1.0 - (bri - 0.38).abs * 2.0).clip(0.0, 1.0) * (1.0 - ton * 0.78) * (0.55 + art * 0.30)).clip(0.0, 1.0);")
  println(io, "        snarePureMix = ((1.0 - (bri - 0.30).abs * 2.4).clip(0.0, 1.0) * (1.0 - ton).pow(0.7) * (0.75 + art * 0.20)).clip(0.0, 1.0);")
  println(io, "        hatMix = (bri * (1.0 - ton) * (0.45 + art * 0.20 + res * 0.15)).clip(0.0, 1.0);")
  println(io, "        tonalMix = (ton * (0.20 + res * 0.18)).clip(0.0, 1.0);")
  println(io, "        lowWeight = ((1.0 - bri) * (0.40 + ton * 0.60)).clip(0.0, 1.0);")
  println(io, "")
  println(io, "        sig = (kickBody * kickMix) + ((snareBody * (0.25 + ton * 0.55)) + (snareNoise * (0.55 + snarePureMix * 0.95))) * snareMix + (hatNoise * hatMix) + (tonalBody * tonalMix) + (sub * lowWeight) + click;")
  println(io, "        air = HPF.ar(sig, (3000 + bri * 8000).clip(1500, 17500)) * (0.02 + hatMix * 0.18);")
  println(io, "        sig = sig + air;")
  println(io, "")
  println(io, "        cutoff = (180 + bri * 15500 + ton * 1200).clip(120, 18000);")
  println(io, "        rq = (0.88 - bri * 0.40 + (1.0 - ton) * 0.05).clip(0.12, 0.95);")
  println(io, "        sig = RLPF.ar(sig, cutoff, rq);")
  println(io, "        sig = BLowShelf.ar(sig, 140, 0.8, ((1.0 - bri) * 6.0) + ton * 1.0 - 2.5);")
  println(io, "        sig = BHiShelf.ar(sig, 4200, 0.9, (bri * 8.5) + hatMix * 3.0 - 5.0);")
  println(io, "")
  println(io, "        drive = 1.0 + art * 1.4 + (1.0 - ton) * 0.35 + res * 0.15;")
  println(io, "        sig = tanh(sig * drive);")
  println(io, "        sig = sig * (0.94 - hatMix * 0.06 - snareMix * 0.03).clip(0.62, 1.0);")
  println(io, "        sig = Normalizer.ar(sig, 0.4, 0.015);")
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
  println(io, "        spread = (0.001 + (1.0 - ton) * 0.006 + res * 0.003 + bri * 0.002).clip(0.0, 0.03);")
  println(io, "        right = DelayC.ar(sig, 0.03, spread);")
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
  # Returns: (abs_notes, vol, brightness, articulation, tonalness, resonance, sustain)
  # sustain semantics:
  #   0.0 => gate length is one step's 1/4
  #   0.0 < sustain < 1.0 => gate length interpolates up to one full step
  #   1.0 => tie to next note on same stream/pitch with no retrigger
  # Note: chord_range and density are ignored for sound synthesis.
  function _parse_stream(s)::Tuple{Vector{Int},Float64,Float64,Float64,Float64,Float64,Float64}
    s isa AbstractVector || return (Int[], 0.0, 0.5, 0.5, 0.5, 0.5, 0.0)
    isempty(s) && return (Int[], 0.0, 0.5, 0.5, 0.5, 0.5, 0.0)

    # strict: [abs_notes, vol, brightness, articulation, tonalness, resonance, chord_range, density, sustain]
    if length(s) >= 1 && s[1] isa AbstractVector
      abs_notes = Int[]
      for v in s[1]
        v === nothing && continue
        push!(abs_notes, clamp(_parse_int(v), PolyphonicConfig.abs_pitch_min(), PolyphonicConfig.abs_pitch_max()))
      end
      sort!(abs_notes)
      unique!(abs_notes)

      vol = clamp(length(s) >= 2 ? _parse_float(s[2]) : 0.0, 0.0, 1.0)
      bri = clamp(length(s) >= 3 ? _parse_float(s[3]) : 0.5, 0.0, 1.0)
      art = clamp(length(s) >= 4 ? _parse_float(s[4]) : 0.5, 0.0, 1.0)
      ton = clamp(length(s) >= 5 ? _parse_float(s[5]) : 0.5, 0.0, 1.0)
      res = clamp(length(s) >= 6 ? _parse_float(s[6]) : 0.5, 0.0, 1.0)
      # skip chord_range (index 7) and density (index 8)
      sus = clamp(length(s) >= 9 ? _parse_float(s[9]) : 0.0, 0.0, 1.0)
      sus = clamp(round(sus * 4.0) / 4.0, 0.0, 1.0)
      return (abs_notes, vol, bri, art, ton, res, sus)
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
    bri = clamp(length(s) >= 4 ? _parse_float(s[4]) : 0.5, 0.0, 1.0)
    art = clamp(length(s) >= 5 ? _parse_float(s[5]) : 0.5, 0.0, 1.0)
    ton = clamp(length(s) >= 6 ? _parse_float(s[6]) : 0.5, 0.0, 1.0)
    res = 0.5
    sus = clamp(length(s) >= 7 ? _parse_float(s[7]) : 0.0, 0.0, 1.0)
    sus = clamp(round(sus * 4.0) / 4.0, 0.0, 1.0)
    return (abs_notes, vol, bri, art, ton, res, sus)
  end

  Event = NamedTuple{
    (:time, :freq, :dur, :amp, :brightness, :articulation, :tonalness, :resonance, :sus),
    Tuple{Float64,Float64,Float64,Float64,Float64,Float64,Float64,Float64,Float64}
  }
  StepVoice = NamedTuple{
    (:stream_idx, :abs_notes, :vol, :brightness, :articulation, :tonalness, :resonance, :sustain),
    Tuple{Int,Vector{Int},Float64,Float64,Float64,Float64,Float64,Float64}
  }
  events = Event[]
  base_voice_gain = 0.30
  active_ties = Dict{Tuple{Int,Int},Int}()

  for (step_idx, step_streams) in enumerate(time_series isa AbstractVector ? time_series : Any[])
    step_duration = float(step_durations[clamp(step_idx, 1, length(step_durations))])
    next_active_ties = Dict{Tuple{Int,Int},Int}()
    step_voices = StepVoice[]

    if step_streams isa AbstractVector
      for (stream_idx, s) in enumerate(step_streams)
        s === nothing && continue
        abs_notes, vol, brightness, articulation, tonalness, resonance, sustain = _parse_stream(s)
        (vol > 0.01 && !isempty(abs_notes)) || continue
        push!(step_voices, (
          stream_idx = stream_idx,
          abs_notes = abs_notes,
          vol = vol,
          brightness = brightness,
          articulation = articulation,
          tonalness = tonalness,
          resonance = resonance,
          sustain = sustain
        ))
      end

      # Compute step_note_mass defensively to avoid "reducing over an empty collection"
      step_note_mass = 0.0
      for v in step_voices
        step_note_mass += float(v.vol) * float(length(v.abs_notes))
      end
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
                brightness  = ev.brightness,
                articulation = ev.articulation,
                tonalness = ev.tonalness,
                resonance = ev.resonance,
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
                brightness  = voice.brightness,
                articulation = voice.articulation,
                tonalness = voice.tonalness,
                resonance = voice.resonance,
                sus  = 1.0
              ))
              next_active_ties[key] = length(events)
            end
          end
        else
          note_dur = step_duration * (0.25 + (0.75 * voice.sustain))
          for midi_note in voice.abs_notes
            freq = midi_to_freq(midi_note)
            push!(events, (
              time = current_time,
              freq = freq,
              dur  = note_dur,
              amp  = amp_each,
              brightness  = voice.brightness,
              articulation = voice.articulation,
              tonalness = voice.tonalness,
              resonance = voice.resonance,
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
      "  [%.6f, ['/s_new', \\polySynth, %d, 0, 0, \\freq, %.6f, \\dur, %.6f, \\amp, %.6f, \\brightness, %.6f, \\articulation, %.6f, \\tonalness, %.6f, \\resonance, %.6f, \\sustain, %.6f, \\subGain, %.6f, \\outBus, %d]],",
      ev.time, node_id, ev.freq, ev.dur, ev.amp, ev.brightness, ev.articulation, ev.tonalness, ev.resonance, ev.sus, sub_gain, mix_bus
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

function _normalize_bpm_value(raw; fallback=PolyphonicConfig.POLYPHONIC_BPM)::Float64
  bpm = try
    _parse_float(raw)
  catch
    float(fallback)
  end
  return PolyphonicConfig.sanitize_bpm(bpm)
end

function _normalize_bpm_series(raw, expected_len::Int; fallback=PolyphonicConfig.POLYPHONIC_BPM, align_tail::Bool=false)::Vector{Float64}
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
  return [PolyphonicConfig.step_duration_from_bpm(float(bpm)) for bpm in bpm_series]
end

function _combine_bpm_series(initial_raw, future_raw, expected_len::Int; fallback=PolyphonicConfig.POLYPHONIC_BPM)::Union{Nothing,Vector{Float64}}
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

          # strict: [abs_notes, vol, brightness, articulation, tonalness, resonance, chord_range, density, sustain]
          if length(s) >= 1 && s[1] isa AbstractVector
            abs_notes = Int[]
            for v in s[1]
              v === nothing && continue
              push!(abs_notes, clamp(_parse_int(v), PolyphonicConfig.abs_pitch_min(), PolyphonicConfig.abs_pitch_max()))
            end
            vol = clamp(length(s) >= 2 ? _parse_float(s[2]) : 0.0, 0.0, 1.0)
            # skip near-zero volume or empty chords
            if vol > 0.001 && !isempty(abs_notes)
              push!(step_out, [abs_notes, vol, length(s) >= 3 ? _parse_float(s[3]) : 0.5, length(s) >= 4 ? _parse_float(s[4]) : 0.5, length(s) >= 5 ? _parse_float(s[5]) : 0.5, length(s) >= 6 ? _parse_float(s[6]) : 0.5, length(s) >= 7 ? _parse_float(s[7]) : 0.0, length(s) >= 8 ? _parse_float(s[8]) : 0.0, length(s) >= 9 ? _parse_float(s[9]) : 0.0])
            end
          else
            # legacy: [oct, pcs, vol, bri, hrd, tex, sustain?]
            oct = _parse_int(length(s) >= 1 ? s[1] : 4)
            note_val = length(s) >= 2 ? s[2] : 0
            pcs = if note_val isa AbstractVector
              [_parse_int(x) % 12 for x in note_val if x !== nothing]
            else
              [_parse_int(note_val) % 12]
            end
            isempty(pcs) && (pcs = [0])
            vol = clamp(length(s) >= 3 ? _parse_float(s[3]) : 0.0, 0.0, 1.0)
            if vol > 0.001 && !isempty(pcs)
              push!(step_out, [oct, pcs, vol, length(s) >= 4 ? _parse_float(s[4]) : 0.5, length(s) >= 5 ? _parse_float(s[5]) : 0.5, length(s) >= 6 ? _parse_float(s[6]) : 0.5, length(s) >= 7 ? _parse_float(s[7]) : 0.0])
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
  raw_sub_gain = get(payload, "sub_gain", 0.0)
  gp = _to_string_dict(get(payload, "generate_polyphonic", nothing))
  raw_bpm = get(payload, "bpm", nothing)
  if raw_bpm === nothing
    raw_bpm = get(gp, "bpm", nothing)
  end
  raw_bpm_series = get(payload, "bpm_series", get(payload, "future_bpm", nothing))
  if raw_bpm_series === nothing
    raw_bpm_series = get(gp, "future_bpm", get(gp, "bpm_series", nothing))
  end
  bpm = _normalize_bpm_value(raw_bpm === nothing ? PolyphonicConfig.POLYPHONIC_BPM : raw_bpm)
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
  sub_gain = clamp(_parse_float(raw_sub_gain), 0.0, 1.0)

  scd_path = _safe_tmp_path("supercollider_render_polyphonic", ".scd")
  wav_path = _safe_tmp_path("supercollider_render_polyphonic", ".wav")

  try
    scd_text = build_score_events_scd(time_series_any, step_durations, wav_path, sub_gain)
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
      "bpm" => (isempty(bpm_series) ? bpm : bpm_series[1]),
      "bpmSeries" => bpm_series,
      "stepDuration" => (isempty(step_durations) ? PolyphonicConfig.step_duration_from_bpm(bpm) : step_durations[1]),
      "stepDurations" => step_durations,
      "subGain" => sub_gain,
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
      "stepDuration" => (isempty(step_durations) ? PolyphonicConfig.step_duration_from_bpm(bpm) : step_durations[1]),
      "stepDurations" => step_durations,
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
