module TimeSeriesAnalyser
  include StatisticsCalculator
  include Utility

  def clustering_subsequences_incremental(data, tolerance_diff_distance)
    min_window_size = 2
    cluster_id_counter = 0
    current_window_size = min_window_size
    tasks = []
    clusters = {
      min_window_size => {
        cluster_id_counter => [{s: 0, e: min_window_size - 1}]
      }
    }

    data.each_with_index do |elm, data_index|
      # 最小幅+1から検知開始
      if data_index > 1
        new_tasks = []
        # タスクがあれば処理する
        tasks.each do |current_task|        
          # 比較対象の部分列を延伸する
          extended_target = {s: current_task[2][:s], e: current_task[2][:e] + 1}

          # 延伸比較対象の部分列群を取り出す その際、比較対象の部分列もクラスタに入っているので除外する
          current_clustered_subsequences = clusters[current_task[0]][current_task[1]].filter{|subsequence|subsequence[:s] != current_task[2][:s]}
          extended_current_clustered_subsequences = current_clustered_subsequences.map{|subsequence| {s: subsequence[:s], e: subsequence[:e] + 1}}
          similar_subsequences = []
          extended_current_clustered_subsequences.each do |old_subsequence|
            distance = euclidean_distance(
              data[old_subsequence[:s]..old_subsequence[:e]],
              data[extended_target[:s]..extended_target[:e]]
            )
            # 許容値以下なら更に延伸し比較する
            if distance <= tolerance_diff_distance
              similar_subsequences << old_subsequence
            end
          end

          if similar_subsequences.length > 0
            # 比較対象の部分列も追加する
            similar_subsequences << extended_target
            cluster_id_counter += 1
            if clusters.key?(current_task[0] + 1)
              clusters[current_task[0] + 1][cluster_id_counter] = similar_subsequences
            else
              clusters[current_task[0] + 1] = {cluster_id_counter => similar_subsequences}
            end

            # 長さ、結合したクラスタid、ターゲットの部分列を次回のタスクに追加する
            new_tasks << [current_task[0] + 1, cluster_id_counter, extended_target]
          end
        end

        # 次回のタスクに入れ替える
        tasks = new_tasks

        # 最短・最新の部分列のクラスタリング開始
        current_subsequence = {s: data_index - 1, e: data_index}
        min_distance = Float::INFINITY
        closest_cluster_id = nil   
        # 長さ2の古い部分列群を取り出す
        clusters[current_window_size].each do |cluster_id, old_subsequences|
          # クラスタ内の距離を累積する
          distances_in_cluster = []
          old_subsequences.each do |old_subsequence|
            distances_in_cluster << euclidean_distance(
              data[old_subsequence[:s]..old_subsequence[:e]],
              data[current_subsequence[:s]..current_subsequence[:e]]
            )
          end
          # 平均を得る
          average_distances = mean(distances_in_cluster)
          if average_distances == 0.0
            min_distance = average_distances
            closest_cluster_id = cluster_id
            break
          end

          if average_distances < min_distance
            min_distance = average_distances
            closest_cluster_id = cluster_id
          end
        end
        # 全て取り出して、最短が許容値以下の場合結合する
        if min_distance <= tolerance_diff_distance
          clusters[current_window_size][closest_cluster_id] << current_subsequence
          # 長さ、結合したクラスタid、ターゲットの部分列を保持する
          tasks << [current_window_size, closest_cluster_id, current_subsequence]
        # 許容値以上の場合は別クラスタに追加
        else
          cluster_id_counter += 1
          clusters[current_window_size][cluster_id_counter] = [current_subsequence]
        end
      end
    end

    clustered_subsequences = []
    clusters.each do |window_size, cluster|
      cluster.each do |cluster_id, subsequences|
        subsequences.each do |subsequence|
          clustered_subsequences << [window_size.to_s, cluster_id.to_s(26).tr("0-9a-p", "a-z"), subsequence[:s] * 1000, (subsequence[:e] + 1) * 1000] 
        end
      end
    end
    return clustered_subsequences, false
  end

  # deprecated
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