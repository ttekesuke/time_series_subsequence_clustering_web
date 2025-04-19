module TimeSeriesAnalyser
  include StatisticsCalculator
  include Utility

  def clustering_subsequences_incremental(data, merge_threshold_ratio, data_index, min_window_size, clusters, cluster_id_counter, tasks)

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

    # 現時点までの時系列データの平均値を得る
    data_mean = mean(data[0..data_index])
    # 得た平均値以下の要素群の平均値を得る
    lower_half_average = mean(data.select { |x| x <= data_mean })
    # 得た平均値以上の要素群の平均値を得る
    upper_half_average = mean(data.select { |x| x >= data_mean })
    max_distance_between_lower_and_upper = euclidean_distance(Array.new(data_index + 1, lower_half_average), Array.new(data_index + 1, upper_half_average))
    current_tasks = tasks.dup
    tasks.clear

    current_tasks.each do |task|
      p 'in current_tasks'
      p "task:#{task}"
      keys_to_parent = task[0].dup
      length = task[1].dup
      parent = dig_clusters_by_keys(clusters, keys_to_parent)
      new_length = length + 1
      latest_start = data_index - new_length + 1
      latest_seq = data[latest_start, new_length]
      p parent[:si]
      p new_length
      p data_index
      p latest_start
      valid_si = parent[:si].select { |s| s + new_length <= data_index + 1 && s != latest_start }
      next if valid_si.empty?

      if parent[:cc].any?
        p 'aruyo'
        new_clusters = {}
        min_distance, best_clusters, best_cluster_id = Float::INFINITY, [], nil
        parent[:cc].each do |cluster_id, child|
          distance = nil
          child[:si].each do |s|
            distance = euclidean_distance(data[s, new_length], latest_seq)
          end
          if distance < min_distance
            min_distance = distance
            best_clusters = [child]
            best_cluster_id = cluster_id
          elsif distance == min_distance
            min_distance = distance
            best_clusters << child
            best_cluster_id = cluster_id
          end
        end
        # 許容割合以下なら結合予定とする
        ratio_in_max_distance = max_distance_between_lower_and_upper == 0 ? 0 : min_distance / max_distance_between_lower_and_upper
        if ratio_in_max_distance <= merge_threshold_ratio
            # todo:
            best_clusters.first[:si] << latest_start
            tasks << [keys_to_parent << best_cluster_id, new_length]
        else
            parent[:cc][cluster_id_counter] = { si: [latest_start], cc: {} }
        end
      else
        p 'kotti'
        p valid_si
        valid_group  = []
        invalid_group = []
        valid_si.each do |s|
          distance = euclidean_distance(data[s, new_length], latest_seq)
          # 許容割合以下なら結合予定とする
          ratio_in_max_distance = max_distance_between_lower_and_upper == 0 ? 0 : distance / max_distance_between_lower_and_upper

          if ratio_in_max_distance <= merge_threshold_ratio
            valid_group << s
          else
            invalid_group << s
          end
        end

        if valid_group.any?
          p 'sotti'
          parent[:cc][cluster_id_counter] = { si: valid_group + [latest_start], cc: {} }
          tasks << [keys_to_parent << cluster_id_counter, new_length]
          cluster_id_counter += 1
        else
          parent[:cc][cluster_id_counter] = { si: [latest_start], cc: {} }
          cluster_id_counter += 1
        end

         p invalid_group
        invalid_group.each do |s|
          parent[:cc][cluster_id_counter] = { si: [s], cc: {} }
          cluster_id_counter += 1

        end
      end
    end

    latest_start = data_index - 1
    latest_seq = data[latest_start, min_window_size]
    min_distance, best_cluster, best_cluster_id = Float::INFINITY, nil, nil

    clusters.each do |cluster_id, cluster|
      next if cluster[:si].include?(latest_start)
      compare_seq = cluster[:si].size == 1 ? data[cluster[:si].first, min_window_size] : average_sequences(cluster[:si].sort[0..1].map { |s| data[s, min_window_size] })
      distance = euclidean_distance(compare_seq, latest_seq)
      min_distance, best_cluster, best_cluster_id = distance, cluster, cluster_id if distance < min_distance
    end
    ratio_in_max_distance = max_distance_between_lower_and_upper == 0 ? 0 : min_distance / max_distance_between_lower_and_upper

    if ratio_in_max_distance <= merge_threshold_ratio
      p "latest_start:#{latest_start}"
      best_cluster[:si] << latest_start unless best_cluster[:si].include?(latest_start)
      p "best_cluster:#{best_cluster}"
      p "best_cluster_id:#{best_cluster_id}"
      tasks << [[best_cluster_id], min_window_size]
    else
      clusters[cluster_id_counter] = { si: [latest_start], cc: {} }
      # tasks << [[cluster_id_counter], min_window_size]
      cluster_id_counter += 1
    end

    return clusters, tasks, cluster_id_counter
  end

  def average_sequences(sequences)
    return sequences.first if sequences.size == 1
    length = sequences.first.size
    sequences.each { |s| raise "Inconsistent lengths" unless s.size == length }
    (0...length).map { |i| sequences.sum { |s| s[i] } / sequences.size.to_f }
  end

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
end
