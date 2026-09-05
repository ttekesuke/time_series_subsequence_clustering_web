module Config

"""Config

System-wide constants and small utility functions.
Polyphonic constants were originally ported from the Rails f2da system; this
module now also owns single-stream clustering and controller defaults.

本モジュールは計算カーネルとなるため、Any を使わず型を固定する。
"""

# --- common numeric defaults ---
const UNIT_MIN::Float64 = 0.0
const UNIT_MID::Float64 = 0.5
const UNIT_MAX::Float64 = 1.0
const SECONDS_PER_MINUTE::Float64 = 60.0
const PROCESSING_TIME_DIGITS::Int = 2

# --- single-stream clustering defaults ---
const SUBSEQUENCE_MIN_WINDOW_SIZE::Int = 2
const DEFAULT_MERGE_THRESHOLD_RATIO::Float64 = 0.3
const DEFAULT_CONTEXTUAL_MIN_WIDTH::Float64 = 1.0
const DEFAULT_RANGE_MIN::Int = 0
const DEFAULT_RANGE_MAX::Int = 24
const DEFAULT_QUERY_MIN_MATCH_WINDOW::Int = 3

# --- musical / midi constants ---
const STEPS_PER_OCTAVE::Int = 12
const OCTAVE_TO_MIDI_C_OFFSET::Int = 1
const MIDI_C4::Int = (4 + OCTAVE_TO_MIDI_C_OFFSET) * STEPS_PER_OCTAVE

const MIDI_A4::Int = 69
const A4_FREQ::Float64 = 440.0
const MIDI_NOTE_MIN::Int = 36
const MIDI_NOTE_MAX::Int = 120

const AMP_EPS::Float64 = 1e-6

# --- query/vector dimensions ---
const MIDI_NOTE_VOL_VALUE_MIN::Float64 = 0.0
const MIDI_NOTE_VOL_VALUE_MAX::Float64 = 127.0
const MIDI_NOTE_VOL_MAX_SET_SIZE::Int = 2
const MIDI_NOTE_VOL_AXIS_RANGES::Vector{Float64} = [127.0, 1.0]

# --- dimension ranges ---
const OCTAVE_RANGE = 0:7
const NOTE_RANGE = 0:11
const FLOAT_STEPS::Vector{Float64} = [round(i / 10.0, digits=1) for i in 0:10]
const VOL_STEPS::Vector{Float64} = [UNIT_MIN, UNIT_MAX]
# 0.0 = re-articulate, 0.5 = continue with a light attack accent,
# 1.0 = continue without re-articulation.
const TIE_STEPS::Vector{Float64} = [UNIT_MIN, UNIT_MID, UNIT_MAX]
const CHORD_SIZE_RANGE = 1:4
const CHORD_RANGE_VALUE_MIN::Int = 0
const CHORD_RANGE_VALUE_MAX::Int = 24
const CHORD_RANGE_SEARCH_RANGE = 0:12

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
const NOTE_REGISTER_MEMORY_STEPS::Int = 16
const NOTE_REGISTER_MIN_ALLOWANCE::Int = AREA_BAND_SIZE
const NOTE_REGISTER_MAX_ALLOWANCE::Int = 28

const POLYPHONIC_BPM::Float64 = 240.0
const POLYPHONIC_STEP_DURATION::Float64 = SECONDS_PER_MINUTE / POLYPHONIC_BPM
const POLYPHONIC_BPM_MIN::Float64 = 1.0
const DEFAULT_TARGET_01::Float64 = 0.5
const DEFAULT_SPREAD_01::Float64 = 0.0
const POLYPHONIC_MIN_WINDOW_SIZE::Int = 2
const DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO::Float64 = 0.02
const OCCURRENCE_INTERVAL_MIN_OCCURRENCES::Int = 3
const OCCURRENCE_INTERVAL_RATIO_MAX::Float64 = 4.0
const OCCURRENCE_INTERVAL_COMPLEXITY_WEIGHT::Float64 = 1.0
const OCCURRENCE_INTERVAL_MAX_BASE_SCALES::Int = 4
const OCCURRENCE_INTERVAL_HISTORY_LIMIT::Int = 64

# Predictive complexity: combine successor distributions from recent suffix
# clusters, then convert candidate likelihood into a 0..1 surprise score.
const PREDICTIVE_MAX_CONTEXT_LENGTH::Int = 32
const PREDICTIVE_HISTORY_LIMIT_PER_CONTEXT::Int = 64
const PREDICTIVE_SUPPORT_PRIOR::Float64 = 2.0
const PREDICTIVE_CONTEXT_DISTANCE_BANDWIDTH::Float64 = 0.10
const PREDICTIVE_SUCCESSOR_DISTANCE_BANDWIDTH::Float64 = 0.22
const COMPLEXITY_PREDICTION_WEIGHT::Float64 = 6.0
const COMPLEXITY_DIVERSITY_WEIGHT::Float64 = 1.0
const COMPLEXITY_SHAPE_WEIGHT::Float64 = 1.0
const COMPLEXITY_OCCURRENCE_WEIGHT::Float64 = 1.0
const COMPLEXITY_MASS_WEIGHT::Float64 = 1.0

const DISSONANCE_STM_MEMORY_SPAN::Float64 = 1.5
const DISSONANCE_STM_MEMORY_WEIGHT::Float64 = 1.0
const DISSONANCE_STM_N_PARTIALS::Int = 8
const DISSONANCE_STM_AMP_PROFILE::Float64 = 0.88
const DISSONANCE_MODEL_SETHARES1993::String = "sethares1993"
const DISSONANCE_STM_PRUNE_THRESHOLD::Float64 = 0.01
const DISSONANCE_CALIBRATION_SCALE::Float64 = 1.0
const DISSONANCE_CALIBRATION_MIN_SCALE::Float64 = 1e-6

# Sethares1993 model parameters
const SETHARES1993_A::Float64 = 3.5
const SETHARES1993_B::Float64 = 5.75
const SETHARES1993_D_MAX::Float64 = 0.24
const SETHARES1993_S1::Float64 = 0.0207
const SETHARES1993_S2::Float64 = 18.96

# Harmonic partial profiles
const HARMONIC_PROFILE_EXP::String = "exp"
const HARMONIC_PROFILE_INVERSE::String = "inverse"
const HARMONIC_PROFILE_CONSTANT::String = "constant"
const HARMONIC_PARTIAL_EXP_PROFILE_BASE::Float64 = 0.88

const INACTIVE_STRENGTH_DECAY::Float64 = 0.98

# safety caps
const MAX_NOTE_CANDIDATES::Int = 8_000
const DEFAULT_DEBUG_TOP_N::Int = 10
const DETAILED_DEBUG_TOP_N::Int = 20

# Current VOICEVOX Song singer is Zundamon (VOICEVOX_SINGER=3003).
# Its usable singing range is A3-E5.
const VOICE_NOTE_MIN::Int = 57
const VOICE_NOTE_MAX::Int = 76

# --- SuperCollider rendering defaults ---
const SC_MIX_BUS::Int = 16
const SC_INITIAL_NODE_ID::Int = 1000
const SC_BASE_VOICE_GAIN::Float64 = 0.30
# Song stems have a substantially lower source level than the procedural SC
# synths. This is applied before the master compander/limiter.
const SC_VOICEVOX_GAIN::Float64 = 8.00
const SC_VOICEVOX_BUFFER_PREROLL_SECONDS::Float64 = 0.10
const SC_MIN_AUDIBLE_VOLUME::Float64 = 0.01
const SC_SANITIZE_MIN_AUDIBLE_VOLUME::Float64 = 0.001
const SC_STEP_GAIN_MIN::Float64 = 0.20
const SC_DEFAULT_VOLUME::Float64 = 0.0
const SC_DEFAULT_BRIGHTNESS::Float64 = 0.5
const SC_DEFAULT_NOISE::Float64 = 0.2
const SC_DEFAULT_HARMONICITY::Float64 = 1.0
const SC_DEFAULT_ATTACK::Float64 = 0.05
const SC_DEFAULT_DECAY::Float64 = 0.20
const SC_DEFAULT_SUSTAIN_RELEASE::Float64 = 0.75
const SC_DEFAULT_TIE::Float64 = 0.0
const SC_TIE_PARTIAL_THRESHOLD::Float64 = 0.25
const SC_TIE_FULL_THRESHOLD::Float64 = 0.75
const SC_TIE_ACCENT_GAIN::Float64 = 0.22
const SC_TIE_ACCENT_DURATION_RATIO::Float64 = 0.20
const SC_DEFAULT_TAIL_PAD_SECONDS::Float64 = 2.0
const SC_MAX_TAIL_PAD_SECONDS::Float64 = 10.0
const SC_RENDER_TIMEOUT_MIN_SECONDS::Float64 = 30.0
const SC_RENDER_TIMEOUT_MAX_SECONDS::Float64 = 300.0
const SC_RENDER_TIMEOUT_DURATION_MULTIPLIER::Float64 = 4.0
const SC_RENDER_TIMEOUT_EXTRA_SECONDS::Float64 = 20.0
const SC_RENDER_LOG_TAIL_CHARS::Int = 12000

"""Whether VOICEVOX generation/rendering is enabled for this deployment."""
function voicevox_enabled()::Bool
  raw = lowercase(strip(get(ENV, "VOICEVOX_ENABLED", "true")))
  return raw in ("1", "true", "yes", "y", "on")
end

# --- GitHub workflow polling defaults ---
const GITHUB_WORKFLOW_RUNS_PER_PAGE::Int = 10
const GITHUB_WORKFLOW_POLL_INTERVAL_SECONDS::Float64 = 1.0
const GITHUB_WORKFLOW_DISPATCH_TOLERANCE_SECONDS::Int = 5
# GitHub caps the complete workflow_dispatch inputs payload at 65,535 chars.
# Leave room for request_id and JSON framing in addition to params_b64.
const GITHUB_WORKFLOW_PARAMS_B64_MAX_CHARS::Int = 60_000

"""base C (MIDI) for given octave index in this system"""
base_c_midi(octave::Integer)::Int = (Int(octave) + OCTAVE_TO_MIDI_C_OFFSET) * STEPS_PER_OCTAVE

abs_pitch_min()::Int = MIDI_NOTE_MIN
abs_pitch_max()::Int = MIDI_NOTE_MAX

function sanitize_bpm(bpm)::Float64
  b = float(bpm)
  return (isfinite(b) && b >= POLYPHONIC_BPM_MIN) ? b : POLYPHONIC_BPM
end

function step_duration_from_bpm(bpm)::Float64
  return SECONDS_PER_MINUTE / sanitize_bpm(bpm)
end

function abs_pitch_width()::Float64
  w = abs(abs_pitch_max() - abs_pitch_min())
  return w <= 0 ? 1.0 : float(w)
end

function note_range_width()::Float64
  w = abs(last(NOTE_RANGE) - first(NOTE_RANGE))
  return w <= 0 ? 1.0 : float(w)
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
