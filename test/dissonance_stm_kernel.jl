using Test

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const _kernel_stm = Main.TimeseriesClusteringAPI.DissonanceStmManager

# The pre-kernel calculation is retained as an independent oracle.  In
# particular, it rebuilds/sorts every merged chord for each memory event.
function _reference_interference(mgr, notes, amps, onset, current)
  total = 0.0
  for event in mgr.memory
    dt = onset - event.onset
    dt < 0 && continue
    weight = exp(-dt / mgr.memory_span)
    weight < mgr.prune_threshold && continue
    merged_notes = vcat(notes, event.midi_notes)
    merged_amps = vcat(amps, event.amps)
    merged = _kernel_stm.dissonance_current_uncached(mgr, merged_notes, merged_amps)
    total += weight * mgr.memory_weight * (merged - current - event.dissonance_current)
  end
  total
end

function _reference_evaluate(mgr, notes, amps, onset)
  canonical = _kernel_stm.canonical_midi_notes(notes)
  current = _kernel_stm.dissonance_current_uncached(mgr, canonical, amps)
  current + _reference_interference(mgr, canonical, amps, onset, current)
end

function _reference_commit!(mgr, notes, amps, onset)
  canonical = _kernel_stm.canonical_midi_notes(notes)
  current = _kernel_stm.dissonance_current_uncached(mgr, canonical, amps)
  result = current + _reference_interference(mgr, canonical, amps, onset, current)
  _kernel_stm.prune!(mgr, onset)
  push!(mgr.memory, _kernel_stm.MemoryEvent(onset, copy(canonical), copy(amps), current))
  result
end

@testset "canonical partial kernel matches uncached roughness" begin
  for (partials, profile) in ((1, 0.88), (8, 0.88), (8, 0.4), (33, 0.88))
    manager = _kernel_stm.Manager(n_partials=partials, amp_profile=profile)
    for (notes, amps) in (
      ([60, 60, 67, 72], [0.75, 0.25, 0.6, 0.9]),
      ([59, 71, 83], [0.3, 0.5, 0.8]),
      ([60, 61, 64, 67], [1e-7, 1e-5, 0.0, 0.3]),
      ([60, 65], [0.8, 0.2]),
      (Int[], Float64[]),
    )
      canonical = _kernel_stm.canonical_midi_notes(notes)
      expected = _kernel_stm.dissonance_current_uncached(manager, canonical, amps)
      actual = _kernel_stm.dissonance_current(manager, canonical, amps)
      @test isapprox(actual, expected; atol=1e-10, rtol=1e-12)
    end
  end

  manager = _kernel_stm.Manager()
  @test _kernel_stm.dissonance_current(manager, [48, 55], [0.7, 0.4]) ==
        _kernel_stm.dissonance_current_uncached(manager, [48, 55], [0.7, 0.4])
  @test_throws ErrorException _kernel_stm.dissonance_current(
    _kernel_stm.Manager(model="unknown"), [60, 67], [0.7, 0.4])
end

@testset "evaluate and commit preserve STM values and pruning" begin
  for (partials, profile, threshold) in ((8, 0.88, 0.25), (1, 0.4, 0.01))
    fast = _kernel_stm.Manager(n_partials=partials, amp_profile=profile,
      prune_threshold=threshold, memory_span=0.45)
    reference = deepcopy(fast)
    for step in 0:42
      onset = step * 0.13
      if step % 9 == 8
        _kernel_stm.prune!(fast, onset)
        _kernel_stm.prune!(reference, onset)
        continue
      end
      notes = step % 3 == 0 ? [60, 60, 67] : [55 + step % 12, 64, 71, 79]
      amps = step % 3 == 0 ? [0.3, 0.7, 0.5] : [0.4, 0.8, 1e-7, 0.1 + step % 4 / 10]
      expected_preview = _reference_evaluate(reference, notes, amps, onset)
      @test isapprox(_kernel_stm.evaluate(fast, notes, amps, onset), expected_preview;
        atol=1e-10, rtol=1e-12)
      expected = _reference_commit!(reference, notes, amps, onset)
      actual = _kernel_stm.commit!(fast, notes, amps, onset)
      @test isapprox(actual, expected; atol=1e-10, rtol=1e-12)
      @test [event.onset for event in fast.memory] == [event.onset for event in reference.memory]
      @test all(isapprox(a.dissonance_current, b.dissonance_current;
        atol=1e-10, rtol=1e-12) for (a, b) in zip(fast.memory, reference.memory))
    end
  end
end
