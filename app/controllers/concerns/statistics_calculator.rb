module StatisticsCalculator

  def mean(d)
    d.sum / d.length.to_d
  end

  def median(d)
    sorted = d.sort
    sorted.length.odd? ? sorted[sorted.length / 2] : (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2.0
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

  # 平均時系列データを計算する
  def calculate_average_time_series(data)
    # 要素数の取得
    length = data.first.size
    # 各時系列データが同じ要素数を持つことを確認
    unless data.all? { |series| series.size == length }
      raise 'All time series must have the same number of elements.'
    end

    # 各インデックスにおける平均を計算
    average_series = Array.new(length, 0)
    data.each do |series|
      series.each_with_index do |value, index|
        average_series[index] += value.to_f / data.size
      end
    end

    average_series
  end

  # 指定された平均・分散に最も近い整数列の組み合わせを探索します。
  #
  # 利用可能な整数は 0 から max_value までの一意な整数です。
  # n が指定されていない場合、0〜(max_value+1) のすべての要素数の部分集合を総当たりします。
  #
  # @param target_mean [Float] 目標とする平均値
  # @param target_variance [Float] 目標とする分散値（母分散）
  # @param max_value [Integer] 使用する整数の最大値（使用可能な整数は 0〜max_value）
  # @param n [Integer, nil] 組み合わせの要素数（nil の場合は全サイズを総当たり）
  # @return [Array<(Array<Array<Integer>>, Float)>] 最良スコアの組み合わせ配列と誤差スコア
  #
  # @example
  #   find_best_subsets(3, 4, 7)
  #   #=> [[[1, 2, 3, 4, 5]], 0.0]（例）
  def find_best_subsets(target_mean, target_variance, max_value, n = nil)
    numbers = (0..max_value).to_a
    best_score = Float::INFINITY
    best_subsets = []

    max_n = numbers.size
    n_values = n.nil? ? (0..max_n).to_a : [n]

    n_values.each do |current_n|
      numbers.combination(current_n).each do |subset|
        next if subset.empty?

        mean = subset.sum.to_f / subset.size
        variance = subset.map { |x| (x - mean) ** 2 }.sum.to_f / subset.size
        score = (mean - target_mean) ** 2 + (variance - target_variance) ** 2

        if score < best_score
          best_score = score
          best_subsets = [subset]
        elsif score == best_score
          best_subsets << subset
        end
      end
    end

    return best_subsets, best_score
  end

end
