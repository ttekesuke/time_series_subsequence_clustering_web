module TimeseriesClusteringAPI

using Genie

include("timeseries/statistics_calculator.jl")
include("timeseries/time_series_cluster_manager.jl")

# ------------------------------------------------------------
# Polyphonic modules (partial import)
# ------------------------------------------------------------
include("polyphonic/polyphonic_config.jl")
include("polyphonic/dissonance_models.jl")
include("polyphonic/dissonance.jl")
include("polyphonic/dissonance_tuning.jl")
include("polyphonic/dissonance_stm_manager.jl")
include("polyphonic/polyphonic_cluster_manager.jl")
include("polyphonic/multi_stream_manager.jl")

include("controllers/supercolliders_controller.jl")
include("controllers/time_series_controller.jl")

# up() を“実行せずに”公開する。async は常に false（ブロッキング）に固定
function up(args...; async::Bool=false, kwargs...)
  return Genie.up(args...; kwargs..., async=false)
end
export up

function main()
  # Genie.genie() が up() を内部で呼ぶ場合も “同期起動” になるようにする
  Genie.config.run_as_server = true
  Genie.genie(; context = @__MODULE__)
end

end
