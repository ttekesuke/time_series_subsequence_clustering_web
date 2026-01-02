# frozen_string_literal: true

# ============================================================
# lib/multi_stream_manager.rb
# ============================================================

require_relative 'polyphonic_config'
require_relative 'polyphonic_cluster_manager'

class MultiStreamManager
  include StatisticsCalculator

  StreamContainer = Struct.new(
    :id,
    :manager,
    :last_value,
    :last_abs_pitch, # 数値でも配列でも可（note chord では配列を入れる）
    :strength,
    keyword_init: true
  )

  attr_reader :stream_pool

  def initialize(
    history_matrix,
    merge_threshold_ratio,
    min_window_size,
    use_complexity_mapping: true,
    value_range: nil,
    max_set_size: PolyphonicConfig::CHORD_SIZE_RANGE.max
  )
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size
    @use_complexity_mapping = !!use_complexity_mapping

    @history_matrix = normalize_history_matrix(history_matrix)

    @next_stream_id = 1
    @stream_pool = []

    @max_simultaneous_notes = max_set_size.to_i
    @max_simultaneous_notes = 1 if @max_simultaneous_notes <= 0

    infer_value_range_from_history!
    if value_range
      vmin = value_range.min
      vmax = value_range.max
      @value_min = vmin.to_f
      @value_max = vmax.to_f
      @value_width = (@value_max - @value_min).abs
      @value_width = 1.0 if @value_width <= 0.0
      @value_range = [@value_min, @value_max]
      @fixed_value_range = true
    else
      @fixed_value_range = false
    end

    @pending_absolute_bases = nil

    build_initial_streams_from_history!
  end

  # note 側が shift 評価で使う
  def active_stream_containers(n)
    ensure_stream_count!(n)
    @stream_pool.first(n)
  end

  # ------------------------------------------------------------
  # init
  # ------------------------------------------------------------
  def initialize_caches
    @stream_pool.each do |c|
      safe_process_manager!(c.manager)
      prime_manager_cache_structures!(c.manager)
    end
  end

  def update_strengths!
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
  # precalc complexity costs (per stream, per value)
  # ------------------------------------------------------------
  def precalculate_costs(candidate_values, q_array)
    candidate_values = Array(candidate_values)
    update_value_range_from_candidates!(candidate_values) unless @fixed_value_range

    costs = {}

    @stream_pool.each do |c|
      per_value = {}
      raw_complexities = []

      candidate_values.each do |v|
        dist, _qty, comp = safe_simulate_add_and_calculate(c.manager, v, q_array)

        raw =
          if comp && finite_number?(comp)
            comp.to_f
          elsif dist && finite_number?(dist)
            dist.to_f
          else
            0.0
          end

        per_value[v] = { raw_complexity: raw }
        raw_complexities << raw
      end

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
  # mapping + score
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

    @pending_absolute_bases = absolute_bases if absolute_bases

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

    cost_matrix = Array.new(n) { Array.new(n, 0.0) }
    dist_matrix = Array.new(n) { Array.new(n, 0.0) }
    comp_matrix = Array.new(n) { Array.new(n, 0.0) }

    abs_width = nil
    if absolute_bases
      bases = Array(absolute_bases).map(&:to_f)
      pc_width = (PolyphonicConfig::NOTE_RANGE.max - PolyphonicConfig::NOTE_RANGE.min).abs.to_f
      pc_width = 1.0 if pc_width <= 0.0
      abs_width = ((bases.max - bases.min).abs + pc_width)
      abs_width = 1.0 if abs_width <= 0.0
    end

    actives.each_with_index do |stream, i|
      (0...n).each do |j|
        v = cand_set[j]

        dist01 =
          if absolute_bases
            base = absolute_bases[i].to_i

            abs_candidate =
              if v.is_a?(Array)
                v.map { |pc| base + (pc.to_i % PolyphonicConfig.pitch_class_mod) }
              else
                [base + (v.to_i % PolyphonicConfig.pitch_class_mod)]
              end

            last_abs = stream.last_abs_pitch
            if last_abs.nil?
              last = stream.last_value
              last_abs =
                if last.is_a?(Array)
                  last.map { |pc| base + (pc.to_i % PolyphonicConfig.pitch_class_mod) }
                else
                  [base + (last.to_i % PolyphonicConfig.pitch_class_mod)]
                end
            end

            pitch_dist01 = set_distance01(abs_candidate, last_abs, width: abs_width, max_count: @max_simultaneous_notes)

            count01 =
              if active_note_counts
                (active_note_counts[i].to_f / @max_simultaneous_notes.to_f).clamp(0.0, 1.0)
              else
                0.0
              end

            ((pitch_dist01 + count01) / 2.0).clamp(0.0, 1.0)
          else
            last = stream.last_value
            last = v if last.nil?

            if v.is_a?(Array) || last.is_a?(Array)
              set_distance01(v, last, width: @value_width, max_count: @max_simultaneous_notes)
            else
              raw = (v.to_f - last.to_f).abs
              (raw / @value_width).clamp(0.0, 1.0)
            end
          end

        comp01 = begin
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

      individual_scores << {
        stream_id: stream.id,
        dist: dist_matrix[i][j],
        complexity01: comp_matrix[i][j]
      }
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
  # commit
  # ------------------------------------------------------------
  def commit_state(best_chord, q_array, strength_params: nil, absolute_bases: nil)
    best_chord = Array(best_chord)
    n = best_chord.length
    ensure_stream_count!(n)

    @pending_absolute_bases = absolute_bases if absolute_bases

    actives = active_streams(n)

    actives.each_with_index do |stream, i|
      v = best_chord[i]

      safe_add_data_point!(stream.manager, v)
      stream.last_value = deep_dup(v)

      if @pending_absolute_bases
        base = @pending_absolute_bases[i].to_i
        stream.last_abs_pitch =
          if v.is_a?(Array)
            v.map { |pc| base + (pc.to_i % PolyphonicConfig.pitch_class_mod) }
          else
            [base + (v.to_i % PolyphonicConfig.pitch_class_mod)]
          end
      end
    end

    update_strengths! if strength_params
    true
  end

  def update_caches_permanently(q_array)
    @stream_pool.each do |c|
      safe_update_caches_permanently!(c.manager, q_array)
    end
    @pending_absolute_bases = nil
  end

  # ------------------------------------------------------------
  # internals
  # ------------------------------------------------------------
  private

  def deep_dup(obj)
    Marshal.load(Marshal.dump(obj))
  rescue
    obj.is_a?(Array) ? obj.map { |e| deep_dup(e) } : obj
  end

  def normalize_history_matrix(history_matrix)
    rows = Array(history_matrix).map { |row| Array(row) }
    rows = [] if rows.nil?

    max_cols = rows.map(&:length).max.to_i
    max_cols = 1 if max_cols <= 0

    # 「値が配列か？」を見て、デフォルトを決める（note chord なら [0]）
    has_array_value =
      rows.any? do |row|
        row.any? { |v| v.is_a?(Array) }
      end

    default_value = has_array_value ? [0] : 0

    rows.map do |row|
      padded = row + Array.new(max_cols - row.length, nil)
      padded[0, max_cols].map do |v|
        v.nil? ? deep_dup(default_value) : deep_dup(v)
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
      (n - @stream_pool.length).times { add_new_stream! }
    elsif @stream_pool.length > n
      @stream_pool = @stream_pool.first(n)
    end
  end

  def add_new_stream!
    id = next_stream_id!

    len =
      if @stream_pool.first && @stream_pool.first.manager.respond_to?(:data)
        Array(@stream_pool.first.manager.data).length
      else
        @history_matrix.length
      end
    len = 1 if len <= 0

    # 既存が配列なら、新規も「セット（配列）」で seed
    seed =
      if @stream_pool.first && @stream_pool.first.last_value.is_a?(Array)
        [@value_min]
      else
        @value_min
      end

    series = Array.new(len) { deep_dup(seed) }

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
      last_value: deep_dup(seed),
      last_abs_pitch: nil,
      strength: 0.0
    )
  end

  def next_stream_id!
    id = @next_stream_id
    @next_stream_id += 1
    id
  end

  def infer_value_range_from_history!
    flat = @history_matrix.flatten.compact

    # chord配列が混ざる場合は flatten がさらに下まで入るのでOK
    nums = flat.flatten.map(&:to_f) rescue flat.map(&:to_f)

    if nums.empty?
      @value_min = 0.0
      @value_max = 1.0
    else
      @value_min = nums.min
      @value_max = nums.max
    end

    @value_range = [@value_min, @value_max]

    @value_width = (@value_max - @value_min).abs
    @value_width = 1.0 if @value_width <= 0.0
  end

  def update_value_range_from_candidates!(candidate_values)
    vals = Array(candidate_values).flatten.compact.map(&:to_f) rescue Array(candidate_values).map(&:to_f)
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
  # Hungarian (min assignment)
  # ------------------------------------------------------------
  def hungarian_min_assignment(cost)
    n = cost.length
    return [] if n <= 0

    u = Array.new(n + 1, 0.0)
    v = Array.new(n + 1, 0.0)
    p = Array.new(n + 1, 0)
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
  # distance helpers (0..1)
  # ------------------------------------------------------------
  def set_distance01(a, b, width:, max_count:)
    a = a.is_a?(Array) ? a.compact : [a].compact
    b = b.is_a?(Array) ? b.compact : [b].compact

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

  # ------------------------------------------------------------
  # safe wrappers
  # ------------------------------------------------------------
  def safe_process_manager!(mgr)
    mgr.process_data if mgr.respond_to?(:process_data)
  rescue
    # noop
  end

  def prime_manager_cache_structures!(mgr)
    %i[
      cluster_distance_cache
      cluster_quantity_cache
      cluster_complexity_cache
      updated_cluster_ids_per_window_for_calculate_distance
      updated_cluster_ids_per_window_for_calculate_quantities
    ].each do |sym|
      next unless mgr.respond_to?(sym) && mgr.respond_to?("#{sym}=")
      cur = mgr.public_send(sym)
      mgr.public_send("#{sym}=", {}) if cur.nil?
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
