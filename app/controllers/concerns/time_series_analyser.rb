module TimeSeriesAnalyser
  include StatisticsCalculator
  def clustering_subsequences_all_timeseries(data, tolerance_diff_distance)
    min_window_size = 2
    cluster_id_counter = 0
    max_window_size = 100
    reached_to_max_window_size = false
    tree = {cluster_id_counter => {}}
    stack = [ {node: tree[cluster_id_counter], window_size: min_window_size, cluster_id: cluster_id_counter, parent_subsequences: []} ]
    clustered_subsequences = []

    while !stack.empty?
      # 最新のスタックを取り出す
      current = stack.pop
      current_window_size = current[:window_size]
      # 深さがmax_window_sizeを超えたら処理をスキップ
      if current_window_size >= max_window_size
        reached_to_max_window_size = true
        next
      end

      current_node = current[:node]
      subsequences = []

      # parent_subsequencesが空なら初回部分列群を生成
      if current[:parent_subsequences].empty?
        start_indexes = 0.step(data.length - min_window_size, 1).to_a
        subsequences = start_indexes.map{|start_index|{start_index: start_index, end_index: start_index + min_window_size - 1}}
      else
        # 複数の部分列がある場合クラスタリング対象
        if current[:parent_subsequences].length > 1
          subsequences = current[:parent_subsequences].map do |s|
            # 部分列を伸ばすと時系列データを超える場合はクラスタリング対象外
            if s[:end_index] + 1 < data.length
              { start_index: s[:start_index], end_index: s[:end_index] + 1 }
            end
          end.compact
        end
      end
      # クラスタリング対象の部分列群がなければスキップ
      next if subsequences.length < 2
  
      # クラスタリング開始
      clusters = {}
      min_distances = []
      cluster_merge_counter = 0
      tolerance_over = false
  
      # 部分列群を初期クラスタ群に変換
      subsequences.each do |subsequence|
        cluster_id_counter += 1
        clusters[cluster_id_counter] = [subsequence]
      end
  
      # クラスタ数が2以上かつ許容値内の間クラスタリング
      while clusters.length > 1 && !tolerance_over do
        min_distance = Float::INFINITY
        closest_pair = nil
  
        clusters.to_a.combination(2).each do |c1, c2|
          distances = []  
          c1[1].each do |c1_subsequence|
            c2[1].each do |c2_subsequence|
              distances << euclidean_distance(data[c1_subsequence[:start_index]..c1_subsequence[:end_index]], data[c2_subsequence[:start_index]..c2_subsequence[:end_index]])
            end
          end

          average_distances = mean(distances)
  
          if average_distances == 0.0
            min_distance = average_distances
            closest_pair = [c1, c2]
            break
          end
  
          if average_distances < min_distance
            min_distance = average_distances
            closest_pair = [c1, c2]
          end
        end
  
        min_distances << min_distance
        combination_length = closest_pair[0][1].length * closest_pair[1][1].length
        gap_last_and_min = cluster_merge_counter == 0 ? min_distances.last : min_distances.last - min_distances.min
        if gap_last_and_min > tolerance_diff_distance
          tolerance_over = true
        else
          cluster_id_counter += 1
          clusters.delete closest_pair[0][0]
          clusters.delete closest_pair[1][0]
          clusters[cluster_id_counter] = closest_pair[0][1] + closest_pair[1][1]
          cluster_merge_counter += 1
        end
      end
      new_nodes = []
      clusters.each do |cluster_id, subsequences|
        subsequences.each do |subsequence|
          clustered_subsequences << [current_window_size.to_s, cluster_id.to_s(26).tr("0-9a-p", "a-z"), subsequence[:start_index] * 1000, (subsequence[:end_index] + 1) * 1000] 
        end
        current_node[cluster_id] = {}
        new_nodes << {node: current_node[cluster_id], window_size: current_window_size + 1, cluster_id: cluster_id, parent_subsequences: subsequences}
      end
      # スタックに追加（若い数字から深くなるように順序を逆にして追加） 
      stack.concat(new_nodes.reverse)
    end

    return clustered_subsequences, reached_to_max_window_size
  end
end