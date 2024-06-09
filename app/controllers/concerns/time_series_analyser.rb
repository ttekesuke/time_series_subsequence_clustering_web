module TimeSeriesAnalyser
  include StatisticsCalculator
  include Utility

  def clustering_subsequences_incremental(data, merge_threshold_ratio, elm, data_index, min_window_size, clusters, cluster_id_counter, tasks, reached_to_end)
    # clustersの構成
    # clusters = {
    #   cluster_id1 => {
    #     s: [[start_index, end_index],[start_index, end_index],..],
    #     c: {
    #       cluster_id2 => {
    #         s: [[start_index, end_index],[start_index, end_index],..],
    #         c: {}
    #       },
    #       cluster_id3 => {
    #         s: [[start_index, end_index],[start_index, end_index],..],
    #         c: {}
    #       }
    #     }
    #   }
    # }

    data_mean = mean(data)
    lower_half_average = mean(data.select { |x| x <= data_mean })
    upper_half_average = mean(data.select { |x| x >= data_mean })
    max_distance_between_lower_and_upper_each_window_size = {}
    
    new_tasks = []
    # タスク(延伸された類似部分列が結合候補のクラスタ内の部分列群と似てればクラスタへ結合)があれば処理する
    tasks.each do |task|    
      # クラスタに結合予定の最新部分列（延伸済）
      current_subsequence = task[1]
      current_window_size = current_subsequence[1] - current_subsequence[0] + 1
      max_distance_between_lower_and_upper = nil
      if max_distance_between_lower_and_upper_each_window_size.key? current_window_size
        max_distance_between_lower_and_upper = max_distance_between_lower_and_upper_each_window_size[current_window_size]
      else
        max_distance_between_lower_and_upper = euclidean_distance(Array.new(current_window_size, lower_half_average), Array.new(current_window_size, upper_half_average))
        max_distance_between_lower_and_upper_each_window_size[current_window_size] = max_distance_between_lower_and_upper
      end
      
      # task[0]はclusters内部の当該クラスタにアクセスするキーが入ってる
      current_cluster = dig_clusters_by_keys(clusters, task[0])
      # {
      #   s: [[si, ei],..],
      #   c: {ci: {..}}
      # }
      has_children = !current_cluster[:c].empty?

      # 子クラスタがあれば、最新部分列の結合予定先となる
      if has_children
        will_merge_clusters = current_cluster[:c]
        will_merge_clusters = will_merge_clusters.transform_values do |cluster|
          {
            s: cluster[:s].filter{|subsequence|subsequence[0] != task[1][0]},
            c: cluster[:c]
          }
        end
      else
        # なければ、最新部分列が前回（延伸前に）結合したクラスタの部分列群を延伸して比較
        cluster_id_counter += 1
        will_merge_clusters = {
          cluster_id_counter => {
            s: current_cluster[:s].filter{|subsequence|subsequence[0] != task[1][0]}.map{|subsequence|[subsequence[0], subsequence[1] + 1]},
            c: {}
          }
        }
      end

      # 結合候補のクラスタを一つずつ処理                    
      will_merge_clusters.each do |cluster_id, cluster|
        similar_subsequences = []
        # 候補側の部分列群を取り出し、最新部分列と距離比較           
        cluster[:s].each do |past_subsequence|
          distance = euclidean_distance(
            data[past_subsequence[0]..past_subsequence[1]],
            data[current_subsequence[0]..current_subsequence[1]]
          )
          # 許容割合以下なら結合予定とする
          ratio_in_max_distance = distance / max_distance_between_lower_and_upper
          if ratio_in_max_distance <= merge_threshold_ratio
            similar_subsequences << past_subsequence
          end
        end

        # 一つでも許容値以下のペアがあれば結合処理
        if similar_subsequences.length > 0
          # 結合候補クラスタ内の全ての部分列群が、比較対象部分列との比較が許容値以下なら既存クラスタに追加
          if similar_subsequences.length == cluster[:s].length
            next_cluster_id = cluster_id
            # 部分列群に追加
            cluster[:s] << current_subsequence
            # クラスタを更新または追加
            current_cluster[:c][next_cluster_id] = cluster
          # 結合候補クラスタ内の一部の部分列群と比較対象部分列が許容値以下なら新しいクラスタを作成
          else
            # 類似していた、結合候補クラスタの類似部分列群に、最新部分列を追加
            similar_subsequences << current_subsequence
            cluster_id_counter += 1
            # 新しいクラスタを作成
            next_cluster_id = cluster_id_counter
            new_cluster = {
              s: similar_subsequences,
              c: {}
            }
            # 新しいクラスタを親クラスタに追加
            current_cluster[:c][cluster_id_counter] = new_cluster
          end
          # 次回の結合用に最新部分列を延伸する
          if !reached_to_end
            extended_current_subsequence = [current_subsequence[0], current_subsequence[1] + 1]
            new_tasks << [task[0] + [next_cluster_id], extended_current_subsequence]
          end
        end
      end
    end

    # 次回のタスクに入れ替える
    tasks = new_tasks

    # 取り出した要素とその一つ前の要素からなる、最短・最新の部分列を、
    # 同じ長さの過去のクラスタへ結合する処理開始
    current_subsequence = [data_index - 1, data_index]
    min_distance = Float::INFINITY
    closest_cluster_id = nil   
    # 最短の過去の部分列群を取り出す。clustersの直下のクラスタ群は全て同じ最短の部分列群を持つクラスタ群。
    clusters.each do |cluster_id, cluster|
      # クラスタ内の部分列群と最短・最新の部分列との距離を累積する
      distances_in_cluster = []
      cluster[:s].each do |past_subsequence|
        distances_in_cluster << euclidean_distance(
          data[past_subsequence[0]..past_subsequence[1]],
          data[current_subsequence[0]..current_subsequence[1]]
        )
      end
      # 平均を得る
      average_distances = mean(distances_in_cluster)

      # 平均が0なら部分列が完全一致しているのでそこに結合して終了
      if average_distances == 0.0
        min_distance = average_distances
        closest_cluster_id = cluster_id
        break
      end

      # 他のクラスタより最短になったら更新
      if average_distances < min_distance
        min_distance = average_distances
        closest_cluster_id = cluster_id
      end
    end

    current_window_size = current_subsequence[1] - current_subsequence[0] + 1
    max_distance_between_lower_and_upper = nil
    if max_distance_between_lower_and_upper_each_window_size.key? current_window_size
      max_distance_between_lower_and_upper = max_distance_between_lower_and_upper_each_window_size[current_window_size]
    else
      max_distance_between_lower_and_upper = euclidean_distance(Array.new(current_window_size, lower_half_average), Array.new(current_window_size, upper_half_average))
      max_distance_between_lower_and_upper_each_window_size[current_window_size] = max_distance_between_lower_and_upper
    end
    # 最短が許容値以下の場合、
    ratio_in_max_distance = min_distance / max_distance_between_lower_and_upper
    if ratio_in_max_distance <= merge_threshold_ratio
      # クラスタ結合する
      clusters[closest_cluster_id][:s] << current_subsequence
      # 元の時系列データから取り出した要素が最後の要素でなければ、
      if !reached_to_end
        # 最新・最短の部分列の結尾を延伸
        extended_current_subsequence = [current_subsequence[0], current_subsequence[1] + 1]
        # 結合したクラスタと延伸部分列をタスクに追加
        tasks << [[closest_cluster_id], extended_current_subsequence]
      end
    # 許容値以上の場合は別クラスタを作成し、タスクには追加しない
    else
      cluster_id_counter += 1
      clusters[cluster_id_counter] = {
        s: [current_subsequence],
        c: {}
      }
    end
    return clusters, tasks, cluster_id_counter
  end

  def dig_clusters_by_keys(clusters, keys)
    current = clusters
    keys.each_with_index do |key, index|
      # 最後のキーの場合は:cを介さずにアクセス
      if index == keys.length - 1
        current = current[key]
      else
        current = current[key]
        current = current[:c] if current && current.is_a?(Hash) && !current[:c].nil?
      end
      return nil if current.nil?
    end
    current
  end

  def clusters_to_timeline(clusters, min_window_size)
    # 完成した木構造のクラスタを、表示用にフラットな構造に変換する。
    stack = clusters.map { |cluster_id, cluster| [min_window_size, cluster_id, cluster] }
    result = []
  
    until stack.empty?
      window_size, cluster_id, current = stack.pop
      current[:s].each do |subsequence|
        result << [window_size.to_s, cluster_id.to_s(26).tr("0-9a-p", "a-z"), subsequence[0] * 1000, (subsequence[1] + 1) * 1000]
      end
      # 子クラスタがあればスタックに追加
      current[:c].each do |child_id, child_cluster|
        stack.push([window_size + 1, child_id, child_cluster])
      end
    end
    return result
  end

  # deprecated
  def clustering_subsequences_all_timeseries(data, merge_threshold_ratio)
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
        if gap_last_and_min > merge_threshold_ratio
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