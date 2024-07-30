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
    # 遷移系のパラメータ
    distance_tansition_between_clusters = generate_params[:distance_tansition_between_clusters].split(',').map{|elm|elm.to_i}
    merge_threshold_ratio = generate_params[:merge_threshold_ratio].to_d

    results = [0,0]
    min_window_size = 2
    cluster_id_counter = 0
    clusters = {
      cluster_id_counter => {
        s: [[0, min_window_size - 1]],
        c: {}
      }
    }
    tasks = []
    # 設定ランキング群のループ
    distance_tansition_between_clusters.each_with_index do |rank, rank_index|
      # ハッシュが入る
      clusters_candidates = []
      cluster_id_counter_candidates = []
      sum_distances_all_window_candidates = []
      tasks_candidates = []
  
      # 候補値のループ
      (generate_params[:range_min].to_i..generate_params[:range_max].to_i).each do |candidate|
        temporary_results = results.dup
        temporary_results << candidate
        temporary_clusters = clusters.deep_dup
        temporary_cluster_id_counter = cluster_id_counter
        temporary_tasks = tasks.dup
        # 候補値でクラスタリング
        temporary_clusters, temporary_tasks, temporary_cluster_id_counter = clustering_subsequences_incremental(
          temporary_results,
          merge_threshold_ratio,
          candidate,
          temporary_results.length - 1,
          min_window_size,
          temporary_clusters,
          temporary_cluster_id_counter,
          temporary_tasks,
          rank_index == distance_tansition_between_clusters.length - 1
        )
        # 階層ごとにまとめる
        clusters_each_window_size = transform_clusters(temporary_clusters, min_window_size)
        
        sum_distances_in_all_window = []
        clusters_each_window_size.each do |window_size, same_window_size_clusters|
          sum_distances = 0
          sum_pattern_length = 0
          # 同一階層内の全組み合わせでクラスタ間の距離を計算（全部再計算）
          same_window_size_clusters.values.combination(2).each do |subsequence_indexes1, subsequence_indexes2|
            subsequences1 = subsequence_indexes1.map{|subsequence|temporary_results[subsequence[0]..subsequence[1]]}
            subsequences2 = subsequence_indexes2.map{|subsequence|temporary_results[subsequence[0]..subsequence[1]]}
            c1_average = calculate_average_time_series(subsequences1)
            c2_average = calculate_average_time_series(subsequences2)
            distance = euclidean_distance(c1_average, c2_average)
            sum_distances += distance
          end

          sum_distances_in_all_window << sum_distances
        end

        sum_distances_all_window_candidates << sum_distances_in_all_window.sum
        clusters_candidates << temporary_clusters
        cluster_id_counter_candidates << temporary_cluster_id_counter
        tasks_candidates << temporary_tasks
      end
      # 候補値のループ終わり。

      # [[距離、index(0)], [距離、index(1)],...]の形式にして距離が小さい順に並べる。indexは候補を処理した順番。
      indexed_average_distances_between_clusters = sum_distances_all_window_candidates.map.with_index { |distance, index| [distance, index] }.sort_by {|candidate|candidate[0] }
      # 指定したランクにある処理順を取得
      result = indexed_average_distances_between_clusters[rank][1]
      results << result
      clusters = clusters_candidates[result]
      cluster_id_counter = cluster_id_counter_candidates[result]
      tasks = tasks_candidates[result]
    end
    render json: {
      results: results,
    }
  end

  private  
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

    def analyse_params
      params.require(:analyse).permit(
        :time_series,
        :merge_threshold_ratio
      )
    end
    
    def generate_params
      params.require(:generate).permit(
        :distance_tansition_between_clusters,
        :subsequences_sparsity_transition,
        :range_min,
        :range_max
      )
    end

end
