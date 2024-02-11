module Utility
  require 'bigdecimal'
  require 'bigdecimal/util'
  ROUNDING_DIGIT = 3  
  
  def max_peak_indexes(d)
    old = d[0]
    result = [0]
    up = nil
    d[1..-1].each_with_index do |elm, index|
      result << index if up and old >= elm
      up = old <= elm
      old = elm
    end
    result
  end
    
  def min_peak_indexes(d)
    old = d[0]
    result = [0]
    up = nil
    d[1..-1].each_with_index do |elm, index|
      result << index if up and old <= elm
      up = old >= elm
      old = elm
    end
    result
  end

  def difference_sequence(d)
    result = []
    old = d[0]

    d[1..-1].each_with_index do |elm|
      result << elm - old
      old = elm
    end
    result
  end

  def round_array(d)
    d.map{|e|e.round(ROUNDING_DIGIT).to_f}
  end
end