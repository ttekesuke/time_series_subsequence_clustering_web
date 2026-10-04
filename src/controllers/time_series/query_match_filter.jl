function _match_score(matches)::Vector{Int}
  isempty(matches) && return Int[]
  counts = Dict{Int,Int}()
  for m in matches
    ws = _parse_int(get(m, "windowSize", 0))
    counts[ws] = get(counts, ws, 0) + 1
  end
  # 降順に並べたwindowSizeごとのcount列を返す（辞書式比較でソート可能）
  sorted_keys = sort(collect(keys(counts)); rev=true)
  return [counts[k] for k in sorted_keys]
end

function _match_contains(outer, inner)::Bool
  oq = _parse_int(get(outer, "q_start", 0))
  od = _parse_int(get(outer, "start", 0))
  ow = _parse_int(get(outer, "windowSize", 0))
  iq = _parse_int(get(inner, "q_start", 0))
  id = _parse_int(get(inner, "start", 0))
  iw = _parse_int(get(inner, "windowSize", 0))

  return oq <= iq &&
         od <= id &&
         iq + iw <= oq + ow &&
         id + iw <= od + ow &&
         (ow > iw || oq != iq || od != id)
end

struct _QueryMatchSpan
  q_start::Int
  db_start::Int
  window_size::Int
end

Base.:(==)(a::_QueryMatchSpan, b::_QueryMatchSpan) =
  a.q_start == b.q_start &&
  a.db_start == b.db_start &&
  a.window_size == b.window_size
Base.isequal(a::_QueryMatchSpan, b::_QueryMatchSpan) = a == b
Base.hash(span::_QueryMatchSpan, h::UInt) =
  hash((span.q_start, span.db_start, span.window_size), h)

@inline _query_match_q_end(span::_QueryMatchSpan) =
  span.q_start + span.window_size
@inline _query_match_db_end(span::_QueryMatchSpan) =
  span.db_start + span.window_size
@inline _fenwick_step(index::Int) = index & -index

function _query_match_span(match)::_QueryMatchSpan
  return _QueryMatchSpan(
    _parse_int(get(match, "q_start", 0)),
    _parse_int(get(match, "start", 0)),
    _parse_int(get(match, "windowSize", 0)),
  )
end

function _query_match_dict(span::_QueryMatchSpan)::Dict{String,Any}
  return Dict{String,Any}(
    "q_start" => span.q_start,
    "start" => span.db_start,
    "windowSize" => span.window_size,
  )
end

mutable struct _MatchDominanceIndex
  db_starts::Vector{Int}
  q_end_coords::Vector{Vector{Int}}
  max_db_ends::Vector{Vector{Int}}
end

function _build_match_dominance_index(
  spans::Vector{_QueryMatchSpan},
)::_MatchDominanceIndex
  db_starts = sort!(unique([span.db_start for span in spans]))
  q_end_coords = [Int[] for _ in eachindex(db_starts)]

  for span in spans
    outer = searchsortedfirst(db_starts, span.db_start)
    q_end = _query_match_q_end(span)
    while outer <= length(db_starts)
      push!(q_end_coords[outer], q_end)
      outer += _fenwick_step(outer)
    end
  end

  for coords in q_end_coords
    sort!(coords)
    unique!(coords)
  end
  max_db_ends = [fill(typemin(Int), length(coords)) for coords in q_end_coords]
  return _MatchDominanceIndex(db_starts, q_end_coords, max_db_ends)
end

function _match_dominance_update!(
  index::_MatchDominanceIndex,
  span::_QueryMatchSpan,
)::Nothing
  outer = searchsortedfirst(index.db_starts, span.db_start)
  q_end = _query_match_q_end(span)
  db_end = _query_match_db_end(span)

  while outer <= length(index.db_starts)
    coords = index.q_end_coords[outer]
    position = searchsortedfirst(coords, q_end)
    inner = length(coords) - position + 1
    tree = index.max_db_ends[outer]
    while inner <= length(tree)
      tree[inner] = max(tree[inner], db_end)
      inner += _fenwick_step(inner)
    end
    outer += _fenwick_step(outer)
  end
  return nothing
end

function _match_is_dominated(
  index::_MatchDominanceIndex,
  span::_QueryMatchSpan,
)::Bool
  outer = searchsortedlast(index.db_starts, span.db_start)
  required_q_end = _query_match_q_end(span)
  required_db_end = _query_match_db_end(span)

  while outer > 0
    coords = index.q_end_coords[outer]
    first_valid = searchsortedfirst(coords, required_q_end)
    if first_valid <= length(coords)
      inner = length(coords) - first_valid + 1
      tree = index.max_db_ends[outer]
      while inner > 0
        tree[inner] >= required_db_end && return true
        inner -= _fenwick_step(inner)
      end
    end
    outer -= _fenwick_step(outer)
  end
  return false
end

function _filter_match_spans(
  spans::Vector{_QueryMatchSpan},
)::Vector{_QueryMatchSpan}
  isempty(spans) && return _QueryMatchSpan[]

  # q_start is the first containment coordinate. For equal q_start, a
  # possible container must have at least as large a window, so visit larger
  # windows first. The dominance index then answers the remaining three exact
  # inequalities: db_start <=, q_end >=, db_end >=.
  ordered = sort(copy(spans); by=span -> (
    span.q_start,
    -span.window_size,
    span.db_start,
  ))
  index = _build_match_dominance_index(ordered)
  kept = _QueryMatchSpan[]

  for span in ordered
    _match_is_dominated(index, span) || push!(kept, span)
    _match_dominance_update!(index, span)
  end

  return sort!(kept; by=span -> (
    span.q_start,
    span.db_start,
    -span.window_size,
  ))
end

function _filter_contained_matches(matches)::Vector{Any}
  isempty(matches) && return Any[]

  # Preserve the first payload for compatibility, while deduplicating before
  # the dominance pass. The returned order remains identical to the legacy
  # implementation.
  first_payload = Dict{_QueryMatchSpan,Any}()
  for match in matches
    span = _query_match_span(match)
    haskey(first_payload, span) || (first_payload[span] = match)
  end

  kept = _filter_match_spans(collect(keys(first_payload)))
  return Any[first_payload[span] for span in kept]
end

function _matches_from_cross_entries(cross_entries)::Vector{Any}
  spans = Set{_QueryMatchSpan}()
  for entry in cross_entries
    window_size = _parse_int(get(entry, "window_size", 0))
    q_indices = get(entry, "q_indices", Int[])
    db_indices = get(entry, "db_indices", Int[])
    for q_start in q_indices
      for db_start in db_indices
        push!(spans, _QueryMatchSpan(
          _parse_int(q_start),
          _parse_int(db_start),
          window_size,
        ))
      end
    end
  end

  return Any[
    _query_match_dict(span)
    for span in _filter_match_spans(collect(spans))
  ]
end
