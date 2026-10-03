ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const STM = Main.TimeseriesClusteringAPI.DissonanceStmManager
started = time()
sha = get(ENV, "GITHUB_SHA", "local")

function reference_commit!(mgr, notes, amps, onset)
  canonical = STM.canonical_midi_notes(notes)
  current = STM.dissonance_current_uncached(mgr, canonical, amps)
  interference = 0.0
  for event in mgr.memory
    dt = onset - event.onset
    dt < 0 && continue
    weight = exp(-dt / mgr.memory_span)
    weight < mgr.prune_threshold && continue
    merged = STM.dissonance_current_uncached(mgr,
      vcat(canonical, event.midi_notes), vcat(amps, event.amps))
    interference += weight * mgr.memory_weight * (merged - current - event.dissonance_current)
  end
  STM.prune!(mgr, onset)
  push!(mgr.memory, STM.MemoryEvent(onset, copy(canonical), copy(amps), current))
  current + interference
end

function fixture(kind, steps)
  return [(kind == :repeated ? [60, 60, 67] : [60 + mod(step, 12), 64, 67, 71],
    kind == :repeated ? [0.5, 0.5, 0.8] : [0.4, 0.6, 0.8, 0.2 + mod(step, 4) / 10],
    step * 0.25) for step in 0:(steps - 1)]
end

function run_sequence(events, mode)
  mgr = STM.Manager(memory_span=1.0)
  total = 0.0
  for (notes, amps, onset) in events
    total += mode == :original ? reference_commit!(mgr, notes, amps, onset) :
      STM.commit!(mgr, notes, amps, onset)
  end
  total
end

function measure(work)
  work() # Compile outside the samples.
  samples = NamedTuple[]
  for _ in 1:3
    GC.gc()
    result = @timed work()
    push!(samples, (time=result.time, bytes=result.bytes))
  end
  minimum(s.time for s in samples), minimum(s.bytes for s in samples)
end

println("dissonance_stm_fixture,sha=$sha,partials=8,span=1.0")
for kind in (:repeated, :changing_chord), steps in (128, 256)
  events = fixture(kind, steps)
  original = run_sequence(events, :original)
  cached = run_sequence(events, :cached)
  @assert isapprox(original, cached; atol=1e-8, rtol=1e-12)
  for mode in (:original, :cached)
    elapsed, bytes = measure(() -> run_sequence(events, mode))
    println("dissonance_stm,fixture=$kind,steps=$steps,mode=$mode,elapsed_s=$elapsed,allocated_bytes=$bytes")
  end
end

# Measure the three stages individually at a fixed memory size.  The memory
# interference stage includes merged-chord roughness; pruning has no kernel.
mgr = STM.Manager(memory_span=1.0)
events = fixture(:changing_chord, 8)
foreach(event -> STM.commit!(mgr, event...), events)
notes, amps, onset = events[end]
canonical = STM.canonical_midi_notes(notes)
current = STM.dissonance_current(mgr, canonical, amps)
for (label, work) in (
  ("current", () -> STM.dissonance_current(mgr, canonical, amps)),
  ("interference", () -> STM.memory_interference(mgr, canonical, amps, onset, current)),
  ("prune", () -> STM.prune!(deepcopy(mgr), onset)),
)
  elapsed, bytes = measure(() -> (for _ in 1:200; work(); end))
  println("dissonance_stm_stage,stage=$label,calls=200,elapsed_s=$elapsed,allocated_bytes=$bytes")
end
println("dissonance_stm_total,sha=$sha,wall_s=$(round(time() - started; digits=3))")
