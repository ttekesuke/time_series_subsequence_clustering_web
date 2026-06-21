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

route("/api/web/time_series/query_db", method=POST) do
  TimeSeriesController.query_db() |> json
end

route("/api/web/time_series/dispatch_generate_polyphonic", method = POST) do
  TimeSeriesController.dispatch_generate_polyphonic()
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
