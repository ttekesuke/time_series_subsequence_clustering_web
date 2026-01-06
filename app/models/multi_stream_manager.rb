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
    :last_abs_pitch,   # 数値でも配列でも可（note chord では配列を入れる）
    :strength,         # 既存互換のため残す（未使用でもOK）
    :presence_sum,     # vol平均用
    :presence_count,   # vol平均用
    :presence_avg,     # vol平均用
    keyword_init: true
  )

  attr_reader :stream_pool

  def initialize(
    history_matrix,
    merge_threshold_ratio,
    min_window_size,
    use_complexity_mapping: true,
    value_range: nil,
    max_set_size: PolyphonicConfig::CHORD_SIZE_RANGE.max,
    track_presence: false # 追加：vol用だけ true
  )
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size
    @use_complexity_mapping = !!use_complexity_mapping
    @track_presence = !!track_presence

    @history_matrix = normalize_history_matrix(history_matrix)

    @next_stream_id = 1
    @stream_pool = []
    @containers_by_id = {}

    # active/inactive の概念を導入
    @active_ids = []
    @inactive_ids = []

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

  # ------------------------------------------------------------
  # active stream control
  # ------------------------------------------------------------

  # controller から「この step の active をこの順で使う」を設定できるようにする
  def set_active_stream_ids!(ids)
    ids = Array(ids).map(&:to_i).uniq
    ids = [@active_ids.first].compact if ids.empty? && @active_ids.any?
    ids = [1] if ids.empty?

    # 足りないIDがあれば作る（連番で増やす）
    ensure_stream_id_max!(ids.max)

    # inactive にいるなら復活
    revive_stream_ids!(ids & @inactive_ids)

    @active_ids = ids
  end

  def active_stream_containers(n)
    n = n.to_i
    n = 1 if n <= 0

    # active_ids が空なら、先頭から n を active にする（初回互換）
    if @active_ids.empty?
      ensure_stream_count_min!(n)
      @active_ids = @stream_pool.map(&:id).first(n)
    end

    # desired が違う場合は controller 側で lifecycle plan を適用してから set_active_stream_ids! する想定。
    # 念のため足りない分は追加で active にする
    if @active_ids.length < n
      ensure_stream_count_min!(n)
      extra = (@stream_pool.map(&:id) - @active_ids - @inactive_ids).first(n - @active_ids.length)
      @active_ids += extra
    elsif @active_ids.length > n
      @active_ids = @active_ids.first(n)
    end

    @active_ids.map { |id| @containers_by_id[id] }.compact
  end

  def inactive_stream_containers
    @inactive_ids.map { |id| @containers_by_id[id] }.compact
  end

  # ------------------------------------------------------------
  # lifecycle planning / applying (追加)
  # ------------------------------------------------------------

  # vol manager 側で呼ぶ。plan は全 dimension に適用する。
  # plan 形式:
  # {
  #   deactivate_ids: [...],
  #   revive_ids: [...],
  #   fork_pairs: [[source_id, new_id], ...],
  #   active_ids: [...]
  # }
  def build_stream_lifecycle_plan(desired_count, target:, spread:)
    desired_count = desired_count.to_i
    desired_count = 1 if desired_count <= 0

    # 現在のアクティブストリームを確定
    current_active = active_stream_containers(desired_count).map(&:id)
    cur_n = current_active.length

    target = target.to_f.clamp(0.0, 1.0)
    spread = spread.to_f.clamp(0.0, 1.0)

    plan = {
      deactivate_ids: [],
      revive_ids: [],
      fork_pairs: [],
      active_ids: current_active.dup
    }

    # --- ストリーム数減少の場合 ---
    if desired_count < cur_n
      k = cur_n - desired_count

      # targetに基づいて削除するストリームを選択
      # targetが高い → presence_avgが高いものを削除（メインストリーム削除）
      # targetが低い → presence_avgが低いものを削除（背景ストリーム削除）
      candidates = current_active.map { |id| [id, presence_of_id(id)] }

      # target値に基づいて重み付けスコアを計算
      weighted_candidates = candidates.map do |id, presence|
        # presence_avgとtargetの距離（targetが高いほど高presenceが選ばれやすい）
        if target >= 0.5
          # 高いtarget: presenceが高いほどscoreが低い（削除されやすい）
          score = 1.0 - presence
        else
          # 低いtarget: presenceが低いほどscoreが低い（削除されやすい）
          score = presence
        end

        # spreadによる確率的要素の追加（spreadが大きいほどランダム性が増す）
        random_factor = spread * (rand - 0.5) * 2.0
        adjusted_score = score + random_factor

        [id, presence, adjusted_score]
      end

      # スコア順にソートして上位k個を削除対象に
      sorted = weighted_candidates.sort_by { |_id, _presence, score| score }
      deactivate_ids = sorted.first(k).map { |id, _, _| id }

      plan[:deactivate_ids] = deactivate_ids
      plan[:active_ids] = current_active - deactivate_ids

      return plan
    end

    # --- ストリーム数増加の場合 ---
    if desired_count > cur_n
      k = desired_count - cur_n

      # 1) 非アクティブストリームから復活させるものの選択
      inactive_candidates = @inactive_ids.map { |id| [id, presence_of_id(id)] }

      if inactive_candidates.any?
        # 復活候補をtargetに基づいて評価
        revival_scores = inactive_candidates.map do |id, presence|
          # targetに近いpresenceを持つものを優先
          distance = (presence - target).abs
          # spreadによる調整
          random_factor = spread * (rand - 0.5)
          score = distance + random_factor
          [id, presence, score]
        end

        # スコア順にソート（低いスコアほどtargetに近い）
        sorted_revivals = revival_scores.sort_by { |_id, _presence, score| score }

        # 最大k個まで復活
        max_revive = [k, sorted_revivals.length].min
        revive_ids = sorted_revivals.first(max_revive).map { |id, _, _| id }
        k -= revive_ids.length

        plan[:revive_ids] = revive_ids
        plan[:active_ids] = current_active + revive_ids
      end

      # 2) まだ増やす必要があれば、フォーク（複製）で対応
      if k > 0
        # 複製元となるストリームを選択（targetに近いpresenceを持つものを優先）
        active_candidates = current_active.map { |id| [id, presence_of_id(id)] }

        fork_sources = []
        k.times do
          if active_candidates.empty?
            # 候補がない場合は最初のアクティブストリームを使用
            source_id = current_active.first
          else
            # targetに近いpresenceを持つストリームを複製元に選択
            scores = active_candidates.map do |id, presence|
              distance = (presence - target).abs
              random_factor = spread * (rand - 0.5) * 0.5  # 複製はランダム性を小さく
              [id, distance + random_factor]
            end

            # 最もtargetに近いものを選択
            source_id = scores.min_by { |_id, score| score }[0]
          end

          fork_sources << source_id
        end

        # 新しいIDを割り当ててforkペアを作成
        fork_pairs = []
        fork_sources.each do |source_id|
          new_id = @next_stream_id
          @next_stream_id += 1
          fork_pairs << [source_id, new_id]
        end

        plan[:fork_pairs] = fork_pairs
        plan[:active_ids] = plan[:active_ids] + fork_pairs.map(&:last)
      end

      return plan
    end

    # ストリーム数が変わらない場合
    plan
  end

  def update_stream_strength(stream_id, volume_value)
    return unless @track_presence

    container = @containers_by_id[stream_id.to_i]
    return unless container

    volume_value = volume_value.to_f.clamp(0.0, 1.0)

    container.presence_sum = container.presence_sum.to_f + volume_value
    container.presence_count = container.presence_count.to_i + 1

    if container.presence_count.to_i > 0
      container.presence_avg = container.presence_sum.to_f / container.presence_count.to_f
      container.presence_avg = container.presence_avg.clamp(0.0, 1.0)
    else
      container.presence_avg = volume_value
    end
  end

  def get_stream_strength(stream_id)
    container = @containers_by_id[stream_id.to_i]
    return 0.0 unless container

    container.presence_avg.to_f.clamp(0.0, 1.0)
  end

  def streams_sorted_by_strength(ascending: false)
    @stream_pool.sort_by do |container|
      ascending ? container.presence_avg.to_f : -container.presence_avg.to_f
    end
  end

  def select_streams_by_strength_target(target, count, spread: 0.0)
    return [] if count <= 0

    target = target.to_f.clamp(0.0, 1.0)
    spread = spread.to_f.clamp(0.0, 1.0)

    # すべてのストリームをstrengthで評価
    scored_streams = @stream_pool.map do |container|
      strength = container.presence_avg.to_f
      # targetとの距離 + spreadによる確率的要素
      base_score = (strength - target).abs
      random_factor = spread * (rand - 0.5) * 2.0
      [container.id, strength, base_score + random_factor]
    end

    # スコア順にソート（低いほどtargetに近い）
    sorted = scored_streams.sort_by { |_id, _strength, score| score }

    # 指定された数のストリームを選択
    sorted.first(count).map { |id, strength, _| [id, strength] }
  end


  def apply_stream_lifecycle_plan!(plan)
    plan ||= {}
    deactivate_ids = Array(plan[:deactivate_ids]).map(&:to_i)
    revive_ids     = Array(plan[:revive_ids]).map(&:to_i)
    fork_pairs     = Array(plan[:fork_pairs]).map { |a| [a[0].to_i, a[1].to_i] }
    active_ids     = Array(plan[:active_ids]).map(&:to_i)

    # deactivate
    deactivate_stream_ids!(deactivate_ids)

    # revive
    revive_stream_ids!(revive_ids)

    # fork
    fork_pairs.each do |src_id, new_id|
      fork_stream_from_id!(src_id, new_id)
    end

    # 次IDを進める（forkで new_id を指定するので）
    if fork_pairs.any?
      max_new = fork_pairs.map(&:last).max
      @next_stream_id = [@next_stream_id, max_new + 1].max
    end

    # active を plan 通りに
    set_active_stream_ids!(active_ids) if active_ids.any?
  end

  def deactivate_stream_ids!(ids)
    ids = Array(ids).map(&:to_i)
    ids.each do |id|
      next unless @active_ids.include?(id)
      @active_ids.delete(id)
      @inactive_ids << id unless @inactive_ids.include?(id)
    end
  end

  def revive_stream_ids!(ids)
    ids = Array(ids).map(&:to_i)
    ids.each do |id|
      next unless @inactive_ids.include?(id)
      @inactive_ids.delete(id)
      @active_ids << id unless @active_ids.include?(id)
    end
  end

  def fork_stream_from_id!(source_id, new_id)
    source_id = source_id.to_i
    new_id = new_id.to_i
    return if @containers_by_id.key?(new_id)

    ensure_stream_id_max!(source_id)

    src = @containers_by_id[source_id]
    # source が無い場合は seed 作成
    if src.nil?
      add_new_stream_with_id!(new_id)
      return
    end

    new_mgr = deep_clone_manager(src.manager)

    new_container = StreamContainer.new(
      id: new_id,
      manager: new_mgr,
      last_value: deep_dup(src.last_value),
      last_abs_pitch: deep_dup(src.last_abs_pitch),
      strength: 0.0,
      presence_sum: src.presence_sum.to_f,
      presence_count: src.presence_count.to_i,
      presence_avg: src.presence_avg.to_f
    )

    @stream_pool << new_container
    @containers_by_id[new_id] = new_container
    @active_ids << new_id unless @active_ids.include?(new_id)
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

  # ------------------------------------------------------------
  # precalc complexity costs (per stream, per value)
  # ※この仕組み自体は残す（他次元で必要）
  # ------------------------------------------------------------
  def precalculate_costs(candidate_values, q_array, n = nil)
    candidate_values = Array(candidate_values)
    update_value_range_from_candidates!(candidate_values) unless @fixed_value_range

    n = (n || @active_ids.length).to_i
    n = 1 if n <= 0
    actives = active_stream_containers(n)

    costs = {}

    actives.each do |c|
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
    n = 1 if n <= 0

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

    actives = active_stream_containers(n)

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

        comp01 =
          begin
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
    n = 1 if n <= 0

    @pending_absolute_bases = absolute_bases if absolute_bases

    actives = active_stream_containers(n)

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

      # 音量値をストリーム強度として更新
      if @track_presence && !(v.is_a?(Array))
        vv = v.to_f.clamp(0.0, 1.0)
        stream.presence_sum = stream.presence_sum.to_f + vv
        stream.presence_count = stream.presence_count.to_i + 1
        stream.presence_avg =
          if stream.presence_count.to_i > 0
            (stream.presence_sum.to_f / stream.presence_count.to_f).clamp(0.0, 1.0)
          else
            vv
          end
      elsif strength_params && strength_params[:update_strength]
        # 手動で強度を更新する場合
        update_stream_strength(stream.id, strength_params[:update_strength])
      end
    end

    true
  end

  def update_caches_permanently(q_array)
    @stream_pool.each do |c|
      safe_update_caches_permanently!(c.manager, q_array)
    end
    @pending_absolute_bases = nil
  end

  def stream_strengths_report
    report = {}

    @stream_pool.each do |container|
      report[container.id] = {
        active: @active_ids.include?(container.id),
        presence_avg: container.presence_avg.to_f,
        presence_count: container.presence_count.to_i,
        last_value: container.last_value
      }
    end

    report
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

  def deep_clone_manager(mgr)
    Marshal.load(Marshal.dump(mgr))
  rescue
    # フォールバック：data を複製して再構築（重いが安全）
    data = begin
      mgr.respond_to?(:data) ? deep_dup(mgr.data) : []
    rescue
      []
    end

    new_mgr = PolyphonicClusterManager.new(
      data,
      @merge_threshold_ratio,
      @min_window_size,
      @value_range,
      max_set_size: @max_simultaneous_notes
    )
    safe_process_manager!(new_mgr)
    prime_manager_cache_structures!(new_mgr)
    new_mgr
  end

  def ensure_stream_id_max!(max_id)
    max_id = max_id.to_i
    return if max_id <= 0
    while @next_stream_id <= max_id
      add_new_stream_with_id!(@next_stream_id)
      @next_stream_id += 1
    end
  end

  def ensure_stream_count_min!(n)
    n = n.to_i
    n = 1 if n <= 0
    ensure_stream_id_max!(n) if @stream_pool.length < n
  end

  def add_new_stream_with_id!(id)
    id = id.to_i
    return if @containers_by_id.key?(id)

    len =
      if @stream_pool.first && @stream_pool.first.manager.respond_to?(:data)
        Array(@stream_pool.first.manager.data).length
      else
        @history_matrix.length
      end
    len = 1 if len <= 0

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

    container = StreamContainer.new(
      id: id,
      manager: mgr,
      last_value: deep_dup(seed),
      last_abs_pitch: nil,
      strength: 0.0,
      presence_sum: 0.0,
      presence_count: 0,
      presence_avg: 0.0
    )

    @stream_pool << container
    @containers_by_id[id] = container

    # 初期は active に入れておく（controller が後で調整）
    @active_ids << id unless @active_ids.include?(id)
  end

  def normalize_history_matrix(history_matrix)
    rows = Array(history_matrix).map { |row| Array(row) }
    rows = [] if rows.nil?

    max_cols = rows.map(&:length).max.to_i
    max_cols = 1 if max_cols <= 0

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
      id = @next_stream_id
      @next_stream_id += 1

      mgr = PolyphonicClusterManager.new(
        series.dup,
        @merge_threshold_ratio,
        @min_window_size,
        @value_range,
        max_set_size: @max_simultaneous_notes
      )

      # presence 初期化（scalar のときだけ）
      pres_sum = 0.0
      pres_cnt = 0
      pres_avg = 0.0
      if @track_presence
        series.each do |v|
          next if v.is_a?(Array)
          vv = v.to_f.clamp(0.0, 1.0)
          pres_sum += vv
          pres_cnt += 1
        end
        pres_avg = pres_cnt > 0 ? (pres_sum / pres_cnt.to_f).clamp(0.0, 1.0) : series.last.to_f.clamp(0.0, 1.0)
      end

      container = StreamContainer.new(
        id: id,
        manager: mgr,
        last_value: series.last,
        last_abs_pitch: nil,
        strength: 0.0,
        presence_sum: pres_sum,
        presence_count: pres_cnt,
        presence_avg: pres_avg
      )

      @stream_pool << container
      @containers_by_id[id] = container
      @active_ids << id
    end
  end

  def infer_value_range_from_history!
    flat = @history_matrix.flatten.compact
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
  # lifecycle helpers
  # ------------------------------------------------------------
  def presence_of_id(id)
    c = @containers_by_id[id.to_i]
    return 0.0 unless c
    # track_presence がない manager でも動くように fallback を入れる
    if @track_presence
      c.presence_avg.to_f.clamp(0.0, 1.0)
    else
      v = c.last_value
      v.is_a?(Array) ? 0.0 : v.to_f.clamp(0.0, 1.0)
    end
  end

  def centered_targets(n, center, spread)
    n = n.to_i
    return [] if n <= 0
    return [center.to_f.clamp(0.0, 1.0)] if n == 1

    center = center.to_f.clamp(0.0, 1.0)
    spread = spread.to_f.clamp(0.0, 1.0)

    half_width = spread / 2.0
    start_val = (center - half_width).clamp(0.0, 1.0)
    end_val   = (center + half_width).clamp(0.0, 1.0)

    (0...n).map do |i|
      t = i.to_f / (n - 1)
      (start_val + (end_val - start_val) * t).clamp(0.0, 1.0)
    end
  end

  # candidates: [[id, presence], ...]
  def pick_ids_by_targets_unique(candidates, targets)
    pool = Array(candidates).map { |id, pv| [id.to_i, pv.to_f] }
    out = []
    targets.each do |t|
      break if pool.empty?
      best = pool.min_by { |(_id, pv)| (pv - t.to_f).abs }
      out << best[0]
      pool.delete(best)
    end
    out
  end

  # ------------------------------------------------------------
  # Hungarian (min assignment) - 既存そのまま
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
  # distance helpers (0..1) - 既存そのまま
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
