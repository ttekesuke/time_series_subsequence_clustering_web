# ------------------------------------------------------------
# GitHub Actions workflow_dispatch integration
# ------------------------------------------------------------
function _env_required(key::AbstractString)
  val = get(ENV, key, "")
  isempty(val) && error("Missing required environment variable: $(key)")
  return val
end

function _github_headers()
  token = _env_required("GITHUB_TOKEN")
  return [
    "Authorization" => "Bearer $(token)",
    "Accept" => "application/vnd.github+json",
    "User-Agent" => "TimeseriesClusteringAPI",
    "X-GitHub-Api-Version" => "2022-11-28",
    "Content-Type" => "application/json",
  ]
end

function _github_repo_base(owner::AbstractString, repo::AbstractString)
  return "https://api.github.com/repos/$(owner)/$(repo)"
end

function _github_dispatch_workflow!(; workflow::AbstractString, ref::AbstractString, inputs::Dict{String,String})
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/dispatches"
  body = JSON3.write(Dict("ref" => ref, "inputs" => inputs))
  res = HTTP.request("POST", url, _github_headers(); body=body)
  return res
end

function _github_list_workflow_runs(; workflow::AbstractString, ref::AbstractString, per_page::Int=Config.GITHUB_WORKFLOW_RUNS_PER_PAGE)
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/runs?event=workflow_dispatch&branch=$(ref)&per_page=$(per_page)"
  res = HTTP.request("GET", url, _github_headers())
  res.status == 200 || return nothing
  return JSON3.read(String(res.body))
end

function _gzip_base64encode(payload::AbstractString)::String
  compressed = transcode(GzipCompressor, Vector{UInt8}(codeunits(payload)))
  return base64encode(compressed)
end

function _find_new_run_after(obj, dispatched_at_utc::DateTime)
  obj === nothing && return nothing
  runs = get(obj, "workflow_runs", Any[])
  for r in runs
    created = get(r, "created_at", "")
    isempty(created) && continue
    created_dt = try
      DateTime(created[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
    catch
      continue
    end
    if created_dt >= (dispatched_at_utc - Dates.Second(Config.GITHUB_WORKFLOW_DISPATCH_TOLERANCE_SECONDS))
      return r
    end
  end
  return nothing
end

function dispatch_generate_polyphonic()
  payload = _payload()
  payload_dict = _to_string_dict(payload)
  gp = get(payload_dict, "generate_polyphonic", Dict{String,Any}())
  gp_dict = _to_string_dict(gp)

  if !Config.voicevox_enabled()
    for key in (
      "voice_stream_counts",
      "voice_inventory_id",
      "voice_token_global_complexity_target",
      "voice_token_stream_complexity_center",
      "voice_token_stream_complexity_span",
      "voice_token_concordance",
      "voice_transition_weight",
    )
      pop!(gp_dict, key, nothing)
    end
  end

  _validate_generate_polyphonic_request!(gp_dict)

  request_id = string(get(gp_dict, "job_id", uuid4()))
  gp_dict["job_id"] = request_id
  payload_dict["generate_polyphonic"] = gp_dict

  workflow = _env_required("GITHUB_WORKFLOW")
  ref = _env_required("GITHUB_REF")

  params_json = JSON3.write(payload_dict)
  params_b64 = _gzip_base64encode(params_json)
  if length(params_b64) > Config.GITHUB_WORKFLOW_PARAMS_B64_MAX_CHARS
    return Dict(
      "ok" => false,
      "error" => "Compressed workflow input is still too large: $(length(params_b64)) chars (limit $(Config.GITHUB_WORKFLOW_PARAMS_B64_MAX_CHARS)).",
      "request_id" => request_id,
      "params_json_bytes" => ncodeunits(params_json),
      "params_b64_chars" => length(params_b64),
    )
  end

  dispatched_at = now(UTC)

  res = try
    _github_dispatch_workflow!(workflow=workflow, ref=ref, inputs=Dict(
      "request_id" => request_id,
      "params_b64" => params_b64,
    ))
  catch e
    return Dict("ok" => false, "error" => string(e))
  end

  run_id = nothing
  run_url = nothing
  html_url = nothing

  if res.status == 200 && !isempty(String(res.body))
    try
      body = JSON3.read(String(res.body))
      run_id = get(body, "workflow_run_id", nothing)
      run_url = get(body, "run_url", nothing)
      html_url = get(body, "html_url", nothing)
    catch
    end
  end

  workflow_page_url = "https://github.com/$(_env_required("GITHUB_OWNER"))/$(_env_required("GITHUB_REPO"))/actions/workflows/$(workflow)"

  if html_url === nothing
    for _ in 1:8
      obj = _github_list_workflow_runs(workflow=workflow, ref=ref, per_page=Config.GITHUB_WORKFLOW_RUNS_PER_PAGE)
      r = _find_new_run_after(obj, dispatched_at)
      if r !== nothing
        run_id = get(r, "id", run_id)
        html_url = get(r, "html_url", html_url)
        run_url = get(r, "url", run_url)
        break
      end
      sleep(Config.GITHUB_WORKFLOW_POLL_INTERVAL_SECONDS)
    end
  end

  return Dict(
    "ok" => (res.status == 204 || res.status == 200),
    "request_id" => request_id,
    "workflow" => workflow,
    "ref" => ref,
    "workflow_page_url" => workflow_page_url,
    "run_id" => run_id,
    "run_url" => run_url,
    "run_html_url" => html_url,
    "http_status" => res.status,
    "params_json_bytes" => ncodeunits(params_json),
    "params_b64_chars" => length(params_b64),
  )
end

# ------------------------------------------------------------
# XML file serving and SVG coordinate mapping
# ------------------------------------------------------------
