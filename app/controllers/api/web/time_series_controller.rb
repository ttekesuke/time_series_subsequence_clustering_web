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
  #  多声生成アクション (Method A + B + C)
  # ============================================================
# ============================================================
  #  多声生成アクション (Method A + B + C)
  # ============================================================
  def generate_polyphonic
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    raw_params = params.require(:generate_polyphonic)
    job_id = raw_params[:job_id]
    broadcast_start(job_id)

    # --- 1. パラメータの準備 ---

    target_continuations = raw_params[:target_continuations].map(&:to_f)
    stream_counts = raw_params[:stream_counts].map(&:to_i)
    global_complexities = raw_params[:global_complexity].map(&:to_f)

    stream_centers = raw_params[:stream_complexity_center].map(&:to_f)
    group_counts   = raw_params[:complexity_group_count].map(&:to_i)
    diversities    = raw_params[:complexity_diversity].map(&:to_f)
    concordances   = raw_params[:group_concordance].map(&:to_f)

    initial_octaves_history = raw_params[:initial_octaves]
    initial_octaves_history = initial_octaves_history.map { |chord| chord.is_a?(Array) ? chord.map(&:to_i) : [] }

    min_window_size = 2
    if initial_octaves_history.length < min_window_size + 1
      last_val = initial_octaves_history.last || [0]
      (min_window_size + 1 - initial_octaves_history.length).times { initial_octaves_history << last_val.dup }
    end

    results = initial_octaves_history.dup
    merge_threshold_ratio = 0.1

    # --- 2. マネージャの初期化 ---

    global_manager = PolyphonicClusterManager.new(results.dup, merge_threshold_ratio, min_window_size)
    global_manager.process_data

    initial_stream_count = results.last.size
    stream_manager = MultiStreamManager.new(results, merge_threshold_ratio, min_window_size)

    # キャッシュの初期構築
    g_clusters = global_manager.transform_clusters(global_manager.clusters, min_window_size)
    initial_calc_values(global_manager, g_clusters, 7, 0, results.length)
    global_manager.updated_cluster_ids_per_window_for_calculate_distance = {}

    stream_manager.initialize_caches

    # --- 3. 生成ループ ---
    candidate_range = (0..7).to_a

    target_continuations.each_with_index do |target_cont, index|
      n = stream_counts[index] || results.last.size

      global_target = global_complexities[index] || global_complexities.last
      center        = stream_centers[index]      || stream_centers.last
      groups        = group_counts[index]        || group_counts.last
      diversity     = diversities[index]         || diversities.last
      concordance   = concordances[index]        || concordances.last

      stream_targets = generate_stream_complexities(n, center, groups, diversity)

      current_len = results.length + 1
      quadratic_integer_array = create_quadratic_integer_array(0, 7 * current_len, current_len)
      stream_costs = stream_manager.precalculate_costs(candidate_range, quadratic_integer_array)

      # 候補生成: 組み合わせ (8Cn)
      candidates_set = candidate_range.combination(n).to_a

      indexed_metrics = []

      candidates_set.each_with_index do |cand_set, idx|
        # Step 1: マッピング解決
        best_ordered_cand, stream_metric = stream_manager.resolve_mapping_and_score(cand_set, stream_costs)

        # Step 2: Method A シミュレーション
        # global_comp (内部複雑度) も受け取る
        global_dist, global_qty, global_comp = global_manager.simulate_add_and_calculate(best_ordered_cand, quadratic_integer_array, global_manager)

        # Step 3: Method C 評価
        discordance = calculate_group_discordance(best_ordered_cand, n, groups)

        indexed_metrics << {
          index: idx,
          ordered_cand: best_ordered_cand,
          global_dist: global_dist,
          global_qty: global_qty,
          global_comp: global_comp,
          stream_scores: stream_metric[:individual_scores],
          discordance: discordance
        }
      end

      # Step 4: ベスト候補の選択
      best_candidate_index = select_best_polyphonic_candidate(
        indexed_metrics,
        global_target,
        stream_targets,
        concordance
      )

      final_chord = indexed_metrics[best_candidate_index][:ordered_cand]

      # Step 5: 確定と更新
      results << final_chord

      # Global更新 (忘却処理は削除)
      global_manager.add_data_point_permanently(final_chord)
      update_caches_permanently(global_manager, min_window_size, quadratic_integer_array)

      # Stream更新
      stream_manager.commit_state(final_chord, quadratic_integer_array)
      stream_manager.update_caches_permanently(quadratic_integer_array)

      broadcast_progress(job_id, index + 1, target_continuations.length)
    end

    timeline = global_manager.clusters_to_timeline(global_manager.clusters, min_window_size)
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    broadcast_done(job_id)

    render json: {
      clusteredSubsequences: timeline,
      timeSeries: results,
      clusters: global_manager.clusters,
      processingTime: ((end_time - start_time)).round(2)
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
            # ★修正: manager.euclidean_distance を呼ぶように変更
            # (Polyphonicならベクトルの距離、Monophonicならスカラーの距離が自動で選ばれる)
            cache[key] = manager.euclidean_distance(as1, as2)
          end
        end
      end

      # 数量 & 内部複雑度
      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}
      c_cache = manager.cluster_complexity_cache[window_size] ||= {} # 新規

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        if cluster && cluster[:si].length > 1
          # 数量
          quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
          q_cache[cid] = quantity

          # 内部複雑度
          complexity = manager.calculate_cluster_complexity(cluster)
          c_cache[cid] = complexity
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
            # ★修正: manager.euclidean_distance を呼ぶように変更
            cache[key] = manager.euclidean_distance(as1, as2)
          end
        end
      end

      # 数量 & 内部複雑度
      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}
      c_cache = manager.cluster_complexity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        if cluster && cluster[:si].length > 1
          quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
          q_cache[cid] = quantity

          complexity = manager.calculate_cluster_complexity(cluster)
          c_cache[cid] = complexity
        end
      end
    end

    manager.updated_cluster_ids_per_window_for_calculate_distance = {}
    manager.updated_cluster_ids_per_window_for_calculate_quantities = {}
  end

  # 共通部品: スコア正規化と重み付け
  def normalize_scores(raw_values, is_complex_when_larger)
    min_val = raw_values.min
    max_val = raw_values.max

    unique_count = raw_values.uniq.size
    weight = if unique_count <= 1
               0.0
             elsif unique_count == 2
               0.2
             else
               1.0
             end

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

  # 値ベースの選択ロジック
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
      result << (start_val < end_val ? value.ceil + 1 : value.floor + 1)
    end
    result
  end

  # Strong Parameters 等
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
# Method B: ターゲット生成
  def generate_stream_complexities(n, center, groups, diversity)
    poles = []
    if groups <= 1
      poles = [center]
    else
      half_width = diversity / 2.0
      min_val = (center - half_width).clamp(0.0, 1.0)
      max_val = (center + half_width).clamp(0.0, 1.0)
      if min_val == max_val
        poles = Array.new(groups, min_val)
      else
        step = (max_val - min_val) / (groups - 1).to_f
        groups.times { |i| poles << min_val + (step * i) }
      end
    end

    targets = []
    n.times do |i|
      group_index = (i * groups / n.to_f).floor
      group_index = [group_index, groups - 1].min
      targets << poles[group_index]
    end
    targets
  end

  # Method C: グループ内不一致度 (Discordance)
  def calculate_group_discordance(chord, n, groups)
    return 0.0 if groups == n
    total_diff = 0.0

    groups.times do |g_idx|
      notes_in_group = []
      n.times do |i|
        my_group = (i * groups / n.to_f).floor
        my_group = [my_group, groups - 1].min
        notes_in_group << chord[i] if my_group == g_idx
      end

      if notes_in_group.size > 1
        # 最大-最小 をオクターブ幅(7.0)で正規化
        diff = (notes_in_group.max - notes_in_group.min).to_f / 7.0
        total_diff += diff
      end
    end
    total_diff / groups.to_f
  end

  # 統合コスト計算
  def select_best_polyphonic_candidate(metrics, global_target, stream_targets, concordance_weight)
    best_idx = nil
    min_total_cost = Float::INFINITY

    # Global指標の正規化 (Dist, Qty, Comp)
    g_dists = normalize_values(metrics.map { |m| m[:global_dist] }, true)
    g_qtys  = normalize_values(metrics.map { |m| m[:global_qty] }, false)
    g_comps = normalize_values(metrics.map { |m| m[:global_comp] }, true)

    # Stream指標の正規化 (Dist, Qty, Comp) - 全ストリーム分をフラットにして正規化範囲を決めるべきだが
    # ここでは候補ごとの平均的なスコアを使う簡易実装とする
    # より厳密には、各ストリームごとの生の値を正規化する必要がある

    metrics.each_with_index do |m, i|
      p 'loop'
      pp m
      # Cost A: Global
      # 3つの指標の平均を Global Complexity とする
      current_global = (g_dists[i] + g_qtys[i] + g_comps[i]) / 3.0
      cost_a = (current_global - global_target).abs

      # Cost B: Stream
      cost_b = 0.0
      m[:stream_scores].each_with_index do |score, s_idx|
        # 個別のスコアを正規化 (簡易的に距離ベース 0~7 -> 0~1)
        # ※本来はここも全体分布から正規化すべき
        s_comp = (score[:dist] / 7.0).clamp(0.0, 1.0)
        target = stream_targets[s_idx]
        cost_b += (s_comp - target).abs
      end
      cost_b /= stream_targets.size.to_f

      # Cost C: Concordance
      # concordance_weightが高いほど、不一致(discordance)を許さない
      cost_c = m[:discordance] * concordance_weight

      p cost_a
      p cost_b
      p cost_c
      total = cost_a + cost_b + cost_c

      if total < min_total_cost
        min_total_cost = total
        best_idx = m[:index]
      end
    end

    best_idx
  end

  # 簡易正規化ヘルパー
  def normalize_values(values, is_complex_when_larger)
    min_v = values.min
    max_v = values.max
    return Array.new(values.size, 0.5) if min_v == max_v

    values.map do |v|
      norm = (v - min_v).to_f / (max_v - min_v)
      is_complex_when_larger ? norm : 1.0 - norm
    end
  end

  def polyphonic_params
    params.require(:generate_polyphonic).permit(
      :job_id,
      global_complexity: [],
      stream_complexity_center: [],
      complexity_group_count: [],
      complexity_diversity: [],
      group_concordance: [],
      target_continuations: [], # 念のため
      stream_counts: [],
      initial_octaves: {} # 配列の配列
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
