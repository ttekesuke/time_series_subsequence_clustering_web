# ============================================================
# app/models/multi_stream_manager.rb
# ============================================================
# frozen_string_literal: true

class MultiStreamManager
  attr_accessor :use_complexity_mapping
  attr_reader :stream_pool

  class StreamContainer
    attr_accessor :id, :manager, :active, :last_note, :strength

    def initialize(id, manager, active: true)
      @id = id
      @manager = manager
      @active = active
      @last_note = manager.data.last
      @last_note = 0.0 if @last_note.nil?
      @strength = 0.0
    end
  end

  def initialize(history_matrix, merge_threshold_ratio, min_window_size, use_complexity_mapping: true)
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size

    # ★fix: uninitialized local variable を踏まない
    @use_complexity_mapping = !!use_complexity_mapping

    @stream_pool = []
    @next_stream_id = 0

    initial_voices = safe_transpose_history(history_matrix)

    initial_voices.each do |voice_data|
      mgr = TimeSeriesClusterManager.new(voice_data, merge_threshold_ratio, min_window_size, false)
      mgr.process_data

      container = StreamContainer.new(@next_stream_id, mgr)
      @stream_pool << container
      @next_stream_id += 1
    end
  end

  def active_streams
    @stream_pool.select(&:active)
  end

  def initialize_caches
    active_streams.each do |s|
      s.manager.cluster_distance_cache[@min_window_size] ||= {}
      s.manager.cluster_quantity_cache[@min_window_size] ||= {}
      s.manager.cluster_complexity_cache[@min_window_size] ||= {}
    end
  end

  # --- Lv.3 コスト事前計算 (ストリーム単位) ---
  def precalculate_costs(range, quadratic_integer_array)
    active_streams.map do |s|
      costs = {}
      range.each do |note|
        d, q, c = s.manager.simulate_add_and_calculate(note, quadratic_integer_array, s.manager)
        costs[note] = { dist: d, quantity: q, complexity: c }
      end
      costs
    end
  end

  # --- ストリーム強度の更新 ---
  def update_strengths!
    raw_complexities = {}

    active_streams.each do |container|
      mgr = container.manager
      total_complexity = 0.0

      mgr.cluster_complexity_cache.each_value do |per_window|
        per_window.each_value { |val| total_complexity += val.to_f }
      end

      raw_complexities[container.id] = total_complexity
    end

    return if raw_complexities.empty?

    min_c = raw_complexities.values.min
    max_c = raw_complexities.values.max

    normalized_complexities =
      if max_c == min_c
        raw_complexities.transform_values { 0.5 }
      else
        raw_complexities.transform_values { |c| (c - min_c) / (max_c - min_c).to_f }
      end

    active_streams.each do |container|
      comp = normalized_complexities[container.id] || 0.0

      vol = container.last_note.to_f
      vol = 0.0 if vol.nan?
      vol = [[vol, 0.0].max, 1.0].min

      container.strength = comp * vol
    end
  end

  # --- 候補セットに対する評価（既存） ---
  def resolve_mapping_and_score(cand_set, stream_costs)
    current_actives = active_streams
    n_streams       = current_actives.size
    n_notes         = cand_set.size

    mapping_result =
      if @use_complexity_mapping
        resolve_mapping_by_complexity(cand_set, stream_costs, current_actives, n_streams, n_notes)
      else
        resolve_mapping_by_pitch_distance(cand_set, current_actives, n_streams, n_notes)
      end

    individual_scores = []
    ordered_chord     = mapping_result.map { |m| m[:note] }

    mapping_result.each do |map|
      note  = map[:note]
      s_idx = map[:stream_idx]

      if s_idx
        individual_scores << stream_costs[s_idx][note]
      else
        parent_s_idx =
          if @use_complexity_mapping
            (0...n_streams).min_by { |i| stream_costs[i][note][:dist] }
          else
            find_closest_stream_index(note, current_actives)
          end
        individual_scores << stream_costs[parent_s_idx][note]
      end
    end

    [ordered_chord, { individual_scores: individual_scores }]
  end

  # --- ストリーム状態の確定（strength_params 対応まで実装） ---
  def commit_state(ordered_chord, quadratic_integer_array, strength_params: nil)
    current_actives = active_streams
    n_notes   = ordered_chord.size
    n_streams = current_actives.size

    # strength を使う場合、先にターゲット取得
    st_target = strength_params&.dig(:target)
    st_spread = strength_params&.dig(:spread)

    if n_notes == n_streams
      current_actives.each_with_index do |s, i|
        s.manager.add_data_point_permanently(ordered_chord[i])
        s.last_note = ordered_chord[i]
      end
      return
    end

    if n_notes > n_streams
      extra_notes = ordered_chord[n_streams..-1] || []
      new_containers = []

      # ★fix: 親選択に strength を反映（あれば）
      parents =
        if strength_params
          pick_parents_for_extra_streams(current_actives, extra_notes.size, st_target, st_spread)
        else
          # 従来: last_note 近い親
          extra_notes.map { |note| current_actives.min_by { |s| (s.last_note.to_f - note.to_f).abs } }
        end

      extra_notes.each_with_index do |_note, idx|
        parent = parents[idx]
        # active が 0 のケースは想定薄いが、念のため
        parent ||= current_actives.first
        raise "No active stream to clone" unless parent

        # ★fix: 「このステップ未コミット状態」をクローン
        new_mgr = Marshal.load(Marshal.dump(parent.manager))

        new_container = StreamContainer.new(@next_stream_id, new_mgr)
        new_container.last_note = parent.last_note
        @stream_pool << new_container
        new_containers << new_container
        @next_stream_id += 1
      end

      # 既存ストリームにコミット
      current_actives.each_with_index do |s, i|
        s.manager.add_data_point_permanently(ordered_chord[i])
        s.last_note = ordered_chord[i]
      end

      # 新ストリームにコミット
      extra_notes.each_with_index do |note, idx|
        s = new_containers[idx]
        s.manager.add_data_point_permanently(note)
        s.last_note = note
      end

      return
    end

    # n_notes < n_streams
    if strength_params
      # ★fix: 残すストリームを strength で選んでから、その中で note を割り当てる
      keepers = select_by_strength(current_actives, n_notes, st_target, st_spread)
      keepers = current_actives.first(n_notes) if keepers.compact.size < n_notes

      available_streams = keepers.dup
      next_actives = []

      ordered_chord.each do |note|
        best_s = available_streams.min_by { |s| (s.last_note.to_f - note.to_f).abs }
        best_s.manager.add_data_point_permanently(note)
        best_s.last_note = note
        next_actives << best_s
        available_streams.delete(best_s)
      end

      # keepers以外は inactive
      (current_actives - next_actives).each { |s| s.active = false }
      next_actives.each { |s| s.active = true }
      return
    end

    # 従来: last_note 近い順に割り当て、残り inactive
    available_streams = current_actives.dup
    next_actives = []

    ordered_chord.each do |note|
      best_s = available_streams.min_by { |s| (s.last_note.to_f - note.to_f).abs }
      best_s.manager.add_data_point_permanently(note)
      best_s.last_note = note
      next_actives << best_s
      available_streams.delete(best_s)
    end

    available_streams.each { |s| s.active = false }
    next_actives.each     { |s| s.active = true }
  end

  def update_caches_permanently(quadratic_integer_array)
    active_streams.each { |s| s.manager.update_caches_permanently(quadratic_integer_array) }
  end

  private

  # ★fix: history_matrix.transpose が「空/可変長」で落ちる問題を吸収
  # - 最大 stream 数に合わせて carry-forward で埋める
  def safe_transpose_history(history_matrix)
    rows = Array(history_matrix)
    return [] if rows.empty?

    max_streams = rows.map { |r| Array(r).length }.max.to_i
    return [] if max_streams <= 0

    voices = Array.new(max_streams) { [] }

    rows.each do |row|
      row = Array(row)
      max_streams.times do |i|
        v = row[i]
        v = voices[i].last if v.nil?
        v = 0.0 if v.nil?
        voices[i] << v
      end
    end

    voices
  end

  def pick_parents_for_extra_streams(candidates, k, target_strength, spread)
    # k が candidates を超える場合は「一旦 distinct で選んで、足りない分は循環」
    base = select_by_strength(candidates, [k, candidates.size].min, target_strength, spread)
    return base if base.size >= k

    out = base.dup
    idx = 0
    while out.size < k
      out << base[idx % base.size]
      idx += 1
    end
    out
  end

  # candidates: StreamContainer の配列
  # k: ほしい本数
  # target_strength: 0.0〜1.0
  # spread: 0.0〜1.0 (0.0=一点集中, 1.0=最大限バラけさせる)
  def select_by_strength(candidates, k, target_strength, spread)
    return [] if k <= 0 || candidates.empty?

    t = [[target_strength.to_f, 0.0].max, 1.0].min
    s = [[spread.to_f, 0.0].max, 1.0].min

    selected  = []
    remaining = candidates.dup

    if k == 1
      chosen = remaining.min_by { |c| (c.strength.to_f - t).abs }
      return chosen ? [chosen] : []
    end

    (0...k).each do |idx|
      break if remaining.empty?

      pos = (idx.to_f / (k - 1).to_f) - 0.5
      target_pos = t + s * pos
      target_pos = [[target_pos, 0.0].max, 1.0].min

      chosen = remaining.min_by { |c| (c.strength.to_f - target_pos).abs }
      selected << chosen
      remaining.delete(chosen)
    end

    selected
  end

  # ============================
  #  複雑度ベースの所属決定
  # ============================
  def resolve_mapping_by_complexity(cand_set, stream_costs, _current_actives, n_streams, n_notes)
    if n_notes == n_streams
      best_perm = nil
      min_cost  = Float::INFINITY

      cand_set.permutation.each do |perm|
        cost = 0.0
        perm.each_with_index do |note, s_idx|
          cost += stream_costs[s_idx][note][:dist].to_f
        end
        if cost < min_cost
          min_cost  = cost
          best_perm = perm
        end
      end

      return best_perm.map.with_index { |note, i| { stream_idx: i, note: note } }
    end

    if n_notes > n_streams
      available_notes = cand_set.dup
      assigned_pairs  = []

      (0...n_streams).each do |s_idx|
        best_note = available_notes.min_by { |note| stream_costs[s_idx][note][:dist].to_f }
        assigned_pairs << { stream_idx: s_idx, note: best_note }
        available_notes.delete_at(available_notes.index(best_note))
      end

      new_pairs = available_notes.map { |n| { stream_idx: nil, note: n } }
      return assigned_pairs + new_pairs
    end

    available_stream_indices = (0...n_streams).to_a
    assigned_pairs = []

    cand_set.each do |note|
      best_s_idx = available_stream_indices.min_by { |s_idx| stream_costs[s_idx][note][:dist].to_f }
      assigned_pairs << { stream_idx: best_s_idx, note: note }
      available_stream_indices.delete(best_s_idx)
    end

    assigned_pairs
  end

  # ============================
  #  距離ベースの所属決定
  # ============================
  def resolve_mapping_by_pitch_distance(cand_set, current_actives, n_streams, n_notes)
    if n_notes == n_streams
      best_perm = nil
      min_dist  = Float::INFINITY

      cand_set.permutation.each do |perm|
        dist = 0.0
        perm.each_with_index do |note, i|
          dist += (current_actives[i].last_note.to_f - note.to_f).abs
        end
        if dist < min_dist
          min_dist  = dist
          best_perm = perm
        end
      end

      return best_perm.map.with_index { |note, i| { stream_idx: i, note: note } }
    end

    if n_notes > n_streams
      available_notes = cand_set.dup
      assigned_pairs  = []

      current_actives.each_with_index do |s, s_idx|
        closest_note = available_notes.min_by { |n| (s.last_note.to_f - n.to_f).abs }
        assigned_pairs << { stream_idx: s_idx, note: closest_note }
        available_notes.delete_at(available_notes.index(closest_note))
      end

      new_pairs = available_notes.map { |n| { stream_idx: nil, note: n } }
      return assigned_pairs + new_pairs
    end

    available_streams = current_actives.map.with_index { |s, i| [s, i] }
    assigned_pairs    = []

    cand_set.each do |note|
      best_s, best_s_idx = available_streams.min_by { |s, _i| (s.last_note.to_f - note.to_f).abs }
      assigned_pairs << { stream_idx: best_s_idx, note: note }
      available_streams.delete_if { |_s, i| i == best_s_idx }
    end

    assigned_pairs
  end

  def find_closest_stream_index(note, streams)
    min_d = Float::INFINITY
    idx = 0
    streams.each_with_index do |s, i|
      d = (s.last_note.to_f - note.to_f).abs
      if d < min_d
        min_d = d
        idx = i
      end
    end
    idx
  end
end
