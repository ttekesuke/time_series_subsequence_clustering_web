# frozen_string_literal: true

# ============================================================
# app/models/dissonance_stm_manager.rb
# ============================================================

require_relative 'polyphonic_config'
require_relative '../../lib/dissonance/dissonance'

class DissonanceStmManager
  def initialize(
    memory_span: 1.5,
    memory_weight: 1.0,
    n_partials: 8,
    amp_profile: 0.88,
    model: 'sethares1993',
    prune_threshold: 0.01
  )
    @memory_span = memory_span.to_f
    @memory_weight = memory_weight.to_f
    @n_partials = n_partials.to_i
    @amp_profile = amp_profile.to_f
    @model = model
    @prune_threshold = prune_threshold.to_f

    @memory = []
  end

  attr_reader :memory

  def evaluate(midi_notes, amps, onset)
    d_current = dissonance_current(midi_notes, amps)
    d_current + memory_interference(midi_notes, amps, onset, d_current)
  end

  def commit!(midi_notes, amps, onset)
    d_current = dissonance_current(midi_notes, amps)
    d_total = d_current + memory_interference(midi_notes, amps, onset, d_current)

    prune!(onset)

    @memory << {
      onset: onset.to_f,
      midi_notes: midi_notes.dup,
      amps: amps.dup,
      dissonance_current: d_current
    }

    d_total
  end

  def order_pitch_classes_by_contribution(pitch_classes, octaves:, vols:, onset:)
    pitch_classes
      .map do |pc|
        midi_notes, amps = build_chord_midi_and_amps_for_all_streams(
          octaves: octaves,
          vols: vols,
          pitch_classes_per_stream: Array.new(octaves.length, pc),
          chord_sizes: Array.new(octaves.length, 1)
        )
        [pc, evaluate(midi_notes, amps, onset).to_f]
      end
      .sort_by { |(_pc, d)| -d }
      .map(&:first)
  end

  def roughness_for_pitchclass_combo(combo, chord_sizes:, octaves:, vols:, onset:)
    ordered = order_pitch_classes_by_contribution(combo, octaves: octaves, vols: vols, onset: onset)

    chords_pcs = chord_sizes.each_with_index.map do |cs, s|
      cs = cs.to_i
      cs = 1 if cs < 1
      cs = ordered.length if cs > ordered.length
      ordered.first(cs)
    end

    midi_notes, amps = build_chord_midi_and_amps_for_all_streams(
      octaves: octaves,
      vols: vols,
      pitch_classes_per_stream: nil,
      chord_sizes: chord_sizes,
      chords_pcs: chords_pcs
    )

    [evaluate(midi_notes, amps, onset).to_f, chords_pcs]
  end

  private

  def dissonance_current(midi_notes, amps)
    midi_notes = Array(midi_notes)
    amps = Array(amps)
    return 0.0 if midi_notes.length < 2
    return 0.0 if midi_notes.length != amps.length

    freqs = []
    a = []

    midi_notes.each_with_index do |m, idx|
      amp = amps[idx].to_f
      next if amp <= PolyphonicConfig::AMP_EPS

      f0 = midi_to_freq(m)
      1.upto(@n_partials) do |p|
        freqs << (f0 * p)
        a     << (amp * (@amp_profile**p))
      end
    end

    return 0.0 if freqs.length < 2
    Dissonance.dissonance(freqs, a, model: @model).to_f
  end

  def memory_interference(midi_notes, amps, onset, d_current)
    return 0.0 if @memory.empty?

    total = 0.0
    onset = onset.to_f

    @memory.each do |evt|
      dt = onset - evt[:onset].to_f
      next if dt < 0

      w = Math.exp(-dt / @memory_span)
      next if w < @prune_threshold

      d_past = evt[:dissonance_current].to_f

      merged_notes = midi_notes + evt[:midi_notes]
      merged_amps  = amps + evt[:amps]
      d_merged = dissonance_current(merged_notes, merged_amps)

      interference = d_merged - d_current - d_past
      total += w * @memory_weight * interference
    end

    total
  end

  def prune!(onset)
    onset = onset.to_f
    @memory.select! do |evt|
      dt = onset - evt[:onset].to_f
      next false if dt < 0
      Math.exp(-dt / @memory_span) >= @prune_threshold
    end
  end

  def midi_to_freq(midi)
    PolyphonicConfig::A4_FREQ * (2.0 ** ((midi.to_f - PolyphonicConfig::MIDI_A4) / PolyphonicConfig::STEPS_PER_OCTAVE.to_f))
  end

  def build_chord_midi_and_amps_for_all_streams(octaves:, vols:, pitch_classes_per_stream:, chord_sizes:, chords_pcs: nil)
    midi_notes = []
    amps = []

    octaves.each_with_index do |oct, s|
      cs = chord_sizes[s].to_i
      cs = 1 if cs < 1

      pcs =
        if chords_pcs
          chords_pcs[s]
        else
          pc = pitch_classes_per_stream[s]
          Array.new(cs, pc)
        end

      v = vols[s].to_f
      a_each = v / pcs.length.to_f

      base_c_midi = PolyphonicConfig.base_c_midi(oct)

      pcs.each do |pc|
        midi_notes << (base_c_midi + (pc.to_i % PolyphonicConfig.pitch_class_mod))
        amps      << a_each
      end
    end

    [midi_notes, amps]
  end
end
