# frozen_string_literal: true

class DissonanceStmManager
  # Sethares roughness + STM interference (Daniel & Weber風の “過去との干渉” を roughness差分で近似)
  #
  # - midi_notes: [Integer, ...]
  # - amps:       [Float, ...]  (音量の絶対値; chord内は等分して「合計がstream vol」になるように渡す想定)
  # - onset:      Float         (秒など。単調増加なら単位は何でもOK)
  #
  # 返すroughnessは“相対値”で、step内 min-max 正規化して target01 に近づける使い方を想定。

  def initialize(
    memory_span: 1.5,
    memory_weight: 1.0,
    n_partials: 8,
    amp_profile: 0.88,
    model: 'sethares1993',
    prune_threshold: 0.01
  )
    @memory_span = memory_span.to_f
    @memory_weight = memory_weight.to_f
    @n_partials = n_partials.to_i
    @amp_profile = amp_profile.to_f
    @model = model
    @prune_threshold = prune_threshold.to_f

    @memory = [] # [{ onset:, midi_notes:, amps:, dissonance_current: }, ...]
  end

  attr_reader :memory

  # --- public: 現在のmemoryを汚さず評価（シミュレーション用） ---
  def evaluate(midi_notes, amps, onset)
    d_current = dissonance_current(midi_notes, amps)
    d_total = d_current + memory_interference(midi_notes, amps, onset, d_current)
    d_total
  end

  # --- public: 確定後にmemoryへコミット ---
  def commit!(midi_notes, amps, onset)
    d_current = dissonance_current(midi_notes, amps)
    d_total = d_current + memory_interference(midi_notes, amps, onset, d_current)

    prune!(onset)

    @memory << {
      onset: onset.to_f,
      midi_notes: midi_notes.dup,
      amps: amps.dup,
      dissonance_current: d_current
    }

    d_total
  end

  # --- public: pitch class の “STM寄与順” 並べ替え（prefix用） ---
  # ここでの「寄与」は、各pcを仮に置いたときのSTM付きroughnessの大きさ
  def order_pitch_classes_by_contribution(pitch_classes, octaves:, vols:, onset:)
    pitch_classes
      .map do |pc|
        midi_notes, amps = build_chord_midi_and_amps_for_all_streams(
          octaves: octaves,
          vols: vols,
          pitch_classes_per_stream: Array.new(octaves.length, pc),
          chord_sizes: Array.new(octaves.length, 1) # pc単体寄与なので1音扱い
        )
        [pc, evaluate(midi_notes, amps, onset).to_f]
      end
      .sort_by { |(_pc, d)| -d } # 大きい順（= 目立つ順）
      .map(&:first)
  end

  # --- public: 12Ck combo の roughness（prefix + chord_size + volume等分込み） ---
  def roughness_for_pitchclass_combo(combo, chord_sizes:, octaves:, vols:, onset:)
    ordered = order_pitch_classes_by_contribution(combo, octaves: octaves, vols: vols, onset: onset)

    # prefix割当で、各streamが鳴らすpcsを確定
    chords_pcs = chord_sizes.each_with_index.map do |cs, s|
      cs = cs.to_i
      cs = 1 if cs < 1
      cs = ordered.length if cs > ordered.length
      ordered.first(cs)
    end

    midi_notes, amps = build_chord_midi_and_amps_for_all_streams(
      octaves: octaves,
      vols: vols,
      pitch_classes_per_stream: nil,  # chords_pcsを直接使う
      chord_sizes: chord_sizes,
      chords_pcs: chords_pcs
    )

    [evaluate(midi_notes, amps, onset).to_f, chords_pcs]
  end

  private

  # Sethares用: MIDI→partials(f0*p) & amp_profile^p
  def dissonance_current(midi_notes, amps)
    freqs = []
    a = []

    midi_notes.each_with_index do |m, idx|
      amp = amps[idx].to_f
      next if amp <= 1e-6

      f0 = midi_to_freq(m)
      1.upto(@n_partials) do |p|
        freqs << (f0 * p)
        a     << (amp * (@amp_profile**p))
      end
    end

    return 0.0 if freqs.length < 2
    Dissonance.dissonance(freqs, a, model: @model).to_f
  end

  def memory_interference(midi_notes, amps, onset, d_current)
    return 0.0 if @memory.empty?

    total = 0.0
    onset = onset.to_f

    @memory.each do |evt|
      dt = onset - evt[:onset].to_f
      next if dt < 0 # 念のため
      w = Math.exp(-dt / @memory_span)
      next if w < @prune_threshold

      d_past = evt[:dissonance_current].to_f

      merged_notes = midi_notes + evt[:midi_notes]
      merged_amps  = amps + evt[:amps]
      d_merged = dissonance_current(merged_notes, merged_amps)

      # “干渉分”だけ足す
      interference = d_merged - d_current - d_past
      total += w * @memory_weight * interference
    end

    total
  end

  def prune!(onset)
    onset = onset.to_f
    @memory.select! do |evt|
      dt = onset - evt[:onset].to_f
      next false if dt < 0
      Math.exp(-dt / @memory_span) >= @prune_threshold
    end
  end

  def midi_to_freq(midi)
    440.0 * (2.0 ** ((midi.to_f - 69.0) / 12.0))
  end

  # chord_size と volume 等分(合計がvol)を反映して「全発音midi+amp」を作る
  #
  # chords_pcs を渡す場合:
  #   chords_pcs[stream] = [pc, pc, ...] でそのまま使う
  #
  def build_chord_midi_and_amps_for_all_streams(octaves:, vols:, pitch_classes_per_stream:, chord_sizes:, chords_pcs: nil)
    midi_notes = []
    amps = []

    octaves.each_with_index do |oct, s|
      cs = chord_sizes[s].to_i
      cs = 1 if cs < 1

      pcs =
        if chords_pcs
          chords_pcs[s]
        else
          pc = pitch_classes_per_stream[s]
          Array.new(cs, pc)
        end

      # 「合計が stream vol」になるよう等分
      v = vols[s].to_f
      a_each = v / pcs.length.to_f

      base_c_midi = (oct.to_i + 1) * 12

      pcs.each do |pc|
        midi_notes << (base_c_midi + pc.to_i)
        amps      << a_each
      end
    end

    [midi_notes, amps]
  end
end
