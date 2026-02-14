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
const MIDI_NOTE_MIN::Int = 24
const MIDI_NOTE_MAX::Int = 120

const AMP_EPS::Float64 = 1e-6

# --- dimension ranges ---
const OCTAVE_RANGE = 0:7
const NOTE_RANGE = 0:11
const FLOAT_STEPS::Vector{Float64} = [round(i / 10.0, digits=1) for i in 0:10]
const CHORD_SIZE_RANGE = 1:4
const CHORD_RANGE_VALUE_MIN::Int = 0
const CHORD_RANGE_VALUE_MAX::Int = 24
const CHORD_RANGE_SEARCH_RANGE = 0:12

const SUSTAIN_QUANTIZE_STEPS::Int = 4
const SUSTAIN_LEVELS::Vector{Float64} = [0.0, 0.25, 0.5, 0.75, 1.0]

const AREA_BAND_SIZE::Int = 4
const AREA_MOVE_BINS::Vector{Tuple{Int,Int}} = [
  (-12, -9),
  (-8,  -7),
  (-6,  -5),
  (-4,  -3),
  (-2,  -1),
  (-1,   1),
  ( 1,   2),
  ( 3,   4),
  ( 5,   6),
  ( 7,   8),
  ( 9,  12),
]
const AREA_TOP_BINS_PER_STREAM_SINGLE::Int = 1
const AREA_TOP_BINS_PER_STREAM_MULTI::Int = 3

const POLYPHONIC_BPM::Float64 = 240.0
const POLYPHONIC_STEP_DURATION::Float64 = 60.0 / POLYPHONIC_BPM
const POLYPHONIC_BPM_MIN::Float64 = 1.0
const DEFAULT_TARGET_01::Float64 = 0.5
const DEFAULT_SPREAD_01::Float64 = 0.0
const POLYPHONIC_MIN_WINDOW_SIZE::Int = 2
const DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO::Float64 = 0.02

const DISSONANCE_STM_MEMORY_SPAN::Float64 = 1.5
const DISSONANCE_STM_MEMORY_WEIGHT::Float64 = 1.0
const DISSONANCE_STM_N_PARTIALS::Int = 8
const DISSONANCE_STM_AMP_PROFILE::Float64 = 0.88

# --- cluster forgetting (importance score) ---
const CLUSTER_IMPORTANCE_DECAY_TAU::Float64 = 100.0
const CLUSTER_IMPORTANCE_THRESHOLD::Float64 = 0

# safety caps
const MAX_NOTE_CANDIDATES::Int = 8_000

"""base C (MIDI) for given octave index in this system"""
base_c_midi(octave::Integer)::Int = (Int(octave) + OCTAVE_TO_MIDI_C_OFFSET) * STEPS_PER_OCTAVE

abs_pitch_min()::Int = MIDI_NOTE_MIN
abs_pitch_max()::Int = MIDI_NOTE_MAX

function sanitize_bpm(bpm)::Float64
  b = float(bpm)
  return (isfinite(b) && b >= POLYPHONIC_BPM_MIN) ? b : POLYPHONIC_BPM
end

function step_duration_from_bpm(bpm)::Float64
  return 60.0 / sanitize_bpm(bpm)
end

function abs_pitch_width()::Float64
  w = abs(abs_pitch_max() - abs_pitch_min())
  return w <= 0 ? 1.0 : float(w)
end

function note_range_width()::Float64
  w = abs(last(NOTE_RANGE) - first(NOTE_RANGE))
  return w <= 0 ? 1.0 : float(w)
end

function quantize_sustain(x)::Float64
  v = clamp(float(x), 0.0, 1.0)
  return clamp(round(v * SUSTAIN_QUANTIZE_STEPS) / float(SUSTAIN_QUANTIZE_STEPS), 0.0, 1.0)
end

function area_band_low_min()::Int
  amin = abs_pitch_min()
  return clamp(Int(fld(amin, AREA_BAND_SIZE) * AREA_BAND_SIZE), MIDI_NOTE_MIN, MIDI_NOTE_MAX)
end

function area_band_low_max()::Int
  amax = abs_pitch_max()
  return clamp(Int(fld(amax, AREA_BAND_SIZE) * AREA_BAND_SIZE), MIDI_NOTE_MIN, MIDI_NOTE_MAX)
end

function area_band_low(abs_note::Integer)::Int
  return clamp(Int(fld(Int(abs_note), AREA_BAND_SIZE) * AREA_BAND_SIZE), area_band_low_min(), area_band_low_max())
end

end # module
