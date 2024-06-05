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

  def generate_random_array(size, lower_bound, upper_bound)
    Array.new(size) { rand(lower_bound..upper_bound) }
  end

  def generate_linear_array(start_val, end_val, num_elements)
    # 配列を生成するためのステップ数を計算します。このステップ数により、開始値から終了値までどのように増加させるかを決定します。
    step = (end_val - start_val).to_f / (num_elements / 2 - 1)
    # 指定された要素数に応じて数値を線形に増加させていく配列を生成します。
    Array.new(num_elements) { |i| (start_val + (i / 2 * step)).round }
  end
  
end