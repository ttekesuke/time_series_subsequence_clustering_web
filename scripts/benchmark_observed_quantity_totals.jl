ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const PCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const TC = Main.TimeseriesClusteringAPI.TimeSeriesController
sha = get(ENV, "GITHUB_SHA", "local")

function prepared()
  mgr = PCM.Manager([Float64[0.0], Float64[1.0]], 0.02, 2, false;
    range_min=0.0, range_max=2.0, max_set_size=1,
    recency=0.0, enable_occurrence_intervals=false)
  PCM.process_data!(mgr)
  TC.initial_calc_values!(mgr, PCM.transform_clusters(mgr))
  empty!(mgr.updated_cluster_ids_per_window_for_calculate_distance)
  preceding = Ref(PCM.current_extended_metrics(mgr))
  distances = Dict(window => sum(values(cache)) for (window, cache) in mgr.cluster_distance_cache)
  empty!(mgr.cluster_distance_cache)
  return mgr, preceding, distances
end

function run_steps(steps, incremental)
  mgr, preceding, distances = prepared()
  totals = incremental ? PCM.observed_quantity_totals(mgr) : nothing
  last = nothing
  for i in 1:steps
    value = Float64[float(mod(i ÷ 4, 3))]
    last = TC.evaluate_observed_complexity!(mgr, value;
      committed_metrics_ref=preceding, observed_distance_sums=distances,
      observed_quantity_totals=totals)
  end
  return mgr, distances, totals, last
end

function measure(work)
  work()
  samples = NamedTuple[]
  for _ in 1:3
    GC.gc()
    result = @timed work()
    push!(samples, (time=result.time, bytes=result.bytes))
  end
  minimum(s.time for s in samples), minimum(s.bytes for s in samples)
end

println("quantity_totals_fixture,sha=$sha,mode=observed,recency=0")
for steps in (32, 64)
  original = run_steps(steps, false)
  incremental = run_steps(steps, true)
  for key in ("distance", "quantity", "complexity")
    @assert isapprox(original[4]["raw"][key], incremental[4]["raw"][key]; atol=1e-8, rtol=1e-8)
  end
  @assert PCM.compressed_clusters_payload(original[1]) == PCM.compressed_clusters_payload(incremental[1])
  mgr, distances, totals, _ = incremental
  for (label, work) in (
    ("aggregate_scan", () -> PCM.calculate_all_extended_current_state(mgr;
      occurrence_intervals=PCM.EMPTY_OCCURRENCE_INTERVAL_METRICS,
      observed_distance_sums=distances)),
    ("aggregate_incremental", () -> PCM.calculate_all_extended_current_state(mgr;
      occurrence_intervals=PCM.EMPTY_OCCURRENCE_INTERVAL_METRICS,
      observed_distance_sums=distances, observed_quantity_totals=totals)),
  )
    elapsed, bytes = measure(() -> (for _ in 1:200; work(); end))
    println("quantity_totals_aggregate,steps=$steps,mode=$label,entries=$(sum(length, values(mgr.cluster_quantity_cache))),elapsed_s=$elapsed,allocated_bytes=$bytes")
  end
  for (label, incremental_mode) in (("original", false), ("incremental", true))
    elapsed, bytes = measure(() -> run_steps(steps, incremental_mode))
    println("quantity_totals_steps,steps=$steps,mode=$label,elapsed_s=$elapsed,allocated_bytes=$bytes")
  end
end
