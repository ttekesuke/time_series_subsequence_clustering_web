using Test
using JSON3
using UUIDs

const _job_tc = Main.TimeseriesClusteringAPI.TimeSeriesController

const _job_xml = """
<score-partwise version="4.0">
<part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
<part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
<note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice></note>
<note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>1</voice></note>
</measure></part></score-partwise>
"""

function _job_request()
  return Dict{String,Any}(
    "source_type" => "upload",
    "filename" => "job-short.musicxml",
    "musicxml_text" => _job_xml,
    "compact_cluster_view" => true,
  )
end

function _wait_job_terminal(id; timeout_s=20.0)
  deadline = time() + timeout_s
  while time() < deadline
    status = _job_tc._analyse_music_job_status(id)
    string(status["status"]) in ("completed", "failed", "cancelled", "interrupted") &&
      return status
    sleep(0.01)
  end
  error("MusicAnalyse job did not finish before timeout")
end

@testset "MusicAnalyse job result matches synchronous result" begin
  old_dir = get(ENV, "ANALYSE_MUSIC_JOB_DIR", nothing)
  root = mktempdir()
  ENV["ANALYSE_MUSIC_JOB_DIR"] = root
  try
    request = _job_request()
    direct_params = _job_tc._prepare_analyse_music_params(request)
    direct = _job_tc._analyse_music_with_params(direct_params; started_at=time())

    started = _job_tc._create_analyse_music_job!(request)
    id = string(started["jobId"])
    status = _wait_job_terminal(id)
    @test status["status"] == "completed"
    @test status["percent"] == 100
    @test status["resultBytes"] > 0
    @test status["serializeSeconds"] >= 0
    @test status["peakRssBytes"] >= 0

    result_path = _job_tc._analyse_music_job_result_path(id)
    @test isfile(result_path)
    job_result = JSON3.read(read(result_path, String))

    for key in (
      "metadata", "timing", "streams", "pianoRoll", "dimensionOrder",
      "dimensions", "streamCountSeries", "soundingNoteCountSeries",
    )
      @test JSON3.write(job_result[key]) == JSON3.write(direct[key])
    end
  finally
    if old_dir === nothing
      delete!(ENV, "ANALYSE_MUSIC_JOB_DIR")
    else
      ENV["ANALYSE_MUSIC_JOB_DIR"] = old_dir
    end
    rm(root; recursive=true, force=true)
  end
end

@testset "MusicAnalyse queued job can be cancelled cooperatively" begin
  old_dir = get(ENV, "ANALYSE_MUSIC_JOB_DIR", nothing)
  root = mktempdir()
  ENV["ANALYSE_MUSIC_JOB_DIR"] = root
  try
    started = _job_tc._create_analyse_music_job!(_job_request())
    id = string(started["jobId"])
    _job_tc._update_analyse_music_job!(id; cancelRequested=true, phase="cancelling")
    status = _wait_job_terminal(id)
    @test status["status"] == "cancelled"
    @test status["errorCode"] == "cancelled"
    @test !isfile(_job_tc._analyse_music_job_result_path(id))
  finally
    if old_dir === nothing
      delete!(ENV, "ANALYSE_MUSIC_JOB_DIR")
    else
      ENV["ANALYSE_MUSIC_JOB_DIR"] = old_dir
    end
    rm(root; recursive=true, force=true)
  end
end

@testset "persisted running MusicAnalyse job becomes interrupted after restart" begin
  old_dir = get(ENV, "ANALYSE_MUSIC_JOB_DIR", nothing)
  root = mktempdir()
  ENV["ANALYSE_MUSIC_JOB_DIR"] = root
  try
    id = string(uuid4())
    metadata_path = _job_tc._analyse_music_job_metadata_path(id)
    mkpath(dirname(metadata_path))
    write(metadata_path, JSON3.write(Dict(
      "jobId" => id,
      "status" => "running",
      "phase" => "clustering",
      "label" => "note/global",
      "processed" => 10,
      "total" => 100,
      "percent" => 10,
      "createdAt" => "2026-10-04T00:00:00",
      "startedAt" => "2026-10-04T00:00:01",
      "completedAt" => nothing,
      "cancelRequested" => false,
      "errorCode" => nothing,
      "errorMessage" => nothing,
      "processingSeconds" => nothing,
      "serializeSeconds" => nothing,
      "resultBytes" => nothing,
      "peakRssBytes" => 0,
    )))

    status = _job_tc._analyse_music_job_status(id)
    @test status["status"] == "interrupted"
    @test status["errorCode"] == "process_restarted"
    persisted = JSON3.read(read(metadata_path, String))
    @test persisted["status"] == "interrupted"
  finally
    if old_dir === nothing
      delete!(ENV, "ANALYSE_MUSIC_JOB_DIR")
    else
      ENV["ANALYSE_MUSIC_JOB_DIR"] = old_dir
    end
    rm(root; recursive=true, force=true)
  end
end
