using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _render_cleanup = Main.TimeseriesClusteringAPI.SupercollidersController

@testset "SuperCollider cleanup is limited to its render job" begin
  unrelated_dir = mktempdir()
  unrelated = joinpath(unrelated_dir, "other.wav")
  write(unrelated, "keep")

  first_id, first_scd, first_wav = _render_cleanup._new_render_job()
  second_id, second_scd, second_wav = _render_cleanup._new_render_job()
  write(first_scd, "score")
  write(first_wav, "audio")
  write(second_scd, "score")
  write(second_wav, "audio")
  _render_cleanup._finish_render_job!(first_id)
  _render_cleanup._finish_render_job!(second_id)

  @test !_render_cleanup._cleanup_render_payload(Dict(
    "cleanup" => Dict("scd_file_path" => unrelated, "sound_file_path" => first_wav),
  ))["ok"]
  @test !_render_cleanup._cleanup_render_payload(Dict(
    "cleanup" => Dict("render_job_id" => "not-a-job"),
  ))["ok"]
  @test isfile(unrelated)
  @test isfile(first_wav) && isfile(second_wav)

  audio_response = _render_cleanup._render_audio_response(first_id)
  @test audio_response.status == 200
  @test String(audio_response.body) == "audio"
  @test any(header -> header.first == "Content-Type" && header.second == "audio/wav", audio_response.headers)

  active_audio_id, active_audio_scd, active_audio_wav = _render_cleanup._new_render_job()
  write(active_audio_scd, "score")
  write(active_audio_wav, "active-audio")
  @test _render_cleanup._render_audio_response(active_audio_id).status == 404
  @test _render_cleanup._delete_render_job!(active_audio_id; allow_active=true)
  @test _render_cleanup._cleanup_render_payload(Dict(
    "cleanup" => Dict("render_job_id" => first_id,
      "scd_file_path" => unrelated, "sound_file_path" => second_wav),
  ))["ok"]
  @test !ispath(first_scd) && !ispath(first_wav)
  @test isfile(second_wav) && isfile(unrelated)
  @test !_render_cleanup._delete_render_job!(first_id)
  @test _render_cleanup._delete_render_job!(second_id)

  symlink_id, symlink_scd, symlink_wav = _render_cleanup._new_render_job()
  symlink(unrelated, symlink_wav)
  write(symlink_scd, "score")
  _render_cleanup._finish_render_job!(symlink_id)
  @test _render_cleanup._delete_render_job!(symlink_id)
  @test isfile(unrelated)
  @test !islink(symlink_wav)

  active_id, active_scd, active_wav = _render_cleanup._new_render_job()
  write(active_scd, "active")
  @test !_render_cleanup._delete_render_job!(active_id)
  @test isfile(active_scd)
  @test _render_cleanup._delete_render_job!(active_id; allow_active=true)
  @test !ispath(active_scd) && !ispath(active_wav)

  expired_id, expired_scd, expired_wav = _render_cleanup._new_render_job()
  write(expired_scd, "expired")
  _render_cleanup._finish_render_job!(expired_id)
  lock(_render_cleanup._RENDER_JOBS_LOCK) do
    job_dir, _ = _render_cleanup._RENDER_JOBS[expired_id]
    _render_cleanup._RENDER_JOBS[expired_id] =
      (job_dir, time() - _render_cleanup._RENDER_JOB_TTL_SECONDS - 1)
  end
  trigger_id, _, _ = _render_cleanup._new_render_job()
  @test !ispath(expired_scd) && !ispath(expired_wav)
  @test !_render_cleanup._delete_render_job!(expired_id)
  @test _render_cleanup._delete_render_job!(trigger_id; allow_active=true)

  rm(unrelated_dir; recursive=true)
end
