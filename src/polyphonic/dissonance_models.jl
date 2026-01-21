module DissonanceModels

"""DissonanceModels

Rails 旧システム (f2da) の `lib/dissonance/models.rb` の移植。
現時点では `sethares1993` のみ提供。

参照:
- William Sethares (1993): roughness/dissonance curve
"""

# Sethares1993 parameters (Rails と一致)
const A::Float64 = 3.5
const B::Float64 = 5.75
const D_MAX::Float64 = 0.24
const S1::Float64 = 0.0207
const S2::Float64 = 18.96

"""Compute dissonance contribution for a single frequency pair.

Inputs must satisfy:
- f1 <= f2
- f1,f2,a1,a2 >= 0

Returns one scalar contribution.
"""
@inline function sethares1993_pair(f1::Float64, f2::Float64, a1::Float64, a2::Float64)::Float64
  # Ruby: s = D_MAX / (S1*f1 + S2)
  s = D_MAX / (S1 * f1 + S2)
  x = s * (f2 - f1)
  spl = a1 * a2
  d = exp(-A * x) - exp(-B * x)
  return spl * d
end

end # module
