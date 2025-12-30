# frozen_string_literal: true

# ============================================================
# lib/multi_stream_manager.rb
#
# 役割:
# - cand_set（同時刻の値配列）を「どのストリームに割り当てるか」を決める
# - ストリームごとの TimeSeriesClusterManager(PolyphonicClusterManager) を保持して更新する
#
# 重要:
# - mapping は「距離」と「複雑度(=cluster由来スコア)」の混合で行える
# - note の場合は octave 決定後に absolute pitch (= base + pc) の距離で mapping できる
# - 同時発音密度(density)により distance_weight / complexity_weight を外側から与えられる
# ============================================================

require_relative 'polyphonic_config'
require_relative 'polyphonic_cluster_manager'

class MultiStreamManager
  include StatisticsCalculator

  StreamContainer = Struct.new(
    :id,
    :manager,
    :last_value,      # 直近の「この次元の値」（noteなら pitch-class）
    :last_abs_pitch,  # note専用: 直近の「絶対ピッチ」（octave base + pc）
    :strength,        # vol用など（任意）
    keyword_init: true
  )

  attr_reader :stream_pool

  # history_matrix: [step][stream] の配列（その次元だけ抜き出した履歴）
  def initialize(history_matrix, merge_threshold_ratio, min_window_size, use_complexity_mapping: true)
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size

    # ★fix: これを入れないと @use_complexity_mapping 未初期化を踏む/真偽が曖昧になりがち
    @use_complexity_mapping = !!use_complexity_mapping

    @history_matrix = normalize_history_matrix(history_matrix)

    @next_stream_id = 1
    @stream_pool = []

    # 値域（あとから candidates を見て更新しても良い）
    infer_value_range_from_history!

    # note用: resolve_mapping_and_score 呼び出し中に保持 → commit_state で確定値に反映する
    @pending_absolute_bases = nil

    # chord_size 最大（count_dist 正規化に使う）
    @max_simultaneous_notes = PolyphonicConfig::CHORD_SIZE_RANGE.max.to_i
    @max_simultaneous_notes = 1 if @max_simultaneous_notes <= 0

    build_initial_streams_from_history!
  end

  # ------------------------------------------------------------
  # 初期化系
  # ------------------------------------------------------------
  def initialize_caches
    @stream_pool.each do |c|
      safe_process_manager!(c.manager)
      prime_manager_cache_structures!(c.manager)
    end
  end

  def update_strengths!
    # vol 用の「ストリーム存在感」みたいなやつ（任意）
    values = @stream_pool.map { |c| c.last_value.to_f }
    min_v = values.min
    max_v = values.max
    width = (max_v - min_v).abs
    width = 1.0 if width <= 0.0

    @stream_pool.each do |c|
      c.strength = ((c.last_value.to_f - min_v) / width).clamp(0.0, 1.0)
    end
  end

  # ------------------------------------------------------------
  # candidates に対する stream 側の「複雑度スコア」を前計算
  # 返り値:
  #   { stream_id => { value => { complexity01: Float } } }
  # ------------------------------------------------------------
  def precalculate_costs(candidate_values, q_array)
    candidate_values = Array(candidate_values)

    # ★候補を見て値域を最新化（距離正規化が安定する）
    update_value_range_from_candidates!(candidate_values)

    costs = {}

    @stream_pool.each do |c|
      per_value = {}

      raw_complexities = []

      candidate_values.each do |v|
        # simulate_add_and_calculate が無い/失敗しても落ちないように
        dist, qty, comp = safe_simulate_add_and_calculate(c.manager, v, q_array)

        # 「複雑度代表値」は comp を優先。無ければ dist を流用
        raw = if comp && finite_number?(comp)
                comp.to_f
              elsif dist && finite_number?(dist)
                dist.to_f
              else
                0.0
              end

        per_value[v] = { raw_complexity: raw }
        raw_complexities << raw
      end

      # 0..1 正規化（その stream 内での相対）
      min_r = raw_complexities.min
      max_r = raw_complexities.max
      span  = (max_r - min_r).abs
      span  = 1.0 if span <= 0.0

      candidate_values.each do |v|
        raw = per_value[v][:raw_complexity].to_f
        per_value[v][:complexity01] = ((raw - min_r) / span).clamp(0.0, 1.0)
      end

      costs[c.id] = per_value
    end

    costs
  end

  # ------------------------------------------------------------
  # cand_set を「現在の active streams」に割り当てて
  # 「ordered_cand（= stream順に並んだ配列）」と
  # 「stream側のスコア」を返す
  #
  # keyword:
  #   absolute_bases: note専用。stream i の octave base（midiのC）配列
  #   active_note_counts: note専用。stream i の chord_size
  #   active_total_notes: note専用。総ノート数（密度計算は外側で済ませてもOK）
  #   distance_weight / complexity_weight: 距離と複雑度の混合率（0..1想定）
  # ------------------------------------------------------------
  def resolve_mapping_and_score(
    cand_set,
    stream_costs,
    absolute_bases: nil,
    active_note_counts: nil,
    active_total_notes: nil,
    distance_weight: nil,
    complexity_weight: nil
  )
    cand_set = Array(cand_set)
    n = cand_set.length
    ensure_stream_count!(n)

    # note用: commit_state で last_abs_pitch を更新するため保持
    @pending_absolute_bases = absolute_bases if absolute_bases

    # mode（従来互換）
    if distance_weight.nil? || complexity_weight.nil?
      if @use_complexity_mapping
        distance_weight   = 0.0
        complexity_weight = 1.0
      else
        distance_weight   = 1.0
        complexity_weight = 0.0
      end
    end

    distance_weight   = distance_weight.to_f.clamp(0.0, 1.0)
    complexity_weight = complexity_weight.to_f.clamp(0.0, 1.0)

    actives = active_streams(n)

    # コスト行列（stream i に cand j を割り当てるコスト）
    cost_matrix = Array.new(n) { Array.new(n, 0.0) }
    dist_matrix = Array.new(n) { Array.new(n, 0.0) }
    comp_matrix = Array.new(n) { Array.new(n, 0.0) }

    abs_width = nil
    if absolute_bases
      bases = Array(absolute_bases).map(&:to_f)
      abs_width = ((bases.max - bases.min).abs + 11.0)
      abs_width = 1.0 if abs_width <= 0.0
    end

    actives.each_with_index do |stream, i|
      (0...n).each do |j|
        v = cand_set[j]

        dist01 =
          if absolute_bases
            # note: stream i に割り当てた場合の絶対ピッチ距離
            base = absolute_bases[i].to_f
            abs_candidate = base + v.to_f
            last_abs = stream.last_abs_pitch
            last_abs = abs_candidate if last_abs.nil?

            pitch_dist01 = ((abs_candidate - last_abs).abs / abs_width).clamp(0.0, 1.0)

            # ★count_dist 正規化: chord_size / max_simultaneous_notes
            count01 =
              if active_note_counts
                (active_note_counts[i].to_f / @max_simultaneous_notes.to_f).clamp(0.0, 1.0)
              else
                0.0
              end

            # ★pitch_dist と count_dist を同スケールで平均（以前ここが怪しかった）
            ((pitch_dist01 + count01) / 2.0).clamp(0.0, 1.0)
          else
            # 通常次元: 最終値との距離
            last = stream.last_value
            last = v if last.nil?
            raw = (v.to_f - last.to_f).abs
            (raw / @value_width).clamp(0.0, 1.0)
          end

        comp01 = begin
          # stream_costs は precalculate_costs の返り値を想定
          h = stream_costs && stream_costs[stream.id] && stream_costs[stream.id][v]
          h ? h[:complexity01].to_f : 0.5
        rescue
          0.5
        end

        dist_matrix[i][j] = dist01
        comp_matrix[i][j] = comp01
        cost_matrix[i][j] = (distance_weight * dist01) + (complexity_weight * comp01)
      end
    end

    assignment = hungarian_min_assignment(cost_matrix)
    # assignment: stream i -> cand index j

    ordered = Array.new(n)
    individual_scores = []
    total_dist = 0.0
    total_comp = 0.0

    actives.each_with_index do |stream, i|
      j = assignment[i]
      v = cand_set[j]
      ordered[i] = v

      total_dist += dist_matrix[i][j]
      total_comp += comp_matrix[i][j]

      # cost_b 側で使う想定（0..1の複雑度寄りスコア）
      individual_scores << { stream_id: stream.id, dist: comp_matrix[i][j] }
    end

    avg_dist = (total_dist / n.to_f).clamp(0.0, 1.0)
    avg_comp = (total_comp / n.to_f).clamp(0.0, 1.0)

    metric = {
      individual_scores: individual_scores,
      avg_distance01: avg_dist,
      avg_complexity01: avg_comp
    }

    [ordered, metric]
  end

  # ------------------------------------------------------------
  # 確定値を各 stream manager にコミット
  # ------------------------------------------------------------
  def commit_state(best_chord, q_array, strength_params: nil)
    best_chord = Array(best_chord)
    n = best_chord.length
    ensure_stream_count!(n)

    actives = active_streams(n)

    actives.each_with_index do |stream, i|
      v = best_chord[i]

      safe_add_data_point!(stream.manager, v)
      stream.last_value = v

      # note の場合、resolve_mapping_and_score で保持した absolute_bases を使って last_abs_pitch を更新
      if @pending_absolute_bases
        base = @pending_absolute_bases[i].to_i
        stream.last_abs_pitch = base + v.to_i
      end
    end

    # vol の「主従」を作りたい場合など（任意）
    if strength_params
      update_strengths!
    end

    true
  end

  def update_caches_permanently(q_array)
    @stream_pool.each do |c|
      safe_update_caches_permanently!(c.manager, q_array)
    end

    # note用の保持は「その step の commit が終わったら」捨てる
    @pending_absolute_bases = nil
  end

  # ------------------------------------------------------------
  # 内部ヘルパ
  # ------------------------------------------------------------
  private

  def normalize_history_matrix(history_matrix)
    m = Array(history_matrix)
    m = [] if m.nil?
    m.map do |row|
      Array(row).map do |v|
        v.nil? ? 0 : v
      end
    end
  end

  def build_initial_streams_from_history!
    steps = @history_matrix.length
    stream_count = @history_matrix.first ? @history_matrix.first.length : 1
    stream_count = 1 if stream_count <= 0

    (0...stream_count).each do |s_idx|
      series = Array.new(steps) { |t| @history_matrix[t][s_idx] }
      id = next_stream_id!

      mgr = PolyphonicClusterManager.new(
        series.dup,
        @merge_threshold_ratio,
        @min_window_size,
        @value_range,
        max_set_size: @max_simultaneous_notes
      )

      @stream_pool << StreamContainer.new(
        id: id,
        manager: mgr,
        last_value: series.last,
        last_abs_pitch: nil,
        strength: 0.0
      )
    end
  end

  def active_streams(n)
    @stream_pool.first(n)
  end

  def ensure_stream_count!(n)
    n = n.to_i
    n = 1 if n <= 0

    if @stream_pool.length < n
      add_count = n - @stream_pool.length
      add_count.times { add_new_stream! }
    elsif @stream_pool.length > n
      # 減った場合は「後ろを inactive」と見做す（保持しても良いが、ここでは切る）
      @stream_pool = @stream_pool.first(n)
    end
  end

  def add_new_stream!
    id = next_stream_id!

    # 既存の長さに合わせて“素直に”埋める
    len =
      if @stream_pool.first && @stream_pool.first.manager.respond_to?(:data)
        Array(@stream_pool.first.manager.data).length
      else
        @history_matrix.length
      end
    len = 1 if len <= 0

    seed = @value_min
    series = Array.new(len, seed)

    mgr = PolyphonicClusterManager.new(
      series.dup,
      @merge_threshold_ratio,
      @min_window_size,
      @value_range,
      max_set_size: @max_simultaneous_notes
    )

    safe_process_manager!(mgr)
    prime_manager_cache_structures!(mgr)

    @stream_pool << StreamContainer.new(
      id: id,
      manager: mgr,
      last_value: seed,
      last_abs_pitch: nil,
      strength: 0.0
    )
  end

  def next_stream_id!
    id = @next_stream_id
    @next_stream_id += 1
    id
  end

  # 値域推定（初期）
  def infer_value_range_from_history!
    flat = @history_matrix.flatten.compact.map(&:to_f)
    if flat.empty?
      @value_min = 0.0
      @value_max = 1.0
    else
      @value_min = flat.min
      @value_max = flat.max
    end

    # それっぽいレンジを用意（PolyphonicClusterManager に渡す）
    @value_range = [@value_min, @value_max]

    @value_width = (@value_max - @value_min).abs
    @value_width = 1.0 if @value_width <= 0.0
  end

  # 候補を見て値域更新（距離正規化が崩れないように）
  def update_value_range_from_candidates!(candidate_values)
    vals = Array(candidate_values).map(&:to_f)
    return if vals.empty?

    cmin = vals.min
    cmax = vals.max

    @value_min = [@value_min, cmin].min
    @value_max = [@value_max, cmax].max

    @value_range = [@value_min, @value_max]

    @value_width = (@value_max - @value_min).abs
    @value_width = 1.0 if @value_width <= 0.0
  end

  # ------------------------------------------------------------
  # Hungarian (min assignment)  O(n^3)
  # 入力: cost[n][n]
  # 出力: assignment[n] where assignment[i]=j
  # ------------------------------------------------------------
  def hungarian_min_assignment(cost)
    n = cost.length
    return [] if n <= 0

    u = Array.new(n + 1, 0.0)
    v = Array.new(n + 1, 0.0)
    p = Array.new(n + 1, 0)   # matched row for column j
    way = Array.new(n + 1, 0)

    (1..n).each do |i|
      p[0] = i
      j0 = 0
      minv = Array.new(n + 1, Float::INFINITY)
      used = Array.new(n + 1, false)

      loop do
        used[j0] = true
        i0 = p[j0]
        delta = Float::INFINITY
        j1 = 0

        (1..n).each do |j|
          next if used[j]
          cur = cost[i0 - 1][j - 1] - u[i0] - v[j]
          if cur < minv[j]
            minv[j] = cur
            way[j] = j0
          end
          if minv[j] < delta
            delta = minv[j]
            j1 = j
          end
        end

        (0..n).each do |j|
          if used[j]
            u[p[j]] += delta
            v[j] -= delta
          else
            minv[j] -= delta
          end
        end

        j0 = j1
        break if p[j0] == 0
      end

      loop do
        j1 = way[j0]
        p[j0] = p[j1]
        j0 = j1
        break if j0 == 0
      end
    end

    assignment = Array.new(n, 0)
    (1..n).each do |j|
      assignment[p[j] - 1] = j - 1
    end
    assignment
  end

  # ------------------------------------------------------------
  # manager 呼び出しの安全ラッパ
  # ------------------------------------------------------------
  def safe_process_manager!(mgr)
    mgr.process_data if mgr.respond_to?(:process_data)
  rescue
    # noop
  end

  def prime_manager_cache_structures!(mgr)
    # simulate_add_and_calculate が内部でこれらを期待する場合があるので
    # “あれば”初期化しておく
    %i[
      cluster_distance_cache
      cluster_quantity_cache
      cluster_complexity_cache
      updated_cluster_ids_per_window_for_calculate_distance
      updated_cluster_ids_per_window_for_calculate_quantities
    ].each do |sym|
      next unless mgr.respond_to?(sym) && mgr.respond_to?("#{sym}=")

      cur = mgr.public_send(sym)
      if cur.nil?
        mgr.public_send("#{sym}=", (sym.to_s.include?('updated_') ? {} : {}))
      end
    end
  rescue
    # noop
  end

  def safe_simulate_add_and_calculate(mgr, value, q_array)
    return [0.0, 0.0, 0.0] unless mgr.respond_to?(:simulate_add_and_calculate)
    mgr.simulate_add_and_calculate(value, q_array, self)
  rescue
    [0.0, 0.0, 0.0]
  end

  def safe_add_data_point!(mgr, value)
    if mgr.respond_to?(:add_data_point_permanently)
      mgr.add_data_point_permanently(value)
    elsif mgr.respond_to?(:data)
      mgr.data << value
    end
  rescue
    # noop
  end

  def safe_update_caches_permanently!(mgr, q_array)
    mgr.update_caches_permanently(q_array) if mgr.respond_to?(:update_caches_permanently)
  rescue
    # noop
  end

  def finite_number?(x)
    x.is_a?(Numeric) && x.finite?
  end
end
