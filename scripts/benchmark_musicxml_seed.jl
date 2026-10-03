ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

module SeedBenchmark
  include(joinpath(@__DIR__, "seed_influx.jl"))
end

const MA = Main.TimeseriesClusteringAPI.MusicAnalysis
const SEED = SeedBenchmark
sha = get(ENV, "GITHUB_SHA", "local")

# 144 notes, three parts, mixed division values.  This is a parser/index
# fixture only; it does not seed Influx or run MusicAnalyse clustering.
parts = String[]
for (id, divisions) in (("P1", 4), ("P2", 6), ("P3", 3))
  measures = String[]
  for bar in 1:12
    notes = join(("<note><pitch><step>C</step><octave>4</octave></pitch><duration>$divisions</duration><voice>1</voice></note>" for _ in 1:4))
    push!(measures, "<measure number=\"$bar\"><attributes><divisions>$divisions</divisions></attributes>$notes</measure>")
  end
  push!(parts, "<part id=\"$id\">$(join(measures))</part>")
end
xml = "<score-partwise><part-list>" * join(("<score-part id=\"$id\"><part-name>$id</part-name></score-part>" for id in ("P1", "P2", "P3"))) * "</part-list>" * join(parts) * "</score-partwise>"

function measure(work)
  work()
  samples = NamedTuple[]
  for _ in 1:5
    GC.gc()
    result = @timed work()
    push!(samples, (time=result.time, bytes=result.bytes))
  end
  minimum(s.time for s in samples), minimum(s.bytes for s in samples)
end

mktemp() do path, io
  write(io, xml)
  close(io)
  streams, measure_starts, _ = SEED.parse_musicxml(path)
  analysis = MA.parse_musicxml_text(xml)
  @assert sum(length, values(streams)) == length(analysis.notes) == 144
  ticks = first.(measure_starts)
  queries = repeat([event.start_tick for events in values(streams) for event in events], 20)
  old_lookup(query) = begin
    index = searchsortedlast([item[1] for item in measure_starts], query)
    index <= 0 ? (measure_starts[1][2], query - measure_starts[1][1]) :
      (measure_starts[index][2], query - measure_starts[index][1])
  end
  @assert all(old_lookup(query) == SEED.measure_at(measure_starts, query, ticks) for query in queries)

  println("musicxml_seed_fixture,sha=$sha,parts=3,measures=12,notes=144,lookups=$(length(queries))")
  for (label, work) in (
    ("parse_seed", () -> SEED.parse_musicxml(path)),
    ("parse_analysis", () -> MA.parse_musicxml_text(xml)),
    ("lookup_original", () -> [old_lookup(query) for query in queries]),
    ("lookup_indexed", () -> [SEED.measure_at(measure_starts, query, ticks) for query in queries]),
  )
    seconds, bytes = measure(work)
    println("musicxml_seed,mode=$label,elapsed_s=$seconds,allocated_bytes=$bytes")
  end
end
