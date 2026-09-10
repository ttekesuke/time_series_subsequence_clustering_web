using Test

const LifecycleMSM = Main.TimeseriesClusteringAPI.MultiStreamManager
const LifecycleConfig = Main.TimeseriesClusteringAPI.Config

function volume_lifecycle_manager()
  manager = LifecycleMSM.Manager(
    [[0.2, 0.8], [0.2, 0.8], [0.2, 0.8]],
    0.3,
    2;
    value_range=LifecycleConfig.VOL_STEPS,
    track_presence=true,
  )
  @test all(0.0 <= LifecycleMSM.get_stream_strength(manager, id) <= 1.0 for id in manager.active_ids)
  return manager
end

@testset "#18 volume lifecycle remains presence-based for generated and fixed volume" begin
  for policy in (:generated, :fixed)
    manager = volume_lifecycle_manager()

    decrease = LifecycleMSM.build_stream_lifecycle_plan(manager, 1; target=0.2, spread=0.0)
    @test decrease.deactivate_ids == [1]
    @test decrease.active_ids == [2]
    LifecycleMSM.apply_stream_lifecycle_plan!(manager, decrease)

    increase = LifecycleMSM.build_stream_lifecycle_plan(manager, 2; target=0.2, spread=0.0)
    @test increase.revive_ids == [1]
    @test isempty(increase.fork_pairs)
    LifecycleMSM.apply_stream_lifecycle_plan!(manager, increase)
    @test Set(manager.active_ids) == Set([1, 2])

    fork_plan = LifecycleMSM.build_stream_lifecycle_plan(manager, 3; target=0.8, spread=0.0)
    @test isempty(fork_plan.revive_ids)
    @test length(fork_plan.fork_pairs) == 1
    @test fork_plan.fork_pairs[1][1] == 2
    LifecycleMSM.apply_stream_lifecycle_plan!(manager, fork_plan)
    @test length(manager.active_ids) == 3

    committed = policy == :generated ? [0.9, 0.2, 0.9] : [0.6, 0.6, 0.6]
    LifecycleMSM.commit_state!(manager, committed)
    @test all(0.0 <= LifecycleMSM.get_stream_strength(manager, id) <= 1.0 for id in manager.active_ids)
  end
end
