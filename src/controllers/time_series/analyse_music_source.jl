const ASAP_RAW_BASE_URL = "https://raw.githubusercontent.com/fosfrancesco/asap-dataset/master"

function _safe_asap_relative_path(raw::AbstractString)::String
  path = replace(strip(String(raw)), '\\' => '/')
  isempty(path) && throw(MusicAnalysis.RequestError(
    "invalid_asap_path",
    "ASAP path is empty.",
  ))
  startswith(path, "/") && throw(MusicAnalysis.RequestError(
    "invalid_asap_path",
    "ASAP path must be relative.",
  ))
  any(part -> part == "..", split(path, '/')) && throw(MusicAnalysis.RequestError(
    "invalid_asap_path",
    "ASAP path must not contain '..'.",
  ))
  return path
end

function _fetch_asap_raw(path::AbstractString)::String
  safe_path = _safe_asap_relative_path(path)
  url = ASAP_RAW_BASE_URL * "/" * HTTP.URIs.escapepath(safe_path)
  response = try
    HTTP.get(
      url;
      status_exception=false,
      connect_timeout=10,
      readtimeout=30,
      headers=["User-Agent" => "time-series-subsequence-clustering-web"],
    )
  catch err
    throw(MusicAnalysis.RequestError(
      "asap_remote_unavailable",
      "ASAP dataset could not be fetched from GitHub: $(err)",
    ))
  end

  response.status == 200 || throw(MusicAnalysis.RequestError(
    "asap_remote_fetch_failed",
    "ASAP dataset GitHub request failed with HTTP $(response.status).",
  ))
  return String(response.body)
end

function _analyse_music_dataset_dir()
  default_dir = normpath(joinpath(@__DIR__, "..", "..", "..", "data", "asap-dataset"))
  dataset_dir = normpath(get(
    ENV,
    "ASAP_DATASET_DIR",
    default_dir,
  ))
  if !isdir(dataset_dir)
    fallback = default_dir
    isdir(fallback) && return fallback
  end
  return dataset_dir
end

function asap_musicxml_sources()
  t0 = time()
  try
    dataset_dir = _analyse_music_dataset_dir()
    metadata_path = joinpath(dataset_dir, "metadata.csv")
    sources = if isfile(metadata_path)
      MusicAnalysis.list_asap_sources(dataset_dir)
    else
      metadata_csv = _fetch_asap_raw("metadata.csv")
      MusicAnalysis.list_asap_sources_from_csv_text(metadata_csv)
    end
    return Dict("sources" => sources)
  catch err
    if err isa MusicAnalysis.RequestError
      @warn "[analyse_music] request rejected" code=err.code message=err.message elapsed_s=round(time() - t0; digits=2)
      throw(AnalyseMusicRequestError(err.code, err.message))
    end
    @error "[analyse_music] request failed" exception=(err, catch_backtrace()) elapsed_s=round(time() - t0; digits=2)
    rethrow()
  end
end

function _prepare_analyse_music_params(p)
  source_type = lowercase(strip(string(get(p, "source_type", "upload"))))
  params = Dict{String,Any}(string(k) => v for (k, v) in pairs(p))
  @info "[analyse_music] request received" source_type=source_type filename=string(get(params, "filename", "")) composer=string(get(params, "composer", "")) title=string(get(params, "title", ""))

  if source_type == "asap"
    composer = string(get(params, "composer", ""))
    folder = string(get(params, "folder", ""))
    xml_score = string(get(params, "xml_score", ""))
    isempty(composer) && throw(MusicAnalysis.RequestError(
      "missing_source",
      "ASAP composer is required.",
    ))
    isempty(folder) && throw(MusicAnalysis.RequestError(
      "missing_source",
      "ASAP folder is required.",
    ))
    isempty(xml_score) && throw(MusicAnalysis.RequestError(
      "missing_source",
      "ASAP xml_score is required.",
    ))
    lowercase(splitext(xml_score)[2]) in (".xml", ".musicxml") || throw(
      MusicAnalysis.RequestError(
        "unsupported_file_type",
        "Only .xml and .musicxml are supported. Compressed .mxl is not supported.",
      ),
    )

    file_path = _xml_file_path(composer, folder, xml_score)
    dataset_dir = _analyse_music_dataset_dir()
    normalized_file = normpath(file_path)
    normalized_dataset = normpath(dataset_dir)
    startswith(normalized_file, normalized_dataset) || throw(
      MusicAnalysis.RequestError("invalid_path", "Invalid ASAP MusicXML path."),
    )
    if isfile(normalized_file)
      @info "[analyse_music] reading ASAP MusicXML from local dataset" path=normalized_file
      params["musicxml_text"] = read(normalized_file, String)
    else
      @info "[analyse_music] local ASAP MusicXML missing; fetching fallback" xml_score=xml_score
      params["musicxml_text"] = _fetch_asap_raw(xml_score)
    end
  elseif source_type == "upload"
    filename = lowercase(strip(string(get(params, "filename", ""))))
    if !isempty(filename) &&
       !(endswith(filename, ".xml") || endswith(filename, ".musicxml"))
      throw(MusicAnalysis.RequestError(
        "unsupported_file_type",
        "Only .xml and .musicxml are supported. Compressed .mxl is not supported.",
      ))
    end
    haskey(params, "musicxml_text") || throw(MusicAnalysis.RequestError(
      "missing_source",
      "Uploaded MusicXML text is required.",
    ))
    @info "[analyse_music] uploaded MusicXML accepted" filename=filename xml_bytes=sizeof(string(params["musicxml_text"]))
  else
    throw(MusicAnalysis.RequestError(
      "invalid_source_type",
      "source_type must be upload or asap.",
    ))
  end

  params["source_type"] = source_type
  return params
end
