class Api::Web::TimeSeriesController < ApplicationController
  include TimeSeriesAnalyser

  def analyse
    data = analyse_params[:time_series].split(',').map{|elm|elm.to_i}
    tolerance_diff_distance = analyse_params[:tolerance_diff_distance].to_d

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
          tolerance_diff_distance,
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
    distance_tansitions_between_clusters = generate_params[:distance_tansitions_between_clusters].split(',').map{|elm|elm.to_i}
    
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
    tolerance_diff_distance = 1
    distances_between_clusters = {}
    # 設定ランキング群のループ
    distance_tansitions_between_clusters.each_with_index do |rank, rank_index|
      # ハッシュが入る
      distances_between_clusters_candidates = []
      clusters_candidates = []
      cluster_id_counter_candidates = []
      average_all_window_candidates = []
      tasks_candidates = []
  
      # 候補値のループ
      (generate_params[:range_min].to_i..generate_params[:range_max].to_i).each do |candidate|
        temporary_results = results.dup
        temporary_results << candidate
        temporary_clusters = clusters.deep_dup
        temporary_cluster_id_counter = cluster_id_counter
        temporary_distances_between_clusters = distances_between_clusters.dup
        temporary_tasks = tasks.dup
        temporary_clusters, temporary_tasks, temporary_cluster_id_counter = clustering_subsequences_incremental(
          temporary_results,
          tolerance_diff_distance,
          candidate,
          temporary_results.length - 1,
          min_window_size,
          temporary_clusters,
          temporary_cluster_id_counter,
          temporary_tasks,
          rank_index == distance_tansitions_between_clusters.length - 1
        )
        # 階層ごとにまとめる
        clusters_each_window_size = transform_clusters(temporary_clusters, min_window_size)

        # 同一階層内で組み合わせ計算（全部再計算）
        averages_all_window = []
        clusters_each_window_size.each do |window_size, same_window_size_clusters|
          sum_distances = 0
          sum_pattern_length = 0

          same_window_size_clusters.values
          .combination(2).each do |subsequence_indexes1, subsequence_indexes2|

            subsequences1 = subsequence_indexes1.map{|subsequence|temporary_results[subsequence[0]..subsequence[1]]}
            subsequences2 = subsequence_indexes2.map{|subsequence|temporary_results[subsequence[0]..subsequence[1]]}
            c1_average = calculate_average_time_series(subsequences1)
            c2_average = calculate_average_time_series(subsequences2)

            distance = euclidean_distance(c1_average, c2_average)

            pattern_length = subsequence_indexes1.length * subsequence_indexes2.length
            sum_pattern_length += pattern_length
            sum_distances += pattern_length * distance
          end

          if sum_pattern_length == 0
            averages_all_window << 0
          else
            averages_all_window << sum_distances / sum_pattern_length
          end
        end
        average_all_window_candidates << mean(averages_all_window )
        clusters_candidates << temporary_clusters
        cluster_id_counter_candidates << temporary_cluster_id_counter
        tasks_candidates << temporary_tasks
      end
      indexed_average_distances_between_clusters = average_all_window_candidates.map.with_index { |distance, index| [distance, index] }
      sorted_indexed_average_distances_between_clusters = indexed_average_distances_between_clusters.sort_by { |pair| pair[0] }
      distance_at_rank, index = sorted_indexed_average_distances_between_clusters[rank]
      results << index

      clusters = clusters_candidates[index]
      cluster_id_counter = cluster_id_counter_candidates[index]
      tasks = tasks_candidates[index]
    end
  end

  private  
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

    def distances_between_clusters(clusters, data)
      # クラスタ間の距離の累積
      result = 0
      clusters.values.combination(2).each do |c1, c2|
        subsequences1 = c1[:s].map{|subsequence|data[subsequence[0]..subsequence[1]]}
        subsequences2 = c2[:s].map{|subsequence|data[subsequence[0]..subsequence[1]]}
        c1_average = calculate_average_time_series(subsequences1)
        c2_average = calculate_average_time_series(subsequences2)
        distance = euclidean_distance(c1_average, c2_average)
        result += c1[:s].length * c2[:s].length * distance
      end
      result
    end

    def analyse_params
      params.require(:analyse).permit(
        :time_series,
        :tolerance_diff_distance
      )
    end
    
    def generate_params
      params.require(:generate).permit(
        :distance_tansitions_between_clusters,
        :range_min,
        :range_max
      )
    end

end
