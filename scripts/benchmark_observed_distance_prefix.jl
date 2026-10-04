ENV["GENIE_ENV"] = "test"
using Genie
Genie.loadapp()

const PCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
sha = get(ENV, "GITHUB_SHA", "local")

manager = PCM.Manager(
  Vector{Float64}[Float64[0.0], Float64[1.0]],
  0.02,
  2,
  false;
  range_min=0.0,
  range_max=1.0,
  max_set_size=1,
  recency=0.0,
  enable_occurrence_intervals=false,
)

function fixture(steps::Int)
  left = Vector{Float64}[
    Float64[0.15 + 0.01 * mod(index, 7)]
    for index in 1:steps
  ]
  right = Vector{Float64}[
    Float64[0.85 - 0.01 * mod(index, 5)]
    for index in 1:steps
  ]
  return left, right
end

function full_prefix_totals(left, right)
  total = 0.0
  rows = 0
  for window_size in 2:length(left)
    squared = 0.0
    @inbounds for index in 1:window_size
      distance = PCM.min_avg_distance(manager, left[index], right[index])
      squared += distance * distance
      rows += 1
    end
    total += sqrt(squared)
  end
  return total, rows
end

function incremental_prefix_totals(left, right)
  total = 0.0
  squared = 0.0
  rows = 0
  @inbounds for window_size in 1:length(left)
    distance = PCM.min_avg_distance(manager, left[window_size], right[window_size])
    squared += distance * distance
    rows += 1
    window_size >= 2 && (total += sqrt(squared))
  end
  return total, rows
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

println("observed_distance_prefix_fixture,sha=$sha,mode=exact")
for steps in (256, 1024, 2352)
  left, right = fixture(steps)
  full_value, full_rows = full_prefix_totals(left, right)
  incremental_value, incremental_rows = incremental_prefix_totals(left, right)
  @assert full_value == incremental_value

  full_elapsed, full_bytes = measure(() -> full_prefix_totals(left, right))
  incremental_elapsed, incremental_bytes =
    measure(() -> incremental_prefix_totals(left, right))

  println(
    "observed_distance_prefix,steps=$steps,mode=full_scan," *
    "rows=$full_rows,elapsed_s=$full_elapsed,allocated_bytes=$full_bytes",
  )
  println(
    "observed_distance_prefix,steps=$steps,mode=incremental," *
    "rows=$incremental_rows,elapsed_s=$incremental_elapsed," *
    "allocated_bytes=$incremental_bytes",
  )
end
