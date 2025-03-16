module MusicAnalyser

  def get_dominance_pitch_incremental(pitch, dominance_hash)
    intervals_harmonious_sorted_inverted = [0, 5, 8, 1, 10, 3, 7, 2, 9, 4, 6, 11]
    dominance_pitch_candidates = (0..11).to_a

    normalized_pitch = pitch % 12
    min_weighted_sum = Float::INFINITY
    dominance_pitch = nil

    # 各主要音の距離合計を計算
    dominance_pitch_candidates.each do |dominance_pitch_candidate|
      # intervals_invertedでのインデックス位置を二乗し距離を計算
      distance_index = intervals_harmonious_sorted_inverted.index((dominance_pitch_candidate - normalized_pitch) % 12)
      distance = distance_index ** 1  # 二乗により後半のインデックスの距離がより増大する

      dominance_hash[dominance_pitch_candidate] << distance
      # dominance_hash[dominance_pitch_candidate].shift if dominance_hash[dominance_pitch_candidate].size > window_size

      # 距離の合計を算出
      weighted_sum_of_distances = dominance_hash[dominance_pitch_candidate].sum

      # 最小の距離合計で支配的な音を選択
      if weighted_sum_of_distances < min_weighted_sum
        min_weighted_sum = weighted_sum_of_distances
        dominance_pitch = dominance_pitch_candidate
      end
    end

    [dominance_pitch, dominance_hash]
  end
end
