class PolyphonicClusterManager < TimeSeriesClusterManager
  def initialize(data, merge_threshold_ratio, min_window_size)
    super(data, merge_threshold_ratio, min_window_size, false)
  end

  def squared_euclidean_distance(seq_a, seq_b)
    sum = 0.0
    seq_a.each_with_index do |set_a, i|
      set_b = seq_b[i]
      d = min_avg_distance(set_a, set_b)
      sum += d * d
    end
    sum
  end

  def euclidean_distance(seq_a, seq_b)
    Math.sqrt(squared_euclidean_distance(seq_a, seq_b))
  end

  def min_avg_distance(a, b)
    return 7.0 unless a.is_a?(Array) && b.is_a?(Array)
    return 0.0 if a.empty? && b.empty?
    return 7.0 if a.empty? || b.empty?

    a_avg = a.map { |x| b.map { |y| (x - y).abs }.min }.sum.to_f / a.length
    b_avg = b.map { |y| a.map { |x| (y - x).abs }.min }.sum.to_f / b.length
    pitch_dist = (a_avg + b_avg) / 2.0

    count_dist = (a.length - b.length).abs.to_f * 1.0
    pitch_dist + count_dist
  end

  def step_distance(a, b)
    min_avg_distance(a, b)
  end

  def average_sequences(sequences)
    return sequences.first if sequences.size == 1
    len = sequences.first.size
    (0...len).map do |t|
      sets_at_t = sequences.map { |seq| seq[t] }
      first_count = sets_at_t.first.size
      all_same_count = sets_at_t.all? { |s| s.size == first_count }

      if all_same_count
        sorted_sets = sets_at_t.map(&:sort)
        avg_set = Array.new(first_count, 0.0)
        sorted_sets.each do |s|
          s.each_with_index { |val, i| avg_set[i] += val }
        end
        avg_set.map { |v| v / sets_at_t.size.to_f }
      else
        sets_at_t.last
      end
    end
  end

  def clustering_subsequences_incremental(data_index)
    current_slice = @data[0..data_index]
    centroid = calculate_vector_mean(current_slice)
    max_dist_sq = 0.0
    current_slice.each do |point|
      d2 = simple_squared_euclidean(point, centroid)
      max_dist_sq = d2 if d2 > max_dist_sq
    end
    max_distance = Math.sqrt(max_dist_sq) * 2.0

    current_tasks = @tasks.dup
    @tasks.clear

    current_tasks.each do |task|
      keys_to_parent = task[0].dup
      length = task[1].dup
      parent = dig_clusters_by_keys(@clusters, keys_to_parent)
      new_length = length + 1
      latest_start = data_index - new_length + 1
      latest_seq = @data[latest_start, new_length]
      valid_si = parent[:si].select { |s| s + new_length <= data_index + 1 && s != latest_start }
      next if valid_si.empty?

      if parent[:cc].any?
        process_existing_clusters(parent, latest_seq, valid_si, max_distance, latest_start, new_length, keys_to_parent)
      else
        process_new_clusters(parent, valid_si, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
      end
    end

    process_root_clusters(data_index, max_distance)
  end

  def simple_squared_euclidean(vec_a, vec_b)
    return 0.0 if vec_a.empty? && vec_b.empty?
    len = [vec_a.size, vec_b.size].min
    sum = 0.0
    len.times do |i|
      d = vec_a[i] - vec_b[i]
      sum += d * d
    end
    sum += (vec_a.size - vec_b.size).abs * 49.0
    sum
  end

  def calculate_vector_mean(vectors)
    return vectors.first if vectors.empty?
    dim = vectors.first.size
    sum_vec = Array.new(dim, 0.0)
    vectors.each do |vec|
      vec.each_with_index { |v, i| sum_vec[i] += v if i < dim }
    end
    count = vectors.size.to_f
    sum_vec.map { |v| v / count }
  end

  def simulate_add_and_calculate(candidate, quadratic_integer_array, controller_context = nil)
    super(candidate, quadratic_integer_array, self)
  end
end
