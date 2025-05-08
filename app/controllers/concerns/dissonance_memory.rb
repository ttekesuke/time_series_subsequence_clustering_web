module DissonanceMemory
  class STM
    include PyCall::Import

    def initialize(memory_decay_rate: 1.5, memory_weight: 1.0, n_partials: 10)
      pyimport :dissonance_bridge
      @bridge = dissonance_bridge  # Pythonモジュールを保持

      @memory_decay_rate = memory_decay_rate
      @memory_weight = memory_weight
      @n_partials = n_partials
      @memory = []
    end

    def compute(note_sequence, onset_times)
      result = []

      note_sequence.each_with_index do |notes, i|
        t_now = onset_times[i]

        d_current = @bridge.compute_dissonance(notes, @n_partials)

        d_memory = 0.0
        new_memory = []

        @memory.each do |event|
          delta_t = t_now - event[:onset]
          w = Math.exp(-delta_t / @memory_decay_rate)

          d_past = event[:dissonance]
          merged = notes + event[:notes]
          d_merged = @bridge.compute_dissonance(merged, @n_partials)

          interference = d_merged - d_current - d_past
          d_memory += w * @memory_weight * interference

          new_memory << event if w > 0.01
        end

        new_memory << {
          notes: notes,
          onset: t_now,
          dissonance: d_current
        }

        @memory = new_memory
        result << d_current + d_memory
      end

      result
    end
  end
end
