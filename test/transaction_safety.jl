const _tx_controller = Main.TimeseriesClusteringAPI.TimeSeriesController
const _tx_pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const _tx_msm = Main.TimeseriesClusteringAPI.MultiStreamManager
const _tx_stm = Main.TimeseriesClusteringAPI.DissonanceStmManager

function _invalid_streamwise_manager()
  manager = _tx_pcm.Manager(
    Vector{Float64}[[0.0], [0.0], [0.0]],
    0.02,
    2,
    false;
    use_streamwise_surface_average=true,
    stream_axis_offset=2.0,
    stream_axis_capacity=1,
    value_min=0.0,
    value_max=1.0,
    range_min=0.0,
    range_max=1.0,
  )
  _tx_pcm.process_data!(manager)
  _tx_pcm.update_caches_permanently!(manager)
  return manager
end

function _pcm_snapshot(manager)
  return (
    data=deepcopy(manager.data),
    clusters=_tx_pcm.clusters_to_dict(manager.clusters),
    cluster_id_counter=manager.cluster_id_counter,
    tasks=deepcopy(manager.tasks),
    updated_distance=deepcopy(manager.updated_cluster_ids_per_window_for_calculate_distance),
    updated_quantity=deepcopy(manager.updated_cluster_ids_per_window_for_calculate_quantities),
    distance_cache=deepcopy(manager.cluster_distance_cache),
    quantity_cache=deepcopy(manager.cluster_quantity_cache),
    complexity_cache=deepcopy(manager.cluster_complexity_cache),
  )
end

function _msm_snapshot(manager)
  return (
    active_ids=copy(manager.active_ids),
    containers=Dict(
      id => (
        manager=_pcm_snapshot(container.manager),
        last_value=deepcopy(container.last_value),
        presence_sum=container.presence_sum,
        presence_count=container.presence_count,
        presence_avg=container.presence_avg,
      )
      for (id, container) in manager.containers_by_id
    ),
  )
end

function _stm_snapshot(manager)
  return [
    (
      onset=event.onset,
      midi_notes=copy(event.midi_notes),
      amps=copy(event.amps),
      dissonance_current=event.dissonance_current,
    )
    for event in manager.memory
  ]
end

@testset "simulation failures propagate and roll back" begin
  manager = _invalid_streamwise_manager()
  before_data = deepcopy(manager.data)
  before_clusters = _tx_pcm.clusters_to_dict(manager.clusters)

  @test_throws ErrorException _tx_controller._safe_simulate_add_and_calculate_all_extended(
    manager,
    Float64[4.0],
  )
  @test manager.data == before_data
  @test _tx_pcm.clusters_to_dict(manager.clusters) == before_clusters

  @test_throws ErrorException _tx_msm.safe_simulate_add_and_calculate(manager, Float64[4.0])
  @test manager.data == before_data
  @test _tx_pcm.clusters_to_dict(manager.clusters) == before_clusters
end

@testset "safe permanent append does not fall back to a raw push" begin
  manager = _invalid_streamwise_manager()
  before_data = deepcopy(manager.data)
  before_clusters = _tx_pcm.clusters_to_dict(manager.clusters)

  @test_throws ErrorException _tx_msm.safe_add_data_point!(manager, Float64[4.0])
  @test manager.data == before_data
  @test _tx_pcm.clusters_to_dict(manager.clusters) == before_clusters
end

@testset "multi-stream commit publishes only after all stream appends succeed" begin
  history = [
    Any[0.0, 0.0],
    Any[0.0, 0.0],
    Any[0.0, 0.0],
  ]
  manager = _tx_msm.Manager(
    history,
    0.02,
    2;
    value_range=[0.0, 1.0],
    track_presence=true,
  )

  # Make only the second stream reject the candidate during incremental clustering.
  bad = manager.containers_by_id[manager.active_ids[2]].manager
  bad.use_streamwise_surface_average = true
  bad.stream_axis_offset = 2.0
  bad.stream_axis_capacity = 1
  bad.value_min = 0.0
  bad.value_max = 1.0
  bad.value_width = 1.0

  before_data = Dict(
    id => deepcopy(manager.containers_by_id[id].manager.data)
    for id in manager.active_ids
  )
  before_last = Dict(
    id => deepcopy(manager.containers_by_id[id].last_value)
    for id in manager.active_ids
  )
  before_presence = Dict(
    id => (
      manager.containers_by_id[id].presence_sum,
      manager.containers_by_id[id].presence_count,
      manager.containers_by_id[id].presence_avg,
    )
    for id in manager.active_ids
  )

  @test_throws ErrorException _tx_msm.commit_state!(manager, [0.0, 4.0])

  for id in manager.active_ids
    stream = manager.containers_by_id[id]
    @test stream.manager.data == before_data[id]
    @test stream.last_value == before_last[id]
    @test (stream.presence_sum, stream.presence_count, stream.presence_avg) == before_presence[id]
  end
end

@testset "future-step staging isolates managers caches STM and stable axis" begin
  axis = _tx_controller.StableStreamAxis(3, [1, 2])

  global_manager = _tx_pcm.Manager(
    Vector{Float64}[[0.0], [0.0], [0.0]],
    0.02,
    2,
    false;
    value_min=0.0,
    value_max=1.0,
    range_min=0.0,
    range_max=1.0,
  )
  _tx_pcm.process_data!(global_manager)
  _tx_pcm.update_caches_permanently!(global_manager)

  stream_manager = _tx_msm.Manager(
    [Any[0.0, 0.0], Any[0.0, 0.0], Any[0.0, 0.0]],
    0.02,
    2;
    value_range=[0.0, 1.0],
    track_presence=true,
  )

  managers = Dict{String,Any}(
    "vol" => Dict{Symbol,Any}(
      :global => global_manager,
      :stream => stream_manager,
      :global_offset => 2.0,
      :stream_axis => axis,
    ),
  )

  stm = _tx_stm.Manager()
  _tx_stm.commit!(stm, [60, 64], [0.5, 0.5], 0.0)

  before_global = _pcm_snapshot(global_manager)
  before_streams = _msm_snapshot(stream_manager)
  before_stm = _stm_snapshot(stm)
  before_axis = (copy(axis.id_to_slot), copy(axis.slot_to_id))

  staged = _tx_controller._stage_generate_polyphonic_step_state(managers, stm, axis, nothing)

  @test staged.managers !== managers
  @test staged.stm_mgr !== stm
  @test staged.stream_axis !== axis
  @test staged.managers["vol"][:stream_axis] === staged.stream_axis

  staged_global = staged.managers["vol"][:global]
  staged_streams = staged.managers["vol"][:stream]
  _tx_pcm.add_data_point_permanently!(staged_global, Float64[0.5])
  _tx_pcm.update_caches_permanently!(staged_global)
  _tx_msm.commit_state!(staged_streams, [0.25, 0.75])
  _tx_msm.update_caches_permanently!(staged_streams)
  _tx_stm.commit!(staged.stm_mgr, [67, 71], [0.4, 0.6], 1.0)
  _tx_controller._register_stream_ids!(staged.stream_axis, [3])

  @test _pcm_snapshot(global_manager) == before_global
  @test _msm_snapshot(stream_manager) == before_streams
  @test _stm_snapshot(stm) == before_stm
  @test (axis.id_to_slot, axis.slot_to_id) == before_axis

  @test length(staged_global.data) == length(global_manager.data) + 1
  @test length(staged.stm_mgr.memory) == length(stm.memory) + 1
  @test haskey(staged.stream_axis.id_to_slot, 3)
  @test !haskey(axis.id_to_slot, 3)
end

@testset "candidate failure context preserves dimension stream and candidate" begin
  axis = _tx_controller.StableStreamAxis(1, [1])
  global_manager = _invalid_streamwise_manager()
  stream_manager = _tx_msm.Manager(
    [Any[0.0], Any[0.0], Any[0.0]],
    0.02,
    2;
    value_range=[0.0, 1.0],
  )
  mgrs = Dict{Symbol,Any}(
    :global => global_manager,
    :stream => stream_manager,
    :global_offset => 2.0,
    :stream_axis => axis,
  )
  context = Dict{Symbol,Any}(
    :operation => "dimension_prepare",
    :dimension => "vol",
    :stream_id => nothing,
    :candidate => nothing,
  )

  @test_throws ErrorException _tx_controller.select_best_values_for_dimension_greedy(
    mgrs,
    Float64[4.0],
    0.5,
    Float64[0.5],
    0.0,
    1;
    priority_order=[1],
    trace_context=context,
  )

  @test context[:operation] == "simulate_candidate"
  @test context[:dimension] == "vol"
  @test context[:stream_id] == stream_manager.active_ids[1]
  @test context[:candidate] == 4.0
end
