ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const MSM = Main.TimeseriesClusteringAPI.MultiStreamManager
const PCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const CTRL = Main.TimeseriesClusteringAPI.TimeSeriesController
const STM = Main.TimeseriesClusteringAPI.DissonanceStmManager

function measure_stage(graph, copy_on_write::Bool)
  GC.gc()
  measurement = @timed begin
    if copy_on_write
      CTRL._stage_generate_polyphonic_step_state(
        graph.managers, graph.stm_mgr, graph.stream_axis, graph.voice_state)
    else
      deepcopy(graph)
    end
  end
  return measurement.bytes, measurement.time
end

# Compare only the speculative transaction setup. The previous implementation
# recursively cloned all compressed span metadata and every task's keys and
# member-distance map; both modes leave the manager in its original state.
function old_span_snapshot(span)
  return PCM.CompressedClusterSpan(
    span.window_min, span.window_max, copy(span.cluster_ids),
    span.si_min, span.as_max, copy(span.versions), copy(span.fit_limits),
    PCM.CompressedClusterSpan[old_span_snapshot(child) for child in span.children],
  )
end

function measure_transaction_setup(mgr, old::Bool)
  GC.gc()
  measurement = @timed begin
    if old
      tasks = [PCM.ClusterTask(copy(t.keys), t.length,
        copy(t.member_squared_distances), t.representative_squared_distance,
        t.representative_version) for t in mgr.tasks]
      distance_ids = PCM.deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_distance)
      quantity_ids = PCM.deep_dup_sets(mgr.updated_cluster_ids_per_window_for_calculate_quantities)
      spans = PCM.CompressedClusterSpan[old_span_snapshot(s) for s in mgr.cluster_spans]
      (tasks, distance_ids, quantity_ids, spans)
    else
      PCM.start_transaction!(mgr)
      PCM.rollback!(mgr)
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

println("transaction_history_steps,mode,allocated_bytes,elapsed_s")
for history_steps in (24, 64, 128)
  history = [Float64[float(step % 3) / 4] for step in 1:history_steps]
  mgr = PCM.Manager(history, 0.02, 2, false;
    range_min=0.0, range_max=1.0, max_set_size=1)
  PCM.process_data!(mgr)
  PCM.update_caches_permanently!(mgr)
  measure_transaction_setup(mgr, true)
  measure_transaction_setup(mgr, false)
  for old in (true, false)
    samples = [measure_transaction_setup(mgr, old) for _ in 1:3]
    allocated = minimum(first, samples)
    elapsed = minimum(last, samples)
    println("$history_steps,$(old ? "recursive_snapshot" : "journal_snapshot"),$allocated,$elapsed")
  end
end

println("stage_history_steps,streams,mode,allocated_bytes,elapsed_s")
for history_steps in (8, 24, 64), streams in (2, 4)
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
  for copy_on_write in (false, true)
    samples = [measure_stage(graph, copy_on_write) for _ in 1:3]
    allocated = minimum(first, samples)
    elapsed = minimum(last, samples)
    println("$history_steps,$streams,$(copy_on_write ? "copy_on_write" : "deepcopy"),$allocated,$elapsed")
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
