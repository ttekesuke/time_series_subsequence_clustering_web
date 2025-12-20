# ============================================================
# lib/dissonance/models.rb
# ============================================================
module DissonanceModels
  module_function

  class Sethares1993
    A = 3.5
    B = 5.75
    D_MAX = 0.24
    S1 = 0.0207
    S2 = 18.96

    def dissonance_pair(f1, f2, a1, a2)
      f1 = Array(f1)
      f2 = Array(f2)
      a1 = Array(a1)
      a2 = Array(a2)

      s   = f1.map { |f| D_MAX / (S1 * f + S2) }
      x   = s.each_with_index.map { |s_i, i| s_i * (f2[i] - f1[i]) }
      spl = a1.zip(a2).map { |a, b| a.to_f * b.to_f }
      d   = x.map { |xi| Math.exp(-A * xi) - Math.exp(-B * xi) }
      spl.zip(d).map { |s_i, d_i| s_i * d_i }
    end
  end

  def models
    { 'sethares1993' => Sethares1993.new }
  end
end
