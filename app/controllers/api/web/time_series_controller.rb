class Api::Web::TimeSeriesController < ApplicationController
  include DissonanceMemory
  include StatisticsCalculator
  require 'pp'

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

    # UIからの入力(0~100)を保持しつつ、計算用(0.0~1.0)に変換
    complexity_transition_int = generate_params[:complexity_transition].split(',').map { |elm| elm.to_i }
    complexity_targets = complexity_transition_int.map { |val| val / 100.0 }

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
    clusters_each_window_size = manager.transform_clusters(manager.clusters, min_window_size)
    initial_calc_values(manager, clusters_each_window_size, candidate_max_master, candidate_min_master, user_set_results.length)

    # 初期化
    manager.updated_cluster_ids_per_window_for_calculate_distance = {}

    results = user_set_results.dup

    # 生成ループ
    complexity_targets.each_with_index do |target_val, rank_index|
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

      indexed_metrics = []

      # 重み配列 (rank非依存)
      current_len = results.length + 1
      quadratic_integer_array = create_quadratic_integer_array(0, (candidate_max_master - candidate_min_master) * current_len, current_len)

      candidates.each_with_index do |candidate, idx|
        # シミュレーション実行 (戻り値にcomplexityを追加)
        avg_dist, quantity, complexity = manager.simulate_add_and_calculate(
          candidate,
          quadratic_integer_array,
          self
        )

        indexed_metrics << {
          index: idx,
          dist: avg_dist,
          quantity: quantity,
          complexity: complexity
        }
      end

      # 評価基準の構築
      criteria = [
        { is_complex_when_larger: true,  data: indexed_metrics.map { |m| [m[:dist], m[:index]] } },
        { is_complex_when_larger: false, data: indexed_metrics.map { |m| [m[:quantity], m[:index]] } },
        { is_complex_when_larger: true,  data: indexed_metrics.map { |m| [m[:complexity], m[:index]] } } # 新規: 内部複雑度
      ]

      # ベスト候補の選択
      result_index = find_complex_candidate_by_value(criteria, target_val)
      result = candidates[result_index]

      results << result
      manager.add_data_point_permanently(result)

      # 決定後のキャッシュ更新
      update_caches_permanently(manager, min_window_size, quadratic_integer_array)

      if selected_use_musical_feature === 'dissonancesOutline'
        best = in_range.find { |r| r[:note] == result }
        dissonance_short_term_memory = best[:memory]
        dissonance_results << best[:dissonance]
      end
      broadcast_progress(job_id, rank_index + 1, complexity_targets.length)
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
      # UI用には整数の配列(0-100)を返す
      timeSeriesComplexityChart: [] + chart_elements_for_complexity + complexity_transition_int.map.with_index { |elm, index| [(user_set_results.length + index).to_s, elm, nil, nil] },
      clusters: manager.clusters,
      processingTime: processing_time_s
    }
  end

  # ============================================================
  #  多声生成アクション (6次元 x 4制御パラメータ)
  # ============================================================
  def generate_polyphonic
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Strong Parameters は使用せず、直接 params を参照して柔軟にデータを受け取る
    # (特に initial_context のような複雑なネスト構造のため)
    raw_params = params.require(:generate_polyphonic)
    job_id = raw_params[:job_id]
    broadcast_start(job_id)

    # --- 1. データ準備 ---

    # 初期文脈: [[[oct, note, vol, bri, hrd, tex], ...], ...]
    initial_context = raw_params[:initial_context]
    initial_context ||= []

    stream_counts = raw_params[:stream_counts].map(&:to_i)
    steps_to_generate = stream_counts.length

    # 結果格納用 (初期文脈をコピー)
    results = initial_context.deep_dup

    # --- 2. 次元定義 (6次元) ---
    dimensions = [
      { key: 'octave', range: (0..10).to_a, is_float: false },
      { key: 'note',   range: (0..11).to_a, is_float: false },
      { key: 'vol',    range: (0..10).map { |i| (i / 10.0).round(1) }, is_float: true },
      { key: 'bri',    range: (0..10).map { |i| (i / 10.0).round(1) }, is_float: true },
      { key: 'hrd',    range: (0..10).map { |i| (i / 10.0).round(1) }, is_float: true },
      { key: 'tex',    range: (0..10).map { |i| (i / 10.0).round(1) }, is_float: true }
    ]

    # 次元ごとにマネージャセット(Global + Stream)を初期化
    managers = {}
    merge_threshold_ratio = 0.1
    min_window = 2

    dimensions.each do |dim|
      # その次元の履歴データだけを抽出してマネージャを作る
      # results は [[stream1_vec, stream2_vec], ...]
      # stream1_vec は [oct, note, vol, ...]
      dim_history = results.map do |step_streams|
        step_streams.map { |s| s[dimensions.index(dim)] }
      end

      # 足りない文脈の補完 (最低3ステップ)
      if dim_history.length < min_window + 1
        last_val = dim_history.last || Array.new(stream_counts.first, dim[:range].first)
        (min_window + 1 - dim_history.length).times { dim_history << last_val.dup }
      end

      managers[dim[:key]] = initialize_managers_for_dimension(dim_history, merge_threshold_ratio, min_window)
    end

    # --- 3. 生成ループ (Time Step) ---
    steps_to_generate.times do |step_idx|
      current_stream_count = stream_counts[step_idx]

      # このステップの全ストリームの値を格納する配列 (初期化)
      # current_step_values[stream_idx] = [oct, note, vol, ...]
      current_step_values = Array.new(current_stream_count) { [] }

      # --- 4. 次元ループ (Dimension) ---
      dimensions.each_with_index do |dim, dim_idx|
        key = dim[:key]
        mgrs = managers[key]

        # パラメータ取得
        p_global = (raw_params["#{key}_global"] || [])[step_idx].to_f
        p_ratio  = (raw_params["#{key}_ratio"]  || [])[step_idx].to_f
        p_tight  = (raw_params["#{key}_tightness"] || [])[step_idx].to_f
        p_conc   = (raw_params["#{key}_conc"]   || [])[step_idx].to_f

        # ターゲット生成 (Method B: バイポーラ)
        stream_targets = generate_bipolar_targets(current_stream_count, p_ratio, p_tight)

        # 候補生成 (重複組み合わせ 11Hn)
        candidates_set = dim[:range].repeated_combination(current_stream_count).to_a

        # 事前計算
        q_array = create_quadratic_integer_array(0, 7 * (results.length + 1), results.length + 1)
        stream_costs = mgrs[:stream].precalculate_costs(dim[:range], q_array)

        # ベスト候補の選択
        best_chord = select_best_chord_for_dimension(
          mgrs, candidates_set, stream_costs, q_array,
          p_global, stream_targets, p_conc,
          current_stream_count,
          dim[:range]
        )

        # 結果を保存 & マネージャ更新
        mgrs[:global].add_data_point_permanently(best_chord)
        mgrs[:global].update_caches_permanently(q_array)

        mgrs[:stream].commit_state(best_chord, q_array)
        mgrs[:stream].update_caches_permanently(q_array)

        # 現在のステップのデータに、決定した次元の値を追加
        best_chord.each_with_index do |val, s_i|
          current_step_values[s_i] << val
        end
      end

      # ステップ完了、結果に追加
      results << current_step_values

      broadcast_progress(job_id, step_idx + 1, steps_to_generate)
    end

    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    broadcast_done(job_id)

    render json: {
      timeSeries: results,
      processingTime: ((end_time - start_time)).round(2)
    }
  end

  private

  # --- 次元ごとのマネージャ初期化 ---
  def initialize_managers_for_dimension(history, ratio, min_window)
    # Global
    g_mgr = PolyphonicClusterManager.new(history.dup, ratio, min_window)
    g_mgr.process_data
    g_clusters = g_mgr.transform_clusters(g_mgr.clusters, min_window)
    initial_calc_values(g_mgr, g_clusters, 7, 0, history.length)
    g_mgr.updated_cluster_ids_per_window_for_calculate_distance = {}

    # Stream
    s_mgr = MultiStreamManager.new(history, ratio, min_window)
    s_mgr.initialize_caches

    { global: g_mgr, stream: s_mgr }
  end

  # --- ターゲット生成 (バイポーラ方式) ---
  def generate_bipolar_targets(n, ratio, tightness)
    complex_count = (n * ratio).round
    simple_count = n - complex_count
    targets = []

    complex_count.times do
      noise = (1.0 - tightness) * 0.5 * rand
      targets << (1.0 - noise).clamp(0.0, 1.0)
    end

    simple_count.times do
      noise = (1.0 - tightness) * 0.5 * rand
      targets << (0.0 + noise).clamp(0.0, 1.0)
    end

    targets.sort
  end

  # --- 候補選択ロジック (次元共通) ---
  def select_best_chord_for_dimension(mgrs, candidates, stream_costs, q_array, global_target, stream_targets, concordance_weight, n, range_def)
    indexed_metrics = []

    candidates.each_with_index do |cand_set, idx|
      # 1. マッピング解決 (Method B)
      best_ordered_cand, stream_metric = mgrs[:stream].resolve_mapping_and_score(cand_set, stream_costs)

      # 2. 全体評価 (Method A)
      g_dist, g_qty, g_comp = mgrs[:global].simulate_add_and_calculate(best_ordered_cand, q_array, mgrs[:global])

      # 3. 不一致度 (Method C)
      min_val = range_def.first
      max_val = range_def.last
      range_width = (max_val - min_val).to_f
      range_width = 1.0 if range_width == 0

      vals = best_ordered_cand
      discordance = (vals.max - vals.min).to_f / range_width

      indexed_metrics << {
        index: idx,
        ordered_cand: best_ordered_cand,
        global_dist: g_dist,
        global_qty: g_qty,
        global_comp: g_comp,
        stream_scores: stream_metric[:individual_scores],
        discordance: discordance
      }
    end

    best_idx = select_best_polyphonic_candidate_unified(
      indexed_metrics,
      global_target,
      stream_targets,
      concordance_weight
    )

    indexed_metrics[best_idx][:ordered_cand]
  end

  # --- 統合コスト計算 (正規化込み) ---
  def select_best_polyphonic_candidate_unified(metrics, global_target, stream_targets, concordance_weight)
    best_idx = nil
    min_total_cost = Float::INFINITY

    g_dists, _ = normalize_scores(metrics.map { |m| m[:global_dist] }, true)
    g_qtys, _  = normalize_scores(metrics.map { |m| m[:global_qty] }, false)
    g_comps, _ = normalize_scores(metrics.map { |m| m[:global_comp] }, true)

    metrics.each_with_index do |m, i|
      current_global = (g_dists[i] + g_qtys[i] + g_comps[i]) / 3.0
      cost_a = (current_global - global_target).abs

      cost_b = 0.0
      m[:stream_scores].each_with_index do |score, s_idx|
        # 個別スコアの簡易正規化
        raw_comp = score[:dist]
        s_comp = raw_comp > 1.0 ? 1.0 : raw_comp
        if raw_comp > 1.0
           s_comp = (raw_comp / 7.0).clamp(0.0, 1.0)
        end

        target = stream_targets[s_idx]
        cost_b += (s_comp - target).abs
      end
      cost_b /= stream_targets.size.to_f

      if concordance_weight < 0
        cost_c = 0.0
      else
        cost_c = m[:discordance] * concordance_weight
      end

      total = cost_a + cost_b + cost_c

      if total < min_total_cost
        min_total_cost = total
        best_idx = m[:index]
      end
    end

    best_idx
  end

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
            # ★修正: managerに委譲してポリフォニック対応
            cache[key] = manager.euclidean_distance(as1, as2)
          end
        end
      end

      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}
      c_cache = manager.cluster_complexity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        if cluster && cluster[:si].length > 1
          quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
          q_cache[cid] = quantity

          comp = manager.calculate_cluster_complexity(cluster)
          c_cache[cid] = comp
        end
      end
    end
  end

  def update_caches_permanently(manager, min_window_size, quadratic_integer_array)
    clusters_each_window_size = manager.transform_clusters(manager.clusters, min_window_size)

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
            # ★修正: managerに委譲
            cache[key] = manager.euclidean_distance(as1, as2)
          end
        end
      end

      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}
      c_cache = manager.cluster_complexity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        if cluster && cluster[:si].length > 1
          quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
          q_cache[cid] = quantity

          comp = manager.calculate_cluster_complexity(cluster)
          c_cache[cid] = comp
        end
      end
    end

    manager.updated_cluster_ids_per_window_for_calculate_distance = {}
    manager.updated_cluster_ids_per_window_for_calculate_quantities = {}
  end

  def normalize_scores(raw_values, is_complex_when_larger)
    min_val = raw_values.min
    max_val = raw_values.max

    unique_count = raw_values.uniq.size
    weight = if unique_count <= 1 then 0.0
             elsif unique_count == 2 then 0.2
             else 1.0 end

    normalized = if min_val == max_val
                   Array.new(raw_values.size, 0.5)
                 else
                   raw_values.map { |v| (v - min_val).to_f / (max_val - min_val) }
                 end

    normalized.map! do |v|
      val = is_complex_when_larger ? v : 1.0 - v
      val * weight
    end

    return normalized, weight
  end

  def find_complex_candidate_by_value(criteria, target_val)
    candidates_score = Hash.new(0.0)
    total_weight = 0.0

    criteria.each do |criterion|
      raw_values = criterion[:data].map { |v| v[0] }
      scores, weight = normalize_scores(raw_values, criterion[:is_complex_when_larger])

      criterion[:data].each_with_index do |(_, index), i|
        candidates_score[index] += scores[i]
      end
      total_weight += weight
    end

    if total_weight > 0
      candidates_score.each_key { |k| candidates_score[k] /= total_weight }
    end

    best_index = nil
    min_diff = Float::INFINITY
    candidates_score.each do |index, score|
      diff = (score - target_val).abs
      if diff < min_diff
        min_diff = diff
        best_index = index
      end
    end

    best_index
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

  def polyphonic_params
    keys = []
    %w[octave note vol bri hrd tex].each do |dim|
      keys << "#{dim}_global"
      keys << "#{dim}_ratio"
      keys << "#{dim}_tightness"
      keys << "#{dim}_conc"
    end

    # Fix: Construct array of permitted args to avoid syntax error
    permitted_args = [
      :job_id,
      { stream_counts: [] },
      { initial_context: {} }
    ]
    permitted_args.concat(keys.map { |k| { k => [] } })

    params.require(:generate_polyphonic).permit(*permitted_args)
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
