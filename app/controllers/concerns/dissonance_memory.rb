# ============================================================
# lib/dissonance/dissonance_memory.rb
# ============================================================
module DissonanceMemory
  require_relative '../../../lib/dissonance/dissonance'
  include Dissonance
  include DissonanceTuning

  module STMStateless
    def self.process(notes, onset, memory,
                     memory_weight: 1.0,
                     memory_span: 3.0,
                     n_partials: 10)

      d_current = DissonanceMemory.calculate_dissonance(notes, n_partials).to_f

      d_memory   = 0.0
      new_memory = []
      nc         = memory.length

      memory.each do |event|
        delta_t = onset - event[:onset]
        next if delta_t < 0.0

        base_activation =
          2.0 - 0.5 * Math.log(delta_t + 1.0) - 0.5 * Math.log(nc + 1.0)
        next if base_activation <= 0.0

        exp_decay = Math.exp(-delta_t / memory_span.to_f)
        w = memory_weight * base_activation * exp_decay

        d_past   = event[:dissonance].to_f
        merged   = notes + event[:notes]
        d_merged = DissonanceMemory.calculate_dissonance(merged, n_partials).to_f

        interference = d_merged - d_current - d_past
        d_memory += w * interference

        new_memory << event
      end

      new_memory << { notes: notes, onset: onset, dissonance: d_current }

      [d_current + d_memory, new_memory]
    end
  end

  def self.calculate_dissonance(notes, n_partials = 10)
    freqs = DissonanceTuning.pitch_to_freq(notes)
    freqs_with_partials, amps = DissonanceTuning.harmonic_tone(freqs, n_partials: n_partials)
    Dissonance.dissonance(freqs_with_partials, amps)
  end
end
