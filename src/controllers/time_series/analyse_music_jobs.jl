# MusicAnalyse persistent job lifecycle.
#
# This file is included into TimeSeriesController so public/internal function names,
# module state, and API behavior remain unchanged while the large controller is
# split by responsibility.

const _ANALYSE_MUSIC_JOB_LOCK = ReentrantLock()
const _ANALYSE_MUSIC_JOBS = Dict{String,Dict{String,Any}}()

_analyse_music_job_root() = normpath(get(
  ENV,
  "ANALYSE_MUSIC_JOB_DIR",
  joinpath(tempdir(), "time_series_subsequence_clustering_analyse_music_jobs"),
))

function _analyse_music_job_limit()::Int
  raw = tryparse(Int, strip(get(ENV, "ANALYSE_MUSIC_MAX_CONCURRENT_JOBS", "1")))
  return max(raw === nothing ? 1 : raw, 1)
end

function _analyse_music_job_id(raw)::String
  id = lowercase(strip(string(raw)))
  occursin(r"^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", id) ||
    throw(AnalyseMusicRequestError("invalid_job_id", "Invalid MusicAnalyse job ID."))
  return id
end

function _analyse_music_job_dir(id::AbstractString)::String
  safe_id = _analyse_music_job_id(id)
  root = _analyse_music_job_root()
  path = normpath(joinpath(root, safe_id))
  startswith(path, root) || throw(AnalyseMusicRequestError(
    "invalid_job_id",
    "Invalid MusicAnalyse job path.",
  ))
  return path
end

_analyse_music_job_metadata_path(id::AbstractString) =
  joinpath(_analyse_music_job_dir(id), "metadata.json")
_analyse_music_job_result_path(id::AbstractString) =
  joinpath(_analyse_music_job_dir(id), "result.json")

function _atomic_write_text(path::AbstractString, content::AbstractString)::Nothing
  mkpath(dirname(path))
  temporary = path * ".tmp-" * string(uuid4())
  try
    open(temporary, "w") do io
      write(io, content)
      flush(io)
    end
    mv(temporary, path; force=true)
  finally
    isfile(temporary) && rm(temporary; force=true)
  end
  return nothing
end

function _analyse_music_job_public(job)::Dict{String,Any}
  keys = (
    "jobId", "status", "phase", "label", "processed", "total", "percent",
    "createdAt", "startedAt", "completedAt", "cancelRequested",
    "errorCode", "errorMessage", "processingSeconds", "serializeSeconds",
    "resultBytes", "peakRssBytes",
  )
  return Dict{String,Any}(key => get(job, key, nothing) for key in keys)
end

function _persist_analyse_music_job!(job)::Nothing
  id = string(job["jobId"])
  _atomic_write_text(
    _analyse_music_job_metadata_path(id),
    JSON3.write(_analyse_music_job_public(job)),
  )
  return nothing
end

function _current_rss_bytes()::Int
  status_path = "/proc/self/status"
  isfile(status_path) || return 0
  try
    for line in eachline(status_path)
      startswith(line, "VmRSS:") || continue
      fields = split(strip(line))
      length(fields) >= 2 || return 0
      kb = tryparse(Int, fields[2])
      return kb === nothing ? 0 : kb * 1024
    end
  catch
  end
  return 0
end

function _update_analyse_music_job!(id::AbstractString; values...)::Dict{String,Any}
  safe_id = _analyse_music_job_id(id)
  return lock(_ANALYSE_MUSIC_JOB_LOCK) do
    job = get(_ANALYSE_MUSIC_JOBS, safe_id, nothing)
    job === nothing && throw(AnalyseMusicRequestError(
      "job_not_found",
      "MusicAnalyse job was not found.",
    ))
    for (key, value) in pairs(values)
      job[string(key)] = value
    end
    rss = _current_rss_bytes()
    job["peakRssBytes"] = max(_parse_int(get(job, "peakRssBytes", 0)), rss)
    _persist_analyse_music_job!(job)
    return _analyse_music_job_public(job)
  end
end

function _analyse_music_job_cancel_requested(id::AbstractString)::Bool
  safe_id = _analyse_music_job_id(id)
  return lock(_ANALYSE_MUSIC_JOB_LOCK) do
    job = get(_ANALYSE_MUSIC_JOBS, safe_id, nothing)
    job === nothing ? true : get(job, "cancelRequested", false) == true
  end
end

function _analyse_music_job_progress!(id::AbstractString, progress)::Nothing
  _update_analyse_music_job!(
    id;
    phase=string(get(progress, "phase", "")),
    label=string(get(progress, "label", "")),
    processed=_parse_int(get(progress, "processed", 0)),
    total=_parse_int(get(progress, "total", 0)),
    percent=_parse_int(get(progress, "percent", 0)),
  )
  return nothing
end

function _load_persisted_analyse_music_job(id::AbstractString)::Dict{String,Any}
  safe_id = _analyse_music_job_id(id)
  path = _analyse_music_job_metadata_path(safe_id)
  isfile(path) || throw(AnalyseMusicRequestError(
    "job_not_found",
    "MusicAnalyse job was not found.",
  ))
  parsed = JSON3.read(read(path, String))
  job = Dict{String,Any}(string(k) => v for (k, v) in pairs(parsed))
  status = string(get(job, "status", "unknown"))
  if status in ("queued", "running")
    job["status"] = "interrupted"
    job["phase"] = "interrupted"
    job["completedAt"] = string(now(UTC))
    job["errorCode"] = "process_restarted"
    job["errorMessage"] = "The server restarted before this MusicAnalyse job completed."
    _atomic_write_text(path, JSON3.write(job))
  end
  return job
end

function _analyse_music_job_status(id::AbstractString)::Dict{String,Any}
  safe_id = _analyse_music_job_id(id)
  in_memory = lock(_ANALYSE_MUSIC_JOB_LOCK) do
    job = get(_ANALYSE_MUSIC_JOBS, safe_id, nothing)
    job === nothing ? nothing : _analyse_music_job_public(job)
  end
  return in_memory === nothing ? _load_persisted_analyse_music_job(safe_id) : in_memory
end

function _run_analyse_music_job!(id::String, request_params)::Nothing
  started = time()
  _update_analyse_music_job!(
    id;
    status="running",
    phase="preparing",
    startedAt=string(now(UTC)),
  )

  try
    cancel_check = () -> begin
      # MusicAnalyse can run with JULIA_NUM_THREADS=1. Yield at every exact
      # score/clustering step so status and cancellation requests remain
      # serviceable without a second Julia process or a second copy of state.
      yield()
      return _analyse_music_job_cancel_requested(id)
    end
    progress_callback = progress -> _analyse_music_job_progress!(id, progress)

    cancel_check() && throw(MusicAnalysis.AnalysisCancelled())
    params = _prepare_analyse_music_params(request_params)
    result = _analyse_music_with_params(
      params;
      progress_callback=progress_callback,
      cancel_check=cancel_check,
      started_at=started,
    )
    cancel_check() && throw(MusicAnalysis.AnalysisCancelled())

    serialize_started = time()
    body = JSON3.write(result)
    serialize_s = time() - serialize_started
    cancel_check() && throw(MusicAnalysis.AnalysisCancelled())
    _atomic_write_text(_analyse_music_job_result_path(id), body)

    _update_analyse_music_job!(
      id;
      status="completed",
      phase="completed",
      label="result ready",
      processed=1,
      total=1,
      percent=100,
      completedAt=string(now(UTC)),
      processingSeconds=float(result["processingTime"]),
      serializeSeconds=serialize_s,
      resultBytes=sizeof(body),
    )
  catch err
    if err isa MusicAnalysis.AnalysisCancelled
      isfile(_analyse_music_job_result_path(id)) &&
        rm(_analyse_music_job_result_path(id); force=true)
      _update_analyse_music_job!(
        id;
        status="cancelled",
        phase="cancelled",
        completedAt=string(now(UTC)),
        errorCode="cancelled",
        errorMessage="MusicAnalyse job was cancelled.",
      )
      return nothing
    end

    code = err isa MusicAnalysis.RequestError ? err.code : "analysis_failed"
    message = err isa MusicAnalysis.RequestError ? err.message : sprint(showerror, err)
    isfile(_analyse_music_job_result_path(id)) &&
      rm(_analyse_music_job_result_path(id); force=true)
    _update_analyse_music_job!(
      id;
      status="failed",
      phase="failed",
      completedAt=string(now(UTC)),
      errorCode=code,
      errorMessage=message,
    )
    @error "[analyse_music_job] failed" job_id=id exception=(err, catch_backtrace())
  end
  return nothing
end

function _create_analyse_music_job!(request_params)::Dict{String,Any}
  id = string(uuid4())
  job = Dict{String,Any}(
    "jobId" => id,
    "status" => "queued",
    "phase" => "queued",
    "label" => "",
    "processed" => 0,
    "total" => 0,
    "percent" => 0,
    "createdAt" => string(now(UTC)),
    "startedAt" => nothing,
    "completedAt" => nothing,
    "cancelRequested" => false,
    "errorCode" => nothing,
    "errorMessage" => nothing,
    "processingSeconds" => nothing,
    "serializeSeconds" => nothing,
    "resultBytes" => nothing,
    "peakRssBytes" => _current_rss_bytes(),
  )

  lock(_ANALYSE_MUSIC_JOB_LOCK) do
    active = count(
      candidate -> string(get(candidate, "status", "")) in ("queued", "running"),
      values(_ANALYSE_MUSIC_JOBS),
    )
    active < _analyse_music_job_limit() || throw(AnalyseMusicRequestError(
      "too_many_jobs",
      "The maximum number of concurrent MusicAnalyse jobs is already running.",
    ))
    _ANALYSE_MUSIC_JOBS[id] = job
    _persist_analyse_music_job!(job)
  end

  @async _run_analyse_music_job!(id, deepcopy(request_params))
  return _analyse_music_job_public(job)
end

function _analyse_music_job_request_id()::String
  payload = _payload()
  nested = _subhash(payload, "analyse_music_job")
  raw = haskey(nested, "job_id") ? nested["job_id"] : get(payload, "job_id", "")
  return _analyse_music_job_id(raw)
end

function analyse_music_job_start()
  payload = _payload()
  request_params = _subhash(payload, "analyse_music")
  return _create_analyse_music_job!(request_params)
end

function analyse_music_job_status()
  return _analyse_music_job_status(_analyse_music_job_request_id())
end

function analyse_music_job_cancel()
  id = _analyse_music_job_request_id()
  status = _analyse_music_job_status(id)
  current = string(get(status, "status", ""))
  current in ("completed", "failed", "cancelled", "interrupted") && return status
  return _update_analyse_music_job!(id; cancelRequested=true, phase="cancelling")
end

function analyse_music_job_result_response()
  id = _analyse_music_job_request_id()
  status = _analyse_music_job_status(id)
  string(get(status, "status", "")) == "completed" || throw(
    AnalyseMusicRequestError(
      "job_not_ready",
      "MusicAnalyse job result is not ready.",
    ),
  )
  path = _analyse_music_job_result_path(id)
  isfile(path) || throw(AnalyseMusicRequestError(
    "job_result_missing",
    "MusicAnalyse job completed but its result file is missing.",
  ))

  started = time()
  body = read(path)
  read_s = time() - started
  return HTTP.Response(
    200,
    [
      "Content-Type" => "application/json; charset=utf-8",
      "Cache-Control" => "no-store",
      "X-Analysis-Result-Bytes" => string(length(body)),
      "X-Analysis-Result-Read-Ms" => string(round(1000 * read_s; digits=3)),
    ],
    body,
  )
end
