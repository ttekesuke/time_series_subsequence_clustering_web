class Api::Web::TimeSeriesController < ApplicationController
  include TimeSeriesAnalyser

  def analyse
    data = analyse_params[:time_series].split(',').map{|elm|elm.to_i}
    merge_threshold_ratio = analyse_params[:merge_threshold_ratio].to_d

    min_window_size = 2
    cluster_id_counter = 0
    clusters = {
      cluster_id_counter => {
        s: [[0, min_window_size - 1]],
        c: {}
      }
    }
    tasks = []
    data.each_with_index do |elm, data_index|
      # 最小幅+1から検知開始
      if data_index > 1
        reached_to_end = data_index == data.length - 1
        clusters, tasks, cluster_id_counter = clustering_subsequences_incremental(
          data,
          merge_threshold_ratio,
          elm,
          data_index,
          min_window_size,
          clusters,
          cluster_id_counter,
          tasks,
          reached_to_end
        )
      end
    end
    timeline = clusters_to_timeline(clusters, min_window_size)
    render json: {
      clusteredSubsequences: timeline,
      timeSeries: [['index', 'allValue']] + data.map.with_index{|elm, index|[index.to_s, elm]},
    }
  end

  def generate
    complexity_transition = generate_params[:complexity_transition].split(',').map { |elm| elm.to_i }
    merge_threshold_ratio = generate_params[:merge_threshold_ratio].to_d
    candidate_min_master = generate_params[:range_min].to_i
    candidate_max_master = generate_params[:range_max].to_i
    results = [0, 0]
    min_window_size = 2
  
    # 実データのクラスタ初期化
    cluster_id_counter, clusters, tasks = initialize_clusters(min_window_size)
  
    # 実データのトレンドデータのクラスタ初期化
    trend_results = convert_to_monotonic_change(results)
    trend_cluster_id_counter, trend_clusters, trend_tasks = initialize_clusters(min_window_size)
  
    # ユーザ指定の順位のループ
    complexity_transition.each_with_index do |rank, rank_index|
      # 生成するデータの確定値の最後の要素の値が上限か下限にいると、必然的に
      # 次に候補となるデータに制約が入る。トレンドの候補も制約を入れる。
      trend_transition_pattern = 
        if results.last == candidate_min_master
          [0, 1]
        elsif results.last == candidate_max_master
          [-1, 0]
        else
          [-1, 0, 1]
        end

      # トレンドの候補からベストマッチを得るために評価値を得る
      trend_average_distances_all_window_candidates, trend_sum_similar_subsequences_quantities, trend_clusters_candidates, trend_cluster_id_counter_candidates, trend_tasks_candidates =
        find_best_candidate(trend_results, trend_transition_pattern, merge_threshold_ratio, min_window_size, trend_clusters, trend_cluster_id_counter, trend_tasks, rank_index, complexity_transition.length)
      # 距離の小さい順に並び替え
      trend_indexed_average_distances = trend_average_distances_all_window_candidates.map.with_index { |distance, index| [distance, index] }.sort_by { |candidate| candidate[0] }
      # 類似数の大きい順に並び替え
      trend_indexed_subsequences_quantities = trend_sum_similar_subsequences_quantities.map.with_index { |quantity, index| [quantity, index] }.sort_by { |candidate| -candidate[0] }
      # 指定ランクを候補数に合わせて正規化
      converted_rank = find_group_index((candidate_min_master..candidate_max_master).to_a.length, trend_transition_pattern.length, rank)

      diff_and_indexes = []
      trend_transition_pattern.each_with_index do |trend, index|
        diff = 0

        diff += calculate_rank_diff(trend_indexed_average_distances, converted_rank, index)
        diff += calculate_rank_diff(trend_indexed_subsequences_quantities, converted_rank, index)
        diff_and_indexes << [diff, index]
      end
      trend_sorted = diff_and_indexes.sort_by {|diff_and_index|diff_and_index[0]}

      # 正規化したランクを使ってベストマッチのトレンドを得る
      trend_result = trend_transition_pattern[trend_sorted[0][1]]
      trend_results << trend_result
      trend_clusters = trend_clusters_candidates[trend_result]
      trend_cluster_id_counter = trend_cluster_id_counter_candidates[trend_result]
      trend_tasks = trend_tasks_candidates[trend_result]
  
      candidate_max = candidate_max_master
      candidate_min = candidate_min_master
  
      # トレンドに応じて生成する実データに制約を入れる
      if trend_result == -1
        candidate_max = results.last - 1
      elsif trend_result == 0
        candidate_max = results.last
        candidate_min = results.last
      elsif trend_result == 1
        candidate_min = results.last + 1
      end
  
      # 実データの候補からベストマッチを得るために評価値を得る
      sum_average_distances_all_window_candidates, sum_similar_subsequences_quantities, clusters_candidates, cluster_id_counter_candidates, tasks_candidates =
        find_best_candidate(results, (candidate_min..candidate_max).to_a, merge_threshold_ratio, min_window_size, clusters, cluster_id_counter, tasks, rank_index, complexity_transition.length)
      # 距離の小さい順に並び替え  
      indexed_average_distances_between_clusters = sum_average_distances_all_window_candidates.map.with_index { |distance, index| [distance, index + candidate_min] }.sort_by { |candidate| candidate[0] }
      # 類似数の大きい順に並び替え
      indexed_subsequences_quantities = sum_similar_subsequences_quantities.map.with_index { |quantity, index| [quantity, index + candidate_min] }.sort_by { |candidate| -candidate[0] }
      # 指定ランクを候補数に合わせて正規化  
      converted_rank = find_group_index((candidate_min_master..candidate_max_master).to_a.length, candidate_max - candidate_min + 1, rank)

      diff_and_indexes = []
      (candidate_min..candidate_max).to_a.each_with_index do |candidate, index|
        diff = 0
   
        diff += calculate_rank_diff(indexed_average_distances_between_clusters, converted_rank, index + candidate_min)
        diff += calculate_rank_diff(indexed_subsequences_quantities, converted_rank, index + candidate_min)
        diff_and_indexes << [diff, index + candidate_min]
      end
      sorted = diff_and_indexes.sort_by {|diff_and_index|diff_and_index[0]}
      # 正規化したランクを使ってベストマッチの実データを得る      
      result = (candidate_min..candidate_max).to_a[sorted[0][1] - candidate_min]
      results << result
      clusters = clusters_candidates[result - candidate_min]
      cluster_id_counter = cluster_id_counter_candidates[result - candidate_min]
      tasks = tasks_candidates[result - candidate_min]
    end
  
    render json: {
      results: results,
    }
  end

  private  
    def calculate_cluster_details(results, candidate, merge_threshold_ratio, min_window_size, clusters, cluster_id_counter, tasks, rank_index, complexity_transition)
      temporary_results = results.dup
      temporary_results << candidate
      temporary_clusters = clusters.deep_dup
      temporary_cluster_id_counter = cluster_id_counter
      temporary_tasks = tasks.dup
    
      temporary_clusters, temporary_tasks, temporary_cluster_id_counter = clustering_subsequences_incremental(
        temporary_results,
        merge_threshold_ratio,
        candidate,
        temporary_results.length - 1,
        min_window_size,
        temporary_clusters,
        temporary_cluster_id_counter,
        temporary_tasks,
        rank_index == complexity_transition - 1
      )
    
      clusters_each_window_size = transform_clusters(temporary_clusters, min_window_size)
      sum_distances_in_all_window = []
      sum_similar_subsequences_quantities = 0
    
      clusters_each_window_size.each do |window_size, same_window_size_clusters|
        sum_distances = 0
    
        same_window_size_clusters.values.combination(2).each do |subsequence_indexes1, subsequence_indexes2|
          subsequences1 = subsequence_indexes1.map{|subsequence|temporary_results[subsequence[0]..subsequence[1]]}
          subsequences2 = subsequence_indexes2.map{|subsequence|temporary_results[subsequence[0]..subsequence[1]]}
          c1_average = calculate_average_time_series(subsequences1)
          c2_average = calculate_average_time_series(subsequences2)
          distance = euclidean_distance(c1_average, c2_average)
          sum_distances += distance
        end
        sum_distances_in_all_window << sum_distances

        # 類似部分列の数は、偏りがあり密集しているほど・窓幅が大きいものほど類似していると見なす。
        # また類似部分列が2個以上のものだけ対象とする
        sum_similar_subsequences_quantities += same_window_size_clusters
        .values
        .filter{|subsequence_indexes|subsequence_indexes.length > 1}
        .map {|subsequence_indexes|subsequence_indexes.length**2 * window_size}.sum
      end

      # クラスタ間の距離は平均を取る
      average_distances_in_all_window = mean(sum_distances_in_all_window)

      [average_distances_in_all_window, sum_similar_subsequences_quantities, temporary_clusters, temporary_cluster_id_counter, temporary_tasks]
    end
    
    def find_best_candidate(results, candidates, merge_threshold_ratio, min_window_size, clusters, cluster_id_counter, tasks, rank_index, complexity_transition)
      average_distances_all_window_candidates = []
      sum_similar_subsequences_quantities_all_window_candidates = []
      clusters_candidates = []
      cluster_id_counter_candidates = []
      tasks_candidates = []
    
      candidates.each do |candidate|
        average_distances, sum_similar_subsequences_quantities, temporary_clusters, temporary_cluster_id_counter, temporary_tasks = calculate_cluster_details(
          results,
          candidate,
          merge_threshold_ratio,
          min_window_size,
          clusters,
          cluster_id_counter,
          tasks,
          rank_index,
          complexity_transition
        )
    
        average_distances_all_window_candidates << average_distances
        sum_similar_subsequences_quantities_all_window_candidates << sum_similar_subsequences_quantities
        clusters_candidates << temporary_clusters
        cluster_id_counter_candidates << temporary_cluster_id_counter
        tasks_candidates << temporary_tasks
      end
    
      [average_distances_all_window_candidates, sum_similar_subsequences_quantities_all_window_candidates, clusters_candidates, cluster_id_counter_candidates, tasks_candidates]
    end

    def initialize_clusters(min_window_size)
      cluster_id_counter = 0
      clusters = {
        cluster_id_counter => {
          s: [[0, min_window_size - 1]],
          c: {}
        }
      }
      tasks = []
    
      [cluster_id_counter, clusters, tasks]
    end

    def convert_same_distance_same_index(distance_index)
      grouped = distance_index.group_by { |distance, _| distance }

      # 結果を格納する配列
      result = []
      index = 0

      # グループごとに処理
      grouped.sort.each do |distance, pairs|
        pairs.each do |_, original_index|
          result << [index, original_index]
        end
        index += pairs.length
      end

      # 期待される形式にソート
      result.sort_by! { |new_index, _| new_index }

      # 結果の表示
      result
    end
    
    # クラスタを、階層（窓幅）ごとにまとめたデータにして返却
    def transform_clusters(clusters, min_window_size)
      clusters_each_window_size = {}
      stack = clusters.map { |id, cluster| [id, cluster, min_window_size] } # 初期スタック。クラスタID、クラスタデータ、階層を要素に持つ
    
      until stack.empty?
        cluster_id, current_cluster, depth = stack.pop
        sequences = current_cluster[:s]
    
        clusters_each_window_size[depth] ||= {}
        clusters_each_window_size[depth][cluster_id] = sequences
    
        # 子クラスタがあればスタックに追加
        current_cluster[:c].each do |sub_cluster_id, sub_cluster|
          stack.push([sub_cluster_id, sub_cluster, depth + 1])
        end
      end
    
      clusters_each_window_size
    end

    def find_group_index(array_size, split_count, value)
      group_boundaries = (0..split_count).map { |i| (i * array_size.to_f / split_count).round }
 
      group_boundaries.each_cons(2).with_index do |(start_bound, end_bound), index|
        return index if value >= start_bound && value < end_bound
      end
    
      # valueが最後のグループに属する場合
      split_count - 1
    end

    def calculate_rank_diff(array, rank, id)
      # グループ化された順位を計算
      grouped_ranks = []
      current_rank = 0
      previous_value = nil
    
      array.each do |value, id|
        if previous_value != value
          current_rank += 1 if previous_value
        end
        grouped_ranks << { value: value, id: id, group: current_rank }
        previous_value = value
      end
    
      # rank=のグループを取得
      rank_value, rank_id = array[rank]
      rank_group = grouped_ranks.find { |item| item[:id] == rank_id }[:group]
    
      # 指定されたidのグループを取得
      item_group = grouped_ranks.find { |item| item[:id] == id }[:group]
    
      # diffを計算
      diff = (rank_group - item_group).abs
      diff
    end

    def analyse_params
      params.require(:analyse).permit(
        :time_series,
        :merge_threshold_ratio
      )
    end
    
    def generate_params
      params.require(:generate).permit(
        :complexity_transition,
        :range_min,
        :range_max
      )
    end

end
