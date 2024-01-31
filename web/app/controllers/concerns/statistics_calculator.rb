module StatisticsCalculator

  def mean(d)
    d.sum / d.length.to_d
  end

  def covariance(d1, d2)
    raise "The two data lengths are different." if d1.size != d2.size

    (d1.zip(d2).map{|_d1, _d2 |_d1 * _d2}.sum / d1.size.to_d) - (mean(d1) * mean(d2))
  end

  def variance(d)
    d.map{|e| (e - (mean(d))) ** 2}.sum / d.length.to_d
  end

  def standard_deviation(d)
    Math.sqrt(variance(d))
  end

  def correlation_coefficient(d1, d2)
    standard_deviations = standard_deviation(d1) * standard_deviation(d2)
    if standard_deviations == 0.0
      0
    else
      covariance(d1, d2) / standard_deviations.to_d
    end
  end
  
  def dtw_distance(d1, d2)
    n = d1.length
    m = d2.length
  
    matrix = Array.new(n + 1) { Array.new(m + 1) }
  
    for i in 0..n
      for j in 0..m
        matrix[i][j] = Float::INFINITY
      end
    end
    matrix[0][0] = 0
  
    for i in 1..n
      for j in 1..m
        cost = (d1[i - 1] - d2[j - 1])**2
        matrix[i][j] = cost + [matrix[i - 1][j], matrix[i][j - 1], matrix[i - 1][j - 1]].min
      end
    end
  
    return Math.sqrt(matrix[n][m])
  end

  def euclidean_distance(d1, d2)
    raise "The two data lengths are different." if d1.size != d2.size
  
    sum_of_squares = 0.0
    d1.each_index do |i|
      sum_of_squares += (d1[i] - d2[i])**2
    end
  
    return Math.sqrt(sum_of_squares)
  end

  def cosine_similarity(d1, d2)
    dot_product = d1.zip(d2).map { |_d1, _d2| _d1 * _d2 }.sum
    magnitude1 = Math.sqrt(d1.map { |_d1| _d1**2 }.sum)
    magnitude2 = Math.sqrt(d2.map { |_d1| _d1**2 }.sum)
    dot_product / (magnitude1 * magnitude2)
  end
  
  def compare_original_and_shifted_data(d)
    raise "Block not provided." unless block_given?

    result = []
    for lag in 0..d.length - 1
      result << yield(d[0...(d.length - lag)], d[lag..-1])
    end
    result
  end
  
  def autocorrelation_coefficient(d)
    compare_original_and_shifted_data(d) {|d1, d2| correlation_coefficient(d1, d2)}
  end
  
  def compare_original_and_shifted_by_euclidean_distance(d)
    compare_original_and_shifted_data(d) {|d1, d2| euclidean_distance(d1, d2)}
  end
  
  def compare_original_and_shifted_by_dtw_distance(d)
    compare_original_and_shifted_data(d) {|d1, d2| dtw_distance(d1, d2)}
  end

  def compare_original_and_shifted_by_cosine_similarity(d)
    compare_original_and_shifted_data(d) {|d1, d2| cosine_similarity(d1, d2)}
  end

end