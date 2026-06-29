module DissonanceModels

using ..Config

"""DissonanceModels

Rails 旧システム (f2da) の `lib/dissonance/models.rb` の移植。
現時点では `sethares1993` のみ提供。

参照:
- William Sethares (1993): roughness/dissonance curve
"""

"""Compute dissonance contribution for a single frequency pair.

Inputs must satisfy:
- f1 <= f2
- f1,f2,a1,a2 >= 0

Returns one scalar contribution.
"""
@inline function sethares1993_pair(f1::Float64, f2::Float64, a1::Float64, a2::Float64)::Float64
  # Ruby: s = Config.SETHARES1993_D_MAX / (Config.SETHARES1993_S1*f1 + Config.SETHARES1993_S2)
  s = Config.SETHARES1993_D_MAX / (Config.SETHARES1993_S1 * f1 + Config.SETHARES1993_S2)
  x = s * (f2 - f1)
  spl = a1 * a2
  d = exp(-Config.SETHARES1993_A * x) - exp(-Config.SETHARES1993_B * x)
  return spl * d
end

end # module
