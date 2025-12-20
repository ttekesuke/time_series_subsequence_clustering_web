# ============================================================
# lib/polyphonic_config.rb
# ============================================================
module PolyphonicConfig
  OCTAVE_RANGE    = (0..7).freeze
  NOTE_RANGE      = (0..11).freeze
  FLOAT_STEPS     = (0..10).map { |i| (i / 10.0).round(1) }.freeze
  CHORD_SIZE_RANGE = (1..8).freeze

  # safety caps
  MAX_NOTE_CANDIDATES = 8_000
end
