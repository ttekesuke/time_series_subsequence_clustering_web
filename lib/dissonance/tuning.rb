module DissonanceTuning
  module_function

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

  # ★ 追加：各音の「レベル（vol）」を掛けた倍音列を生成
  #
  # base_freqs : [f1, f2, ...]
  # levels     : [l1, l2, ...]（通常 0.0〜1.0 を想定）
  #
  # 戻り値: [freqs_with_partials, amps_with_partials]
  #   どちらも flatten 済み配列で、Dissonance.dissonance にそのまま渡せる形。
  #
  def harmonic_tone_with_levels(base_freqs, levels, n_partials: 1, profile: 'exp')
    base_freqs = Array(base_freqs)
    levels     = Array(levels)

    if base_freqs.length != levels.length
      raise ArgumentError, "base_freqs.size (#{base_freqs.length}) must equal levels.size (#{levels.length})"
    end

    idx = (1..n_partials).to_a

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

    freqs_with_partials = []
    amps_with_partials  = []

    base_freqs.each_with_index do |f, i|
      level = levels[i].to_f
      # 音量はとりあえず 0 以上にクリップ（上限はとりあえず制限しない）
      level = 0.0 if level < 0.0

      partial_freqs = idx.map { |k| f * k }
      freqs_with_partials.concat(partial_freqs)

      # 各部分音の振幅に level を掛ける
      partial_amps = amp_profile.map { |a| a * level }
      amps_with_partials.concat(partial_amps)
    end

    [freqs_with_partials, amps_with_partials]
  end

  def pitch_to_freq(pitch, base_freq: 440.0, steps_per_octave: 12)
    Array(pitch).map { |p| base_freq * (2 ** (p.to_f / steps_per_octave)) }
  end

  def freq_to_pitch(freq, base_freq: 440.0, steps_per_octave: 12)
    Array(freq).map { |f| Math.log2(f / base_freq) * steps_per_octave }
  end
end
