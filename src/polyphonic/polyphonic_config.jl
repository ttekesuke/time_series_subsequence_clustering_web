module PolyphonicConfig

"""PolyphonicConfig

Rails 旧システム (f2da) の `PolyphonicConfig` を 1:1 で移植。
`generate_polyphonic` 系で参照される定数・ユーティリティを提供する。

本モジュールは計算カーネルとなるため、Any を使わず型を固定する。
"""

# --- musical / midi constants ---
const STEPS_PER_OCTAVE::Int = 12
const OCTAVE_TO_MIDI_C_OFFSET::Int = 1  # oct=4 -> baseC=60 (C4)

const MIDI_A4::Int = 69
const A4_FREQ::Float64 = 440.0

const AMP_EPS::Float64 = 1e-6

# --- dimension ranges ---
const OCTAVE_RANGE = 0:7
const NOTE_RANGE = 0:11
const FLOAT_STEPS::Vector{Float64} = [round(i / 10.0, digits=1) for i in 0:10]
const CHORD_SIZE_RANGE = 1:4

# --- cluster forgetting (importance score) ---
const CLUSTER_IMPORTANCE_DECAY_TAU::Float64 = 100.0
const CLUSTER_IMPORTANCE_THRESHOLD::Float64 = 0

# safety caps
const MAX_NOTE_CANDIDATES::Int = 8_000

"""base C (MIDI) for given octave index in this system"""
base_c_midi(octave::Integer)::Int = (Int(octave) + OCTAVE_TO_MIDI_C_OFFSET) * STEPS_PER_OCTAVE

abs_pitch_min()::Int = base_c_midi(first(OCTAVE_RANGE)) + first(NOTE_RANGE)
abs_pitch_max()::Int = base_c_midi(last(OCTAVE_RANGE)) + last(NOTE_RANGE)

function abs_pitch_width()::Float64
  w = abs(abs_pitch_max() - abs_pitch_min())
  return w <= 0 ? 1.0 : float(w)
end

function note_range_width()::Float64
  w = abs(last(NOTE_RANGE) - first(NOTE_RANGE))
  return w <= 0 ? 1.0 : float(w)
end

end # module
