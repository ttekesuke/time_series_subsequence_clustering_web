module Dissonance

"""Dissonance

Rails 旧システム (f2da) の `lib/dissonance/dissonance.rb` の移植。

特徴:
- amps がほぼ0で落ちる問題回避のため、amp < 1e-6 は除外
- (freq,amp) を freq 昇順にソート
- 全ペア組合せの pair dissonance を合計

本関数は STM roughness 計算の最小核となるため、Any を使わず型を固定。
"""

using ..DissonanceModels

const AMP_FILTER_EPS::Float64 = 1e-6

"""Compute total dissonance of a collection of partials."""
function dissonance(freqs::Vector{Float64}, amps::Vector{Float64}; model::String="sethares1993")::Float64
  n_in = length(freqs)
  if n_in < 2 || n_in != length(amps)
    return 0.0
  end

  # filter by amp threshold (Rails: >= 1e-6)
  idxs = Int[]
  sizehint!(idxs, n_in)
  @inbounds for i in 1:n_in
    if amps[i] >= AMP_FILTER_EPS
      push!(idxs, i)
    end
  end
  if length(idxs) < 2
    return 0.0
  end

  # build sorted freq/amp pairs by freq asc
  pairs = Vector{Tuple{Float64,Float64}}(undef, length(idxs))
  @inbounds for (k, i) in enumerate(idxs)
    pairs[k] = (freqs[i], amps[i])
  end
  sort!(pairs, by = x -> x[1])

  m = length(pairs)
  m < 2 && return 0.0

  total = 0.0
  @inbounds for i in 1:(m-1)
    f1 = pairs[i][1]
    a1 = pairs[i][2]
    for j in (i+1):m
      f2 = pairs[j][1]
      a2 = pairs[j][2]
      if model == "sethares1993"
        total += DissonanceModels.sethares1993_pair(f1, f2, a1, a2)
      else
        # 将来拡張用：Rails は model String/obj 両方許容だが、現段階は sethares1993 のみ
        error("Unsupported dissonance model: $(model)")
      end
    end
  end

  return total
end

end # module
