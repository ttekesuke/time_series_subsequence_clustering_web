module DissonanceMemory
  require_relative '../../../lib/dissonance/dissonance'
  include Dissonance
  include DissonanceTuning

  module STMStateless
    # notes:  [midi_like_pitches]
    # onset:  秒などの連続時間 (generate_polyphonic 側から 0.25 * step_idx とかで渡す想定)
    # memory: [{ notes:, onset:, dissonance: }, ...]
    #
    # options:
    #   :memory_weight  … STM 全体の効き具合
    #   :memory_span    … 追加の指数減衰 (論文よりも短く/長くしたいとき用)
    #   :n_partials     … 倍音数
    def self.process(notes, onset, memory,
                     memory_weight: 1.0,
                     memory_span: 3.0,
                     n_partials: 10)

      # ① 現在フレームの不協和度
      d_current = DissonanceMemory.calculate_dissonance(notes, n_partials).to_f

      d_memory   = 0.0
      new_memory = []
      nc         = memory.length # N_c = メモリ中イベント数

      memory.each do |event|
        delta_t = onset - event[:onset]
        # 未来のイベントは無視
        next if delta_t < 0.0

        # --- 論文ベースの活性度 A_n(t, N_c) ---
        # A_n = 2 - 0.5 ln(t+1) - 0.5 ln(N_c+1)
        base_activation =
          2.0 - 0.5 * Math.log(delta_t + 1.0) - 0.5 * Math.log(nc + 1.0)

        # A_n が 0 以下になったら貢献なし
        next if base_activation <= 0.0

        # オプション：元の memory_span の指数減衰も掛ける
        exp_decay = Math.exp(-delta_t / memory_span.to_f)

        # 最終的な重み
        w = memory_weight * base_activation * exp_decay

        # ② 過去イベントとの干渉成分
        d_past   = event[:dissonance].to_f
        merged   = notes + event[:notes]
        d_merged = DissonanceMemory.calculate_dissonance(merged, n_partials).to_f

        # クロス項 = 全体 - (現在単独 + 過去単独)
        interference = d_merged - d_current - d_past

        d_memory += w * interference

        # まだ活性度が生きているイベントだけ残す
        new_memory << event
      end

      # ③ 現在イベントをメモリに追加
      current_event = {
        notes:      notes,
        onset:      onset,
        dissonance: d_current
      }
      new_memory << current_event

      return d_current + d_memory, new_memory
    end
  end

  # ここは従来どおり（そのまま）
  def self.calculate_dissonance(notes, n_partials = 10)
    freqs = DissonanceTuning.pitch_to_freq(notes)
    freqs_with_partials, amps = DissonanceTuning.harmonic_tone(freqs, n_partials: n_partials)
    Dissonance.dissonance(freqs_with_partials, amps)
  end
end
