# Ruby translation of dissonant (c) 2018 Bohumír Zámečník - MIT License
# https://github.com/bzamecnik/dissonant/

require 'matrix'
require_relative 'models'
require_relative 'tuning'

module Dissonance
  module_function

  def dissonance(freqs, amps, model: 'sethares1993', aggregation: ->(d) { d.sum })
    freqs = freqs.flatten
    amps = amps.flatten
    nonzero_indexes = amps.each_index.select { |i| amps[i] >= 1e-6 }
    freqs = nonzero_indexes.map { |i| freqs[i] }
    amps  = nonzero_indexes.map { |i| amps[i] }

    # Sort frequencies
    freq_amp_pairs = freqs.zip(amps).sort_by { |f, _| f }
    freqs, amps = freq_amp_pairs.transpose

    n = freqs.length
    idx_pairs = (0...n).to_a.combination(2).to_a

    f1 = idx_pairs.map { |i, _| freqs[i] }
    f2 = idx_pairs.map { |_, j| freqs[j] }
    a1 = idx_pairs.map { |i, _| amps[i] }
    a2 = idx_pairs.map { |_, j| amps[j] }

    dis_vals = dissonance_pair(f1, f2, a1, a2, model)
    aggregation.call(dis_vals)
  end

  def dissonance_pair(f1, f2, a1, a2, model)
    raise 'Negative values not allowed' unless [f1, f2, a1, a2].flatten.all? { |v| v >= 0 }
    mod = model.is_a?(String) ? DissonanceModels.models[model] : model
    mod.dissonance_pair(f1, f2, a1, a2)
  end
end
