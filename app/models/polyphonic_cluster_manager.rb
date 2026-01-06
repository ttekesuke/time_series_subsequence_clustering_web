# frozen_string_literal: true

# ============================================================
# lib/polyphonic_cluster_manager.rb
# ============================================================

require_relative 'polyphonic_config'

class PolyphonicClusterManager < TimeSeriesClusterManager
  # value_range: 次元の値域（pitch class 0..11 / octave 0..7 / float 0..1 等）
  # max_set_size: 「同時発音数（chord_size）」の最大（count_dist 正規化に使う）
  def initialize(data, merge_threshold_ratio, min_window_size, value_range = nil, max_set_size: PolyphonicConfig::CHORD_SIZE_RANGE.max)
    super(data, merge_threshold_ratio, min_window_size, false)

    min_v = nil
    max_v = nil

    if value_range
      if value_range.is_a?(Hash)
        min_v = value_range[:min] || value_range['min']
        max_v = value_range[:max] || value_range['max']
      else
        min_v = value_range.min if value_range.respond_to?(:min)
        max_v = value_range.max if value_range.respond_to?(:max)
      end
    end

    if !min_v.nil? && !max_v.nil?
      @value_min = min_v.to_f
      @value_max = max_v.to_f
      @value_width = (@value_max - @value_min).abs
    else
      # フォールバックは 0..1 に寄せる（マジックナンバー排除）
      @value_min = 0.0
      @value_max = 1.0
      @value_width = 1.0
    end

    @value_width = 1.0 if @value_width <= 0.0

    @max_set_size = max_set_size.to_i
    @max_set_size = 1 if @max_set_size <= 0
  end

  # ------------------------------------------------------------
  # distance
  # ------------------------------------------------------------
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

  # scalar/array 両対応:
  # - scalar は [scalar] として扱う
  # - 配列はそのまま（順序は無視して距離化）
  def min_avg_distance(a, b)
    a = normalize_set(a)
    b = normalize_set(b)

    return 0.0 if a.empty? && b.empty?
    return 1.0 if a.empty? || b.empty?

    a_avg = a.map { |x| b.map { |y| (x.to_f - y.to_f).abs }.min }.sum.to_f / a.length.to_f
    b_avg = b.map { |y| a.map { |x| (y.to_f - x.to_f).abs }.min }.sum.to_f / b.length.to_f
    pitch_dist = (a_avg + b_avg) / 2.0
    pitch_norm = (pitch_dist / @value_width).clamp(0.0, 1.0)

    count_dist = (a.length - b.length).abs.to_f
    count_norm = (count_dist / @max_set_size.to_f).clamp(0.0, 1.0)

    if count_norm <= 0.0
      pitch_norm
    else
      (pitch_norm + count_norm) / 2.0
    end
  end

  # 内部複雑度計算用
  def step_distance(a, b)
    min_avg_distance(a, b)
  end

  def average_sequences(sequences)
    return sequences.first if sequences.size == 1
    len = sequences.first.size

    (0...len).map do |t|
      raw_points = sequences.map { |seq| seq[t] }.compact
      return sequences.last[t] if raw_points.empty?

      sets_at_t = raw_points.map { |p| normalize_set(p) }

      first_count = sets_at_t.first.size
      all_same_count = sets_at_t.all? { |s| s.is_a?(Array) && s.size == first_count }

      if all_same_count
        sorted_sets = sets_at_t.map(&:sort)
        avg_set = Array.new(first_count, 0.0)

        sorted_sets.each do |s|
          s.each_with_index { |val, i| avg_set[i] += val.to_f }
        end

        avg_set.map { |v| v / sets_at_t.size.to_f }
      else
        # count が揃わない場合は「最後（最新）」を代表に
        sequences.last[t]
      end
    end
  end

  # ------------------------------------------------------------
  # polyphonic は scalar mean ベースの max_distance 推定が使えないので override
  # ------------------------------------------------------------
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
      next unless parent

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
    va = normalize_vector(vec_a)
    vb = normalize_vector(vec_b)

    return 0.0 if va.empty? && vb.empty?

    len = [va.size, vb.size].min
    sum = 0.0
    len.times do |i|
      d = va[i].to_f - vb[i].to_f
      sum += d * d
    end

    # 長さ差は「値域最大幅」を基準に寄与させる
    sum += (va.size - vb.size).abs * (@value_width**2)

    sum
  end

  def calculate_vector_mean(vectors)
    vectors = Array(vectors)
    return normalize_vector(vectors.first) if vectors.size <= 1

    normalized = vectors.map { |v| normalize_vector(v) }
    max_dim = normalized.map(&:size).max.to_i
    max_dim = 1 if max_dim <= 0

    sums = Array.new(max_dim, 0.0)
    cnts = Array.new(max_dim, 0)

    normalized.each do |vec|
      vec.each_with_index do |val, i|
        next if val.nil?
        sums[i] += val.to_f
        cnts[i] += 1
      end
    end

    sums.each_with_index.map do |s, i|
      c = cnts[i]
      c > 0 ? (s / c.to_f) : 0.0
    end
  end

  def simulate_add_and_calculate(candidate, quadratic_integer_array, controller_context = nil)
    super(candidate, quadratic_integer_array, self)
  end

  private

  def normalize_set(x)
    return [] if x.nil?
    x.is_a?(Array) ? x.compact : [x]
  end

  def normalize_vector(x)
    return [] if x.nil?
    x.is_a?(Array) ? x.compact : [x]
  end
end
