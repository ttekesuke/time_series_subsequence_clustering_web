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
    rules_priority = [:similarity,:distance]
    distance_tansitions_between_clusters = generate_params[:distance_tansitions_between_clusters].split(',').map{|elm|elm.to_i}
    similarity_transitions = generate_params[:similarity_transitions].split(',').map{|elm|elm.to_i}
    
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
    merge_threshold_ratio = generate_params[:merge_threshold_ratio].to_d
    distances_between_clusters_each_window_size = {}
    # 設定ランキング群のループ
    distance_tansitions_between_clusters.each_with_index do |rank, rank_index|
      # ハッシュが入る
      clusters_candidates = []
      cluster_id_counter_candidates = []
      average_all_window_candidates = []
      tasks_candidates = []
      similarity_candidates = []

  
      # 候補値のループ
      (generate_params[:range_min].to_i..generate_params[:range_max].to_i).each do |candidate|
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
          rank_index == distance_tansitions_between_clusters.length - 1
        )
        # 階層ごとにまとめる
        clusters_each_window_size = transform_clusters(temporary_clusters, min_window_size)

        similarity_candidate = 0
        
        averages_all_window = []
        clusters_each_window_size.each do |window_size, same_window_size_clusters|
          sum_distances = 0
          sum_pattern_length = 0
          # 同一階層内の全組み合わせでクラスタ間の距離を計算（全部再計算）
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
          # 類似度のスコアは、同じクラスタ内の部分列の数の二乗に比例する
          same_window_size_clusters.values.each do |cluster|
            variances = []
            cluster.transpose.map{|same_index|same_index.map{|index|temporary_results[index]}}.each do |same_index|
              variances << variance(same_index)
            end
            inverse_variance_factor = 1.0 / (1 + mean(variances))
            similarity_candidate += cluster.length.pow(2) * inverse_variance_factor
          end
        end

        average_all_window_candidates << mean(averages_all_window )
        clusters_candidates << temporary_clusters
        cluster_id_counter_candidates << temporary_cluster_id_counter
        tasks_candidates << temporary_tasks
        similarity_candidates << similarity_candidate
      end
      indexed_average_distances_between_clusters = average_all_window_candidates.map.with_index { |distance, index| [distance, index] }
      sorted_indexed_average_distances_between_clusters = convert_same_distance_same_index(indexed_average_distances_between_clusters)
      distance_at_rank, distance_index = sorted_indexed_average_distances_between_clusters[rank]

      indexed_similarity = similarity_candidates.map.with_index { |similarity, index| [similarity, index] }
      sorted_indexed_similarity = convert_same_distance_same_index(indexed_similarity)
      similarity_at_rank, similarity_index = sorted_indexed_similarity[similarity_transitions[rank_index]]


      index_candidates = {
        distance: {
          index: distance_index,
          list: sorted_indexed_average_distances_between_clusters,
          sum_distances_between_other_rules_rank: 0,
          rank: rank,
          intersection_index_length_between_other_rules: 0
        },
        similarity: {
          index: similarity_index,
          list: sorted_indexed_similarity,
          sum_distances_between_other_rules_rank: 0,
          rank: similarity_transitions[rank_index],
          intersection_index_length_between_other_rules: 0
        },
        
      }
      result_index = nil
      index_candidates.each do |parent_rule_key, parent_rule|
        parent_first = parent_rule[:list][parent_rule[:rank]][0]
        parent_same = parent_rule[:list].filter{|elm|elm[0] == parent_first}
        parent_same_index = parent_same.map{|elm|elm[1]}
        index_candidates.each do |child_rule_key, child_rule|
          next if parent_rule_key == child_rule_key
          # ステップ1: 2番目の要素がparent_same_indexに含まれるものを見つける
          parent_index_in_child = child_rule[:list].select { |sub_array| parent_same_index.include?(sub_array[1]) }

          # 見つかった要素の1番目の要素を抽出
          target_distance_steps = parent_index_in_child.map { |sub_array| sub_array[0] }.uniq


          # ステップ2: 1番目の要素がtarget_distance_steps
          child_same_index = child_rule[:list].select { |sub_array| target_distance_steps.include?(sub_array[0]) }.map{|elm|elm[1]}

          intersection = parent_same_index & child_same_index
          parent_rule[:intersection_index_length_between_other_rules] += intersection.length
        end
      end

      if result_index.nil?
        min_key = index_candidates.min_by do |key, value|
          [value[:intersection_index_length_between_other_rules], rules_priority.index(key)]
        end.first

        if min_key == :distance
          result_index = distance_index
        else
          result_index = similarity_index
        end
      end
      results << result_index
      clusters = clusters_candidates[result_index]
      cluster_id_counter = cluster_id_counter_candidates[result_index]
      tasks = tasks_candidates[result_index]
    end
    render json: {
      result: results,
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
        :distance_tansitions_between_clusters,
        :similarity_transitions,
        :range_min,
        :range_max
      )
    end

end
