class Api::Web::TimeSeriesController < ApplicationController
  include DissonanceMemory
  include StatisticsCalculator

  def analyse
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    job_id = analyse_params[:job_id]
    broadcast_start(job_id)

    data = analyse_params[:time_series].split(',').map { |elm| elm.to_i }
    merge_threshold_ratio = analyse_params[:merge_threshold_ratio].to_d
    calculate_distance_when_added_subsequence_to_cluster = true

    min_window_size = 2

    manager = TimeSeriesClusterManager.new(data, merge_threshold_ratio, min_window_size, calculate_distance_when_added_subsequence_to_cluster)
    manager.process_data

    timeline = manager.clusters_to_timeline(manager.clusters, min_window_size)
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    processing_time_s = ((end_time - start_time)).round(2)

    broadcast_done(job_id)
    render json: {
      clusteredSubsequences: timeline,
      timeSeriesChart: [] + data.map.with_index { |elm, index| [index.to_s, elm, nil, nil] },
      clusters: manager.clusters,
      processingTime: processing_time_s
    }
  end

  def generate
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    job_id = generate_params[:job_id]
    broadcast_start(job_id)

    user_set_results = generate_params[:first_elements].split(',').map { |elm| elm.to_i }
    complexity_transition = generate_params[:complexity_transition].split(',').map { |elm| elm.to_i }
    merge_threshold_ratio = generate_params[:merge_threshold_ratio].to_d
    candidate_min_master = generate_params[:range_min].to_i
    candidate_max_master = generate_params[:range_max].to_i
    min_window_size = 2
    selected_use_musical_feature = generate_params[:selected_use_musical_feature]

    dissonance_results = []
    dissonance_current_time = 0.to_d
    dissonance_short_term_memory = []
    time_unit = 0.125
    calculate_distance_when_added_subsequence_to_cluster = false

    if generate_params[:selected_use_musical_feature].present? && generate_params[:selected_use_musical_feature] === 'dissonancesOutline'
      dissonance_transition = generate_params[:dissonance][:transition].split(',').map(&:to_i)
      dissonance_duration_transition = generate_params[:dissonance][:duration_transition].split(',').map(&:to_i)
      dissonance_range = generate_params[:dissonance][:range].to_i
    end
    if generate_params[:selected_use_musical_feature].present? && generate_params[:selected_use_musical_feature] === 'durationsOutline'
      duration_outline_transition = generate_params[:duration][:outline_transition].split(',').map(&:to_i)
      duration_outline_range = generate_params[:duration][:outline_range].to_i
    end

    manager = TimeSeriesClusterManager.new(user_set_results.dup, merge_threshold_ratio, min_window_size, calculate_distance_when_added_subsequence_to_cluster)

    user_set_results.each_with_index do |elm, data_index|
      if selected_use_musical_feature === 'dissonancesOutline'
        duration = dissonance_duration_transition[data_index]
        dissonance_current_time += duration * time_unit.to_d
        dissonance, dissonance_short_term_memory = STMStateless.process([elm], dissonance_current_time, dissonance_short_term_memory)
        dissonance_results << dissonance
      end
    end

    manager.process_data

    # 初期キャッシュ構築
    clusters_each_window_size = transform_clusters(manager.clusters, min_window_size)
    initial_calc_values(manager, clusters_each_window_size, candidate_max_master, candidate_min_master, user_set_results.length)

    # 初期化
    manager.updated_cluster_ids_per_window_for_calculate_distance = {}

    results = user_set_results.dup

    complexity_transition.each_with_index do |rank, rank_index|
      candidate_max = candidate_max_master
      candidate_min = candidate_min_master
      candidates = (candidate_min..candidate_max).to_a
      current_dissonance_short_term_memory = dissonance_short_term_memory.dup
      in_range = []

      if selected_use_musical_feature === 'dissonancesOutline'
        dissonance_current_time += dissonance_duration_transition[rank_index] * time_unit.to_d
        dissonance_rank = dissonance_transition[rank_index]
        results_in_candidates = candidates.map do |note|
          notes = [note]
          dissonance, memory = STMStateless.process(notes, dissonance_current_time, current_dissonance_short_term_memory)
          { dissonance: dissonance, memory: memory, note: note }
        end
        from = [dissonance_rank - dissonance_range, 0].max
        to = [dissonance_rank + dissonance_range, results_in_candidates.size - 1].min
        sorted_results_in_candidates = results_in_candidates.sort_by { |r| r[:dissonance] }
        in_range = sorted_results_in_candidates[from..to]
        candidates = in_range.map { |r| r[:note] }
      elsif selected_use_musical_feature === 'durationsOutline'
        duration_outline_rank = duration_outline_transition[rank_index]
        from = [duration_outline_rank - duration_outline_range, 0].max
        to = [duration_outline_rank + duration_outline_range, candidates.size - 1].min
        candidates = candidates[from..to]
      end

      indexed_average_distances_between_clusters = []
      indexed_subsequences_quantities = []

      current_len = results.length + 1
      quadratic_integer_array = create_quadratic_integer_array(0, (candidate_max_master - candidate_min_master) * current_len, current_len)

      candidates.each_with_index do |candidate, idx|
        # シミュレーション実行
        avg_dist, quantity = manager.simulate_add_and_calculate(
          candidate,
          quadratic_integer_array,
          self
        )

        indexed_average_distances_between_clusters << [avg_dist, idx]
        indexed_subsequences_quantities << [quantity, idx]
      end

      converted_rank = rank / candidates.length.to_d

      metrics_with_direction = [
        { is_complex_when_larger: true, data: indexed_average_distances_between_clusters },
        { is_complex_when_larger: false, data: indexed_subsequences_quantities }
      ]

      result_index_in_candidates = find_complex_candidate(metrics_with_direction, converted_rank)
      result = candidates[result_index_in_candidates]

      results << result
      manager.add_data_point_permanently(result)

      # キャッシュ更新
      update_caches_permanently(manager, min_window_size, quadratic_integer_array)

      # 忘却処理 (Pruning)
      manager.prune_clusters

      if selected_use_musical_feature === 'dissonancesOutline'
        best = in_range.find { |r| r[:note] == result }
        dissonance_short_term_memory = best[:memory]
        dissonance_results << best[:dissonance]
      end
      broadcast_progress(job_id, rank_index + 1, complexity_transition.length)
    end

    chart_elements_for_complexity = Array.new(user_set_results.length) { |index| [index.to_s, nil, nil, nil] }

    timeline = manager.clusters_to_timeline(manager.clusters, min_window_size)
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    processing_time_s = ((end_time - start_time)).round(2)

    broadcast_done(job_id)

    render json: {
      clusteredSubsequences: timeline,
      timeSeriesChart: [] + results.map.with_index { |elm, index| [index.to_s, elm, nil, nil] },
      timeSeries: results,
      timeSeriesComplexityChart: [] + chart_elements_for_complexity + complexity_transition.map.with_index { |elm, index| [(user_set_results.length + index).to_s, elm, nil, nil] },
      clusters: manager.clusters,
      processingTime: processing_time_s
    }
  end

  private

  def initial_calc_values(manager, clusters_each_window_size, max_master, min_master, len)
    quadratic_integer_array = create_quadratic_integer_array(0, (max_master - min_master) * len, len)

    clusters_each_window_size.each do |window_size, same_window_size_clusters|
      all_ids = same_window_size_clusters.keys
      updated_ids = manager.updated_cluster_ids_per_window_for_calculate_distance[window_size].to_a
      cache = manager.cluster_distance_cache[window_size] ||= {}

      updated_ids.each do |cid1|
        all_ids.each do |cid2|
          next if cid1 == cid2
          key = [cid1, cid2].sort
          as1 = same_window_size_clusters.dig(cid1, :as)
          as2 = same_window_size_clusters.dig(cid2, :as)
          if as1 && as2
            cache[key] = euclidean_distance(as1, as2)
          end
        end
      end

      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        if cluster && cluster[:si].length > 1
          quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
          q_cache[cid] = quantity
        end
      end
    end
  end

  def update_caches_permanently(manager, min_window_size, quadratic_integer_array)
    clusters_each_window_size = transform_clusters(manager.clusters, min_window_size)

    clusters_each_window_size.each do |window_size, same_window_size_clusters|
      all_ids = same_window_size_clusters.keys
      updated_ids = manager.updated_cluster_ids_per_window_for_calculate_distance[window_size].to_a
      cache = manager.cluster_distance_cache[window_size] ||= {}

      updated_ids.each do |cid1|
        all_ids.each do |cid2|
          next if cid1 == cid2
          key = [cid1, cid2].sort
          as1 = same_window_size_clusters.dig(cid1, :as)
          as2 = same_window_size_clusters.dig(cid2, :as)
          if as1 && as2
            cache[key] = euclidean_distance(as1, as2)
          end
        end
      end

      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        if cluster && cluster[:si].length > 1
          quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
          q_cache[cid] = quantity
        end
      end
    end

    manager.updated_cluster_ids_per_window_for_calculate_distance = {}
    manager.updated_cluster_ids_per_window_for_calculate_quantities = {}
  end

  def transform_clusters(clusters, min_window_size)
    clusters_each_window_size = {}
    stack = clusters.map { |id, cluster| [id, cluster, min_window_size] }

    until stack.empty?
      cluster_id, current_cluster, depth = stack.pop
      sequences = current_cluster[:si].map { |start_index| [start_index, start_index + depth - 1] }

      clusters_each_window_size[depth] ||= {}
      clusters_each_window_size[depth][cluster_id] = {si: sequences, as: current_cluster[:as]}

      current_cluster[:cc].each do |sub_cluster_id, sub_cluster|
        stack.push([sub_cluster_id, sub_cluster, depth + 1])
      end
    end

    clusters_each_window_size
  end

  def find_complex_candidate(criteria, converted_rank)
    candidates = Hash.new { |h, k| h[k] = 0 }

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

    sorted_candidates = candidates.sort_by { |_, score| score }

    n = sorted_candidates.size
    rank_index = (converted_rank.to_f * n).floor
    rank_index = [rank_index, n - 1].min

    sorted_candidates[rank_index]&.first
  end

  def create_quadratic_integer_array(start_val, end_val, count)
    result = []
    count.times do |i|
      t = i.to_f / (count - 1)
      curve = t ** 10
      value = start_val + (end_val - start_val) * curve

      if start_val < end_val
        result << value.ceil + 1
      else
        result << value.floor + 1
      end
    end
    result
  end

  def analyse_params
    params.require(:analyse).permit(:time_series, :merge_threshold_ratio, :job_id)
  end

  def generate_params
    params.require(:generate).permit(
      :complexity_transition, :range_min, :range_max, :first_elements,
      :merge_threshold_ratio, :job_id, :selected_use_musical_feature,
      dissonance: [:transition, :duration_transition, :range],
      duration: [:outline_transition, :outline_range]
    )
  end

  def broadcast_start(job_id)
    raise "job_id missing" if job_id.blank?
    ActionCable.server.broadcast("progress_#{job_id}", { status: 'start', job_id: job_id })
  end

  def broadcast_progress(job_id, current, total)
    percent = (current.to_f * 100 / total).floor
    ActionCable.server.broadcast("progress_#{job_id}", { status: 'progress', progress: percent })
  end

  def broadcast_done(job_id)
    ActionCable.server.broadcast("progress_#{job_id}", { status: 'done' })
  end
end
