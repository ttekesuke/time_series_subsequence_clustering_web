using Test
using Random

const _query_tc = Main.TimeseriesClusteringAPI.TimeSeriesController

_query_match(q, d, w) = Dict{String,Any}(
  "q_start" => q,
  "start" => d,
  "windowSize" => w,
)

_query_match_key(match) = (
  Int(match["q_start"]),
  Int(match["start"]),
  Int(match["windowSize"]),
)

function _legacy_filter_contained_matches(matches)
  deduped = Any[]
  seen = Set{Tuple{Int,Int,Int}}()
  for match in matches
    key = _query_match_key(match)
    if !(key in seen)
      push!(seen, key)
      push!(deduped, match)
    end
  end

  kept = Any[]
  for (index, match) in enumerate(deduped)
    contained = false
    for (other_index, other) in enumerate(deduped)
      index == other_index && continue
      if _query_tc._match_contains(other, match)
        contained = true
        break
      end
    end
    contained || push!(kept, match)
  end

  return sort!(kept; by=match -> (
    Int(match["q_start"]),
    Int(match["start"]),
    -Int(match["windowSize"]),
  ))
end

function _assert_query_filter_equivalent(matches)
  expected = _legacy_filter_contained_matches(matches)
  actual = _query_tc._filter_contained_matches(matches)
  @test _query_match_key.(actual) == _query_match_key.(expected)
  @test _query_tc._match_score(actual) == _query_tc._match_score(expected)
end

@testset "query match dominance preserves exact legacy containment" begin
  cases = [
    Any[
      _query_match(0, 0, 4),
      _query_match(1, 1, 2),
    ],
    Any[
      _query_match(0, 0, 4),
      _query_match(0, 0, 2),
      _query_match(0, 0, 2),
    ],
    Any[
      _query_match(0, 5, 4),
      _query_match(1, 4, 2),
      _query_match(1, 6, 2),
    ],
    Any[
      _query_match(0, 0, 4),
      _query_match(3, 3, 4),
      _query_match(2, 0, 2),
    ],
    Any[
      _query_match(0, 0, 3),
      _query_match(0, 1, 3),
      _query_match(1, 0, 3),
      _query_match(1, 1, 2),
    ],
    Any[
      _query_match(0, 0, 8),
      _query_match(1, 1, 6),
      _query_match(2, 2, 4),
      _query_match(3, 3, 2),
      _query_match(8, 8, 3),
    ],
  ]

  for matches in cases
    _assert_query_filter_equivalent(matches)
  end
end

@testset "query match dominance matches quadratic oracle on randomized sets" begin
  Random.seed!(0x31D0)
  for _ in 1:30
    matches = Any[]
    for _ in 1:120
      q_start = rand(0:24)
      db_start = rand(0:24)
      window_size = rand(1:10)
      push!(matches, _query_match(q_start, db_start, window_size))
      rand() < 0.15 && push!(matches,
        _query_match(q_start, db_start, window_size))
    end
    _assert_query_filter_equivalent(matches)
  end
end

@testset "cross-entry products dedupe before payload materialization" begin
  cross_entries = Any[
    Dict{String,Any}(
      "window_size" => 6,
      "cluster_id" => 10,
      "q_indices" => [0, 4],
      "db_indices" => [0, 4],
    ),
    Dict{String,Any}(
      "window_size" => 6,
      "cluster_id" => 11,
      "q_indices" => [0, 4],
      "db_indices" => [0, 4],
    ),
    Dict{String,Any}(
      "window_size" => 2,
      "cluster_id" => 12,
      "q_indices" => [1, 5],
      "db_indices" => [1, 5],
    ),
  ]

  materialized = Any[]
  for entry in cross_entries
    for q_start in entry["q_indices"], db_start in entry["db_indices"]
      push!(materialized, _query_match(
        q_start, db_start, entry["window_size"]))
    end
  end

  expected = _legacy_filter_contained_matches(materialized)
  actual = _query_tc._matches_from_cross_entries(cross_entries)
  @test _query_match_key.(actual) == _query_match_key.(expected)
  @test _query_tc._match_score(actual) == _query_tc._match_score(expected)

  unique_products = Set(_query_match_key(match) for match in materialized)
  @test length(unique_products) < length(materialized)
end
