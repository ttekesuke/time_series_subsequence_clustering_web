class Api::Web::SupercollidersController < ApplicationController
  require 'erb'
  def midi_to_freq(midi)
    440.0 * (2.0 ** ((midi - 69) / 12.0))
  end

  def generate
    raw_tracks = params[:supercollider] ? params[:supercollider][:tracks] : params[:tracks]
    tracks = (raw_tracks || []).map do |track|
      {
        durations: track[:durations].is_a?(String) ? track[:durations].split(',').map(&:to_i) : Array(track[:durations]).map(&:to_i),
        midiNoteNumbers: track[:midiNoteNumbers].is_a?(String) ? track[:midiNoteNumbers].split(',').map(&:to_i) : Array(track[:midiNoteNumbers]).map(&:to_i),
        tone: track[:tone].to_i,
        harmRichness: track[:harmRichness].to_f,
        brightness: track[:brightness].to_f,
        noiseContent: track[:noiseContent].to_f,
        formantChar: track[:formantChar].to_f,
        inharmonicity: track[:inharmonicity].to_f,
        resonance: track[:resonance].to_f,
      }
    end
    filename = "rendered_#{SecureRandom.hex}.wav"
    @sound_file_path = Rails.root.join("tmp", filename).to_s
    total_duration = tracks.map { |track| track[:durations].sum }.max.to_f * 0.125 rescue 1.0

    # ERBテンプレート展開
    erb_path = Rails.root.join('supercollider', 'render.scd.erb')
    @scd_file_path = Rails.root.join('tmp', "render_#{SecureRandom.hex}.scd")
    template = File.read(erb_path)
    renderer = ERB.new(template)
    scd_code = renderer.result_with_hash(
      tracks: tracks,
      filepath: @sound_file_path,
      total_duration: total_duration,
      midi_to_freq: method(:midi_to_freq)
    )
    File.write(@scd_file_path, scd_code)

    pid = Process.spawn(
      { "QT_QPA_PLATFORM" => "offscreen" },
      "sclang", @scd_file_path.to_s
    )
    Process.detach(pid)

    if wait_for_complete_file(@sound_file_path, timeout: 30)
      # ファイルを読み込んでBase64に変換
      base64_data = Base64.strict_encode64(File.binread(@sound_file_path))

      render json: {
        sound_file_path: @sound_file_path,
        scd_file_path: @scd_file_path,
        audio_data: base64_data
      }
    else
      render plain: "Failed to generate audio", status: 500
    end

  end

  def cleanup
    sound_file_path = delete_params[:sound_file_path]
    if sound_file_path && File.exist?(sound_file_path)
      File.delete(sound_file_path) rescue nil
    else
      render json: { message: "Sound File not found" }, status: 404
    end

    scd_file_path = delete_params[:scd_file_path]
    if scd_file_path && File.exist?(scd_file_path)
      File.delete(scd_file_path) rescue nil
    else
      render json: { message: "SCD File not found" }, status: 404
    end

    render json: { message: "File deleted" }
  end

  def wait_for_complete_file(filepath, timeout: 30)
    start = Time.now
    last_size = -1

    loop do
      # ファイルが存在しない場合
      unless File.exist?(filepath)
        break if Time.now - start > timeout
        sleep 1.0
        next
      end

      current_size = File.size(filepath)

      # ファイルサイズが前回と同じなら「生成完了」とみなす
      if current_size > 0 && current_size == last_size
        return true
      end

      last_size = current_size
      break if Time.now - start > timeout
      sleep 1.0
    end

    false
  end

  private
    def delete_params
      params.require(:cleanup).permit(
        :sound_file_path,
        :scd_file_path
      )
    end
end
