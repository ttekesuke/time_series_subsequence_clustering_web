ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const TC = Main.TimeseriesClusteringAPI.TimeSeriesController
sha = get(ENV, "GITHUB_SHA", "local")

match(q, d, w) = Dict{String,Any}(
  "q_start" => q,
  "start" => d,
  "windowSize" => w,
)

function legacy_filter(matches)
  deduped = Any[]
  seen = Set{Tuple{Int,Int,Int}}()
  for m in matches
    key = (
      Int(m["q_start"]),
      Int(m["start"]),
      Int(m["windowSize"]),
    )
    if !(key in seen)
      push!(seen, key)
      push!(deduped, m)
    end
  end

  kept = Any[]
  for (i, m) in enumerate(deduped)
    contained = false
    for (j, other) in enumerate(deduped)
      i == j && continue
      if TC._match_contains(other, m)
        contained = true
        break
      end
    end
    contained || push!(kept, m)
  end
  return sort!(kept; by=m -> (
    Int(m["q_start"]),
    Int(m["start"]),
    -Int(m["windowSize"]),
  ))
end

function fixture(count)
  matches = Any[]
  for i in 0:(count - 1)
    q_start = mod(i * 17, count + 31)
    db_start = mod(i * 29, count + 47)
    window_size = 2 + mod(i * 7, 13)
    push!(matches, match(q_start, db_start, window_size))
    i % 5 == 0 && push!(matches,
      match(q_start, db_start, window_size))
  end
  return matches
end

function normalize(matches)
  return [
    (Int(m["q_start"]), Int(m["start"]), Int(m["windowSize"]))
    for m in matches
  ]
end

function measure(work)
  work()
  samples = NamedTuple[]
  for _ in 1:3
    GC.gc()
    result = @timed work()
    push!(samples, (time=result.time, bytes=result.bytes))
  end
  return minimum(sample.time for sample in samples),
    minimum(sample.bytes for sample in samples)
end

println("query_match_filter_fixture,sha=$sha")
for count in (256, 768, 1536)
  matches = fixture(count)
  expected = legacy_filter(matches)
  actual = TC._filter_contained_matches(matches)
  @assert normalize(actual) == normalize(expected)

  legacy_elapsed, legacy_bytes = measure(() -> legacy_filter(matches))
  indexed_elapsed, indexed_bytes =
    measure(() -> TC._filter_contained_matches(matches))

  println(
    "query_match_filter,count=$count,materialized=$(length(matches))," *
    "kept=$(length(actual)),mode=quadratic,elapsed_s=$legacy_elapsed," *
    "allocated_bytes=$legacy_bytes",
  )
  println(
    "query_match_filter,count=$count,materialized=$(length(matches))," *
    "kept=$(length(actual)),mode=indexed,elapsed_s=$indexed_elapsed," *
    "allocated_bytes=$indexed_bytes",
  )
end
