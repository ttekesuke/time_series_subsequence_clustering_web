# ------------------------------------------------------------
# statistics_calculator.jl
#   Minimal port of Rails StatisticsCalculator concern
# ------------------------------------------------------------

"""
Compute mean for a numeric vector.
Returns Float64.

Rails original:
  def mean(d)
    d.sum / d.length.to_d
  end
"""
mean_value(d::AbstractVector{<:Real})::Float64 = isempty(d) ? 0.0 : float(sum(d)) / float(length(d))
