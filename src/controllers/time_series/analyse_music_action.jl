function _analyse_music_with_params(
  params;
  progress_callback=nothing,
  cancel_check=nothing,
  started_at::Float64=time(),
)
  result = MusicAnalysis.analyse_music_payload(
    params,
    @__MODULE__;
    progress_callback=progress_callback,
    cancel_check=cancel_check,
  )
  result["processingTime"] = round(
    time() - started_at;
    digits=Config.PROCESSING_TIME_DIGITS,
  )
  return result
end

function analyse_music()
  t0 = time()
  payload = _payload()
  p = _subhash(payload, "analyse_music")

  try
    params = _prepare_analyse_music_params(p)
    result = _analyse_music_with_params(params; started_at=t0)
    @info "[analyse_music] request completed" processing_time_s=result["processingTime"] step_count=get(get(result, "timing", Dict{String,Any}()), "stepCount", nothing) streams=length(get(result, "streams", Any[]))
    return result
  catch err
    if err isa MusicAnalysis.RequestError
      @warn "[analyse_music] request rejected" code=err.code message=err.message elapsed_s=round(time() - t0; digits=2)
      throw(AnalyseMusicRequestError(err.code, err.message))
    end
    @error "[analyse_music] request failed" exception=(err, catch_backtrace()) elapsed_s=round(time() - t0; digits=2)
    rethrow()
  end
end
