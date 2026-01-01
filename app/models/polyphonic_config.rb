# frozen_string_literal: true

# ============================================================
# lib/polyphonic_config.rb
# ============================================================
module PolyphonicConfig
  # --- musical / midi constants ---
  STEPS_PER_OCTAVE = 12
  OCTAVE_TO_MIDI_C_OFFSET = 1 # oct=4 -> baseC=60 (C4)

  MIDI_A4 = 69
  A4_FREQ = 440.0

  AMP_EPS = 1e-6

  # --- dimension ranges ---
  OCTAVE_RANGE     = (0..7).freeze
  NOTE_RANGE       = (0..11).freeze
  FLOAT_STEPS      = (0..10).map { |i| (i / 10.0).round(1) }.freeze
  CHORD_SIZE_RANGE = (1..8).freeze

  # safety caps
  MAX_NOTE_CANDIDATES = 8_000

  module_function

  # base C (MIDI) for given octave index in this system
  def base_c_midi(octave)
    (octave.to_i + OCTAVE_TO_MIDI_C_OFFSET) * STEPS_PER_OCTAVE
  end

  def pitch_class_mod
    STEPS_PER_OCTAVE
  end

  def abs_pitch_min
    base_c_midi(OCTAVE_RANGE.min) + NOTE_RANGE.min
  end

  def abs_pitch_max
    base_c_midi(OCTAVE_RANGE.max) + NOTE_RANGE.max
  end

  def abs_pitch_width
    w = (abs_pitch_max - abs_pitch_min).abs.to_f
    w <= 0.0 ? 1.0 : w
  end

  def note_range_width
    w = (NOTE_RANGE.max - NOTE_RANGE.min).abs.to_f
    w <= 0.0 ? 1.0 : w
  end
end
