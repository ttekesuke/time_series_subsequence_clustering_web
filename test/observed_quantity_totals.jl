using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _quantity_pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const _quantity_controller = Main.TimeseriesClusteringAPI.TimeSeriesController

function _quantity_fixture(streamwise)
  seed = streamwise ? [Float64[10.0, 140.0], Float64[20.0, 150.0]] :
    [Float64[0.0], Float64[1.0]]
  manager = _quantity_pcm.Manager(seed, 0.02, 2, false;
    range_min=0.0, range_max=streamwise ? 386.0 : 2.0,
    max_set_size=streamwise ? 2 : 1,
    use_streamwise_surface_average=streamwise,
    stream_axis_offset=streamwise ? 129.0 : 1.0,
    stream_axis_capacity=streamwise ? 2 : 1,
    recency=0.0, enable_occurrence_intervals=false)
  _quantity_pcm.process_data!(manager)
  _quantity_controller.initial_calc_values!(manager, _quantity_pcm.transform_clusters(manager))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
  prior = Ref(_quantity_pcm.current_extended_metrics(manager))
  distances = Dict(window => sum(values(cache)) for (window, cache) in manager.cluster_distance_cache)
  empty!(manager.cluster_distance_cache)
  return manager, prior, distances
end

@testset "observed quantity deltas match every cache and scoring axis" begin
  for streamwise in (false, true)
    baseline, baseline_prior, baseline_distances = _quantity_fixture(streamwise)
    optimized, optimized_prior, optimized_distances = _quantity_fixture(streamwise)
    totals = _quantity_pcm.observed_quantity_totals(optimized)
    sequence = streamwise ?
      [Float64[10.0 + mod(i ÷ 3, 3), 140.0 + mod(i, 4)] for i in 1:28] :
      [Float64[float(mod(i ÷ 3, 3))] for i in 1:56]

    for (index, value) in enumerate(sequence)
      if index == length(sequence)
        # Exercise the periodic complete rebaseline without a long score.
        totals.commits = 255
      end
      expected = _quantity_controller.evaluate_observed_complexity!(baseline, value;
        committed_metrics_ref=baseline_prior, observed_distance_sums=baseline_distances)
      actual = _quantity_controller.evaluate_observed_complexity!(optimized, value;
        committed_metrics_ref=optimized_prior, observed_distance_sums=optimized_distances,
        observed_quantity_totals=totals)
      for key in ("prediction", "diversity", "shape", "mass")
        a, b = actual[key], expected[key]
        @test isequal(a, b) || (a !== nothing && b !== nothing && isapprox(a, b; atol=1e-8, rtol=1e-8))
      end
      for key in ("distance", "quantity", "complexity")
        @test isapprox(actual["raw"][key], expected["raw"][key]; atol=1e-8, rtol=1e-8)
      end
      @test isapprox(totals.quantity,
        sum(sum(values(cache)) for cache in values(optimized.cluster_quantity_cache)); atol=1e-8)
      @test isapprox(totals.complexity,
        sum(sum(values(cache)) for cache in values(optimized.cluster_complexity_cache)); atol=1e-8)
      for (window, cache) in optimized.cluster_quantity_cache
        @test isapprox(totals.quantities[window], sum(values(cache)); atol=1e-8)
      end
      for (window, cache) in optimized.cluster_complexity_cache
        @test isapprox(totals.complexities[window], sum(values(cache)); atol=1e-8)
      end
    end
    @test _quantity_pcm.compressed_clusters_payload(optimized) ==
      _quantity_pcm.compressed_clusters_payload(baseline)
    @test totals.commits == 256
  end
end
