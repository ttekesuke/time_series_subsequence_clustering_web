class TimeSeriesClusterManager
  include StatisticsCalculator
  include Utility
  attr_accessor :clusters, :cluster_id_counter, :tasks
  attr_accessor :updated_cluster_ids_per_window_for_calculate_distance
  attr_accessor :cluster_distance_cache
  attr_accessor :updated_cluster_ids_per_window_for_calculate_quantities
  attr_accessor :cluster_quantity_cache
  attr_reader :recording_mode

  def initialize(data, merge_threshold_ratio, min_window_size, calculate_distance_when_added_subsequence_to_cluster)
    @data = data
    @merge_threshold_ratio = merge_threshold_ratio
    @min_window_size = min_window_size
    @calculate_distance_when_added_subsequence_to_cluster = calculate_distance_when_added_subsequence_to_cluster
    @cluster_id_counter = 0

    # 初期化 (ID:0 の強制更新ロジックは削除済み)
    @clusters = { @cluster_id_counter => { si: [0], cc: {}, as: [0, min_window_size] } }
    # clustersの構成
    # clusters = {
    #   cluster_id1 => {
    #     si: [start_index1,start_index2..],
    #     cc: {
    #       cluster_id2 => {
    #         si: [start_index3,start_index4..],
    #         cc: {},
    #         as: [average_of_sequences_in_same_cluster]
    #       },
    #       cluster_id3 => {
    #         si: [start_index5,start_index6..],
    #         cc: {},
    #         as: [average_of_sequences_in_same_cluster]
    #       }
    #     }
    #   }
    # }

    @updated_cluster_ids_per_window_for_calculate_distance = {}
    @updated_cluster_ids_per_window_for_calculate_distance[@min_window_size] ||= Set.new
    @updated_cluster_ids_per_window_for_calculate_distance[@min_window_size] << @cluster_id_counter

    @updated_cluster_ids_per_window_for_calculate_quantities = {}
    @updated_cluster_ids_per_window_for_calculate_quantities[@min_window_size] ||= Set.new
    @updated_cluster_ids_per_window_for_calculate_quantities[@min_window_size] << @cluster_id_counter

    @cluster_distance_cache = {}
    @cluster_distance_cache[@min_window_size] ||= {}
    @cluster_quantity_cache = {}
    @cluster_quantity_cache[@min_window_size] ||= {}
    @cluster_id_counter += 1
    @tasks = []
    @recording_mode = false
    @journal = []
  end

  # ... (process_data, add_data_point_permanently 等は変更なし) ...
  def process_data
    @data.each_with_index do |_, data_index|
      next if data_index <= @min_window_size - 1
      clustering_subsequences_incremental(data_index)
    end
  end

  def add_data_point_permanently(val)
    @data << val
    clustering_subsequences_incremental(@data.length - 1)
  end

  # --- Lv.3 シミュレーション (ControllerContext対応) ---
  def simulate_add_and_calculate(candidate, quadratic_integer_array, controller_context)
    start_transaction!
    reset_updated_ids_for_simulation!

    begin
      @data << candidate
      record_action(:data_push)

      clustering_subsequences_incremental(@data.length - 1)

      # 修正: self.transform_clusters を呼ぶ (コントローラではなく自身に定義)
      clusters_each_window_size = transform_clusters(@clusters, @min_window_size)

      sum_distances_in_all_window = 0
      sum_similar_subsequences_quantities = 0

      clusters_each_window_size.each do |window_size, same_window_size_clusters|
        sum_distances = 0
        all_ids = same_window_size_clusters.keys
        updated_ids = @updated_cluster_ids_per_window_for_calculate_distance[window_size].to_a

        cache = @cluster_distance_cache[window_size]
        if cache.nil?
          cache = {}
          @cluster_distance_cache[window_size] = cache
          record_action(:hash_set_key, @cluster_distance_cache, window_size, nil)
        end

        updated_ids.each do |cid1|
          all_ids.each do |cid2|
            next if cid1 == cid2
            key = [cid1, cid2].sort
            as1 = same_window_size_clusters.dig(cid1, :as)
            as2 = same_window_size_clusters.dig(cid2, :as)
            if as1 && as2
              # 距離計算は controller_context を介する
              dist = controller_context.send(:euclidean_distance, as1, as2)
              old_val = cache[key]
              cache[key] = dist
              record_action(:cache_write, cache, key, old_val)
            end
          end
        end
        sum_distances = cache.values.sum
        sum_distances_in_all_window += (sum_distances / window_size)

        updated_quant_ids = @updated_cluster_ids_per_window_for_calculate_quantities[window_size].to_a rescue []
        q_cache = @cluster_quantity_cache[window_size]
        if q_cache.nil?
          q_cache = {}
          @cluster_quantity_cache[window_size] = q_cache
          record_action(:hash_set_key, @cluster_quantity_cache, window_size, nil)
        end

        updated_quant_ids.each do |cid|
          cluster = same_window_size_clusters[cid]
          if cluster && cluster[:si].length > 1
            # transform_clusters経由なので s[0]
            quantity = cluster[:si].map { |s| quadratic_integer_array[s[0]] }.inject(1) { |product, n| product * n }
            old_val = q_cache[cid]
            q_cache[cid] = quantity
            record_action(:cache_write, q_cache, cid, old_val)
          end
        end
        sum_similar_subsequences_quantities += q_cache.values.sum
      end

      return sum_distances_in_all_window, sum_similar_subsequences_quantities

    ensure
      rollback!
    end
  end
  def clusters_to_timeline(clusters, min_window_size)
    stack = clusters.map { |id, cluster| [min_window_size, id, cluster] }
    result = []

    until stack.empty?
      window_size, cluster_id, current = stack.pop
      current[:si].each do |start_index|
        result << [window_size.to_s, cluster_id.to_s(26).tr("0-9a-p", "a-z"), start_index * 1000, (start_index + window_size) * 1000]
      end

      if current[:cc]
        current[:cc].each do |child_id, child_cluster|
          stack.push([window_size + 1, child_id, child_cluster])
        end
      end
    end
    return result
  end


  def transform_clusters(clusters, min_window_size)
    clusters_each_window_size = {}
    stack = clusters.map { |id, cluster| [id, cluster, min_window_size] }

    until stack.empty?
      cluster_id, current_cluster, depth = stack.pop
      sequences = current_cluster[:si].map { |start_index| [start_index, start_index + depth - 1] }

      clusters_each_window_size[depth] ||= {}
      clusters_each_window_size[depth][cluster_id] = {si: sequences, as: current_cluster[:as]}

      current_cluster[:cc].each do |sub_cluster_id, sub_cluster|
        stack.push([sub_cluster_id, sub_cluster, depth + 1])
      end
    end

    clusters_each_window_size
  end

  # ... (以下、privateメソッド: start_transaction, rollback, record_action, reset_updated_ids, clustering_subsequences_incremental 等は前回と同じ) ...
  def add_updated_id(hash, window, id)
    hash[window] ||= Set.new
    hash[window] << id
  end

  private

  def start_transaction!
    @recording_mode = true
    @journal = []
    @snapshot_state = {
      tasks: @tasks.dup,
      cluster_id_counter: @cluster_id_counter,
      updated_dist_ids: deep_dup_sets(@updated_cluster_ids_per_window_for_calculate_distance),
      updated_quant_ids: deep_dup_sets(@updated_cluster_ids_per_window_for_calculate_quantities)
    }
  end

  def reset_updated_ids_for_simulation!
    @updated_cluster_ids_per_window_for_calculate_distance.clear
    @updated_cluster_ids_per_window_for_calculate_quantities.clear
  end

  def rollback!
    @journal.reverse_each do |entry|
      case entry[:type]
      when :data_push
        @data.pop
      when :si_push
        entry[:target][:si].pop
      when :as_update
        entry[:target][:as] = entry[:old_value]
      when :cc_add
        entry[:target].delete(entry[:key])
      when :root_add
        @clusters.delete(entry[:key])
      when :cache_write, :hash_set_key
        if entry[:old_value].nil?
          entry[:target].delete(entry[:key])
        else
          entry[:target][entry[:key]] = entry[:old_value]
        end
      end
    end

    @tasks = @snapshot_state[:tasks]
    @cluster_id_counter = @snapshot_state[:cluster_id_counter]
    @updated_cluster_ids_per_window_for_calculate_distance = @snapshot_state[:updated_dist_ids]
    @updated_cluster_ids_per_window_for_calculate_quantities = @snapshot_state[:updated_quant_ids]

    @recording_mode = false
    @journal = []
    @snapshot_state = nil
  end

  def record_action(type, target = nil, key = nil, old_value = nil)
    return unless @recording_mode
    @journal << { type: type, target: target, key: key, old_value: old_value }
  end

  def deep_dup_sets(hash_of_sets)
    new_h = {}
    hash_of_sets.each do |k, v|
      new_h[k] = v.dup
    end
    new_h
  end

  def clustering_subsequences_incremental(data_index)
    data_mean = mean(@data[0..data_index])
    lower_half_average = mean(@data.select { |x| x <= data_mean })
    upper_half_average = mean(@data.select { |x| x >= data_mean })
    max_distance_between_lower_and_upper = euclidean_distance(
      Array.new(data_index + 1, lower_half_average),
      Array.new(data_index + 1, upper_half_average)
    )

    current_tasks = @tasks.dup
    @tasks.clear

    current_tasks.each do |task|
      keys_to_parent = task[0].dup
      length = task[1].dup
      parent = dig_clusters_by_keys(@clusters, keys_to_parent)
      new_length = length + 1
      latest_start = data_index - new_length + 1
      latest_seq = @data[latest_start, new_length]
      valid_si = parent[:si].select { |s| s + new_length <= data_index + 1 && s != latest_start }
      next if valid_si.empty?

      if parent[:cc].any?
        process_existing_clusters(parent, latest_seq, valid_si, max_distance_between_lower_and_upper, latest_start, new_length, keys_to_parent)
      else
        process_new_clusters(parent, valid_si, latest_seq, max_distance_between_lower_and_upper, latest_start, new_length, keys_to_parent)
      end
    end

    process_root_clusters(data_index, max_distance_between_lower_and_upper)
  end

  def process_existing_clusters(parent, latest_seq, valid_si, max_distance, latest_start, new_length, keys_to_parent)
    min_distance, best_clusters, best_cluster_id = Float::INFINITY, [], nil
    parent[:cc].each do |cluster_id, child|
      distance = nil
      child[:si].each do |s|
        distance = euclidean_distance(@data[s, new_length], latest_seq)
      end
      if distance < min_distance
        min_distance = distance
        best_clusters = [child]
        best_cluster_id = cluster_id
      elsif distance == min_distance
        best_clusters << child
        best_cluster_id = cluster_id
      end
    end

    ratio_in_max_distance = max_distance.zero? ? 0 : min_distance / max_distance
    if ratio_in_max_distance <= @merge_threshold_ratio
      target_cluster = best_clusters.first

      target_cluster[:si] << latest_start
      record_action(:si_push, target_cluster)

      old_as = target_cluster[:as]
      new_as = average_sequences(target_cluster[:si].map { |s| @data[s, new_length] })
      target_cluster[:as] = new_as
      record_action(:as_update, target_cluster, nil, old_as)

      add_updated_id(@updated_cluster_ids_per_window_for_calculate_quantities, new_length, best_cluster_id)

      if @calculate_distance_when_added_subsequence_to_cluster
        add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, new_length, best_cluster_id)
      end
      @tasks << [keys_to_parent.dup << best_cluster_id, new_length]
    else
      new_cluster = { si: [latest_start], cc: {}, as: latest_seq.dup }
      parent[:cc][@cluster_id_counter] = new_cluster
      record_action(:cc_add, parent[:cc], @cluster_id_counter)

      add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, new_length, @cluster_id_counter)
      @cluster_id_counter += 1
    end
  end

  def process_new_clusters(parent, valid_si, latest_seq, max_distance, latest_start, new_length, keys_to_parent)
    valid_group = []
    invalid_group = []
    valid_si.each do |s|
      distance = euclidean_distance(@data[s, new_length], latest_seq)
      ratio_in_max_distance = max_distance.zero? ? 0 : distance / max_distance

      if ratio_in_max_distance <= @merge_threshold_ratio
        valid_group << s
      else
        invalid_group << s
      end
    end

    if valid_group.any?
      new_cluster = { si: valid_group + [latest_start], cc: {}, as: average_sequences((valid_group + [latest_start]).map { |s| @data[s, new_length] }) }
      parent[:cc][@cluster_id_counter] = new_cluster
      record_action(:cc_add, parent[:cc], @cluster_id_counter)

      add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, new_length, @cluster_id_counter)
      @tasks << [keys_to_parent.dup << @cluster_id_counter, new_length]
      @cluster_id_counter += 1
    else
      new_cluster = { si: [latest_start], cc: {}, as: latest_seq.dup }
      parent[:cc][@cluster_id_counter] = new_cluster
      record_action(:cc_add, parent[:cc], @cluster_id_counter)

      add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, new_length, @cluster_id_counter)
      @cluster_id_counter += 1
    end

    invalid_group.each do |s|
      new_cluster = { si: [s], cc: {}, as: @data[s, new_length] }
      parent[:cc][@cluster_id_counter] = new_cluster
      record_action(:cc_add, parent[:cc], @cluster_id_counter)

      add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, new_length, @cluster_id_counter)
      @cluster_id_counter += 1
    end
  end

  def process_root_clusters(data_index, max_distance)
    latest_start = data_index - 1
    latest_seq = @data[latest_start, @min_window_size]
    min_distance, best_cluster, best_cluster_id = Float::INFINITY, nil, nil

    @clusters.each do |cluster_id, cluster|
      next if cluster[:si].include?(latest_start)

      compare_seq = if cluster[:si].size == 1
                      @data[cluster[:si].first, @min_window_size]
                    else
                      average_sequences(cluster[:si].sort[0..1].map { |s| @data[s, @min_window_size] })
                    end

      distance = euclidean_distance(compare_seq, latest_seq)
      min_distance, best_cluster, best_cluster_id = distance, cluster, cluster_id if distance < min_distance
    end

    ratio_in_max_distance = max_distance.zero? ? 0 : min_distance / max_distance

    if best_cluster && ratio_in_max_distance <= @merge_threshold_ratio
      unless best_cluster[:si].include?(latest_start)
        best_cluster[:si] << latest_start
        record_action(:si_push, best_cluster)

        old_as = best_cluster[:as]
        best_cluster[:as] = average_sequences(best_cluster[:si].map { |s| @data[s, @min_window_size] })
        record_action(:as_update, best_cluster, nil, old_as)

        add_updated_id(@updated_cluster_ids_per_window_for_calculate_quantities, @min_window_size, best_cluster_id)
        if @calculate_distance_when_added_subsequence_to_cluster
          add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, @min_window_size, best_cluster_id)
        end
      end
      @tasks << [[best_cluster_id], @min_window_size]
    else
      new_cluster = { si: [latest_start], cc: {}, as: @data[latest_start, @min_window_size] }
      @clusters[@cluster_id_counter] = new_cluster
      record_action(:root_add, nil, @cluster_id_counter)

      add_updated_id(@updated_cluster_ids_per_window_for_calculate_distance, @min_window_size, @cluster_id_counter)
      @cluster_id_counter += 1
    end
  end

  def average_sequences(sequences)
    return sequences.first if sequences.size == 1
    length = sequences.first.size
    sequences.each { |s| raise "Inconsistent lengths" unless s.size == length }
    (0...length).map { |i| sequences.sum { |s| s[i] } / sequences.size.to_f }
  end

  def dig_clusters_by_keys(clusters, keys)
    current = clusters
    keys.each_with_index do |key, index|
      if index == keys.length - 1
        current = current[key]
      else
        current = current[key]
        current = current[:cc] if current && current.is_a?(Hash) && !current[:cc].nil?
      end
      return nil if current.nil?
    end
    current
  end
end
