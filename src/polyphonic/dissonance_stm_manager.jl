module DissonanceStmManager

"""DissonanceStmManager

Rails 旧システム (f2da) の `app/models/dissonance_stm_manager.rb` を 1:1 で移植。

- Sethares1993 (roughness) を使った dissonance_current
- short term memory interference（指数減衰）
- pitch class combo の roughness 評価（note 生成の前半）

重要: Rails と完全一致させるため、(freq,amp) の freq 昇順ソートを Dissonance 側で必ず実施する。
"""

using ..PolyphonicConfig
using ..Dissonance

struct MemoryEvent
  onset::Float64
  midi_notes::Vector{Int}
  amps::Vector{Float64}
  dissonance_current::Float64
end

mutable struct Manager
  memory_span::Float64
  memory_weight::Float64
  n_partials::Int
  amp_profile::Float64
  model::String
  prune_threshold::Float64
  memory::Vector{MemoryEvent}
end

"""Create a new STM manager.

Parameters are Rails defaults.
"""
function Manager(; memory_span::Float64=1.5, memory_weight::Float64=1.0, n_partials::Int=8, amp_profile::Float64=0.88, model::String="sethares1993", prune_threshold::Float64=0.01)
  return Manager(memory_span, memory_weight, n_partials, amp_profile, model, prune_threshold, MemoryEvent[])
end

# ---- public api ----

function evaluate(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64)::Float64
  d_current = dissonance_current(mgr, midi_notes, amps)
  return d_current + memory_interference(mgr, midi_notes, amps, onset, d_current)
end

function commit!(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64)::Float64
  d_current = dissonance_current(mgr, midi_notes, amps)
  d_total = d_current + memory_interference(mgr, midi_notes, amps, onset, d_current)

  prune!(mgr, onset)

  push!(mgr.memory, MemoryEvent(float(onset), copy(midi_notes), copy(amps), d_current))
  return d_total
end

"""Order pitch classes by their dissonance contribution.

This matches Rails `order_pitch_classes_by_contribution`:
- evaluate single-pc chord (each stream chord_size=1) for each pc
- sort by descending dissonance
"""
function order_pitch_classes_by_contribution(mgr::Manager, pitch_classes::Vector{Int}; octaves::Vector{Int}, vols::Vector{Float64}, onset::Float64)::Vector{Int}
  scored = Vector{Tuple{Int,Float64}}()
  sizehint!(scored, length(pitch_classes))

  for pc in pitch_classes
    pcs_per_stream = fill(pc, length(octaves))
    chord_sizes = fill(1, length(octaves))
    midi_notes, amps = build_chord_midi_and_amps_for_all_streams(octaves, vols, pcs_per_stream, chord_sizes)
    d = evaluate(mgr, midi_notes, amps, onset)
    push!(scored, (pc, d))
  end

  sort!(scored, by = x -> -x[2])
  return [x[1] for x in scored]
end

"""Compute roughness for a pitchclass combo.

Returns (roughness_value, chords_pcs)
- chords_pcs is Vector{Vector{Int}} (pcs per stream), same as Rails.
"""
function roughness_for_pitchclass_combo(mgr::Manager, combo::Vector{Int}; chord_sizes::Vector{Int}, octaves::Vector{Int}, vols::Vector{Float64}, onset::Float64)
  ordered = order_pitch_classes_by_contribution(mgr, combo; octaves=octaves, vols=vols, onset=onset)

  chords_pcs = Vector{Vector{Int}}(undef, length(chord_sizes))
  for (s, cs_raw) in enumerate(chord_sizes)
    cs = Int(cs_raw)
    cs < 1 && (cs = 1)
    cs > length(ordered) && (cs = length(ordered))
    chords_pcs[s] = ordered[1:cs]
  end

  midi_notes, amps = build_chord_midi_and_amps_for_all_streams(octaves, vols, nothing, chord_sizes; chords_pcs=chords_pcs)
  return (evaluate(mgr, midi_notes, amps, onset), chords_pcs)
end

# ---- internal ----

@inline function midi_to_freq(midi::Int)::Float64
  return PolyphonicConfig.A4_FREQ * (2.0 ^ ((float(midi) - float(PolyphonicConfig.MIDI_A4)) / float(PolyphonicConfig.STEPS_PER_OCTAVE)))
end

function dissonance_current(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64})::Float64
  n = length(midi_notes)
  if n < 2 || n != length(amps)
    return 0.0
  end

  freqs = Float64[]
  a = Float64[]
  sizehint!(freqs, n * mgr.n_partials)
  sizehint!(a, n * mgr.n_partials)

  @inbounds for i in 1:n
    amp = float(amps[i])
    if amp <= PolyphonicConfig.AMP_EPS
      continue
    end

    f0 = midi_to_freq(midi_notes[i])
    for p in 1:mgr.n_partials
      push!(freqs, f0 * p)
      push!(a, amp * (mgr.amp_profile ^ p))
    end
  end

  length(freqs) < 2 && return 0.0
  return Dissonance.dissonance(freqs, a; model=mgr.model)
end

function memory_interference(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64, d_current::Float64)::Float64
  isempty(mgr.memory) && return 0.0

  total = 0.0
  onset_f = float(onset)

  for evt in mgr.memory
    dt = onset_f - evt.onset
    dt < 0 && continue

    w = exp(-dt / mgr.memory_span)
    w < mgr.prune_threshold && continue

    d_past = evt.dissonance_current

    merged_notes = Vector{Int}(undef, length(midi_notes) + length(evt.midi_notes))
    merged_amps  = Vector{Float64}(undef, length(amps) + length(evt.amps))

    copyto!(merged_notes, 1, midi_notes, 1, length(midi_notes))
    copyto!(merged_notes, length(midi_notes)+1, evt.midi_notes, 1, length(evt.midi_notes))

    copyto!(merged_amps, 1, amps, 1, length(amps))
    copyto!(merged_amps, length(amps)+1, evt.amps, 1, length(evt.amps))

    d_merged = dissonance_current(mgr, merged_notes, merged_amps)

    interference = d_merged - d_current - d_past
    total += w * mgr.memory_weight * interference
  end

  return total
end

function prune!(mgr::Manager, onset::Float64)
  onset_f = float(onset)
  filtered = MemoryEvent[]
  sizehint!(filtered, length(mgr.memory))

  for evt in mgr.memory
    dt = onset_f - evt.onset
    dt < 0 && continue
    if exp(-dt / mgr.memory_span) >= mgr.prune_threshold
      push!(filtered, evt)
    end
  end

  mgr.memory = filtered
  return nothing
end

"""Build chord midi_notes and amps for all streams.

This is a Julia port of Rails `build_chord_midi_and_amps_for_all_streams`.

- octaves::Vector{Int}
- vols::Vector{Float64}
- pitch_classes_per_stream::Union{Nothing,Vector{Int}} (when chords_pcs is nothing)
- chord_sizes::Vector{Int}
- chords_pcs::Union{Nothing,Vector{Vector{Int}}}

Returns (midi_notes::Vector{Int}, amps::Vector{Float64})
"""
function build_chord_midi_and_amps_for_all_streams(octaves::Vector{Int}, vols::Vector{Float64}, pitch_classes_per_stream::Union{Nothing,Vector{Int}}, chord_sizes::Vector{Int}; chords_pcs::Union{Nothing,Vector{Vector{Int}}}=nothing)
  length(octaves) == length(vols) || error("octaves.length must equal vols.length")
  length(octaves) == length(chord_sizes) || error("octaves.length must equal chord_sizes.length")

  midi_notes = Int[]
  amps = Float64[]

  for s in eachindex(octaves)
    cs = Int(chord_sizes[s])
    cs < 1 && (cs = 1)

    pcs::Vector{Int} = if chords_pcs !== nothing
      chords_pcs[s]
    else
      pitch_classes_per_stream === nothing && error("pitch_classes_per_stream is required when chords_pcs is nothing")
      pc = pitch_classes_per_stream[s]
      fill(Int(pc), cs)
    end

    v = float(vols[s])
    a_each = v / float(length(pcs))

    base_c = PolyphonicConfig.base_c_midi(octaves[s])

    for pc in pcs
      m = base_c + mod(Int(pc), PolyphonicConfig.STEPS_PER_OCTAVE)
      push!(midi_notes, m)      
      push!(amps, a_each)
    end
  end

  return (midi_notes, amps)
end

end # module
