# frozen_string_literal: true

require 'set'

class Api::Web::TimeSeriesController < ApplicationController
  include StatisticsCalculator

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
    time_unit = 0.125
    calculate_distance_when_added_subsequence_to_cluster = false

    manager = TimeSeriesClusterManager.new(
      user_set_results.dup,
      merge_threshold_ratio,
      min_window_size,
      calculate_distance_when_added_subsequence_to_cluster
    )


    manager.process_data

    clusters_each_window_size = manager.transform_clusters(manager.clusters, min_window_size)
    initial_calc_values(manager, clusters_each_window_size, candidate_max_master, candidate_min_master, user_set_results.length)

    manager.updated_cluster_ids_per_window_for_calculate_distance = {}

    results = user_set_results.dup

    complexity_targets.each_with_index do |target_val, rank_index|
      candidates = (candidate_min_master..candidate_max_master).to_a
      in_range = []

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

      manager.update_caches_permanently(quadratic_integer_array)
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



  # ============================================================
  # generate_polyphonic (多声)
  #   生成順序（確定）:
  #     1) vol
  #     2) octave
  #     3) chord_size
  #     4) timbre(bri, hrd, tex)
  #     5) note（12Ck + STM dissonanceで集合 -> shiftで chord を確定）
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

    results = deep_dup(initial_context)

    note_idx = 1
    oct_idx  = 0
    vol_idx  = 2
    bri_idx  = 3
    hrd_idx  = 4
    tex_idx  = 5

    normalize_pcs = ->(v) do
      pcs = v.is_a?(Array) ? v : [v]
      pcs = pcs.compact.map { |x| x.to_i % PolyphonicConfig.pitch_class_mod }
      pcs = [PolyphonicConfig::NOTE_RANGE.min] if pcs.empty?
      pcs
    end

    # initial_context の note を配列化
    results.each do |step_streams|
      next if step_streams.nil?
      step_streams.each do |vec|
        next if vec.nil? || !vec.is_a?(Array)
        vec[note_idx] = normalize_pcs.call(vec[note_idx])
      end
    end

    base_step_index = results.length
    dimension_order = %w[vol octave chord_size bri hrd tex note]

    dim_defs = {
      'octave' => { key: 'octave', range: PolyphonicConfig::OCTAVE_RANGE.to_a, is_float: false, idx_in_result: 0 },
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


    managers = {}
    merge_threshold_ratio = 0.1
    min_window = 2
    max_simultaneous_notes = PolyphonicConfig::CHORD_SIZE_RANGE.max.to_i

    # --- octave/vol/bri/hrd/tex を通常初期化 ---
    %w[octave vol bri hrd tex].each do |key|
      dim = dim_defs[key]

      dim_history = results.map do |step_streams|
        (step_streams || []).map { |s| s[dim[:idx_in_result]] }
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

    # --- note は chord（pcs配列）として stream クラスタリングしたい ---
    # stream_history: step×stream の各セルが pcs配列
    note_stream_history = results.map do |step_streams|
      (step_streams || []).map do |s|
        normalize_pcs.call(s[note_idx])
      end
    end

    # global_history: そのstepで鳴る pitch class 合併集合（ネスト配列を避ける）
    note_global_history = results.map do |step_streams|
      pcs =
        (step_streams || [])
          .flat_map { |s| normalize_pcs.call(s[note_idx]) }
          .uniq
          .sort
      pcs = [PolyphonicConfig::NOTE_RANGE.min] if pcs.empty?
      pcs
    end

    if note_stream_history.length < min_window + 1
      last_row = note_stream_history.last || Array.new(stream_counts.first || 1, [PolyphonicConfig::NOTE_RANGE.min])
      (min_window + 1 - note_stream_history.length).times { note_stream_history << deep_dup(last_row) }
    end

    if note_global_history.length < min_window + 1
      last_val = note_global_history.last || [PolyphonicConfig::NOTE_RANGE.min]
      (min_window + 1 - note_global_history.length).times { note_global_history << deep_dup(last_val) }
    end

    note_global_mgr = initialize_global_manager(
      note_global_history,
      merge_threshold_ratio,
      min_window,
      PolyphonicConfig::NOTE_RANGE.to_a,
      max_simultaneous_notes: max_simultaneous_notes
    )

    note_stream_mgr = MultiStreamManager.new(
      note_stream_history,
      merge_threshold_ratio,
      min_window,
      value_range: PolyphonicConfig::NOTE_RANGE.to_a,
      max_set_size: max_simultaneous_notes
    )
    note_stream_mgr.initialize_caches

    managers['note'] = { global: note_global_mgr, stream: note_stream_mgr }

    # chord_size 履歴（notePCS.length ベース）※range外をclamp
    chord_history = results.map do |step_streams|
      (step_streams || []).map do |s|
        pcs = normalize_pcs.call(s[note_idx])
        cs = pcs.length
        cs = 1 if cs < 1
        cs = max_simultaneous_notes if cs > max_simultaneous_notes
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

    # initial_context を STM に投入（notePCS配列として扱う）
    step_duration = 0.25
    results.each_with_index do |step_streams, i|
      next if step_streams.nil? || step_streams.empty?

      midi_notes = []
      amps = []

      step_streams.each do |s|
        oct = s[oct_idx].to_i
        pcs = normalize_pcs.call(s[note_idx])
        vol = s[vol_idx].to_f

        base_c_midi = PolyphonicConfig.base_c_midi(oct)
        a_each = vol / pcs.length.to_f

        pcs.each do |pc|
          midi_notes << (base_c_midi + (pc.to_i % PolyphonicConfig.pitch_class_mod))
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

        # ----------------------------
        # note 特別処理（root廃止 / chordをクラスタリング対象に）
        # ----------------------------
        if key == 'note'
          chord_sizes = step_decisions.fetch('chord_size')
          octaves     = step_decisions.fetch('octave')
          vols        = step_decisions.fetch('vol')

          k = chord_sizes.max.to_i
          k = 1 if k < 1
          k = PolyphonicConfig.pitch_class_mod if k > PolyphonicConfig.pitch_class_mod

          pitch_classes = PolyphonicConfig::NOTE_RANGE.to_a
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
              base_c_midi = PolyphonicConfig.base_c_midi(octaves[s].to_i)
              a_each = vols[s].to_f / pcs.length.to_f
              pcs.each do |pc|
                midi_notes << (base_c_midi + (pc.to_i % PolyphonicConfig.pitch_class_mod))
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
            base_c_midi = PolyphonicConfig.base_c_midi(octaves[s].to_i)
            a_each = vols[s].to_f / pcs.length.to_f
            pcs.each do |pc|
              midi_notes << (base_c_midi + (pc.to_i % PolyphonicConfig.pitch_class_mod))
              amps << a_each
            end
          end
          stm_mgr.commit!(midi_notes, amps, onset)

          # --- B) shift を note(cost) で決める（rootは使わない） ---
          absolute_bases = octaves.map { |o| PolyphonicConfig.base_c_midi(o.to_i) }
          abs_width = compute_abs_width(absolute_bases)

          active_note_counts = chord_sizes.map(&:to_i)
          active_total_notes = active_note_counts.sum.to_i

          density01 =
            if current_stream_count <= 0
              0.0
            else
              (active_total_notes.to_f / (max_simultaneous_notes.to_f * current_stream_count.to_f)).clamp(0.0, 1.0)
            end
          distance_weight   = density01
          complexity_weight = 1.0 - density01

          containers = mgrs[:stream].active_stream_containers(current_stream_count)

          shift_metrics = []

          (0...(PolyphonicConfig.pitch_class_mod)).each do |shift|
            shifted_ordered = best_ordered.map { |pc| (pc + shift) % PolyphonicConfig.pitch_class_mod }.sort

            chords_for_streams = chord_sizes.each_with_index.map do |cs, s|
              cs = cs.to_i
              cs = 1 if cs < 1
              cs = shifted_ordered.length if cs > shifted_ordered.length
              shifted_ordered.first(cs)
            end

            global_value = shifted_ordered # globalは合併集合（ネストを避ける）

            g_dist, g_qty, g_comp = mgrs[:global].simulate_add_and_calculate(global_value, q_array)

            stream_dists01 = []
            stream_complexities_raw = []

            chords_for_streams.each_with_index do |pcs, s|
              base = absolute_bases[s].to_i

              cand_abs = pcs.map { |pc| base + (pc.to_i % PolyphonicConfig.pitch_class_mod) }

              last_abs = containers[s].last_abs_pitch
              if last_abs.nil?
                last_val = containers[s].last_value
                last_pcs = last_val.is_a?(Array) ? last_val : [last_val]
                last_abs = last_pcs.map { |pc| base + (pc.to_i % PolyphonicConfig.pitch_class_mod) }
              end

              dist01 = set_distance01(cand_abs, last_abs, width: abs_width, max_count: max_simultaneous_notes)
              stream_dists01 << dist01

              d_s, _q_s, c_s = containers[s].manager.simulate_add_and_calculate(pcs, q_array)
              raw =
                if c_s.is_a?(Numeric) && c_s.finite?
                  c_s.to_f
                elsif d_s.is_a?(Numeric) && d_s.finite?
                  d_s.to_f
                else
                  0.0
                end
              stream_complexities_raw << raw
            end

            discordance = average_pairwise_distance(
              chords_for_streams,
              width: (PolyphonicConfig::NOTE_RANGE.max - PolyphonicConfig::NOTE_RANGE.min).abs.to_f,
              max_count: max_simultaneous_notes
            )

            shift_metrics << {
              shift: shift,
              global_dist: g_dist,
              global_qty: g_qty,
              global_comp: g_comp,
              stream_dists01: stream_dists01,
              stream_complexities_raw: stream_complexities_raw,
              discordance: discordance,
              chords_for_streams: chords_for_streams,
              global_value: global_value
            }
          end

          # global 正規化（shift間で）
          g_dists01, _ = normalize_scores(shift_metrics.map { |m| m[:global_dist] }, true)
          g_qtys01, _  = normalize_scores(shift_metrics.map { |m| m[:global_qty] }, false)
          g_comps01, _ = normalize_scores(shift_metrics.map { |m| m[:global_comp] }, true)

          # stream complexity 正規化（streamごとに shift間で）
          n_shifts = shift_metrics.length
          complexity01 = Array.new(current_stream_count) { Array.new(n_shifts, 0.5) }

          current_stream_count.times do |s|
            raws = shift_metrics.map { |m| m[:stream_complexities_raw][s].to_f }
            min_r = raws.min
            max_r = raws.max
            span_r = (max_r - min_r).abs
            span_r = 1.0 if span_r <= 0.0

            raws.each_with_index do |r, i|
              complexity01[s][i] = ((r - min_r) / span_r).clamp(0.0, 1.0)
            end
          end

          best_metric_idx = 0
          best_total_cost = Float::INFINITY

          shift_metrics.each_with_index do |m, idx|
            current_global = (g_dists01[idx] + g_qtys01[idx] + g_comps01[idx]) / 3.0
            cost_a = (current_global - global_target.to_f).abs

            cost_b = 0.0
            if stream_targets.any?
              stream_targets.each_with_index do |t, s|
                dist01 = m[:stream_dists01][s].to_f
                comp01 = complexity01[s][idx].to_f
                mixed01 = (distance_weight * dist01) + (complexity_weight * comp01)
                cost_b += (mixed01 - t.to_f).abs
              end
              cost_b /= stream_targets.size.to_f
            end

            cost_c =
              if concord_w.to_f < 0
                0.0
              else
                m[:discordance].to_f * concord_w.to_f
              end

            total = cost_a + cost_b + cost_c
            if total < best_total_cost
              best_total_cost = total
              best_metric_idx = idx
            end
          end

          best_m = shift_metrics[best_metric_idx]
          best_chords_for_streams = best_m[:chords_for_streams]
          best_global_value = best_m[:global_value]

          # managers 更新（note は chord を stream に、合併集合を global に入れる）
          mgrs[:global].add_data_point_permanently(best_global_value)
          mgrs[:global].update_caches_permanently(q_array)

          mgrs[:stream].commit_state(best_chords_for_streams, q_array, absolute_bases: absolute_bases)
          mgrs[:stream].update_caches_permanently(q_array)

          # timeSeries 出力は chord pcs 配列
          best_chords_for_streams.each_with_index do |pcs, s_i|
            current_step_values[s_i][note_idx] = normalize_pcs.call(pcs)
          end

          step_decisions[key] = best_global_value
          next
        end

        # ----------------------------
        # note 以外（従来通り）
        # ----------------------------
        stream_costs = mgrs[:stream].precalculate_costs(dim[:range], q_array)
        mgrs[:stream].update_strengths! if key == 'vol'

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

        if key != 'chord_size'
          best_chord.each_with_index do |val, s_i|
            current_step_values[s_i][dim[:idx_in_result]] = val
          end
        end
      end

      results << current_step_values
      broadcast_progress(job_id, step_idx + 1, steps_to_generate)
    end

    end_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    broadcast_done(job_id)

    # --- 最終正規化（型・範囲保証）---
    results.each do |step_streams|
      next unless step_streams.is_a?(Array)
      step_streams.each do |vec|
        next unless vec.is_a?(Array)

        vec[oct_idx] = vec[oct_idx].to_i.clamp(PolyphonicConfig::OCTAVE_RANGE.min, PolyphonicConfig::OCTAVE_RANGE.max)
        vec[note_idx] = normalize_pcs.call(vec[note_idx])

        vec[vol_idx] = vec[vol_idx].to_f.clamp(0.0, 1.0)
        vec[bri_idx] = vec[bri_idx].to_f.clamp(0.0, 1.0)
        vec[hrd_idx] = vec[hrd_idx].to_f.clamp(0.0, 1.0)
        vec[tex_idx] = vec[tex_idx].to_f.clamp(0.0, 1.0)
      end
    end

    # --- クラスタ情報 ---
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

    render json: {
      timeSeries: results,
      clusters: cluster_payload,
      processingTime: (end_time - start_time).round(2)
    }
  end

  private

  # ----------------------------
  # note 専用ユーティリティ
  # ----------------------------
  def compute_abs_width(absolute_bases)
    bases = Array(absolute_bases).map(&:to_f)
    pc_width = (PolyphonicConfig::NOTE_RANGE.max - PolyphonicConfig::NOTE_RANGE.min).abs.to_f
    pc_width = 1.0 if pc_width <= 0.0
    w = (bases.max - bases.min).abs + pc_width
    w = 1.0 if w <= 0.0
    w
  end

  def set_distance01(a, b, width:, max_count:)
    a = Array(a).compact
    b = Array(b).compact

    return 0.0 if a.empty? && b.empty?
    return 1.0 if a.empty? || b.empty?

    width = width.to_f
    width = 1.0 if width <= 0.0

    max_count = max_count.to_i
    max_count = 1 if max_count <= 0

    a_avg = a.map { |x| b.map { |y| (x.to_f - y.to_f).abs }.min }.sum.to_f / a.length.to_f
    b_avg = b.map { |y| a.map { |x| (y.to_f - x.to_f).abs }.min }.sum.to_f / b.length.to_f
    pitch_dist = (a_avg + b_avg) / 2.0
    pitch_norm = (pitch_dist / width).clamp(0.0, 1.0)

    count_norm = ((a.length - b.length).abs.to_f / max_count.to_f).clamp(0.0, 1.0)

    ((pitch_norm + count_norm) / 2.0).clamp(0.0, 1.0)
  end

  def average_pairwise_distance(chords, width:, max_count:)
    chords = Array(chords).map { |c| Array(c).compact }
    n = chords.length
    return 0.0 if n < 2

    sum = 0.0
    cnt = 0

    (0...n).each do |i|
      ((i + 1)...n).each do |j|
        sum += set_distance01(chords[i], chords[j], width: width, max_count: max_count)
        cnt += 1
      end
    end

    cnt > 0 ? (sum / cnt.to_f) : 0.0
  end

  # ----------------------------
  # small utilities
  # ----------------------------
  def deep_dup(obj)
    Marshal.load(Marshal.dump(obj))
  rescue
    obj.is_a?(Array) ? obj.map { |e| deep_dup(e) } : obj
  end

  def array_param(raw, key, idx)
    # raw が Hash でない場合も落とさない（念のため）
    return nil unless raw.respond_to?(:[])

    val = raw[key]
    return nil if val.nil?

    # stepごとの配列なら idx を参照
    if val.is_a?(Array)
      # idxが範囲外でも落とさず、最後の値を使う（設計上これが一番自然）
      val[idx] || val.last
    else
      # スカラーなら「全step共通の定数」とみなす
      val
    end
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
  def initialize_global_manager(history, ratio, min_window, value_range, max_simultaneous_notes: PolyphonicConfig::CHORD_SIZE_RANGE.max)
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
    g_mgr
  end

  def initialize_managers_for_dimension(history, ratio, min_window, value_range, max_simultaneous_notes: PolyphonicConfig::CHORD_SIZE_RANGE.max)
    g_mgr = initialize_global_manager(history, ratio, min_window, value_range, max_simultaneous_notes: max_simultaneous_notes)

    s_mgr = MultiStreamManager.new(
      history,
      ratio,
      min_window,
      value_range: value_range,
      max_set_size: max_simultaneous_notes
    )
    s_mgr.initialize_caches

    { global: g_mgr, stream: s_mgr }
  end

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

  def select_best_polyphonic_candidate_unified_with_cost(
    metrics,
    global_target,
    stream_targets,
    concordance_weight,
    stream_dist_max: 1.0
  )
    best_idx = nil
    min_total_cost = Float::INFINITY

    g_dists, _ = normalize_scores(metrics.map { |m| m[:global_dist] }, true)
    g_qtys, _  = normalize_scores(metrics.map { |m| m[:global_qty] }, false)
    g_comps, _ = normalize_scores(metrics.map { |m| m[:global_comp] }, true)

    stream_dist_max = stream_dist_max.to_f
    stream_dist_max = 1.0 if stream_dist_max <= 0.0

    metrics.each_with_index do |m, i|
      current_global = (g_dists[i] + g_qtys[i] + g_comps[i]) / 3.0
      cost_a = (current_global - global_target.to_f).abs

      cost_b = 0.0
      if stream_targets.size > 0
        m[:stream_scores].each_with_index do |score, s_idx|
          raw_dist = score[:dist].to_f
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

    base_stream_dist_max =
      if absolute_bases
        PolyphonicConfig.abs_pitch_width
      else
        range_width
      end

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

  # --- cluster cache init (あなたの現状コードを維持) ---
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
