class TimeSeriesClusterManager
  include StatisticsCalculator
  include Utility
  attr_accessor :clusters
  attr_accessor :cluster_id_counter
  attr_accessor :tasks

  def initialize(data, merge_threshold_ratio, min_window_size)
    @data = data
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size
    @cluster_id_counter = 0
    # clustersの構成
    # clusters = {
    #   cluster_id1 => {
    #     si: [start_index1,start_index2..],
    #     cc: {
    #       cluster_id2 => {
    #         si: [start_index3,start_index4..],
    #         cc: {}
    #       },
    #       cluster_id3 => {
    #         si: [start_index5,start_index6..],
    #         cc: {}
    #       }
    #     }
    #   }
    # }
    @clusters = { @cluster_id_counter => { si: [0], cc: {} } }
    @cluster_id_counter += 1
    @tasks = []
  end

  def process_data
    @data.each_with_index do |_, data_index|
      next if data_index <= @min_window_size - 1

      clustering_subsequences_incremental(data_index)
    end
  end

  private

  def clustering_subsequences_incremental(data_index)
    # 現時点までの時系列データの平均値を得る
    data_mean = mean(@data[0..data_index])
    lower_half_average = mean(@data.select { |x| x <= data_mean })
    upper_half_average = mean(@data.select { |x| x >= data_mean })
    max_distance_between_lower_and_upper = euclidean_distance(
      Array.new(data_index + 1, lower_half_average),
      Array.new(data_index + 1, upper_half_average)
    )

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
        process_existing_clusters(parent, latest_seq, valid_si, max_distance_between_lower_and_upper, latest_start, new_length, keys_to_parent)
      else
        process_new_clusters(parent, valid_si, latest_seq, max_distance_between_lower_and_upper, latest_start, new_length, keys_to_parent)
      end
    end

    process_root_clusters(data_index, max_distance_between_lower_and_upper)
  end

  def process_existing_clusters(parent, latest_seq, valid_si, max_distance, latest_start, new_length, keys_to_parent)
    min_distance, best_clusters, best_cluster_id = Float::INFINITY, [], nil
    parent[:cc].each do |cluster_id, child|
      distance = nil
      child[:si].each do |s|
        distance = euclidean_distance(@data[s, new_length], latest_seq)
      end
      if distance < min_distance
        min_distance = distance
        best_clusters = [child]
        best_cluster_id = cluster_id
      elsif distance == min_distance
        best_clusters << child
        best_cluster_id = cluster_id
      end
    end

    ratio_in_max_distance = max_distance.zero? ? 0 : min_distance / max_distance
    if ratio_in_max_distance <= @merge_threshold_ratio
      best_clusters.first[:si] << latest_start
      @tasks << [keys_to_parent.dup << best_cluster_id, new_length]
    else
      parent[:cc][@cluster_id_counter] = { si: [latest_start], cc: {} }
      @cluster_id_counter += 1
    end
  end

  def process_new_clusters(parent, valid_si, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    valid_group = []
    invalid_group = []
    valid_si.each do |s|
      distance = euclidean_distance(@data[s, new_length], latest_seq)
      ratio_in_max_distance = max_distance.zero? ? 0 : distance / max_distance

      if ratio_in_max_distance <= @merge_threshold_ratio
        valid_group << s
      else
        invalid_group << s
      end
    end

    if valid_group.any?
      parent[:cc][@cluster_id_counter] = { si: valid_group + [latest_start], cc: {} }
      @tasks << [keys_to_parent.dup << @cluster_id_counter, new_length]
      @cluster_id_counter += 1
    else
      parent[:cc][@cluster_id_counter] = { si: [latest_start], cc: {} }
      @cluster_id_counter += 1
    end

    invalid_group.each do |s|
      parent[:cc][@cluster_id_counter] = { si: [s], cc: {} }
      @cluster_id_counter += 1
    end
  end

  def process_root_clusters(data_index, max_distance)
    latest_start = data_index - 1
    latest_seq = @data[latest_start, @min_window_size]
    min_distance, best_cluster, best_cluster_id = Float::INFINITY, nil, nil

    @clusters.each do |cluster_id, cluster|
      next if cluster[:si].include?(latest_start)

      compare_seq = if cluster[:si].size == 1
                      @data[cluster[:si].first, @min_window_size]
                    else
                      average_sequences(cluster[:si].sort[0..1].map { |s| @data[s, @min_window_size] })
                    end

      distance = euclidean_distance(compare_seq, latest_seq)
      min_distance, best_cluster, best_cluster_id = distance, cluster, cluster_id if distance < min_distance
    end

    ratio_in_max_distance = max_distance.zero? ? 0 : min_distance / max_distance

    if best_cluster && ratio_in_max_distance <= @merge_threshold_ratio
      best_cluster[:si] << latest_start unless best_cluster[:si].include?(latest_start)
      @tasks << [[best_cluster_id], @min_window_size]
    else
      @clusters[@cluster_id_counter] = { si: [latest_start], cc: {} }
      @cluster_id_counter += 1
    end
  end
  def average_sequences(sequences)
    return sequences.first if sequences.size == 1
    length = sequences.first.size
    sequences.each { |s| raise "Inconsistent lengths" unless s.size == length }
    (0...length).map { |i| sequences.sum { |s| s[i] } / sequences.size.to_f }
  end

  public
  def clusters_to_timeline(clusters, min_window_size)
    # 完成した木構造のクラスタを、表示用にフラットな構造に変換する。
    stack = clusters.map { |cluster_id, cluster| [min_window_size, cluster_id, cluster] }
    result = []

    until stack.empty?
      window_size, cluster_id, current = stack.pop
      current[:si].each do |start_index|
        result << [window_size.to_s, cluster_id.to_s(26).tr("0-9a-p", "a-z"), start_index * 1000, (start_index + window_size) * 1000]
      end
      # 子クラスタがあればスタックに追加
      current[:cc].each do |child_id, child_cluster|
        stack.push([window_size + 1, child_id, child_cluster])
      end
    end
    return result
  end

  def clean_clusters(clusters)
    clusters.delete_if do |key, cluster|
      # まず子クラスタを再帰的に処理
      clean_clusters(cluster[:cc])

      # si の要素が1つしかなければ削除
      cluster[:si].size == 1
    end
  end

  def dig_clusters_by_keys(clusters, keys)
    current = clusters
    keys.each_with_index do |key, index|
      # 最後のキーの場合は:cを介さずにアクセス
      if index == keys.length - 1
        current = current[key]
      else
        current = current[key]
        current = current[:cc] if current && current.is_a?(Hash) && !current[:cc].nil?
      end
      return nil if current.nil?
    end
    current
  end
  # Utility methods (mean, euclidean_distance, dig_clusters_by_keys, etc.)
  # These can be moved here from TimeSeriesAnalyser or kept as module methods.
end
