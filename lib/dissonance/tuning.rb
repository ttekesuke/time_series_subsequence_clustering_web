module DissonanceTuning
  module_function

  def harmonic_tone(base_freqs, n_partials: 1, profile: 'exp')
    base_freqs = Array(base_freqs)
    idx = (1..n_partials).to_a
    freqs = base_freqs.map { |f| idx.map { |i| f * i } }

    amp_profile = case profile
                  when 'exp'
                    idx.map { |i| 0.88 ** i }
                  when 'inverse'
                    idx.map { |i| 1.0 / i }
                  when 'constant'
                    idx.map { |_| 1.0 }
                  else
                    raise ArgumentError, "Invalid profile: #{profile}"
                  end

    amps = Array.new(base_freqs.length) { amp_profile.dup }
    return freqs.flatten, amps.flatten
  end

  def pitch_to_freq(pitch, base_freq: 440.0, steps_per_octave: 12)
    Array(pitch).map { |p| base_freq * (2 ** (p.to_f / steps_per_octave)) }
  end

  def freq_to_pitch(freq, base_freq: 440.0, steps_per_octave: 12)
    Array(freq).map { |f| Math.log2(f / base_freq) * steps_per_octave }
  end
end
