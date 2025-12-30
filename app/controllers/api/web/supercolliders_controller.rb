# ============================================================
# app/controllers/api/web/supercolliders_controller.rb
# ============================================================
# frozen_string_literal: true

require "timeout"

class Api::Web::SupercollidersController < ApplicationController
  # ============================================================
  #  多声データからの音声レンダリング（和音対応）
  # ============================================================
  def render_polyphonic
    time_series = params[:time_series] || params.dig(:supercollider, :time_series)
    p time_series
    note_chords_pitch_classes = params[:note_chords_pitch_classes] || params.dig(:supercollider, :note_chords_pitch_classes) || []

    step_duration = params[:step_duration].to_f
    step_duration = 0.25 if step_duration <= 0

    if time_series.blank?
      render plain: "No time series data provided", status: 400
      return
    end

    filename = "poly_rendered_#{SecureRandom.hex}.wav"
    @sound_file_path = Rails.root.join("tmp", filename).to_s

    # 合計時間
    total_duration = time_series.length * step_duration

    # ERBテンプレート展開
    erb_path = Rails.root.join('supercollider', 'render_polyphonic.scd.erb')
    @scd_file_path = Rails.root.join('tmp', "render_poly_#{SecureRandom.hex}.scd")

    template = File.read(erb_path)
    renderer = ERB.new(template)

    scd_code = renderer.result_with_hash(
      time_series: time_series,
      note_chords_pitch_classes: note_chords_pitch_classes, # ★追加
      step_duration: step_duration,
      filepath: @sound_file_path,
      total_duration: total_duration,
      midi_to_freq: ->(note) { 440.0 * (2.0 ** ((note - 69) / 12.0)) }
    )

    File.write(@scd_file_path, scd_code)

    # SuperCollider実行
    pid = Process.spawn(
      { "QT_QPA_PLATFORM" => "offscreen" },
      "sclang", @scd_file_path.to_s
    )
    Process.detach(pid)

    # ファイル生成待ち (少し長めに45秒)
    if wait_for_complete_file(@sound_file_path, timeout: 45)
      base64_data = Base64.strict_encode64(File.binread(@sound_file_path))

      render json: {
        sound_file_path: @sound_file_path,
        scd_file_path: @scd_file_path,
        audio_data: base64_data
      }
    else
      render plain: "Failed to render audio", status: 500
    end
  end

  # 一時ファイル削除
  def cleanup
    paths = [params[:cleanup][:sound_file_path], params[:cleanup][:scd_file_path]]
    paths.each do |path|
      if path.present? && File.exist?(path) && path.start_with?(Rails.root.join('tmp').to_s)
        File.delete(path)
      end
    end
    render json: { status: 'ok' }
  end

  private

  def midi_to_freq(note)
    440.0 * (2.0 ** ((note - 69) / 12.0))
  end

  def wait_for_complete_file(path, timeout: 30)
    start = Time.now
    while Time.now - start < timeout
      if File.exist?(path) && File.size(path) > 0
        sleep 0.5
        return true
      end
      sleep 0.1
    end
    false
  end
end
