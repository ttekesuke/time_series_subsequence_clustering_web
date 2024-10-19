module TimeSeriesAnalyser
  include StatisticsCalculator
  include Utility

  def clustering_subsequences_incremental(data, merge_threshold_ratio, elm, data_index, min_window_size, clusters, cluster_id_counter, tasks, reached_to_end, belongs_to_cluster_each_window_size)

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
      if belongs_to_cluster_each_window_size[current_window_size].nil?
        belongs_to_cluster_each_window_size[current_window_size] = {}
      end
      max_distance_between_lower_and_upper = nil
      if max_distance_between_lower_and_upper_each_window_size.key? current_window_size
        max_distance_between_lower_and_upper = max_distance_between_lower_and_upper_each_window_size[current_window_size]
      else
        max_distance_between_lower_and_upper = euclidean_distance(Array.new(current_window_size, lower_half_average), Array.new(current_window_size, upper_half_average))
        max_distance_between_lower_and_upper_each_window_size[current_window_size] = max_distance_between_lower_and_upper
      end

      # task[0]はclusters内部の当該クラスタにアクセスするキー(cluster_idの配列)が入ってる
      current_cluster = dig_clusters_by_keys(clusters, task[0])
      # {
      #   s: [[si, ei],..],
      #   c: {ci: {..}}
      # }

      # 結合候補の過去の部分列群と最新部分列（延伸済）を比較
      min_distance = Float::INFINITY
      closest_subsequences = []

      current_cluster[:s].filter{|subsequence|subsequence[0] != task[1][0]}.map{|subsequence|[subsequence[0], subsequence[1] + 1]}.each do |past_subsequence|
        # 候補側の部分列群を取り出し、最新部分列と距離比較
        distance = euclidean_distance(
          data[past_subsequence[0]..past_subsequence[1]],
          data[current_subsequence[0]..current_subsequence[1]]
        )

        if distance == min_distance
          min_distance = distance
          closest_subsequences << past_subsequence
        elsif distance < min_distance
          min_distance = distance
          closest_subsequences = [past_subsequence]
        end
      end
      # 許容割合以下なら結合予定とする
      ratio_in_max_distance = max_distance_between_lower_and_upper == 0 ? 0 : min_distance / max_distance_between_lower_and_upper
      if ratio_in_max_distance <= merge_threshold_ratio
        closest_subsequence = closest_subsequences.first
        # 一番距離が近い部分列がクラスタ所属済みならそこに追加
        if belongs_to_cluster_each_window_size[current_window_size].keys.include?(closest_subsequence[0])
          cluster_id = belongs_to_cluster_each_window_size[current_window_size][closest_subsequence[0]]
          # 一番距離が近い部分列が属するクラスターidが、taskの結合しようとしてるクラスターでなければ
          # 一番距離が近い部分列が属するクラスターを探して結合する
          if cluster_id != task[0][-1]
            closest_cluster = find_cluster(clusters, cluster_id)
            closest_cluster[:s] << current_subsequence
          else
            current_cluster[:c][cluster_id][:s] << current_subsequence
          end

          belongs_to_cluster_each_window_size[current_window_size][current_subsequence[0]] = cluster_id
          # 次回の結合用に最新部分列を延伸する
          if !reached_to_end
            extended_current_subsequence = [current_subsequence[0], current_subsequence[1] + 1]
            new_tasks << [task[0] + [cluster_id], extended_current_subsequence]
          end
        # 未所属ならその部分列と新しいクラスタ作成
        else
          cluster_id_counter += 1
          # 新しいクラスタを作成
          new_cluster = {
            s: closest_subsequences + [current_subsequence],
            c: {}
          }

          # 新しいクラスタを親クラスタに追加
          current_cluster[:c][cluster_id_counter] = new_cluster
          if belongs_to_cluster_each_window_size[current_window_size].nil?
            belongs_to_cluster_each_window_size[current_window_size] = {[current_subsequence[0]] => cluster_id_counter}
            closest_subsequences.each do |closest_subsequence|
              belongs_to_cluster_each_window_size[current_window_size] = {[closest_subsequence[0]] => cluster_id_counter}
            end
          else
            belongs_to_cluster_each_window_size[current_window_size][current_subsequence[0]] = cluster_id_counter
            closest_subsequences.each do |closest_subsequence|
              belongs_to_cluster_each_window_size[current_window_size][closest_subsequence[0]] = cluster_id_counter
            end
          end
          # 次回の結合用に最新部分列を延伸する
          if !reached_to_end
            extended_current_subsequence = [current_subsequence[0], current_subsequence[1] + 1]
            new_tasks << [task[0] + [cluster_id_counter], extended_current_subsequence]
          end
        end
      end
    end

    # 次回のタスクに入れ替える
    tasks = new_tasks

    # 取り出した要素とその一つ前の要素からなる、最短・最新の部分列を、
    # 同じ長さの過去のクラスタへ結合する処理開始
    current_subsequence = [data_index - (min_window_size - 1), data_index]
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
    if belongs_to_cluster_each_window_size[current_window_size].nil?
      belongs_to_cluster_each_window_size[current_window_size] = {}
    end
    max_distance_between_lower_and_upper = nil
    if max_distance_between_lower_and_upper_each_window_size.key? current_window_size
      max_distance_between_lower_and_upper = max_distance_between_lower_and_upper_each_window_size[current_window_size]
    else
      max_distance_between_lower_and_upper = euclidean_distance(Array.new(current_window_size, lower_half_average), Array.new(current_window_size, upper_half_average))
      max_distance_between_lower_and_upper_each_window_size[current_window_size] = max_distance_between_lower_and_upper
    end
    # 確定した要素の最大から最小までの長さが0の場合1種類しか要素が存在していないので0にして常に結合されるようにする。
    ratio_in_max_distance = max_distance_between_lower_and_upper == 0 ? 0 : min_distance / max_distance_between_lower_and_upper
    # 指定した結合閾値割合よりも少なければクラスタ結合
    if ratio_in_max_distance <= merge_threshold_ratio
      # クラスタ所属済みと設定
      belongs_to_cluster_each_window_size[current_window_size][current_subsequence[0]] = closest_cluster_id

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
      # クラスタ所属済みと設定
      cluster_id_counter += 1

      belongs_to_cluster_each_window_size[current_window_size][current_subsequence[0]] = cluster_id_counter
      # 元の時系列データから取り出した要素が最後の要素でなければ、
      clusters[cluster_id_counter] = {
        s: [current_subsequence],
        c: {}
      }

    end
    return clusters, tasks, cluster_id_counter, belongs_to_cluster_each_window_size
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

  def find_cluster(clusters, target_cluster_id)
    clusters.each do |cluster_id, value|
      return value if cluster_id == target_cluster_id
      # 再帰的にネストされたcを探索
      result = find_cluster(value[:c], target_cluster_id) if value[:c]
      return result if result
    end
    nil  # 見つからなかった場合
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
end
