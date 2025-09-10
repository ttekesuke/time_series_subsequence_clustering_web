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
        midiNoteNumbers: track[:midiNoteNumbers].is_a?(String) ? track[:midiNoteNumbers].split(',').map(&:to_i) : Array(track[:midiNoteNumbers]).map(&:to_i)
      }
    end
    node_id = 1000
    events = []

    tracks.each do |track|
      time = 0.0
      track[:durations].each_with_index do |dur, idx|
        freq = midi_to_freq(track[:midiNoteNumbers][idx])
        dur  = dur * 0.125
        events << [time, node_id, freq, dur]
        time += dur
        node_id += 1
      end
    end


    groups = events.group_by { |t, _nid, _f, _d| t }
    p groups
    filename = "rendered_#{SecureRandom.hex}.wav"
    @filepath = Rails.root.join("tmp", filename).to_s
    total_duration = tracks.map { |track| track[:durations].sum }.max.to_f * 0.125 rescue 1.0

    # ERBテンプレート展開
    erb_path = Rails.root.join('supercollider', 'render.scd.erb')
    scd_path = Rails.root.join('tmp', "render_#{SecureRandom.hex}.scd")
    template = File.read(erb_path)
    renderer = ERB.new(template)
    scd_code = renderer.result_with_hash(
      tracks: tracks,
      filepath: @filepath,
      total_duration: total_duration,
      midi_to_freq: method(:midi_to_freq)
    )
    File.write(scd_path, scd_code)

    pid = Process.spawn(
      { "QT_QPA_PLATFORM" => "offscreen" },
      "sclang", scd_path.to_s,
      out: "log/sclang_out.log",
      err: "log/sclang_err.log"
    )
    Process.detach(pid)
    timeout = 5
    start = Time.now
    until File.size?(@filepath) || (Time.now - start > timeout)
      sleep 0.1
    end

    if File.size?(@filepath)
      send_file @filepath, type: "audio/wav", disposition: "inline"
      File.delete(scd_path) if File.exist?(scd_path)
    else
      File.delete(scd_path) if File.exist?(scd_path)
      render plain: "Failed to generate audio", status: 500
    end
  end



end
