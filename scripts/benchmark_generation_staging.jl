ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const MSM = Main.TimeseriesClusteringAPI.MultiStreamManager
const CTRL = Main.TimeseriesClusteringAPI.TimeSeriesController
const STM = Main.TimeseriesClusteringAPI.DissonanceStmManager

function measure_stage(graph, shared_rows::Bool)
  GC.gc()
  measurement = @timed begin
    if shared_rows
      CTRL._stage_generate_polyphonic_step_state(
        graph.managers, graph.stm_mgr, graph.stream_axis, graph.voice_state)
    else
      deepcopy(graph)
    end
  end
  return measurement.bytes, measurement.time
end

function measure_commit(seed, staged::Bool, values)
  manager = deepcopy(seed)
  GC.gc()
  measurement = @timed begin
    if staged
      MSM.commit_state_staged!(manager, values)
      MSM.update_caches_staged!(manager)
    else
      MSM.commit_state!(manager, values)
      MSM.update_caches_permanently!(manager)
    end
  end
  return measurement.bytes, measurement.time
end

println("stage_history_steps,streams,mode,allocated_bytes,elapsed_s")
for history_steps in (8, 24), streams in (2, 4)
  history = [Any[float((step + slot) % 3) / 4 for slot in 1:streams]
    for step in 1:history_steps]
  seed = MSM.Manager(history, 0.02, 2; value_range=[0.0, 1.0])
  axis = CTRL.StableStreamAxis(streams, collect(1:streams))
  graph = (
    managers=Dict("vol" => Dict{Symbol,Any}(
      :global => deepcopy(seed.stream_pool[1].manager),
      :stream => seed,
      :stream_axis => axis,
    )),
    stm_mgr=STM.Manager(),
    stream_axis=axis,
    voice_state=nothing,
  )
  measure_stage(graph, false)
  measure_stage(graph, true)
  for shared_rows in (false, true)
    samples = [measure_stage(graph, shared_rows) for _ in 1:3]
    allocated = minimum(first, samples)
    elapsed = minimum(last, samples)
    println("$history_steps,$streams,$(shared_rows ? "shared_rows" : "deepcopy"),$allocated,$elapsed")
  end
end

println("history_steps,streams,mode,allocated_bytes,elapsed_s")
for history_steps in (8, 24), streams in (2, 4)
  history = [Any[float((step + slot) % 3) / 4 for slot in 1:streams]
    for step in 1:history_steps]
  seed = MSM.Manager(history, 0.02, 2; value_range=[0.0, 1.0])
  values = fill(0.5, streams)
  # Compile both paths before collecting allocations and elapsed times.
  measure_commit(seed, false, values)
  measure_commit(seed, true, values)
  for staged in (false, true)
    samples = [measure_commit(seed, staged, values) for _ in 1:3]
    allocated = minimum(first, samples)
    elapsed = minimum(last, samples)
    println("$history_steps,$streams,$(staged ? "staged" : "atomic"),$allocated,$elapsed")
  end
end
