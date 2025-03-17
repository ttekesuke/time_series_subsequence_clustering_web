module MusicAnalyser

  def get_dominance_pitch_incremental(pitch, dominance_hash)
    intervals_harmonious_sorted_inverted = [0, 5, 8, 1, 10, 3, 7, 2, 9, 4, 6, 11]
    dominance_pitch_candidates = (0..11).to_a

    normalized_pitch = pitch % 12

    # 各音の主要度を計算
    dominance_pitch_candidates.each do |dominance_pitch_candidate|
      distance_index = intervals_harmonious_sorted_inverted.index((dominance_pitch_candidate - normalized_pitch) % 12)
      # 指数関数を適用し、距離が近いほど影響を大きくする
      distance = Math.exp(-distance_index)
      dominance_hash[dominance_pitch_candidate] << distance
    end

     dominance_hash
  end
end
