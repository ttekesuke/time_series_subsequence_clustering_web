using Test
using Random

const _ProdPCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
if !isdefined(Main.TimeseriesClusteringAPI, :LegacyPolyphonicClusterManager)
  Base.include(
    Main.TimeseriesClusteringAPI,
    joinpath(@__DIR__, "reference", "polyphonic_cluster_manager_legacy.jl"),
  )
end
const _LegacyPCM = Main.TimeseriesClusteringAPI.LegacyPolyphonicClusterManager

_round12(x::Real) = round(Float64(x); digits=12)

function _norm_polyseq(seq)
  [[_round12(x) for x in row] for row in seq]
end

function _norm_metrics(metrics)
  temporal = metrics.occurrence_intervals
  return (
    distance=_round12(metrics.distance),
    quantity=_round12(metrics.quantity),
    complexity=_round12(metrics.complexity),
    occurrence=(
      distance=_round12(temporal.distance),
      quantity=_round12(temporal.quantity),
      complexity=_round12(temporal.complexity),
      prediction=isnan(temporal.prediction) ? "NaN" : _round12(temporal.prediction),
      ready=temporal.ready,
    ),
  )
end

function _norm_prediction(M, mgr)
  dist = M.build_predictive_distribution(mgr)
  rows = [
    (
      value=[_round12(x) for x in successor.value],
      mass=_round12(successor.mass),
    )
    for successor in dist.successors
  ]
  sort!(rows; by=row -> Tuple(row.value))
  return (
    ready=dist.ready,
    peak=_round12(dist.peak_likelihood),
    successors=rows,
  )
end

function _norm_cache(cache)
  rows = Any[]
  for ws in sort!(collect(keys(cache)))
    inner = cache[ws]
    vals = Any[]
    for key in sort!(collect(keys(inner)); by=string)
      push!(vals, (key=string(key), value=_round12(inner[key])))
    end
    push!(rows, (window=ws, values=vals))
  end
  return rows
end

function _logical_snapshot(M, mgr)
  clusters_each = M.collect_clusters_each(mgr)
  nodes = Any[]
  for ws in sort!(collect(keys(clusters_each)))
    same_ws = clusters_each[ws]
    for cid in sort!(collect(keys(same_ws)))
      node = same_ws[cid]
      push!(nodes, (
        window=ws,
        id=cid,
        starts=sort(copy(node.si)),
        representative=_norm_polyseq(node.as),
      ))
    end
  end

  timeline_payload =
    M === _ProdPCM ?
      M.clusters_to_timeline(mgr) :
      M.clusters_to_timeline(mgr.clusters, mgr.min_window_size)
  timeline = [
    (
      window=Int(item["window_size"]),
      id=String(item["cluster_id"]),
      starts=Int[x for x in item["indices"]],
    )
    for item in timeline_payload
  ]
  sort!(timeline; by=item -> (item.window, parse(Int, item.id), Tuple(item.starts)))

  return (
    data=_norm_polyseq(mgr.data),
    cluster_id_counter=mgr.cluster_id_counter,
    tasks=sort([
      hasproperty(task, :keys) ?
        (Tuple(getproperty(task, :keys)), getproperty(task, :length)) :
        (Tuple(task[1]), task[2])
      for task in mgr.tasks
    ]; by=string),
    nodes=nodes,
    timeline=timeline,
    distance_cache=_norm_cache(mgr.cluster_distance_cache),
    quantity_cache=_norm_cache(mgr.cluster_quantity_cache),
    complexity_cache=_norm_cache(mgr.cluster_complexity_cache),
    metrics=_norm_metrics(M.calculate_all_extended_current_state(mgr)),
    prediction=_norm_prediction(M, mgr),
  )
end

function _assert_lossless_compression(prod)
  spans = _ProdPCM.compress_cluster_tree(prod)
  @test spans === prod.cluster_spans
  @test _ProdPCM.compressed_virtual_nodes(spans) == _ProdPCM.logical_virtual_nodes(prod)

  # Every physical span must be internally consistent and reconstruct all
  # logical ids/windows without duplicates.
  rows = _ProdPCM.logical_virtual_nodes(prod)
  ids = [row.cluster_id for row in rows]
  @test length(ids) == length(unique(ids))
  @test all(span -> length(span.cluster_ids) == length(span.versions) == length(span.fit_limits), spans)
end

function _assert_equivalent(prod, legacy)
  @test _logical_snapshot(_ProdPCM, prod) == _logical_snapshot(_LegacyPCM, legacy)
  _assert_lossless_compression(prod)
end

function _make_managers(scenario; initial_count=nothing)
  data = deepcopy(scenario.data)
  if initial_count !== nothing
    data = deepcopy(data[1:initial_count])
  end
  prod = _ProdPCM.Manager(
    data,
    scenario.threshold,
    2,
    false;
    scenario.kwargs...,
  )
  legacy = _LegacyPCM.Manager(
    deepcopy(data),
    scenario.threshold,
    2,
    false;
    scenario.kwargs...,
  )
  return prod, legacy
end

function _run_bulk_case(scenario)
  prod, legacy = _make_managers(scenario)
  _ProdPCM.process_data!(prod)
  _LegacyPCM.process_data!(legacy)
  _ProdPCM.update_caches_permanently!(prod)
  _LegacyPCM.update_caches_permanently!(legacy)
  _assert_equivalent(prod, legacy)

  before_prod = _logical_snapshot(_ProdPCM, prod)
  before_legacy = _logical_snapshot(_LegacyPCM, legacy)
  for candidate in scenario.candidates
    pm = _ProdPCM.simulate_add_and_calculate_all_extended(prod, copy(candidate))
    lm = _LegacyPCM.simulate_add_and_calculate_all_extended(legacy, copy(candidate))
    @test _norm_metrics(pm) == _norm_metrics(lm)
    @test _logical_snapshot(_ProdPCM, prod) == before_prod
    @test _logical_snapshot(_LegacyPCM, legacy) == before_legacy
  end
end

function _run_incremental_case(scenario)
  @test length(scenario.data) >= 2
  prod, legacy = _make_managers(scenario; initial_count=2)
  _ProdPCM.process_data!(prod)
  _LegacyPCM.process_data!(legacy)
  _ProdPCM.update_caches_permanently!(prod)
  _LegacyPCM.update_caches_permanently!(legacy)
  _assert_equivalent(prod, legacy)

  for value in scenario.data[3:end]
    simulated_prod = _ProdPCM.simulate_add_and_calculate_all_extended(prod, copy(value))
    simulated_legacy = _LegacyPCM.simulate_add_and_calculate_all_extended(legacy, copy(value))
    @test _norm_metrics(simulated_prod) == _norm_metrics(simulated_legacy)

    _ProdPCM.add_data_point_permanently!(prod, copy(value))
    _LegacyPCM.add_data_point_permanently!(legacy, copy(value))
    _ProdPCM.update_caches_permanently!(prod)
    _LegacyPCM.update_caches_permanently!(legacy)

    # Keep the exact legacy two-phase behavior: candidate simulation and
    # committed-state aggregation are intentionally not assumed equivalent.
    _assert_equivalent(prod, legacy)
  end
end

Random.seed!(0x51A7)
random_scalar = [Float64[float(rand(0:4))] for _ in 1:18]
random_poly = [
  sort!(unique(Float64[rand(58:66) for _ in 1:rand(0:3)]))
  for _ in 1:18
]

const _compression_equivalence_scenarios = [
  (
    name="constant",
    data=[Float64[1.0] for _ in 1:16],
    threshold=0.0,
    kwargs=(range_min=0.0, range_max=4.0, max_set_size=1),
    candidates=[Float64[1.0], Float64[2.0]],
  ),
  (
    name="alternating",
    data=[Float64[isodd(i) ? 0.0 : 1.0] for i in 1:18],
    threshold=0.0,
    kwargs=(range_min=0.0, range_max=1.0, max_set_size=1),
    candidates=[Float64[0.0], Float64[1.0]],
  ),
  (
    name="periodic-3",
    data=[Float64[mod(i - 1, 3)] for i in 1:18],
    threshold=0.0,
    kwargs=(range_min=0.0, range_max=2.0, max_set_size=1),
    candidates=[Float64[0.0], Float64[2.0]],
  ),
  (
    name="branching-extensions",
    data=[Float64[0],Float64[1],Float64[0],Float64[2],Float64[0],Float64[1],Float64[0],Float64[3],Float64[0],Float64[1],Float64[0],Float64[2],Float64[0],Float64[1]],
    threshold=0.0,
    kwargs=(range_min=0.0, range_max=3.0, max_set_size=1),
    candidates=[Float64[0.0], Float64[3.0]],
  ),
  (
    name="embedded-long-repeat",
    data=[Float64[1],Float64[2],Float64[3],Float64[4],Float64[5],Float64[9],Float64[1],Float64[2],Float64[3],Float64[4],Float64[5],Float64[8],Float64[1],Float64[2],Float64[3],Float64[4],Float64[5]],
    threshold=0.0,
    kwargs=(range_min=0.0, range_max=9.0, max_set_size=1),
    candidates=[Float64[6.0], Float64[1.0]],
  ),
  (
    name="rests-and-notes",
    data=[Float64[], Float64[60], Float64[], Float64[60], Float64[], Float64[60],
          Float64[], Float64[62], Float64[], Float64[60], Float64[], Float64[60]],
    threshold=0.0,
    kwargs=(range_min=36.0, range_max=120.0, max_set_size=1),
    candidates=[Float64[], Float64[60]],
  ),
  (
    name="polyphonic-chords",
    data=[
      Float64[60,64], Float64[62,65], Float64[60,64], Float64[62,65],
      Float64[60,64], Float64[67,71], Float64[60,64], Float64[62,65],
      Float64[60,64], Float64[62,65], Float64[60,64], Float64[67,71],
    ],
    threshold=0.0,
    kwargs=(range_min=36.0, range_max=120.0, max_set_size=4),
    candidates=[Float64[60,64], Float64[62,65]],
  ),
  (
    name="varying-cardinality",
    data=[
      Float64[60], Float64[60,64], Float64[60], Float64[60,64],
      Float64[60], Float64[60,64,67], Float64[60], Float64[60,64],
      Float64[60], Float64[60,64],
    ],
    threshold=0.0,
    kwargs=(range_min=36.0, range_max=120.0, max_set_size=4),
    candidates=[Float64[60], Float64[60,64]],
  ),
  (
    name="approximate-merge",
    data=[Float64[0.00],Float64[0.10],Float64[0.01],Float64[0.11],Float64[0.02],Float64[0.12],Float64[0.03],Float64[0.13],Float64[0.04],Float64[0.14]],
    threshold=0.08,
    kwargs=(range_min=0.0, range_max=1.0, max_set_size=1),
    candidates=[Float64[0.05], Float64[0.15]],
  ),
  (
    name="ordered-vector",
    data=[
      Float64[60,0.5],Float64[62,0.8],Float64[60,0.5],Float64[62,0.8],Float64[60,0.5],Float64[64,0.3],
      Float64[60,0.5],Float64[62,0.8],Float64[60,0.5],Float64[62,0.8],
    ],
    threshold=0.03,
    kwargs=(
      range_min=0.0,
      range_max=127.0,
      max_set_size=2,
      point_distance_mode=:ordered_vector,
      point_axis_ranges=Float64[127.0,1.0],
    ),
    candidates=[Float64[60,0.5], Float64[64,0.3]],
  ),
  (
    name="streamwise-surface",
    data=[
      Float64[60.0, 129.0 + 67.0],
      Float64[62.0, 129.0 + 69.0],
      Float64[60.0, 129.0 + 67.0],
      Float64[62.0, 129.0 + 69.0],
      Float64[60.0, 129.0 + 67.0],
      Float64[64.0, 129.0 + 71.0],
      Float64[60.0, 129.0 + 67.0],
      Float64[62.0, 129.0 + 69.0],
    ],
    threshold=0.02,
    kwargs=(
      range_min=0.0,
      range_max=400.0,
      max_set_size=2,
      use_streamwise_surface_average=true,
      stream_axis_offset=129.0,
      stream_axis_capacity=2,
    ),
    candidates=[Float64[60.0,196.0], Float64[64.0,200.0]],
  ),
  (
    name="recency",
    data=[Float64[mod(i - 1, 4)] for i in 1:18],
    threshold=0.0,
    kwargs=(range_min=0.0, range_max=3.0, max_set_size=1, recency=0.7),
    candidates=[Float64[0.0], Float64[3.0]],
  ),
  (
    name="seeded-random-scalar",
    data=random_scalar,
    threshold=0.12,
    kwargs=(range_min=0.0, range_max=4.0, max_set_size=1),
    candidates=[Float64[0.0], Float64[4.0]],
  ),
  (
    name="seeded-random-polyphonic",
    data=random_poly,
    threshold=0.08,
    kwargs=(range_min=36.0, range_max=120.0, max_set_size=4),
    candidates=[Float64[], Float64[60,64]],
  ),
]

@testset "polyphonic compression preserves legacy behavior" begin
  for scenario in _compression_equivalence_scenarios
    @testset "$(scenario.name) bulk" begin
      _run_bulk_case(scenario)
    end
    @testset "$(scenario.name) incremental" begin
      _run_incremental_case(scenario)
    end
  end
end


function _count_compressed_spans(spans)
  total = length(spans)
  for span in spans
    total += _count_compressed_spans(span.children)
  end
  return total
end

@testset "lossless view actually compresses repeated chains" begin
  data = [Float64[mod(i - 1, 2)] for i in 1:24]
  mgr = _ProdPCM.Manager(data, 0.0, 2; range_min=0.0, range_max=1.0, max_set_size=1)
  _ProdPCM.process_data!(mgr)
  spans = _ProdPCM.compress_cluster_tree(mgr)
  logical_count = length(_ProdPCM.logical_virtual_nodes(mgr))
  compressed_count = _count_compressed_spans(spans)
  @test compressed_count <= logical_count
  @test any(span -> span.window_max > span.window_min, spans) ||
        compressed_count < logical_count
  @test _ProdPCM.compressed_virtual_nodes(spans) ==
        _ProdPCM.logical_virtual_nodes(mgr)
end


@testset "physical compressed storage survives append and simulation rollback" begin
  data = [Float64[mod(i - 1, 3)] for i in 1:18]
  mgr = _ProdPCM.Manager(data, 0.0, 2; range_min=0.0, range_max=2.0, max_set_size=1)
  _ProdPCM.process_data!(mgr)

  committed_rows = deepcopy(_ProdPCM.logical_virtual_nodes(mgr))
  committed_physical = deepcopy(mgr.cluster_spans)

  _ProdPCM.simulate_add_and_calculate_all_extended(mgr, Float64[1.0])
  @test _ProdPCM.logical_virtual_nodes(mgr) == committed_rows
  @test _ProdPCM.compressed_virtual_nodes(mgr.cluster_spans) ==
        _ProdPCM.compressed_virtual_nodes(committed_physical)

  _ProdPCM.add_data_point_permanently!(mgr, Float64[0.0])
  @test !isempty(mgr.cluster_spans)
  @test _ProdPCM.compressed_virtual_nodes(mgr.cluster_spans) ==
        _ProdPCM.logical_virtual_nodes(mgr)
end


@testset "production code does not depend on physical cluster storage" begin
  repo_root = normpath(joinpath(@__DIR__, ".."))
  source_roots = [
    joinpath(repo_root, "src", "controllers"),
    joinpath(repo_root, "src", "music"),
    joinpath(repo_root, "src", "polyphonic", "multi_stream_manager.jl"),
    joinpath(repo_root, "src", "voice"),
  ]

  offenders = String[]
  for root in source_roots
    paths = if isfile(root)
      String[root]
    elseif isdir(root)
      String[
        joinpath(dir, file)
        for (dir, _, files) in walkdir(root)
        for file in files
        if endswith(file, ".jl")
      ]
    else
      String[]
    end

    for path in paths
      text = read(path, String)
      if occursin("working_clusters", text) || occursin("cluster_spans", text)
        push!(offenders, relpath(path, repo_root))
      end
    end
  end

  @test isempty(offenders)
end
