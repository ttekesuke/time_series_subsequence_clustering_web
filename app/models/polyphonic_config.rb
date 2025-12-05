module PolyphonicConfig
  OCTAVE_RANGE = (0..7).freeze
  NOTE_RANGE   = (0..11).freeze
  FLOAT_STEPS  = (0..10).map { |i| (i / 10.0).round(1) }.freeze
end
