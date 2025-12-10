class MultiStreamManager
  attr_reader :active_managers
  attr_accessor :use_complexity_mapping   # ★モード切替フラグ（既存）
  attr_reader :stream_pool

  class StreamContainer
    attr_accessor :id, :manager, :active, :last_note, :strength

    def initialize(id, manager, active: true)
      @id = id
      @manager = manager
      @active = active
      @last_note = manager.data.last
      @strength = 0.0  # ★ストリーム強度 (0.0〜1.0)
    end
  end

  def initialize(history_matrix, merge_threshold_ratio, min_window_size)
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size
    @use_complexity_mapping  = use_complexity_mapping  # ★(元のまま)
    @stream_pool = []
    @next_stream_id = 0

    initial_voices = history_matrix.transpose

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
      clusters = s.manager.transform_clusters(s.manager.clusters, @min_window_size)
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
  #
  # cluster_complexity_cache を集約し、0.0〜1.0に正規化した複雑度と
  # last_note (vol 次元なら音量) を掛け合わせて strength を更新する。
  def update_strengths!
    raw_complexities = {}

    active_streams.each do |container|
      mgr = container.manager
      total_complexity = 0.0

      mgr.cluster_complexity_cache.each_value do |per_window|
        per_window.each_value do |val|
          total_complexity += val.to_f
        end
      end

      raw_complexities[container.id] = total_complexity
    end

    return if raw_complexities.empty?

    min_c = raw_complexities.values.min
    max_c = raw_complexities.values.max

    normalized_complexities = {}

    if max_c == min_c
      raw_complexities.each_key do |sid|
        normalized_complexities[sid] = 0.5
      end
    else
      raw_complexities.each do |sid, c|
        normalized_complexities[sid] = (c - min_c) / (max_c - min_c).to_f
      end
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

    [ ordered_chord, { individual_scores: individual_scores } ]
  end

  # --- ストリーム状態の確定（ここを強度パラメータ対応に拡張） ---
  #
  # strength_params が与えられたとき:
  #   - Δ>0: 追加ストリームの親を strength に基づいて選ぶ
  #   - Δ<0: オフにするストリームを strength に基づいて選ぶ

  def commit_state(ordered_chord, quadratic_integer_array, strength_params: nil)
    current_actives = active_streams
    n_notes   = ordered_chord.size
    n_streams = current_actives.size

    if n_notes == n_streams
      # --- ケース1: ノート数 = ストリーム数 ---
      current_actives.each_with_index do |s, i|
        s.manager.add_data_point_permanently(ordered_chord[i])
        s.last_note = ordered_chord[i]
      end

    elsif n_notes > n_streams
      # --- ケース2: ノート数 > ストリーム数 (ストリーム増加) ---

      # 余ったノート（= 新しく増えるストリームぶん）
      extra_notes = ordered_chord[n_streams..-1] || []
      new_containers = []

      # 1) まず「このステップをまだコミットしていない状態の親」をクローン
      extra_notes.each do |note|
        # 親は last_note が近いストリーム（ここは後で strength_params で差し替え可能）
        parent = current_actives.min_by { |s| (s.last_note - note).abs }

        # ★ポイント：
        #  parent.manager は「前ステップまで」の状態のクローンにする。
        #  既にこのステップ分を追加済みの状態をクローンしてしまうと、
        #  新ストリームだけ @data.length が 1 ステップ先に行ってしまう。
        new_mgr = Marshal.load(Marshal.dump(parent.manager))

        new_container = StreamContainer.new(@next_stream_id, new_mgr)
        new_container.last_note = parent.last_note
        @stream_pool << new_container
        new_containers << new_container
        @next_stream_id += 1
      end

      # 2) 既存ストリームに先頭 n_streams 分のノートを書き込む
      current_actives.each_with_index do |s, i|
        s.manager.add_data_point_permanently(ordered_chord[i])
        s.last_note = ordered_chord[i]
      end

      # 3) 新ストリームに残りのノートを書き込む
      extra_notes.each_with_index do |note, idx|
        s = new_containers[idx]
        s.manager.add_data_point_permanently(note)
        s.last_note = note
      end

    else
      # --- ケース3: ノート数 < ストリーム数 (ストリーム減少) ---
      available_streams = current_actives.dup
      next_actives = []

      ordered_chord.each do |note|
        best_s = available_streams.min_by { |s| (s.last_note - note).abs }
        best_s.manager.add_data_point_permanently(note)
        best_s.last_note = note
        next_actives << best_s
        available_streams.delete(best_s)
      end

      # 余ったストリームは inactive にする
      available_streams.each { |s| s.active = false }
      next_actives.each     { |s| s.active = true }
    end

    # strength_params（target / spread）を使った
    # 「どのストリームをプロトタイプにするか」の選択ロジックは、
    # ここに後で差し込めるようにしておく。
    # 例:
    #   if strength_params
    #     apply_strength_based_prototype_selection(strength_params)
    #   end
  end


  def update_caches_permanently(quadratic_integer_array)
    active_streams.each do |s|
      s.manager.update_caches_permanently(quadratic_integer_array)
    end
  end

  private

  # --- 強度ベース選択ヘルパ ---
  #
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
      selected << chosen if chosen
      return selected
    end

    (0...k).each do |idx|
      break if remaining.empty?

      # idx を 0..(k-1) → -0.5..0.5 にマッピング
      pos = if k == 1
              0.0
            else
              (idx.to_f / (k - 1).to_f) - 0.5
            end

      target_pos = t + s * pos
      target_pos = [[target_pos, 0.0].max, 1.0].min

      chosen = remaining.min_by { |c| (c.strength.to_f - target_pos).abs }
      selected << chosen
      remaining.delete(chosen)
    end

    selected
  end

  # ============================
  #  複雑度ベースの所属決定（既存）
  # ============================
  def resolve_mapping_by_complexity(cand_set, stream_costs, current_actives, n_streams, n_notes)
    mapping_result = []

    if n_notes == n_streams
      best_perm = nil
      min_cost  = Float::INFINITY

      cand_set.permutation.each do |perm|
        cost = 0.0
        perm.each_with_index do |note, s_idx|
          score = stream_costs[s_idx][note]
          cost += score[:dist]
        end
        if cost < min_cost
          min_cost  = cost
          best_perm = perm
        end
      end

      mapping_result = best_perm.map.with_index do |note, i|
        { stream_idx: i, note: note }
      end

    elsif n_notes > n_streams
      available_notes = cand_set.dup
      assigned_pairs  = []

      (0...n_streams).each do |s_idx|
        best_note = available_notes.min_by do |note|
          stream_costs[s_idx][note][:dist]
        end
        assigned_pairs << { stream_idx: s_idx, note: best_note }
        available_notes.delete_at(available_notes.index(best_note))
      end

      new_pairs = available_notes.map { |n| { stream_idx: nil, note: n } }
      mapping_result = assigned_pairs + new_pairs

    else
      available_stream_indices = (0...n_streams).to_a
      assigned_pairs           = []

      cand_set.each do |note|
        best_s_idx = available_stream_indices.min_by do |s_idx|
          stream_costs[s_idx][note][:dist]
        end
        assigned_pairs << { stream_idx: best_s_idx, note: note }
        available_stream_indices.delete(best_s_idx)
      end

      mapping_result = assigned_pairs
    end

    mapping_result
  end

  # ============================
  #  距離ベースの所属決定（既存）
  # ============================
  def resolve_mapping_by_pitch_distance(cand_set, current_actives, n_streams, n_notes)
    mapping_result = []

    if n_notes == n_streams
      best_perm = nil
      min_dist  = Float::INFINITY

      cand_set.permutation.each do |perm|
        dist = 0
        perm.each_with_index do |note, i|
          dist += (current_actives[i].last_note - note).abs
        end
        if dist < min_dist
          min_dist  = dist
          best_perm = perm
        end
      end

      mapping_result = best_perm.map.with_index do |note, i|
        { stream_idx: i, note: note }
      end

    elsif n_notes > n_streams
      available_notes = cand_set.dup
      assigned_pairs  = []

      current_actives.each_with_index do |s, s_idx|
        closest_note = available_notes.min_by { |n| (s.last_note - n).abs }
        assigned_pairs << { stream_idx: s_idx, note: closest_note }
        available_notes.delete_at(available_notes.index(closest_note))
      end

      new_pairs = available_notes.map { |n| { stream_idx: nil, note: n } }
      mapping_result = assigned_pairs + new_pairs

    else
      available_streams = current_actives.map.with_index { |s, i| [s, i] }
      assigned_pairs    = []

      cand_set.each do |note|
        best_s, best_s_idx = available_streams.min_by { |s, i| (s.last_note - note).abs }
        assigned_pairs << { stream_idx: best_s_idx, note: note }
        available_streams.delete_if { |s, i| i == best_s_idx }
      end

      mapping_result = assigned_pairs
    end

    mapping_result
  end

  def find_closest_stream_index(note, streams)
    min_d = Float::INFINITY
    idx = 0
    streams.each_with_index do |s, i|
      d = (s.last_note - note).abs
      if d < min_d
        min_d = d
        idx = i
      end
    end
    idx
  end
end
