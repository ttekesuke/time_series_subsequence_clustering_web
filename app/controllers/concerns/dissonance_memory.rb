module DissonanceMemory
  module Loader
    def self.load_once!
      return if defined?(@@loaded) && @@loaded

      require 'pycall/import'
      PyCall.sys.path.append('lib/python')
      @@loaded = true
    rescue => e
      Rails.logger.error "[PyCall Loader] Failed: #{e.class} - #{e.message}"
      raise e
    end
  end
  module STMStateless
    ::DissonanceMemory::Loader.load_once!
    extend PyCall::Import
    pyimport :dissonance_bridge

    def self.process(notes, onset, memory, memory_span: 1.5, memory_weight: 1.0, n_partials: 10)
      d_current = dissonance_bridge.compute_dissonance(notes, n_partials).to_f

      d_memory = 0.0
      new_memory = []

      memory.each do |event|
        delta_t = onset - event[:onset]
        w = Math.exp(-delta_t / memory_span)
        next if w < 0.01

        d_past = event[:dissonance]
        merged = notes + event[:notes]
        d_merged = dissonance_bridge.compute_dissonance(merged, n_partials).to_f

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
end
