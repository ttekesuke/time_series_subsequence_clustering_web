class Api::Web::TimeSeriesAnalysisController < ApplicationController
  include StatisticsCalculator

  def create
    data = time_series_analysis_params[:time_series].split(',').map{|elm|elm.to_i}
    data_length = data.length
    min_window_size = 2
    current_window_size = min_window_size
    cluster_id_counter = 0
    all_window_clusters = []
    tolerance_diff_distance = time_series_analysis_params[:tolerance_diff_distance].to_d
    start_indexes = 0.step(data_length - min_window_size, 1).to_a
  
    # 部分列を生成
    current_window_subsequences = generate_subsequences(current_window_size, start_indexes)
  
    while current_window_subsequences.length > 0 do
      p "current_window_size:#{current_window_size}"
      min_distances = []
      cluster_merge_counter = 0
      tolerance_over = false
      current_window_clusters = []
      # 部分列を使って初期クラスタ作成
      current_window_subsequences.each do |subsequence|
        current_window_clusters << {
          id: cluster_id_counter, 
          subsequences: [subsequence]
        }
        cluster_id_counter += 1
      end
  
      # クラスタ結合
      while current_window_clusters.length > 1 && !tolerance_over do
        min_distance = Float::INFINITY
        closest_pair = nil
        current_window_clusters.combination(2).each do |c1, c2|
          sum_distances = 0
          
          c1[:subsequences].each do |c1_subsequence|
            c2[:subsequences].each do |c2_subsequence|
              sum_distances += euclidean_distance(data[c1_subsequence[:start_index]..c1_subsequence[:end_index]], data[c2_subsequence[:start_index]..c2_subsequence[:end_index]])
            end
          end
          # 部分列が完全一致なら結合して終わり
          if sum_distances == 0.0
            min_distance = sum_distances
            closest_pair = [c1, c2]
            break
          end
          # 最短になったら更新
          if sum_distances < min_distance
            min_distance = sum_distances
            closest_pair = [c1, c2]
          end
        end
  
        min_distances << min_distance

        combination_length = closest_pair[0][:subsequences].length * closest_pair[1][:subsequences].length
        # 許容値値を超えると結合終了
        current_tolerance_diff_distance = tolerance_diff_distance * current_window_size / combination_length.to_d / 2
        
        if (cluster_merge_counter == 0 && min_distances.last > current_tolerance_diff_distance) || (cluster_merge_counter > 1 && min_distances.last - min_distances.min > current_tolerance_diff_distance) 
          tolerance_over = true
        else
          current_window_clusters.delete_if { |c| c[:id] == closest_pair[0][:id] || c[:id] == closest_pair[1][:id] }
          current_window_clusters << {
            id: cluster_id_counter, 
            subsequences: closest_pair[0][:subsequences] + closest_pair[1][:subsequences]
          }
          cluster_id_counter += 1
          cluster_merge_counter += 1
        end
      end
      # そのwindow_sizeにおけるクラスタリング結果を保存
      all_window_clusters << current_window_clusters
      next_window_clusters = Marshal.load(Marshal.dump(current_window_clusters))
      # 結合完了後に、同じクラスタ内で部分列同士をチェック。部分列同士で時系列上で重複すれば、前にある部分列側は今後クラスタ結合の対象外とする
      next_window_clusters.each do |cluster|
        other_subsequences = []
        not_overlapping = []
        # 時系列上での重複チェック
        cluster[:subsequences].each do |subsequence|
          other_subsequences = cluster[:subsequences].filter{|may_remove_subsequence| subsequence != may_remove_subsequence && subsequence[:start_index] < may_remove_subsequence[:start_index]}
          not_overlapping << subsequence if other_subsequences.all?{|other_subsequence| subsequence[:end_index] + 1 < other_subsequence[:start_index]}
        end
        cluster[:subsequences] = not_overlapping      
  
        # 次の長さのwindow_sizeでも元データをはみ出さない部分列だけ残す
        cluster[:subsequences] = cluster[:subsequences].filter{|subsequence|subsequence[:start_index] + current_window_size <= data.length - 1}
      end
  
      current_window_size += 1
      # 次の部分列群を生成する
      current_window_subsequences = generate_subsequences(
        current_window_size, 
        next_window_clusters
        .filter{|cluster|cluster[:subsequences].length > 1}
        .map{|cluster|cluster[:subsequences].map{|subsequence|subsequence[:start_index]}}.flatten
      )
    end

    @clustered_subsequences = []
  
    all_window_clusters.each_with_index do |window_clusters, window_cluster_index|
      window_clusters.each_with_index do |cluster, cluster_index|
        cluster[:subsequences].each do |subsequence|
          @clustered_subsequences << [(window_cluster_index + min_window_size).to_s, cluster_index.to_s(26).tr("0-9a-p", "a-z"), subsequence[:start_index] * 1000, (subsequence[:end_index] + 1) * 1000] 
        end
      end
    end
    render json: {
      clusteredSubsequences: @clustered_subsequences,
      timeSeries: [['index', 'allValue']] + data.map.with_index{|elm, index|[index.to_s, elm]}
    }

  end

  private
    def generate_subsequences(window_size, start_indexes)
      start_indexes.map{|start_index|{start_index: start_index, end_index: start_index + window_size - 1}}
    end

    def time_series_analysis_params
      params.require(:time_series_analysis).permit(
        :time_series,
        :tolerance_diff_distance
      )
    end

end
