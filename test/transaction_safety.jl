const _tx_controller = Main.TimeseriesClusteringAPI.TimeSeriesController
const _tx_pcm = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const _tx_msm = Main.TimeseriesClusteringAPI.MultiStreamManager

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
