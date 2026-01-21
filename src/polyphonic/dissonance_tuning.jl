module DissonanceTuning

"""DissonanceTuning

Rails 旧システム (f2da) の `lib/dissonance/tuning.rb` の部分移植。
現時点では generate_polyphonic の中心計算には必須ではありませんが、
STM/roughness 検証や将来拡張で有用なため同梱します。
"""

"""Generate harmonic partials for base frequencies.
Returns (freqs, amps) as flat vectors.
"""
function harmonic_tone(base_freqs::Vector{Float64}; n_partials::Int=1, profile::String="exp")
  n_partials < 1 && return (Float64[], Float64[])
  idx = collect(1:n_partials)

  amp_profile::Vector{Float64} = if profile == "exp"
    [0.88^i for i in idx]
  elseif profile == "inverse"
    [1.0 / i for i in idx]
  elseif profile == "constant"
    fill(1.0, n_partials)
  else
    error("Invalid profile: $(profile)")
  end

  freqs = Float64[]
  amps  = Float64[]
  sizehint!(freqs, length(base_freqs) * n_partials)
  sizehint!(amps,  length(base_freqs) * n_partials)

  @inbounds for f in base_freqs
    for (k, i) in enumerate(idx)
      push!(freqs, f * i)
      push!(amps,  amp_profile[k])
    end
  end

  return (freqs, amps)
end

"""Harmonic tone with per-note levels."""
function harmonic_tone_with_levels(base_freqs::Vector{Float64}, levels::Vector{Float64}; n_partials::Int=1, profile::String="exp")
  length(base_freqs) == length(levels) || error("base_freqs.size must equal levels.size")
  n_partials < 1 && return (Float64[], Float64[])

  idx = collect(1:n_partials)
  amp_profile::Vector{Float64} = if profile == "exp"
    [0.88^i for i in idx]
  elseif profile == "inverse"
    [1.0 / i for i in idx]
  elseif profile == "constant"
    fill(1.0, n_partials)
  else
    error("Invalid profile: $(profile)")
  end

  freqs = Float64[]
  amps  = Float64[]
  sizehint!(freqs, length(base_freqs) * n_partials)
  sizehint!(amps,  length(base_freqs) * n_partials)

  @inbounds for i in eachindex(base_freqs)
    f = base_freqs[i]
    lvl = levels[i]
    lvl = lvl < 0 ? 0.0 : lvl
    for (k, p) in enumerate(idx)
      push!(freqs, f * p)
      push!(amps, amp_profile[k] * lvl)
    end
  end

  return (freqs, amps)
end

"""Convert pitch steps to frequency."""
function pitch_to_freq(pitches::Vector{Float64}; base_freq::Float64=440.0, steps_per_octave::Int=12)
  return [base_freq * (2.0^(p / steps_per_octave)) for p in pitches]
end

"""Convert frequency to pitch steps."""
function freq_to_pitch(freqs::Vector{Float64}; base_freq::Float64=440.0, steps_per_octave::Int=12)
  return [log2(f / base_freq) * steps_per_octave for f in freqs]
end

end # module
