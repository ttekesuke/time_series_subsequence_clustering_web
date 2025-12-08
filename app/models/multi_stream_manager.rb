class MultiStreamManager
  attr_reader :active_managers
  attr_accessor :use_complexity_mapping   # ★追加：モード切替フラグ
  attr_reader :stream_pool

  class StreamContainer
    attr_accessor :id, :manager, :active, :last_note
    def initialize(id, manager, active: true)
      @id = id
      @manager = manager
      @active = active
      @last_note = manager.data.last
    end
  end

  def initialize(history_matrix, merge_threshold_ratio, min_window_size)
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size
    @use_complexity_mapping  = use_complexity_mapping  # ★追加
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

def resolve_mapping_and_score(cand_set, stream_costs)
  current_actives = active_streams
  n_streams       = current_actives.size
  n_notes         = cand_set.size

  # --- 所属決定（モードで分岐） ---
  mapping_result =
    if @use_complexity_mapping
      resolve_mapping_by_complexity(cand_set, stream_costs, current_actives, n_streams, n_notes)
    else
      resolve_mapping_by_pitch_distance(cand_set, current_actives, n_streams, n_notes)
    end

  # --- スコア抽出（ここは共通） ---
  individual_scores = []
  ordered_chord     = mapping_result.map { |m| m[:note] }

  mapping_result.each do |map|
    note  = map[:note]
    s_idx = map[:stream_idx]

    if s_idx
      individual_scores << stream_costs[s_idx][note]
    else
      # 新規ストリーム用のスコア：複雑度モードでも、
      # どの既存ストリームを「親」とみなすかを決める必要がある
      # → parent_s_idx の決め方は簡略にしておき、
      #    実際のスコアは stream_costs から取る
      parent_s_idx =
        if @use_complexity_mapping
          # ★複雑度ベース：コスト最小のストリームを親とみなす
          (0...n_streams).min_by { |i| stream_costs[i][note][:dist] }
        else
          # ★従来どおりの距離ベース
          find_closest_stream_index(note, current_actives)
        end

      individual_scores << stream_costs[parent_s_idx][note]
    end
  end

  [ ordered_chord, { individual_scores: individual_scores } ]
end


  def commit_state(ordered_chord, quadratic_integer_array)
    current_actives = active_streams
    n_notes   = ordered_chord.size
    n_streams = current_actives.size

    if n_notes == n_streams
      # --- ケース1: ノート数 = ストリーム数 ---
      current_actives.each_with_index do |s, i|
        note = ordered_chord[i]
        s.manager.add_data_point_permanently(note)
        s.last_note = note
      end

    elsif n_notes > n_streams
      # --- ケース2: ノート数 > ストリーム数（ストリーム増加） ---

      # 既存ストリームに割り当てるノートと、
      # 新規ストリーム用ノートを分離（resolve_* の仕様に合わせて先頭 n_streams を既存用とみなす）
      base_notes  = ordered_chord[0, n_streams]         # 既存ストリームに入るノート
      extra_notes = ordered_chord[n_streams..-1] || []  # 増加分（新規ストリーム用）

      new_containers = []

      # 1) まず「分岐元からのクローン」を作る（この段階では既存ストリームにはまだ add しない）
      extra_notes.each do |note|
        # ★どのストリームから分岐させるか
        parent =
          # ここを「current_actives.first」にすれば必ず Stm1 から分岐
          current_actives.min_by { |s| (s.last_note - note).abs }

        # 親の“現在ステップ前”の状態を丸ごとコピー
        parent_snapshot = Marshal.load(Marshal.dump(parent.manager))
        # 新ストリーム側にこのステップのノートを 1 回だけ追加
        parent_snapshot.add_data_point_permanently(note)

        new_container = StreamContainer.new(@next_stream_id, parent_snapshot)
        new_container.last_note = note
        new_containers << new_container
        @next_stream_id += 1
      end

      # 2) 既存ストリームに対して、このステップのノートを追加
      current_actives.each_with_index do |s, i|
        note = base_notes[i]
        s.manager.add_data_point_permanently(note)
        s.last_note = note
      end

      # 3) 新しく生まれたストリームをプールに登録
      @stream_pool.concat(new_containers)

    else
      # --- ケース3: ノート数 < ストリーム数（ストリーム減少） ---
      available_streams = current_actives.dup
      next_actives      = []

      # 各ノートに対して「一番近い last_note を持つストリーム」を選び、そのストリームだけ延命
      ordered_chord.each do |note|
        best_s = available_streams.min_by { |s| (s.last_note - note).abs }
        best_s.manager.add_data_point_permanently(note)
        best_s.last_note = note
        next_actives << best_s
        available_streams.delete(best_s)
      end

      # 余ったストリームは非アクティブ化
      available_streams.each { |s| s.active = false }
      next_actives.each     { |s| s.active = true }
    end
  end


  def update_caches_permanently(quadratic_integer_array)
    active_streams.each do |s|
      s.manager.update_caches_permanently(quadratic_integer_array)
    end
  end

  private


  # ============================
  #  複雑度ベースの所属決定
  # ============================
  def resolve_mapping_by_complexity(cand_set, stream_costs, current_actives, n_streams, n_notes)
    mapping_result = []

    if n_notes == n_streams
      # ---- ケース1: ノート数 = ストリーム数 ----
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
      # ---- ケース2: ノート数 > ストリーム数 ----
      # まずは「既存ストリームに1つずつ割り当て」部分を
      # 複雑度コストの貪欲最小で行う
      available_notes = cand_set.dup
      assigned_pairs  = []

      (0...n_streams).each do |s_idx|
        # このストリームに追加したときの dist が最小のノートを選ぶ
        best_note = available_notes.min_by do |note|
          stream_costs[s_idx][note][:dist]
        end
        assigned_pairs << { stream_idx: s_idx, note: best_note }
        available_notes.delete_at(available_notes.index(best_note))
      end

      # 余ったノートは「新規ストリーム候補」として stream_idx=nil のまま
      new_pairs = available_notes.map { |n| { stream_idx: nil, note: n } }

      mapping_result = assigned_pairs + new_pairs

    else # n_notes < n_streams
      # ---- ケース3: ノート数 < ストリーム数 ----
      # 各ノートに対して、「複雑度コストが最小のストリーム」を貪欲に対応付け
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
  #  距離ベースの所属決定（従来ロジック）
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

    else # n_notes < n_streams
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
