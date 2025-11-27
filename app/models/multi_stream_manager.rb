class MultiStreamManager
  attr_reader :active_managers

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
    n_streams = current_actives.size
    n_notes = cand_set.size

    mapping_result = []

    if n_notes == n_streams
      best_perm = nil
      min_dist = Float::INFINITY

      cand_set.permutation.each do |perm|
        dist = 0
        perm.each_with_index { |note, i| dist += (current_actives[i].last_note - note).abs }
        if dist < min_dist
          min_dist = dist
          best_perm = perm
        end
      end
      mapping_result = best_perm.map.with_index { |note, i| { stream_idx: i, note: note } }

    elsif n_notes > n_streams
      available_notes = cand_set.dup
      assigned_pairs = []

      current_actives.each_with_index do |s, s_idx|
        closest_note = available_notes.min_by { |n| (s.last_note - n).abs }
        assigned_pairs << { stream_idx: s_idx, note: closest_note }
        available_notes.delete_at(available_notes.index(closest_note))
      end

      new_pairs = available_notes.map { |n| { stream_idx: nil, note: n } }
      mapping_result = assigned_pairs + new_pairs

    else # n_notes < n_streams
      available_streams = current_actives.map.with_index { |s, i| [s, i] }
      assigned_pairs = []

      cand_set.each do |note|
        best_s, best_s_idx = available_streams.min_by { |s, i| (s.last_note - note).abs }
        assigned_pairs << { stream_idx: best_s_idx, note: note }
        available_streams.delete_if { |s, i| i == best_s_idx }
      end

      mapping_result = assigned_pairs
    end

    individual_scores = []
    ordered_chord = mapping_result.map { |m| m[:note] }

    mapping_result.each do |map|
      note = map[:note]
      s_idx = map[:stream_idx]

      if s_idx
        individual_scores << stream_costs[s_idx][note]
      else
        parent_s_idx = find_closest_stream_index(note, current_actives)
        individual_scores << stream_costs[parent_s_idx][note]
      end
    end

    [ ordered_chord, { individual_scores: individual_scores } ]
  end

  def commit_state(ordered_chord, quadratic_integer_array)
    current_actives = active_streams
    n_notes = ordered_chord.size
    n_streams = current_actives.size

    if n_notes == n_streams
      current_actives.each_with_index do |s, i|
        s.manager.add_data_point_permanently(ordered_chord[i])
        s.last_note = ordered_chord[i]
      end

    elsif n_notes > n_streams
      current_actives.each_with_index do |s, i|
        s.manager.add_data_point_permanently(ordered_chord[i])
        s.last_note = ordered_chord[i]
      end

      (n_streams...n_notes).each do |i|
        note = ordered_chord[i]
        parent = current_actives.min_by { |s| (s.last_note - note).abs }

        new_mgr = Marshal.load(Marshal.dump(parent.manager))
        new_mgr.add_data_point_permanently(note)

        new_container = StreamContainer.new(@next_stream_id, new_mgr)
        @stream_pool << new_container
        @next_stream_id += 1
      end

    else # n_notes < n_streams
      available_streams = current_actives.dup
      next_actives = []

      ordered_chord.each do |note|
        best_s = available_streams.min_by { |s| (s.last_note - note).abs }
        best_s.manager.add_data_point_permanently(note)
        best_s.last_note = note
        next_actives << best_s
        available_streams.delete(best_s)
      end

      available_streams.each { |s| s.active = false }
      next_actives.each { |s| s.active = true }
    end
  end

  def update_caches_permanently(quadratic_integer_array)
    active_streams.each do |s|
      s.manager.update_caches_permanently(quadratic_integer_array)
    end
  end

  private

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
