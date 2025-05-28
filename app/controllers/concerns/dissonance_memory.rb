module DissonanceMemory
  require_relative '../../../lib/dissonance/dissonance'
  include Dissonance
  include DissonanceTuning
  module STMStateless
    def self.process(notes, onset, memory, memory_span: 1.5, memory_weight: 1.0, n_partials: 10)
      d_current = DissonanceMemory.calculate_dissonance(notes, n_partials).to_f

      d_memory = 0.0
      new_memory = []

      memory.each do |event|
        delta_t = onset - event[:onset]
        w = Math.exp(-delta_t / memory_span)
        next if w < 0.01

        d_past = event[:dissonance]
        merged = notes + event[:notes]
        d_merged = DissonanceMemory.calculate_dissonance(merged, n_partials).to_f

        interference = d_merged - d_current - d_past
        d_memory += w * memory_weight * interference

        new_memory << event if w > 0.01
      end

      current_event = {
        notes: notes,
        onset: onset,
        dissonance: d_current
      }

      new_memory << current_event
      return d_current + d_memory, new_memory
    end
  end

  def self.calculate_dissonance(notes, n_partials = 10)
    # 1. ピッチ（MIDI番号）の配列を周波数に変換（例: C4, E4, G4）
    freqs = DissonanceTuning.pitch_to_freq(notes)  # => [261.63, 329.63, 391.99] など

    # 2. 各周波数に対して倍音をつける（10個の部分音）
    freqs_with_partials, amps = DissonanceTuning.harmonic_tone(freqs, n_partials: n_partials)

    # 3. 不協和度を計算
    Dissonance.dissonance(freqs_with_partials, amps)
  end
end
