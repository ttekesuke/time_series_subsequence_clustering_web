class Api::Web::TimeSeriesController < ApplicationController
  include TimeSeriesAnalyser

  def analyse
    data = analyse_params[:time_series].split(',').map{|elm|elm.to_i}
    merge_threshold_ratio = analyse_params[:merge_threshold_ratio].to_d

    min_window_size = 2
    cluster_id_counter = 0
    clusters = {cluster_id_counter => { si: [0], cc: {} }}
    cluster_id_counter += 1
    tasks = []
    data.each_with_index do |elm, data_index|
      # 最小幅+1から検知開始
      if data_index > min_window_size - 1
        clusters, tasks, cluster_id_counter = clustering_subsequences_incremental(
          data,
          merge_threshold_ratio,
          data_index,
          min_window_size,
          clusters,
          cluster_id_counter,
          tasks,
        )
      end
    end
    if analyse_params[:show_single_cluster] == false
      clusters = clean_clusters(clusters)
    end
    timeline = clusters_to_timeline(clusters, min_window_size)
    render json: {
      clusteredSubsequences: timeline,
      timeSeriesChart: [] + data.map.with_index{|elm, index|[index.to_s, elm, nil, nil]},
    }
  end

  def generate
    user_set_results = generate_params[:first_elements].split(',').map { |elm| elm.to_i }
    complexity_transition = generate_params[:complexity_transition].split(',').map { |elm| elm.to_i }
    merge_threshold_ratio = generate_params[:merge_threshold_ratio].to_d
    candidate_min_master = generate_params[:range_min].to_i
    candidate_max_master = generate_params[:range_max].to_i
    trend_candidate_min_master = -1
    trend_candidate_max_master = 1
    min_window_size = 2
    # ユーザ指定の冒頭の時系列データを解析しクラスタを作成する
    # ユーザ指定の冒頭の時系列データをトレンドにする
    trend_user_set_results = convert_to_monotonic_change(user_set_results)
    # 実データのトレンドデータのクラスタ初期化
    trend_cluster_id_counter, trend_clusters, trend_tasks = initialize_clusters(min_window_size)

    trend_user_set_results.each_with_index do |elm, data_index|
      # 最小幅+1から検知開始
      if data_index > min_window_size - 1
        trend_clusters, trend_tasks, trend_cluster_id_counter = clustering_subsequences_incremental(
          trend_user_set_results,
          merge_threshold_ratio,
          data_index,
          min_window_size,
          trend_clusters,
          trend_cluster_id_counter,
          trend_tasks,
        )
      end
    end

    # 移行
    trend_results = trend_user_set_results.dup
    # 解析
    cluster_id_counter, clusters, tasks = initialize_clusters(min_window_size)
    user_set_results.each_with_index do |elm, data_index|
      # 最小幅+1から検知開始
      if data_index > min_window_size - 1
        clusters, tasks, cluster_id_counter = clustering_subsequences_incremental(
          user_set_results,
          merge_threshold_ratio,
          data_index,
          min_window_size,
          clusters,
          cluster_id_counter,
          tasks,
        )
      end
    end

    # 移行
    results = user_set_results.dup

    # ユーザ指定の順位のループ
    complexity_transition.each_with_index do |rank, rank_index|
      # 生成するデータの確定値の最後の要素の値が上限か下限にいると、必然的に
      # 次に候補となるデータに制約が入る。トレンドの候補も制約を入れる。
      trend_candidate_min = trend_candidate_min_master
      trend_candidate_max = trend_candidate_max_master
      if results.last == candidate_min_master
        trend_candidate_min = 0
      elsif results.last == candidate_max_master
        trend_candidate_max = 0
      end

      trend_candidates = (trend_candidate_min..trend_candidate_max).to_a

      # トレンドの候補からベストマッチを得るために評価値を得る
      trend_average_distances_all_window_candidates, trend_sum_similar_subsequences_quantities, trend_clusters_candidates, trend_cluster_id_counter_candidates, trend_tasks_candidates =
        find_best_candidate(
          trend_results,
          trend_candidates,
          merge_threshold_ratio,
          min_window_size,
          trend_clusters,
          trend_cluster_id_counter,
          trend_tasks,
          rank_index,
        )
      # 距離にindex付与
      trend_indexed_average_distances = trend_average_distances_all_window_candidates.map.with_index { |distance, index| [distance, index] }
      # 類似数にindex付与
      trend_indexed_subsequences_quantities = trend_sum_similar_subsequences_quantities.map.with_index { |quantity, index| [quantity, index] }
      # 指定ランクを割合に変換
      converted_rank = rank / (candidate_min_master..candidate_max_master).to_a.length.to_d

      metrics_with_direction = [
        { is_complex_when_larger: true, data: normalize(trend_indexed_average_distances)},
        { is_complex_when_larger: false, data: normalize(trend_indexed_subsequences_quantities) }
      ]
      diff_and_indexes = calculate_total_differences(metrics_with_direction, converted_rank)
      trend_sorted = diff_and_indexes.sort_by {|diff_and_index|diff_and_index[:difference_value]}

      # 正規化したランクを使ってベストマッチのトレンドを得る
      # todo:trend_sortedの先頭の同率トップが複数あれば選ぶ方法が必要
      result_index_in_trend_candidates = trend_sorted[0][:index]
      trend_result = trend_candidates[result_index_in_trend_candidates]
      trend_results << trend_result
      trend_clusters = trend_clusters_candidates[result_index_in_trend_candidates]
      trend_cluster_id_counter = trend_cluster_id_counter_candidates[result_index_in_trend_candidates]
      trend_tasks = trend_tasks_candidates[result_index_in_trend_candidates]

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
      candidates = (candidate_min..candidate_max).to_a

      # 実データの候補からベストマッチを得るために評価値を得る
      sum_average_distances_all_window_candidates, sum_similar_subsequences_quantities, clusters_candidates, cluster_id_counter_candidates, tasks_candidates =
        find_best_candidate(
          results,
          candidates,
          merge_threshold_ratio,
          min_window_size,
          clusters,
          cluster_id_counter,
          tasks,
          rank_index,
        )
      # 距離の小さい順に並び替え
      indexed_average_distances_between_clusters = sum_average_distances_all_window_candidates.map.with_index { |distance, index| [distance, index] }
      # 類似数の大きい順に並び替え
      indexed_subsequences_quantities = sum_similar_subsequences_quantities.map.with_index { |quantity, index| [quantity, index] }
      # 指定ランクを割合に変換
      converted_rank = rank / (candidate_min_master..candidate_max_master).to_a.length.to_d

      metrics_with_direction = [
        { is_complex_when_larger: true, data: normalize(indexed_average_distances_between_clusters)},
        { is_complex_when_larger: false, data: normalize(indexed_subsequences_quantities) }
      ]

      diff_and_indexes = calculate_total_differences(metrics_with_direction, converted_rank)
      sorted = diff_and_indexes.sort_by {|diff_and_index|diff_and_index[:difference_value]}
      # 正規化したランクを使ってベストマッチの実データを得る
      result_index_in_candidates = sorted[0][:index]
      result = candidates[result_index_in_candidates]
      results << result
      clusters = clusters_candidates[result_index_in_candidates]
      cluster_id_counter = cluster_id_counter_candidates[result_index_in_candidates]
      tasks = tasks_candidates[result_index_in_candidates]
    end

    chart_elements_for_complexity = Array.new(user_set_results.length) { |index| [index.to_s, nil, nil, nil] }

    timeline = clusters_to_timeline(clusters, min_window_size)
    render json: {
      clusteredSubsequences: timeline,
      timeSeriesChart: [] + results.map.with_index{|elm, index|[index.to_s, elm, nil, nil]},
      timeSeries: results,
      timeSeriesComplexityChart: [] + chart_elements_for_complexity + complexity_transition.map.with_index{|elm, index|[(user_set_results.length + index).to_s, elm, nil, nil]},
    }
  end

  private
    def calculate_cluster_details(results, candidate, merge_threshold_ratio, min_window_size, clusters, cluster_id_counter, tasks, rank_index)
      temporary_results = results.dup
      temporary_results << candidate
      temporary_clusters = clusters.deep_dup
      temporary_cluster_id_counter = cluster_id_counter
      temporary_tasks = tasks.dup

      temporary_clusters, temporary_tasks, temporary_cluster_id_counter = clustering_subsequences_incremental(
        temporary_results,
        merge_threshold_ratio,
        temporary_results.length - 1,
        min_window_size,
        temporary_clusters,
        temporary_cluster_id_counter,
        temporary_tasks,
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
        # 長い部分列同士の距離は少なく見積もる
        sum_distances_in_all_window << sum_distances / window_size

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

    # 正規化関数：配列の最小・最大を基に0〜1にスケール
    def normalize(results)
      values = results.map { |value, index| BigDecimal(value.to_s) }  # BigDecimalに変換
      min_value = values.min
      max_value = values.max
      range = max_value - min_value

      if range == 0
        # すべての値が同じ場合、全ての値を0にする
        results.map { [BigDecimal("0"), _2] }  # 候補のindexは維持しつつ、すべて0に
      else
        # 通常の正規化
        results.map do |value, index|
          normalized_value = (BigDecimal(value.to_s) - min_value) / range  # 0から1に正規化
          [normalized_value, index]
        end
      end
    end

    def find_best_candidate(results, candidates, merge_threshold_ratio, min_window_size, clusters, cluster_id_counter, tasks, rank_index)
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
      clusters = {cluster_id_counter => { si: [0], cc: {} }}
      cluster_id_counter += 1
      tasks = []

      [cluster_id_counter, clusters, tasks]
    end

    # クラスタを、階層（窓幅）ごとにまとめたデータにして返却
    def transform_clusters(clusters, min_window_size)
      clusters_each_window_size = {}
      stack = clusters.map { |id, cluster| [id, cluster, min_window_size] } # 初期スタック。クラスタID、クラスタデータ、階層を要素に持つ

      until stack.empty?
        cluster_id, current_cluster, depth = stack.pop
        sequences = current_cluster[:si].map{|start_index|[start_index, start_index + depth - 1]}

        clusters_each_window_size[depth] ||= {}
        clusters_each_window_size[depth][cluster_id] = sequences

        # 子クラスタがあればスタックに追加
        current_cluster[:cc].each do |sub_cluster_id, sub_cluster|
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

    # 差分の合計を求める関数
    # metrics: 指標の正規化結果をまとめた配列 ([[normalized_distances], [normalized_quantities], ...])
    def calculate_total_differences(metrics_with_direction, target)
      num_candidates = metrics_with_direction.first[:data].size
      differences = Array.new(num_candidates, 0.0)
      differences.each_with_index do |difference, index|
        original_index = metrics_with_direction.first[:data][index][1]
        differences[index] = {difference_value: 0, index: original_index}
      end

      metrics_with_direction.each do |metric|
        is_complex_when_larger = metric[:is_complex_when_larger]
        data = metric[:data]

        data.each do |normalized_value, index|
          normalized_value = normalized_value.to_d
          adjusted_value = is_complex_when_larger ? normalized_value : (1 - normalized_value)
          difference = differences.find{|difference|difference[:index] == index}
          difference[:difference_value] += (adjusted_value - target).abs
        end
      end

      differences
    end


    def analyse_params
      params.require(:analyse).permit(
        :time_series,
        :merge_threshold_ratio,
        :show_single_cluster
      )
    end

    def generate_params
      params.require(:generate).permit(
        :complexity_transition,
        :range_min,
        :range_max,
        :first_elements,
        :merge_threshold_ratio,
      )
    end

end
