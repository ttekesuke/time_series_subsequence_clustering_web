ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()
benchmark_started_at = time()
benchmark_sha = get(ENV, "GITHUB_SHA", "local")
println("music_events_fixture,sha=$benchmark_sha,max_steps=512,parts=3")

const MA = Main.TimeseriesClusteringAPI.MusicAnalysis

# A bounded extraction-only fixture. This does not run clustering or a long score.
parts = ("P1", "P2", "P3")
dynamics = MA.DynamicEvent[
  MA.DynamicEvent(part, n // 4, 0.2 + 0.1 * mod(n + part_index, 6))
  for (part_index, part) in enumerate(parts) for n in 0:4:64
]
wedges = MA.WedgeEvent[
  MA.WedgeEvent(part, n // 4, (n + 20) // 4, iseven(n) ? "crescendo" : "diminuendo")
  for part in parts for n in 0:8:48
]
tempos = MA.TempoEvent[MA.TempoEvent(n // 4, 72.0 + n) for n in 0:8:64]
sort!(dynamics; by=e -> (e.time_q, e.part_id))
sort!(wedges; by=e -> (e.start_q, e.part_id))
parsed = MA.ParsedScore(MA.NoteEvent[], dynamics, wedges, tempos,
  Dict(part => part for part in parts), 64 // 1)
times = Rational{Int}[n // 4 for n in 0:511]
index = MA._score_event_index(parsed)

function old_values(parsed, times, parts)
  total = 0.0
  for t in times
    total += MA.seconds_at(parsed, t) + MA.tempo_at(parsed, t)
    for part in parts
      total += MA.dynamic_at(parsed, part, t)
    end
  end
  return total
end
function indexed_values(index, times, parts)
  total = 0.0
  cursor = MA.ScoreEventCursor()
  for t in times
    seconds, bpm = MA._step_timing!(index, cursor, t)
    total += seconds + bpm
    for part in parts
      total += MA._dynamic_at!(index, cursor, part, t)
    end
  end
  return total
end

function measure(work)
  work() # Compile the closure and its call site before measuring.
  samples = NamedTuple[]
  for _ in 1:5
    GC.gc()
    result = @timed work()
    push!(samples, (bytes=result.bytes, time=result.time))
  end
  return minimum(sample.bytes for sample in samples), minimum(sample.time for sample in samples)
end

for step_count in (128, 256, 512)
  sample_times = times[1:step_count]
  @assert old_values(parsed, sample_times, parts) == indexed_values(index, sample_times, parts)
  for (label, work) in (("scan", () -> old_values(parsed, sample_times, parts)),
      ("indexed_reuse", () -> indexed_values(index, sample_times, parts)),
      ("indexed_with_build", () -> indexed_values(MA._score_event_index(parsed), sample_times, parts)))
    bytes, elapsed = measure(work)
    println("music_events,steps=$step_count,parts=$(length(parts)),mode=$label,allocated_bytes=$bytes,elapsed_s=$elapsed")
  end
end
println("music_events_summary,sha=$benchmark_sha,wall_s=$(round(time() - benchmark_started_at; digits=3))")
