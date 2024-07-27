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
    metrics_priority = [:sparsity,:distance]
    # 遷移系のパラメータ
    distance_tansition_between_clusters = generate_params[:distance_tansition_between_clusters].split(',').map{|elm|elm.to_i}
    subsequences_sparsity_transition = generate_params[:subsequences_sparsity_transition].split(',').map{|elm|elm.to_i}
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
      sparsity_candidates = []

  
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

        sparsity_candidate = 0
        
        sum_distances_in_all_window = []
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
            sum_distances += distance
          end

          sum_distances_in_all_window << sum_distances
          # sparsity_candidateのスコアは、同じクラスタ内の部分列の数の二乗の逆数に比例する
          sparsity_candidate = 0
          same_window_size_clusters.values.each do |cluster|
            variances = []
            cluster.transpose.map{|same_index|same_index.map{|index|temporary_results[index]}}.each do |same_index|
              variances << variance(same_index)
            end
            inverse_variance_factor = 1.0 / (1 + mean(variances))
            sparsity_candidate += 1.0 / (cluster.length.pow(2) * inverse_variance_factor)
          end
        end

        sum_distances_all_window_candidates << sum_distances_in_all_window.sum
        clusters_candidates << temporary_clusters
        cluster_id_counter_candidates << temporary_cluster_id_counter
        tasks_candidates << temporary_tasks
        sparsity_candidates << sparsity_candidate
      end
      # 候補値のループ終わり。

      # [[距離、index(0)], [距離、index(1)],...]の形式にする。indexは候補を処理した順番。
      indexed_average_distances_between_clusters = sum_distances_all_window_candidates.map.with_index { |distance, index| [distance, index] }
      # 処理した順番を距離が小さい順に並べる。要素の1番目にはその順位の数字が並ぶ。ただし同じ距離は同率順位となる。
      # [[1、index(0)], [2、index(1)], [1、index(2)]...]は[[0、index(0)], [0、index(2)], [2、index(1)]...]となる。
      sorted_indexed_average_distances_between_clusters = convert_same_distance_same_index(indexed_average_distances_between_clusters)
      # ユーザが指定したランクの実際の順位と処理順を取得
      distance_at_rank, distance_index = sorted_indexed_average_distances_between_clusters[rank]

      # [[まばら度、index(0)], [まばら度、index(1)],...]の形式にする。indexは候補を処理した順番。
      indexed_sparsity = sparsity_candidates.map.with_index { |sparsity, index| [sparsity, index] }
      # 処理した順番をまばら度が小さい順に並べる。要素の1番目にはその順位の数字が並ぶ。ただし同じ距離は同率順位となる。
      # [[1、index(0)], [2、index(1)], [1、index(2)]...]は[[0、index(0)], [0、index(2)], [2、index(1)]...]となる。
      sorted_indexed_sparsity = convert_same_distance_same_index(indexed_sparsity)
      # ユーザが指定したランクの実際の順位と処理淳を取得。ランクの順番を使う。
      sparsity_at_rank, sparsity_index = sorted_indexed_sparsity[subsequences_sparsity_transition[rank_index]]

      index_candidates = {
        distance: {
          list: sorted_indexed_average_distances_between_clusters,
          sum_distances_between_other_metrics_rank: 0,
          rank: rank,
          intersection_index_length_between_other_metrics: 0
        },
        sparsity: {
          list: sorted_indexed_sparsity,
          sum_distances_between_other_metrics_rank: 0,
          rank: subsequences_sparsity_transition[rank_index],
          intersection_index_length_between_other_metrics: 0
        },
        
      }
      result_index = nil

      index_candidates.each do |parent_metric_key, parent_metric|
        # ソートされた候補群から、ある指標で指定されたランクにある候補の実際の順位を得る
        parent_index = parent_metric[:list][parent_metric[:rank]][0]
        # 得た順位と同率順位の候補群を得る。つまり指定したランクと同等の結果となった候補群を得ることになる。
        parent_same = parent_metric[:list].filter{|elm|elm[0] == parent_index}
        # 同率順位の候補群の、処理順を得る
        parent_same_processed_index = parent_same.map{|elm|elm[1]}

        # 他の指標をループする
        index_candidates.each do |child_metric_key, child_metric|
          # 他の指標とだけ比較する
          next if parent_metric_key == child_metric_key
          # ある指標で必要となる処理順群と同じ処理順群を他の指標から得る
          parent_index_in_child = child_metrc[:list].select { |sorted_index_and_processed_index| parent_same_processed_index.include?(index_and_rank_index[1]) }
          # 他の指標の処理順群の同率順位群を得る
          parent_rank_in_child = parent_index_in_child.map { |sorted_index_and_processed_index| index_and_rank_index[0] }.uniq
          # parent_rank_in_childの候補群の処理順を得る
          child_same_index = child_metric[:list].select { |sorted_index_and_processed_index| parent_rank_in_child.include?(sorted_index_and_processed_index[0]) }.map{|elm|elm[1]}
          # ある指標と他の指標とで積集合となる処理順を得て、その長さを足す
          intersection = parent_same_processed_index & child_same_index
          parent_metric[:intersection_index_length_between_other_metrics] += intersection.length
        end
      end

      if result_index.nil?
        # 処理順の候補が一番少ない指標を優先する
        min_key = index_candidates.min_by do |key, value|
          [value[:intersection_index_length_between_other_metrics], metrics_priority.index(key)]
        end.first

        if min_key == :distance
          result_index = distance_index
        else
          result_index = sparsity_index
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
        :distance_tansition_between_clusters,
        :subsequences_sparsity_transition,
        :range_min,
        :range_max
      )
    end

end
