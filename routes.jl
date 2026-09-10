using Genie.Router
using Genie.Renderer.Json
using Genie.Requests
using Dates

using TimeseriesClusteringAPI
using TimeseriesClusteringAPI.TimeSeriesController
using TimeseriesClusteringAPI.SupercollidersController

function _with_polyphonic_request_errors(f::Function)
  try
    return f()
  catch err
    if err isa TimeSeriesController.GeneratePolyphonicRequestError
      return json(Dict(
        "ok" => false,
        "error" => "invalid_generate_polyphonic_request",
        "code" => err.code,
        "message" => err.message,
      ); status=422)
    end
    rethrow()
  end
end

function _with_generate_request_errors(f::Function)
  try
    return f()
  catch err
    if err isa TimeSeriesController.GenerateRequestError
      return json(Dict(
        "ok" => false,
        "error" => "invalid_generate_request",
        "code" => err.code,
        "message" => err.message,
      ); status=422)
    end
    rethrow()
  end
end

# ------------------------------------------------------------
# Health check (frontend proxy / readiness check)
# ------------------------------------------------------------
route("/api/health") do
  (; status="ok", ts=string(now())) |> json
end

# Runtime feature flags. Never expose connection settings or credentials.
route("/api/features") do
  raw = lowercase(strip(get(ENV, "CLUSTERING_QUERY_ENABLED", "false")))
  clustering_query = raw in ("1", "true", "yes", "y", "on")
  voicevox = TimeseriesClusteringAPI.Config.voicevox_enabled()
  (; clustering_query=clustering_query, voicevox=voicevox) |> json
end

# Public, read-only view of the measured voice-token inventory.  The frontend
# uses this to inspect the same acoustic embeddings used by voice generation.
route("/api/web/time_series/voice_inventory", method=POST) do
  raw_payload = Requests.jsonpayload()
  raw_payload === nothing && (raw_payload = Dict{String,Any}())
  payload = Dict{String,Any}(string(k) => v for (k, v) in pairs(raw_payload))
  inventory_id = strip(string(get(payload, "id", "ja_voicevox_all")))
  occursin(r"^[A-Za-z0-9_-]+$", inventory_id) || error("Invalid voice inventory id.")
  inventory_dir = normpath(joinpath(@__DIR__, "config", "voice_inventories"))
  inventory = TimeseriesClusteringAPI.VoiceTokenGeneration.load_inventory(
    joinpath(inventory_dir, "$(inventory_id).json"),
  )
  inventory.id == inventory_id || error("Voice inventory id does not match its file name.")
  Dict(
    "id" => inventory.id,
    "modelId" => inventory.model_id,
    "featureVersion" => inventory.feature_version,
    "source" => inventory.source,
    "dimensions" => inventory.dimensions,
    "tokens" => [Dict(
      "id" => token.id,
      "text" => token.text,
      "phones" => token.phones,
      "embedding" => token.embedding,
    ) for token in inventory.tokens],
  ) |> json
end

# ------------------------------------------------------------
# Rails compatible endpoints
#   POST /api/web/time_series/analyse
#   POST /api/web/time_series/generate
#   POST /api/web/time_series/generate_polyphonic
# ------------------------------------------------------------
route("/api/web/time_series/analyse", method=POST) do
  TimeSeriesController.analyse() |> json
end

route("/api/web/time_series/generate", method=POST) do
  _with_generate_request_errors() do
    TimeSeriesController.generate() |> json
  end
end

route("/api/web/time_series/generate_polyphonic", method=POST) do
  _with_polyphonic_request_errors() do
    TimeSeriesController.generate_polyphonic() |> json
  end
end

route("/api/web/time_series/query_db", method=POST) do
  TimeSeriesController.query_db() |> json
end

route("/api/web/time_series/dispatch_generate_polyphonic", method = POST) do
  _with_polyphonic_request_errors() do
    TimeSeriesController.dispatch_generate_polyphonic()
  end
end

# ------------------------------------------------------------
# XML and SVG coordinate endpoints
# ------------------------------------------------------------
route("/api/web/time_series/get_xml", method=POST) do
  TimeSeriesController.get_xml() |> json
end

route("/api/web/time_series/get_note_positions", method=POST) do
  TimeSeriesController.get_note_positions() |> json
end

route("/api/web/time_series/map_note_positions_to_db_points", method=POST) do
  TimeSeriesController.map_note_positions_to_db_points() |> json
end

# ------------------------------------------------------------
# SuperCollider endpoints (Rails compatible)
#   POST   /api/web/supercolliders/render_polyphonic
#   DELETE /api/web/supercolliders/cleanup
# ------------------------------------------------------------
route("/api/web/supercolliders/render_polyphonic", method=POST) do
  SupercollidersController.render_polyphonic() |> json
end

route("/api/web/supercolliders/cleanup", method=DELETE) do
  SupercollidersController.cleanup() |> json
end
