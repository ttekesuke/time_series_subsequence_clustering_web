class Api::Web::TimeSeriesController < ApplicationController
  include TimeSeriesAnalyser
  include MusicAnalyser

  def analyse
    job_id = analyse_params[:job_id]
    broadcast_start(job_id)
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
      broadcast_progress(job_id, data_index + 1, data.length)
    end
    timeline = clusters_to_timeline(clusters, min_window_size)

    broadcast_done(job_id)
    render json: {
      clusteredSubsequences: timeline,
      timeSeriesChart: [] + data.map.with_index{|elm, index|[index.to_s, elm, nil, nil]},
    }
  end

  def generate
    job_id = generate_params[:job_id]
    broadcast_start(job_id)
    user_set_results = generate_params[:first_elements].split(',').map { |elm| elm.to_i }
    complexity_transition = generate_params[:complexity_transition].split(',').map { |elm| elm.to_i }
    merge_threshold_ratio = generate_params[:merge_threshold_ratio].to_d
    candidate_min_master = generate_params[:range_min].to_i
    candidate_max_master = generate_params[:range_max].to_i
    min_window_size = 2
    # ユーザ指定の冒頭の時系列データを解析しクラスタを作成する
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
      candidate_max = candidate_max_master
      candidate_min = candidate_min_master

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
        { is_complex_when_larger: true, data: indexed_average_distances_between_clusters},
        { is_complex_when_larger: false, data: indexed_subsequences_quantities }
      ]

      # 正規化したランクを使ってベストマッチの実データを得る
      result_index_in_candidates = find_complex_candidate(metrics_with_direction, converted_rank)
      result = candidates[result_index_in_candidates]
      results << result
      clusters = clusters_candidates[result_index_in_candidates]
      cluster_id_counter = cluster_id_counter_candidates[result_index_in_candidates]
      tasks = tasks_candidates[result_index_in_candidates]
      broadcast_progress(job_id, rank_index + 1, complexity_transition.length)

    end

    chart_elements_for_complexity = Array.new(user_set_results.length) { |index| [index.to_s, nil, nil, nil] }

    timeline = clusters_to_timeline(clusters, min_window_size)

    broadcast_done(job_id)

    render json: {
      clusteredSubsequences: timeline,
      timeSeriesChart: [] + results.map.with_index{|elm, index|[index.to_s, elm, nil, nil,]},
      timeSeries: results,
      timeSeriesComplexityChart: [] + chart_elements_for_complexity + complexity_transition.map.with_index{|elm, index|[(user_set_results.length + index).to_s, elm, nil, nil]},
    }
  end

  private
    def calculate_cluster_details(results, candidate, merge_threshold_ratio, min_window_size, clusters, cluster_id_counter, tasks, rank_index)
      temporary_results = results.dup
      temporary_results << candidate
      temporary_clusters = Marshal.load(Marshal.dump(clusters))

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

    def find_complex_candidate(criteria, converted_rank)
      candidates = Hash.new { |h, k| h[k] = 0 } # 候補インデックスごとのスコア

      criteria.each do |criterion|
        is_complex_when_larger = criterion[:is_complex_when_larger]
        data = criterion[:data]

        values = data.map { |v| v[0] }
        min_value, max_value = values.min, values.max

        normalized_values = if min_value == max_value
                              Array.new(values.size, 0)
                            else
                              values.map { |v| (v - min_value).to_f / (max_value - min_value) }
                            end

        normalized_values.map! { |v| is_complex_when_larger ? v : 1 - v }

        data.each_with_index do |(_, index), i|
          candidates[index] += normalized_values[i]
        end
      end

      # スコアが高い順にソート
      sorted_candidates = candidates.sort_by { |_, score| score }

      # converted_rank に対応するインデックスを取得
      n = sorted_candidates.size
      rank_index = (converted_rank * n).floor
      rank_index = [rank_index, n - 1].min

      # 指定されたランクの候補インデックスを返す
      sorted_candidates[rank_index]&.first
    end


    def windowing_dominance_hash(dominance_hash, window_size = 100)
      # 各キー（0〜11）ごとの時系列データを取得
      time_series = dominance_hash.values.transpose
      smoothed_values = []
      normalized_data = time_series.map.with_index do |values, i|
        # 直近 `window_size` 個の平均を計算（スムージング）
        smoothed_values = values.map.with_index do |_, idx|
          start_idx = [0, i - window_size + 1].max
          history = time_series[start_idx..i].map { |row| row[idx] }
          history.sum.to_f / history.size
        end
        smoothed_values
      end

      # 元の dominance_hash のキーにマッピング
      keys = dominance_hash.keys
      keys.zip(normalized_data.transpose).to_h
    end

    def analyse_params
      params.require(:analyse).permit(
        :time_series,
        :merge_threshold_ratio,
        :job_id
      )
    end

    def generate_params
      params.require(:generate).permit(
        :complexity_transition,
        :range_min,
        :range_max,
        :first_elements,
        :merge_threshold_ratio,
        :job_id
      )
    end

    def broadcast_start(job_id)
      raise "job_id missing" if job_id.blank?
      ActionCable.server.broadcast("progress_#{job_id}", {
        status: 'start',
        job_id: job_id
      })
    end

    def broadcast_progress(job_id, current, total)
      percent = (current.to_f * 100 / total).floor
      ActionCable.server.broadcast("progress_#{job_id}", {
        status: 'progress',
        progress: percent
      })
    end

    def broadcast_done(job_id)
      ActionCable.server.broadcast("progress_#{job_id}", {
        status: 'done',
      })
    end
end
