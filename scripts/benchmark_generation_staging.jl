ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const MSM = Main.TimeseriesClusteringAPI.MultiStreamManager

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
