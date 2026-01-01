# frozen_string_literal: true

require 'set'

class Api::Web::TimeSeriesController < ApplicationController
  include DissonanceMemory
  include StatisticsCalculator
  include PolyphonicConfig

  DIM_INDEX = {
    'octave' => 0,
    'note'   => 1,
    'vol'    => 2,
    'bri'    => 3,
    'hrd'    => 4,
    'tex'    => 5
  }.freeze

  # ============================================================
  # Analyse
  # ============================================================
  def analyse
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    job_id = analyse_params[:job_id]
    broadcast_start(job_id)

    data = analyse_params[:time_series]
    merge_threshold_ratio = analyse_params[:merge_threshold_ratio].to_d
    calculate_distance_when_added_subsequence_to_cluster = true
    min_window_size = 2

    manager = TimeSeriesClusterManager.new(
      data,
      merge_threshold_ratio,
      min_window_size,
      calculate_distance_when_added_subsequence_to_cluster
    )
    manager.process_data

    timeline = manager.clusters_to_timeline(manager.clusters, min_window_size)
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    processing_time_s = (end_time - start_time).round(2)

    broadcast_done(job_id)
    render json: {
      clusteredSubsequences: timeline,
      timeSeries: data,
      clusters: manager.clusters,
      processingTime: processing_time_s
    }
  end

  # ============================================================
  # generate (単音)
  # ============================================================
  def generate
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    job_id = generate_params[:job_id]
    broadcast_start(job_id)

    user_set_results = generate_params[:first_elements].split(',').map(&:to_i)

    complexity_transition_int =
    complexity_targets = generate_params[:complexity_transition].split(',').map(&:to_f)

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

    if selected_use_musical_feature.present? && selected_use_musical_feature == 'dissonancesOutline'
      dissonance_transition = generate_params[:dissonance][:transition].split(',').map(&:to_i)
      dissonance_duration_transition = generate_params[:dissonance][:duration_transition].split(',').map(&:to_i)
      dissonance_range = generate_params[:dissonance][:range].to_i
    end
    if selected_use_musical_feature.present? && selected_use_musical_feature == 'durationsOutline'
      duration_outline_transition = generate_params[:duration][:outline_transition].split(',').map(&:to_i)
      duration_outline_range = generate_params[:duration][:outline_range].to_i
    end

    manager = TimeSeriesClusterManager.new(
      user_set_results.dup,
      merge_threshold_ratio,
      min_window_size,
      calculate_distance_when_added_subsequence_to_cluster
    )

    user_set_results.each_with_index do |elm, data_index|
      next unless selected_use_musical_feature == 'dissonancesOutline'
      duration = dissonance_duration_transition[data_index]
      dissonance_current_time += duration * time_unit.to_d
      dissonance, dissonance_short_term_memory = STMStateless.process([elm], dissonance_current_time, dissonance_short_term_memory)
      dissonance_results << dissonance
    end

    manager.process_data

    clusters_each_window_size = manager.transform_clusters(manager.clusters, min_window_size)
    initial_calc_values(manager, clusters_each_window_size, candidate_max_master, candidate_min_master, user_set_results.length)

    manager.updated_cluster_ids_per_window_for_calculate_distance = {}

    results = user_set_results.dup

    complexity_targets.each_with_index do |target_val, rank_index|
      candidates = (candidate_min_master..candidate_max_master).to_a
      current_dissonance_short_term_memory = dissonance_short_term_memory.dup
      in_range = []

      if selected_use_musical_feature == 'dissonancesOutline'
        dissonance_current_time += dissonance_duration_transition[rank_index] * time_unit.to_d
        dissonance_rank = dissonance_transition[rank_index]
        results_in_candidates = candidates.map do |note|
          dissonance, memory = STMStateless.process([note], dissonance_current_time, current_dissonance_short_term_memory)
          { dissonance: dissonance, memory: memory, note: note }
        end
        from = [dissonance_rank - dissonance_range, 0].max
        to = [dissonance_rank + dissonance_range, results_in_candidates.size - 1].min
        sorted = results_in_candidates.sort_by { |r| r[:dissonance] }
        in_range = sorted[from..to]
        candidates = in_range.map { |r| r[:note] }
      elsif selected_use_musical_feature == 'durationsOutline'
        duration_outline_rank = duration_outline_transition[rank_index]
        from = [duration_outline_rank - duration_outline_range, 0].max
        to = [duration_outline_rank + duration_outline_range, candidates.size - 1].min
        candidates = candidates[from..to]
      end

      indexed_metrics = []
      current_len = results.length + 1
      quadratic_integer_array = create_quadratic_integer_array(0, (candidate_max_master - candidate_min_master) * current_len, current_len)

      candidates.each_with_index do |candidate, idx|
        avg_dist, quantity, complexity = manager.simulate_add_and_calculate(candidate, quadratic_integer_array, self)
        indexed_metrics << { index: idx, dist: avg_dist, quantity: quantity, complexity: complexity }
      end

      criteria = [
        { is_complex_when_larger: true,  data: indexed_metrics.map { |m| [m[:dist], m[:index]] } },
        { is_complex_when_larger: false, data: indexed_metrics.map { |m| [m[:quantity], m[:index]] } },
        { is_complex_when_larger: true,  data: indexed_metrics.map { |m| [m[:complexity], m[:index]] } }
      ]

      result_index = find_complex_candidate_by_value(criteria, target_val)
      result = candidates[result_index]

      results << result
      manager.add_data_point_permanently(result)

      update_caches_permanently(manager, min_window_size, quadratic_integer_array)

      if selected_use_musical_feature == 'dissonancesOutline'
        best = in_range.find { |r| r[:note] == result }
        dissonance_short_term_memory = best[:memory]
        dissonance_results << best[:dissonance]
      end

      broadcast_progress(job_id, rank_index + 1, complexity_targets.length)
    end

    timeline = manager.clusters_to_timeline(manager.clusters, min_window_size)
    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    processing_time_s = (end_time - start_time).round(2)

    broadcast_done(job_id)

    render json: {
      clusteredSubsequences: timeline,
      timeSeries: results,
      complexityTransition: user_set_results.map { nil } + complexity_transition_int,
      clusters: manager.clusters,
      processingTime: processing_time_s
    }
  end

  # ============================================================
  # generate_polyphonic (多声)
  #   生成順序（確定）:
  #     1) vol
  #     2) octave
  #     3) chord_size
  #     4) timbre(bri, hrd, tex)
  #     5) note（12Ck + STM dissonanceで集合 -> shiftでroot配置）
  # ============================================================
  def generate_polyphonic
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    raw = polyphonic_params
    job_id = raw['job_id']
    broadcast_start(job_id)

    initial_context   = raw['initial_context'] || []
    stream_counts     = (raw['stream_counts'] || []).map(&:to_i)
    steps_to_generate = stream_counts.length

    strength_targets   = (raw['stream_strength_target'] || []).map(&:to_f)
    strength_spreads   = (raw['stream_strength_spread'] || []).map(&:to_f)
    dissonance_targets = (raw['dissonance_target'] || []).map(&:to_f)

    # ============================================================
    # results: [step][stream][6] = [oct, notePCS(Array), vol, bri, hrd, tex]
    # ★重要: note を常に配列化しておく（initial_contextも含む）
    # ============================================================
    results = deep_dup(initial_context)

    note_idx = 1
    oct_idx  = 0
    vol_idx  = 2
    bri_idx  = 3
    hrd_idx  = 4
    tex_idx  = 5

    normalize_pcs = ->(v) do
      pcs = v.is_a?(Array) ? v : [v]
      pcs = pcs.compact.map { |x| x.to_i % 12 }
      pcs = [0] if pcs.empty?
      pcs
    end

    results.each do |step_streams|
      next if step_streams.nil?
      step_streams.each do |vec|
        next if vec.nil? || !vec.is_a?(Array)
        vec[note_idx] = normalize_pcs.call(vec[note_idx])
      end
    end

    base_step_index = results.length  # ★fix: onset基準

    chord_sizes_timeline = []   # [generatedStep][stream] = chord_size
    # note_chords_pitch_classes は廃止（timeSeries.note に入れる）

    # 次元順（確定）
    dimension_order = %w[vol octave chord_size bri hrd tex note]

    dim_defs = {
      'octave' => { key: 'octave', range: PolyphonicConfig::OCTAVE_RANGE.to_a, is_float: false, idx_in_result: 0 },
      # ★noteは idx 1 だが、中身は配列（pcs）
      'note'   => { key: 'note',   range: PolyphonicConfig::NOTE_RANGE.to_a,   is_float: false, idx_in_result: 1 },
      'vol'    => { key: 'vol',    range: PolyphonicConfig::FLOAT_STEPS,       is_float: true,  idx_in_result: 2 },
      'bri'    => { key: 'bri',    range: PolyphonicConfig::FLOAT_STEPS,       is_float: true,  idx_in_result: 3 },
      'hrd'    => { key: 'hrd',    range: PolyphonicConfig::FLOAT_STEPS,       is_float: true,  idx_in_result: 4 },
      'tex'    => { key: 'tex',    range: PolyphonicConfig::FLOAT_STEPS,       is_float: true,  idx_in_result: 5 },
      'chord_size' => {
        key: 'chord_size',
        range: PolyphonicConfig::CHORD_SIZE_RANGE.to_a,
        is_float: false,
        idx_in_result: nil
      }
    }

    # --- managers 初期化 ---
    managers = {}
    merge_threshold_ratio = 0.1
    min_window = 2
    max_simultaneous_notes = PolyphonicConfig::CHORD_SIZE_RANGE.max.to_i

    %w[octave note vol bri hrd tex].each do |key|
      dim = dim_defs[key]

      dim_history =
        if key == 'note'
          # ★noteは配列なので、クラスタリング用履歴は root（pcs.first）で作る
          results.map do |step_streams|
            (step_streams || []).map do |s|
              pcs = normalize_pcs.call(s[dim[:idx_in_result]])
              pcs.first
            end
          end
        else
          results.map do |step_streams|
            (step_streams || []).map { |s| s[dim[:idx_in_result]] }
          end
        end

      if dim_history.length < min_window + 1
        last_val = dim_history.last || Array.new(stream_counts.first || 1, dim[:range].first)
        (min_window + 1 - dim_history.length).times { dim_history << deep_dup(last_val) }
      end

      managers[key] = initialize_managers_for_dimension(
        dim_history,
        merge_threshold_ratio,
        min_window,
        dim[:range],
        max_simultaneous_notes: max_simultaneous_notes
      )
    end

    # chord_size の履歴（initial_context の notePCS 配列長を使えるなら使う）
    chord_history = results.map do |step_streams|
      (step_streams || []).map do |s|
        pcs = normalize_pcs.call(s[note_idx])
        cs = pcs.length
        cs = 1 if cs < 1
        cs
      end
    end
    if chord_history.length < min_window + 1
      last = chord_history.last || Array.new(stream_counts.first || 1, 1)
      (min_window + 1 - chord_history.length).times { chord_history << deep_dup(last) }
    end
    managers['chord_size'] = initialize_managers_for_dimension(
      chord_history,
      merge_threshold_ratio,
      min_window,
      dim_defs['chord_size'][:range],
      max_simultaneous_notes: max_simultaneous_notes
    )

    # --- STM manager ---
    stm_mgr = DissonanceStmManager.new(
      memory_span: 1.5,
      memory_weight: 1.0,
      n_partials: 8,
      amp_profile: 0.88
    )

    # initial_context を STM に投入（★notePCS配列として扱う）
    step_duration = 0.25
    results.each_with_index do |step_streams, i|
      next if step_streams.nil? || step_streams.empty?

      midi_notes = []
      amps = []

      step_streams.each do |s|
        oct = s[oct_idx].to_i
        pcs = normalize_pcs.call(s[note_idx])     # 配列
        vol = s[vol_idx].to_f

        base_c_midi = (oct + 1) * 12
        a_each = vol / pcs.length.to_f

        pcs.each do |pc|
          midi_notes << (base_c_midi + (pc.to_i % 12))
          amps << a_each
        end
      end

      onset = i.to_f * step_duration
      stm_mgr.commit!(midi_notes, amps, onset)
    end

    # --- 生成ループ ---
    steps_to_generate.times do |step_idx|
      current_stream_count = stream_counts[step_idx].to_i
      current_stream_count = 1 if current_stream_count <= 0

      current_step_values = Array.new(current_stream_count) { Array.new(6) }
      step_decisions = {}

      dimension_order.each do |key|
        dim  = dim_defs[key]
        mgrs = managers[key]

        global_target = array_param(raw, "#{key}_global", step_idx).to_f
        stream_center = array_param(raw, "#{key}_center", step_idx).to_f
        stream_spread = array_param(raw, "#{key}_spread", step_idx).to_f
        concord_w     = array_param(raw, "#{key}_conc", step_idx).to_f

        stream_targets = generate_centered_targets(current_stream_count, stream_center, stream_spread)

        value_min = dim[:range].min.to_f
        value_max = dim[:range].max.to_f
        current_len = mgrs[:global].data.length + 1
        q_array = create_quadratic_integer_array(value_min, value_max, current_len)

        stream_costs = mgrs[:stream].precalculate_costs(dim[:range], q_array)
        mgrs[:stream].update_strengths! if key == 'vol'

        # ============================================================
        # note 特別処理：結果は notePCS(Array) を timeSeries に入れる
        # ============================================================
        if key == 'note'
          chord_sizes = step_decisions.fetch('chord_size')
          octaves     = step_decisions.fetch('octave')
          vols        = step_decisions.fetch('vol')

          k = chord_sizes.max.to_i
          k = 1 if k < 1
          k = 12 if k > 12

          pitch_classes = (0..11).to_a
          onset = (base_step_index + step_idx).to_f * step_duration
          target01 = (dissonance_targets[step_idx] || 0.5).to_f.clamp(0.0, 1.0)

          combos = pitch_classes.combination(k).to_a

          rough_list = []
          ordered_list_for_combo = []

          combos.each do |combo|
            ordered = stm_mgr.order_pitch_classes_by_contribution(
              combo,
              octaves: octaves,
              vols: vols,
              onset: onset
            )

            chords_pcs = chord_sizes.each_with_index.map do |cs, s|
              cs = cs.to_i
              cs = 1 if cs < 1
              cs = ordered.length if cs > ordered.length
              ordered.first(cs)
            end

            midi_notes = []
            amps = []
            chords_pcs.each_with_index do |pcs, s|
              base_c_midi = (octaves[s].to_i + 1) * 12
              a_each = vols[s].to_f / pcs.length.to_f
              pcs.each do |pc|
                midi_notes << (base_c_midi + pc.to_i)
                amps << a_each
              end
            end

            d = stm_mgr.evaluate(midi_notes, amps, onset).to_f
            rough_list << d
            ordered_list_for_combo << ordered
          end

          min_d = rough_list.min
          max_d = rough_list.max
          span = (max_d - min_d)
          span = 1.0 if span == 0.0

          best_i = 0
          best_cost = Float::INFINITY
          rough_list.each_with_index do |d, i|
            norm = (d - min_d) / span
            cost = (norm - target01).abs
            if cost < best_cost
              best_cost = cost
              best_i = i
            end
          end

          best_ordered = ordered_list_for_combo[best_i]

          # A確定後だけ STM commit
          best_chords_pcs_for_commit = chord_sizes.each_with_index.map do |cs, s|
            cs = cs.to_i
            cs = 1 if cs < 1
            cs = best_ordered.length if cs > best_ordered.length
            best_ordered.first(cs)
          end

          midi_notes = []
          amps = []
          best_chords_pcs_for_commit.each_with_index do |pcs, s|
            base_c_midi = (octaves[s].to_i + 1) * 12
            a_each = vols[s].to_f / pcs.length.to_f
            pcs.each do |pc|
              midi_notes << (base_c_midi + pc.to_i)
              amps << a_each
            end
          end
          stm_mgr.commit!(midi_notes, amps, onset)

          # --- B) shift を試して root 配置（クラスタ評価用）は root で決める ---
          best_shift = 0
          best_root_chord = nil
          best_note_cost = Float::INFINITY

          max_note_candidates = (PolyphonicConfig::MAX_NOTE_CANDIDATES rescue 8000)

          absolute_bases = octaves.map { |o| (o.to_i + 1) * 12 }
          active_note_counts = chord_sizes.map(&:to_i)
          active_total_notes = active_note_counts.sum.to_i

          (0..11).each do |shift|
            allowed = best_ordered.map { |pc| (pc + shift) % 12 }.sort
            candidates_set = limited_repeated_combinations(allowed, current_stream_count, max_note_candidates)

            cand_root, cand_cost = select_best_chord_for_dimension_with_cost(
              mgrs,
              candidates_set,
              stream_costs,
              q_array,
              global_target,
              stream_targets,
              concord_w,
              current_stream_count,
              { min: 0, max: 11 },
              absolute_bases: absolute_bases,
              active_note_counts: active_note_counts,
              active_total_notes: active_total_notes,
              max_simultaneous_notes: max_simultaneous_notes
            )

            if cand_cost < best_note_cost
              best_note_cost = cand_cost
              best_root_chord = cand_root
              best_shift = shift
            end
          end

          # ★timeSeries に入れる chord pcs 配列を確定
          shifted_ordered = best_ordered.map { |pc| (pc + best_shift) % 12 }
          chords_for_streams = chord_sizes.each_with_index.map do |cs, s|
            cs = cs.to_i
            cs = 1 if cs < 1
            cs = shifted_ordered.length if cs > shifted_ordered.length
            shifted_ordered.first(cs)
          end

          # --- 内部クラスタリングは root（数値）で更新 ---
          mgrs[:global].add_data_point_permanently(best_root_chord)
          mgrs[:global].update_caches_permanently(q_array)
          mgrs[:stream].commit_state(best_root_chord, q_array)
          mgrs[:stream].update_caches_permanently(q_array)

          # --- ★出力 timeSeries の note スロットには chord pcs 配列を入れる ---
          chords_for_streams.each_with_index do |pcs, s_i|
            current_step_values[s_i][note_idx] = pcs.map { |pc| pc.to_i % 12 }
          end

          # root は step_decisions に残す（後段で使う可能性があるなら）
          step_decisions[key] = best_root_chord
          next
        end

        # ============================================================
        # note 以外：従来枠組み（数値）
        # ============================================================
        candidates_set = dim[:range].repeated_combination(current_stream_count).to_a

        cand_chord, _cost = select_best_chord_for_dimension_with_cost(
          mgrs,
          candidates_set,
          stream_costs,
          q_array,
          global_target,
          stream_targets,
          concord_w,
          current_stream_count,
          dim[:range],
          max_simultaneous_notes: max_simultaneous_notes
        )
        best_chord = cand_chord

        mgrs[:global].add_data_point_permanently(best_chord)
        mgrs[:global].update_caches_permanently(q_array)

        if key == 'vol'
          st_target = strength_targets[step_idx] || 0.5
          st_spread = strength_spreads[step_idx] || 0.0
          mgrs[:stream].commit_state(best_chord, q_array, strength_params: { target: st_target, spread: st_spread })
        else
          mgrs[:stream].commit_state(best_chord, q_array)
        end
        mgrs[:stream].update_caches_permanently(q_array)

        step_decisions[key] = best_chord

        if key == 'chord_size'
          chord_sizes_timeline << best_chord.map(&:to_i)
        else
          best_chord.each_with_index do |val, s_i|
            current_step_values[s_i][dim[:idx_in_result]] = val
          end
        end
      end

      # ★この時点で current_step_values[s][note] は配列、他は数値になっている
      results << current_step_values
      broadcast_progress(job_id, step_idx + 1, steps_to_generate)
    end

    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    broadcast_done(job_id)

    # === クラスタ情報 ===
    cluster_payload = {}
    %w[octave note vol bri hrd tex chord_size].each do |key|
      mgrs = managers[key]
      next unless mgrs

      g_mgr = mgrs[:global]
      s_mgr = mgrs[:stream]

      global_timeline = g_mgr.clusters_to_timeline(g_mgr.clusters, min_window)

      streams_hash = {}
      s_mgr.stream_pool.each do |container|
        stream_id = container.id
        s_mgr_for_stream = container.manager
        streams_hash[stream_id] = s_mgr_for_stream.clusters_to_timeline(s_mgr_for_stream.clusters, min_window)
      end

      cluster_payload[key] = { global: global_timeline, streams: streams_hash }
    end
    p results

    render json: {
      timeSeries: results,
      clusters: cluster_payload,
      processingTime: (end_time - start_time).round(2)
    }
  end


  private

  # ----------------------------
  # small utilities
  # ----------------------------
  def deep_dup(obj)
    Marshal.load(Marshal.dump(obj))
  rescue
    obj.is_a?(Array) ? obj.map { |e| deep_dup(e) } : obj
  end

  def array_param(raw, key, idx)
    arr = raw[key]
    return nil unless arr.is_a?(Array)
    arr[idx]
  end

  # 決定論で repeated_combination を「最大 limit 個まで」生成する（values昇順前提）
  def limited_repeated_combinations(values, n, limit)
    values = values.sort
    return [] if n <= 0
    return values.map { |v| [v] }.take(limit) if n == 1

    m = values.length
    idxs = Array.new(n, 0)
    out = []

    loop do
      out << idxs.map { |i| values[i] }
      break if out.length >= limit

      pos = n - 1
      while pos >= 0 && idxs[pos] == m - 1
        pos -= 1
      end
      break if pos < 0

      next_val = idxs[pos] + 1
      (pos...n).each { |k| idxs[k] = next_val }
    end

    out
  end

  # --- 次元ごとのマネージャ初期化 ---
  def initialize_managers_for_dimension(history, ratio, min_window, value_range, max_simultaneous_notes: PolyphonicConfig::CHORD_SIZE_RANGE.max)
    g_mgr = PolyphonicClusterManager.new(
      history.dup,
      ratio,
      min_window,
      value_range,
      max_set_size: max_simultaneous_notes
    )
    g_mgr.process_data
    g_clusters = g_mgr.transform_clusters(g_mgr.clusters, min_window)
    initial_calc_values(g_mgr, g_clusters, value_range.max.to_f, value_range.min.to_f, history.length)
    g_mgr.updated_cluster_ids_per_window_for_calculate_distance = {}

    s_mgr = MultiStreamManager.new(history, ratio, min_window)
    s_mgr.initialize_caches

    { global: g_mgr, stream: s_mgr }
  end

  # --- ターゲット生成（決定論） ---
  # spread: 0..1 を「分布の幅」として扱う（大きいほどstream間に差が出る）
  def generate_centered_targets(n, center, spread)
    return [] if n <= 0
    return [center.to_f.clamp(0.0, 1.0)] if n == 1

    center = center.to_f.clamp(0.0, 1.0)
    spread = spread.to_f.clamp(0.0, 1.0)

    half_width = spread / 2.0
    start_val = (center - half_width).clamp(0.0, 1.0)
    end_val   = (center + half_width).clamp(0.0, 1.0)

    targets = []
    (0...n).each do |i|
      t = i.to_f / (n - 1)
      targets << (start_val + (end_val - start_val) * t).clamp(0.0, 1.0)
    end
    targets
  end

  # ============================================================
  # 既存ロジック（cost付きラッパ） - FIX: hardcode "7" 제거
  # ============================================================
  def select_best_polyphonic_candidate_unified_with_cost(
    metrics,
    global_target,
    stream_targets,
    concordance_weight,
    stream_dist_max: 1.0 # ★追加：次元ごとの最大距離で正規化する
  )
    best_idx = nil
    min_total_cost = Float::INFINITY

    g_dists, _ = normalize_scores(metrics.map { |m| m[:global_dist] }, true)
    g_qtys, _  = normalize_scores(metrics.map { |m| m[:global_qty] }, false)
    g_comps, _ = normalize_scores(metrics.map { |m| m[:global_comp] }, true)

    # safety
    stream_dist_max = stream_dist_max.to_f
    stream_dist_max = 1.0 if stream_dist_max <= 0.0

    metrics.each_with_index do |m, i|
      current_global = (g_dists[i] + g_qtys[i] + g_comps[i]) / 3.0
      cost_a = (current_global - global_target.to_f).abs

      cost_b = 0.0
      if stream_targets.size > 0
        m[:stream_scores].each_with_index do |score, s_idx|
          raw_dist = score[:dist].to_f

          # ★FIX: 常に値域で 0..1 に正規化（raw_dist が 1 以下でも割る）
          dist01 = (raw_dist / stream_dist_max).clamp(0.0, 1.0)

          target = stream_targets[s_idx].to_f
          cost_b += (dist01 - target).abs
        end
        cost_b /= stream_targets.size.to_f
      end

      cost_c =
        if concordance_weight.to_f < 0
          0.0
        else
          m[:discordance].to_f * concordance_weight.to_f
        end

      total = cost_a + cost_b + cost_c
      if total < min_total_cost
        min_total_cost = total
        best_idx = m[:index]
      end
    end

    [best_idx, min_total_cost]
  end


  # range_def:
  #   Array(range) でも Hash{min,max} でもOK（note shift用の幅固定に使う）
  # range_def:
  #   Array(range) でも Hash{min,max} でもOK（note shift用の幅固定に使う）
  def select_best_chord_for_dimension_with_cost(
    mgrs,
    candidates,
    stream_costs,
    q_array,
    global_target,
    stream_targets,
    concordance_weight,
    n,
    range_def,
    absolute_bases: nil,
    active_note_counts: nil,
    active_total_notes: nil,
    max_simultaneous_notes: PolyphonicConfig::CHORD_SIZE_RANGE.max
  )
    indexed_metrics = []

    # -----------------------------
    # 密度（0..1）→ 所属判定の甘さ調整
    # -----------------------------
    max_simul = max_simultaneous_notes.to_i
    max_simul = 1 if max_simul <= 0

    total_notes = active_total_notes.to_i
    density01 =
      if n.to_i <= 0
        0.0
      else
        (total_notes.to_f / (max_simul * n.to_i)).clamp(0.0, 1.0)
      end

    assignment_distance_weight   = density01
    assignment_complexity_weight = 1.0 - density01

    # -----------------------------
    # range_def から min/max/width を一度だけ決める
    # -----------------------------
    min_val =
      if range_def.is_a?(Hash)
        range_def[:min].to_f
      else
        Array(range_def).min.to_f
      end

    max_val =
      if range_def.is_a?(Hash)
        range_def[:max].to_f
      else
        Array(range_def).max.to_f
      end

    range_width = (max_val - min_val).abs
    range_width = 1.0 if range_width <= 0.0

    # ★ stream_dist_max の「候補」
    #  - 通常：その次元の range_width
    #  - note 特別処理（absolute_basesあり）：absolute pitch の幅を候補に
    base_stream_dist_max =
      if absolute_bases
        abs_min = PolyphonicConfig::OCTAVE_RANGE.min * 12 + PolyphonicConfig::NOTE_RANGE.min
        abs_max = PolyphonicConfig::OCTAVE_RANGE.max * 12 + PolyphonicConfig::NOTE_RANGE.max
        w = (abs_max - abs_min).abs.to_f
        w <= 0.0 ? 1.0 : w
      else
        range_width
      end

    # -----------------------------
    # 候補ごとの計測
    # -----------------------------
    candidates.each_with_index do |cand_set, idx|
      best_ordered_cand, stream_metric =
        mgrs[:stream].resolve_mapping_and_score(
          cand_set,
          stream_costs,
          absolute_bases: absolute_bases,
          active_note_counts: active_note_counts,
          active_total_notes: active_total_notes,
          distance_weight: assignment_distance_weight,
          complexity_weight: assignment_complexity_weight
        )

      g_dist, g_qty, g_comp = mgrs[:global].simulate_add_and_calculate(best_ordered_cand, q_array, mgrs[:global])

      vals = best_ordered_cand
      discordance = (vals.max - vals.min).to_f / range_width

      indexed_metrics << {
        index: idx,
        ordered_cand: best_ordered_cand,
        global_dist: g_dist,
        global_qty: g_qty,
        global_comp: g_comp,
        stream_scores: (stream_metric && stream_metric[:individual_scores]) ? stream_metric[:individual_scores] : [],
        discordance: discordance
      }
    end

    return [[], Float::INFINITY] if indexed_metrics.empty?

    # -----------------------------
    # ★ dist が「既に0..1」かどうかを見て分母を決める
    #   - max_raw_dist <= 1 なら 1.0（追加で割らない）
    #   - それ以外は base_stream_dist_max（次元の最大幅で割る）
    # -----------------------------
    max_raw_dist = 0.0
    indexed_metrics.each do |m|
      (m[:stream_scores] || []).each do |score|
        d = score[:dist].to_f
        max_raw_dist = d if d > max_raw_dist
      end
    end

    stream_dist_max_for_cost =
      if max_raw_dist <= 1.000001
        1.0
      else
        base_stream_dist_max
      end

    # -----------------------------
    # best選択（★ここが修正点：stream_dist_max を渡す）
    # -----------------------------
    best_idx, best_cost = select_best_polyphonic_candidate_unified_with_cost(
      indexed_metrics,
      global_target,
      stream_targets,
      concordance_weight,
      stream_dist_max: stream_dist_max_for_cost
    )

    best = indexed_metrics[best_idx]
    [best[:ordered_cand], best_cost]
  end


  # ============================================================
  # cluster cache init
  # ============================================================
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
          cache[key] = manager.euclidean_distance(as1, as2) if as1 && as2
        end
      end

      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}
      c_cache = manager.cluster_complexity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        next unless cluster && cluster[:si].length > 1

        quantity =
          cluster[:si]
            .map { |s| quadratic_integer_array[s[0]] }
            .inject(1) { |product, n| product * n }

        q_cache[cid] = quantity
        c_cache[cid] = manager.calculate_cluster_complexity(cluster)
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
          cache[key] = manager.euclidean_distance(as1, as2) if as1 && as2
        end
      end

      updated_quant_ids = manager.updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
      q_cache = manager.cluster_quantity_cache[window_size] ||= {}
      c_cache = manager.cluster_complexity_cache[window_size] ||= {}

      updated_quant_ids.each do |cid|
        cluster = same_window_size_clusters[cid]
        next unless cluster && cluster[:si].length > 1

        quantity =
          cluster[:si]
            .map { |s| quadratic_integer_array[s[0]] }
            .inject(1) { |product, n| product * n }
        q_cache[cid] = quantity

        c_cache[cid] = manager.calculate_cluster_complexity(cluster)
      end
    end

    manager.updated_cluster_ids_per_window_for_calculate_distance = {}
    manager.updated_cluster_ids_per_window_for_calculate_quantities = {}
  end

  # ============================================================
  # scoring helpers
  # ============================================================
  def normalize_scores(raw_values, is_complex_when_larger)
    min_val = raw_values.min
    max_val = raw_values.max

    unique_count = raw_values.uniq.size
    weight =
      if unique_count <= 1
        0.0
      elsif unique_count == 2
        0.2
      else
        1.0
      end

    normalized =
      if min_val == max_val
        Array.new(raw_values.size, 0.5)
      else
        raw_values.map { |v| (v - min_val).to_f / (max_val - min_val) }
      end

    normalized.map! do |v|
      val = is_complex_when_larger ? v : 1.0 - v
      val * weight
    end

    [normalized, weight]
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

    candidates_score.each_key { |k| candidates_score[k] /= total_weight } if total_weight > 0

    best_index = nil
    min_diff = Float::INFINITY
    candidates_score.each do |index, score|
      diff = (score - target_val.to_f).abs
      if diff < min_diff
        min_diff = diff
        best_index = index
      end
    end

    best_index
  end

  # ★NaN防止：count<=1 を必ず処理
  def create_quadratic_integer_array(start_val, end_val, count)
    count = count.to_i
    return [start_val.to_f.ceil + 1] if count <= 1

    result = []
    (0...count).each do |i|
      t = i.to_f / (count - 1)
      curve = t**10
      value = start_val + (end_val - start_val) * curve
      result << (start_val < end_val ? value.ceil + 1 : value.floor + 1)
    end
    result
  end

  # ============================================================
  # params
  # ============================================================
  def analyse_params
    params.require(:analyse).permit(:merge_threshold_ratio, :job_id, time_series: [])
  end

  def generate_params
    params.require(:generate).permit(
      :complexity_transition, :range_min, :range_max, :first_elements,
      :merge_threshold_ratio, :job_id, :selected_use_musical_feature,
      dissonance: %i[transition duration_transition range],
      duration: %i[outline_transition outline_range]
    )
  end

  # initial_context はネスト配列なので permit だと落ちることがある → to_unsafe_h
  def polyphonic_params
    params.require(:generate_polyphonic).to_unsafe_h
  end

  # ============================================================
  # broadcast
  # ============================================================
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
