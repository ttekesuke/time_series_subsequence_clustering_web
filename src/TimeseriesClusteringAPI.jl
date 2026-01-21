module TimeseriesClusteringAPI

using Genie

include("timeseries/statistics_calculator.jl")
include("timeseries/time_series_cluster_manager.jl")

# ------------------------------------------------------------
# Polyphonic modules (partial import)
#
# generate_polyphonic の完全移植は別途実装しますが、
# 先行して roughness/STM 周辺から段階的に追加します。
# ------------------------------------------------------------
include("polyphonic/polyphonic_config.jl")
include("polyphonic/dissonance_models.jl")
include("polyphonic/dissonance.jl")
include("polyphonic/dissonance_tuning.jl")
include("polyphonic/dissonance_stm_manager.jl")
include("polyphonic/polyphonic_cluster_manager.jl")
include("polyphonic/multi_stream_manager.jl")

include("controllers/time_series_controller.jl")
include("controllers/supercolliders_controller.jl")

const up = Genie.up
export up

function main()
  Genie.genie(; context = @__MODULE__)
end

end
