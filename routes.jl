using Genie.Router
using Genie.Renderer.Json
using Genie.Requests
using Dates

using TimeseriesClusteringAPI
using TimeseriesClusteringAPI.TimeSeriesController
using TimeseriesClusteringAPI.SupercollidersController

# ------------------------------------------------------------
# Health check (frontend proxy / readiness check)
# ------------------------------------------------------------
route("/api/health") do
  (; status="ok", ts=string(now())) |> json
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
  TimeSeriesController.generate() |> json
end

route("/api/web/time_series/generate_polyphonic", method=POST) do
  TimeSeriesController.generate_polyphonic() |> json
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
