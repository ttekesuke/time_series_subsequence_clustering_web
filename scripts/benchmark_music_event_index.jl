ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

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
times = Rational{Int}[n // 4 for n in 0:255]
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

old_values(parsed, times, parts)
indexed_values(index, times, parts)
@assert old_values(parsed, times, parts) == indexed_values(index, times, parts)

for (label, work) in (("scan", () -> old_values(parsed, times, parts)),
    ("indexed_with_build", () -> indexed_values(MA._score_event_index(parsed), times, parts)))
  GC.gc()
  result = @timed work()
  println("music_events,steps=$(length(times)),parts=$(length(parts)),mode=$label,allocated_bytes=$(result.bytes),elapsed_s=$(result.time)")
end
