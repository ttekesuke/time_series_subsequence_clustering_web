module TimeSeriesController

using Genie.Requests
using Dates
using HTTP
using JSON
using Base64
using UUIDs


# The manager is defined in the parent module (TimeseriesClusteringAPI)
# after include("timeseries/time_series_cluster_manager.jl").
import ..TimeSeriesClusterManager
import ..process_data!
import ..clusters_to_timeline
import ..clusters_to_dict
import ..transform_clusters
import ..simulate_add_and_calculate
import ..add_data_point_permanently!
import ..update_caches_permanently!
import ..euclidean_distance
import ..calculate_cluster_complexity

# polyphonic modules (Stage5+)
import ..PolyphonicConfig
import ..PolyphonicClusterManager
import ..MultiStreamManager
import ..DissonanceStmManager

# ------------------------------------------------------------
# Utilities
# ------------------------------------------------------------
function _to_string_dict(raw)
  raw === nothing && return Dict{String,Any}()
  d = Dict{String,Any}()
  try
    for (k,v) in pairs(raw)
      d[string(k)] = v
    end
    return d
  catch
    return Dict{String,Any}()
  end
end

function _payload()
  # Genie.Requests.jsonpayload() returns Dict-like object.
  # We normalize keys to String for easier access.
  raw = Requests.jsonpayload()
  if raw === nothing || isempty(raw)
    raw = Requests.params()
  end
  return _to_string_dict(raw)
end

function _subhash(d::Dict{String,Any}, key::String)
  return _to_string_dict(get(d, key, nothing))
end

_parse_float(x) = x isa Real ? float(x) : (x === nothing ? 0.0 : parse(Float64, string(x)))
_parse_int(x) = x isa Integer ? Int(x) : (x === nothing ? 0 : parse(Int, string(x)))

function _parse_csv_ints(s::AbstractString)
  isempty(strip(s)) && return Int[]
  return [parse(Int, strip(x)) for x in split(s, ",") if !isempty(strip(x))]
end

function _parse_csv_floats(s::AbstractString)
  isempty(strip(s)) && return Float64[]
  return [parse(Float64, strip(x)) for x in split(s, ",") if !isempty(strip(x))]
end

# Rails-like normalize (0..1 with weighting)
function normalize_scores(raw_values::Vector{Float64}, is_complex_when_larger::Bool)
  if isempty(raw_values)
    return (Float64[], 0.0)
  end
  min_val = minimum(raw_values)
  max_val = maximum(raw_values)
  unique_count = length(unique(raw_values))
  weight = unique_count <= 1 ? 0.0 : (unique_count == 2 ? 0.2 : 1.0)

  normalized =
    if max_val == min_val
      fill(0.5, length(raw_values))
    else
      [(v - min_val) / (max_val - min_val) for v in raw_values]
    end

  scores = Float64[]
  for v in normalized
    val = is_complex_when_larger ? v : (1.0 - v)
    push!(scores, val * weight)
  end
  return (scores, weight)
end

function find_complex_candidate_by_value(criteria::Vector{Dict{String,Any}}, target_val::Float64)
  candidates_score = Dict{Int,Float64}()
  total_weight = 0.0

  for criterion in criteria
    data = criterion["data"]::Vector{Tuple{Float64,Int}}
    raw_values = [d[1] for d in data]
    scores, weight = normalize_scores(raw_values, criterion["is_complex_when_larger"])
    for (i, item) in enumerate(data)
      idx = item[2]
      candidates_score[idx] = get(candidates_score, idx, 0.0) + scores[i]
    end
    total_weight += weight
  end

  if total_weight > 0.0
    for (k,v) in candidates_score
      candidates_score[k] = v / total_weight
    end
  end

  best_index = 0
  min_diff = Inf
  for (idx, score) in candidates_score
    diff = abs(score - target_val)
    if diff < min_diff
      min_diff = diff
      best_index = idx
    end
  end
  return best_index
end

# NaN prevention for count<=1
function create_quadratic_integer_array(start_val::Real, end_val::Real, count::Int)
  count <= 1 && return [ceil(Int, start_val) + 1]
  result = Int[]
  for i in 0:(count-1)
    t = float(i) / float(count-1)
    curve = t^10
    value = start_val + (end_val - start_val) * curve
    if start_val < end_val
      push!(result, ceil(Int, value) + 1)
    else
      push!(result, floor(Int, value) + 1)
    end
  end
  return result
end

# Initialize cache values (we compute "full" caches for stability)
function initial_calc_values!(manager, clusters_each_window_size, max_master::Real, min_master::Real, len::Int)
  qarr = create_quadratic_integer_array(0.0, (float(max_master) - float(min_master)) * float(len), len)

  for (window_size, same_ws) in clusters_each_window_size
    all_ids = collect(keys(same_ws))

    # distance cache
    cache = get!(manager.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    for i in 1:length(all_ids)
      for j in (i+1):length(all_ids)
        cid1 = all_ids[i]
        cid2 = all_ids[j]
        as1 = same_ws[cid1]["as"]
        as2 = same_ws[cid2]["as"]
        key = cid1 < cid2 ? (cid1,cid2) : (cid2,cid1)

        # ✅ manager.euclidean_distance ではなく関数呼び出し
        cache[key] = euclidean_distance(as1, as2)
      end
    end

    # quantity & complexity cache
    q_cache = get!(manager.cluster_quantity_cache, window_size, Dict{Int,Float64}())
    c_cache = get!(manager.cluster_complexity_cache, window_size, Dict{Int,Float64}())
    for (cid, cluster) in same_ws
      si = cluster["si"]
      length(si) > 1 || continue
      q = 1.0
      for s in si
        idx = s[1] + 1
        if 1 <= idx <= length(qarr)
          q *= qarr[idx]
        end
      end
      q_cache[cid] = q

      # ✅ manager.calculate_cluster_complexity ではなく関数呼び出し
      c_cache[cid] = calculate_cluster_complexity(cluster)
    end
  end

  return nothing
end


# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

"""
POST /api/web/time_series/analyse
Rails compatible payload:
  { analyse: { time_series: [...], merge_threshold_ratio: 0.3, job_id: "..." } }

Returns:
  clusteredSubsequences, timeSeries, clusters, processingTime
"""
function analyse()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "analyse")

  # time_series: array of numbers
  raw_series = get(p, "time_series", Any[])

  data = Int[]
  for v in raw_series
    try
      push!(data, _parse_int(v))
    catch
      # ignore non-parsable
    end
  end

  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", 0.3))
  min_window_size = 2
  calculate_distance_when_added_subsequence_to_cluster = true

  manager = TimeSeriesClusterManager(
    copy(data),
    merge_threshold_ratio,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster;
    scale_mode = :global_halves
  )

  process_data!(manager)

  timeline = clusters_to_timeline(manager.clusters, min_window_size)
  processing_time_s = round(time() - t0; digits=2)
  println("analyse processing time (s): ", processing_time_s)

  return Dict(
    "clusteredSubsequences" => timeline,
    "timeSeries" => data,
    "clusters" => clusters_to_dict(manager.clusters),
    "processingTime" => processing_time_s
  )
end


"""
POST /api/web/time_series/generate
Rails compatible payload:
  { generate: {
      first_elements: "0,1,2",
      complexity_transition: "0.1,0.2,...",
      merge_threshold_ratio: 0.3,
      range_min: 0,
      range_max: 12,
      selected_use_musical_feature: "...",
      job_id: "..."
    }
  }

Returns:
  clusteredSubsequences, timeSeries, complexityTransition, clusters, processingTime
"""
function generate()

  t0 = time()

  payload = _payload()
  p = _subhash(payload, "generate")

  first_elements = _parse_csv_ints(string(get(p, "first_elements", "")))
  complexity_targets = _parse_csv_floats(string(get(p, "complexity_transition", "")))
  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", 0.3))

  candidate_min_master = _parse_int(get(p, "range_min", 0))
  candidate_max_master = _parse_int(get(p, "range_max", 24))

  min_window_size = 2
  calculate_distance_when_added_subsequence_to_cluster = false

  manager = TimeSeriesClusterManager(
    copy(first_elements),
    merge_threshold_ratio,
    min_window_size,
    calculate_distance_when_added_subsequence_to_cluster;
    scale_mode = :range_fixed,
    range_min = candidate_min_master,
    range_max = candidate_max_master
  )


  process_data!(manager)

  clusters_each = transform_clusters(manager.clusters, min_window_size)
  initial_calc_values!(manager, clusters_each, candidate_max_master, candidate_min_master, length(first_elements))

  # reset updated ids (Rails does this before candidate loop)
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

  results = copy(first_elements)

  for (rank_index, target_val) in enumerate(complexity_targets)
    candidates = collect(candidate_min_master:candidate_max_master)

    indexed_metrics = Vector{Dict{String,Any}}()
    current_len = length(results) + 1

    qarr = create_quadratic_integer_array(
      0.0,
      (candidate_max_master - candidate_min_master) * current_len,
      current_len
    )

    for (idx, candidate) in enumerate(candidates)
      avg_dist, quantity, complexity = simulate_add_and_calculate(manager, candidate, qarr)
      push!(indexed_metrics, Dict(
        "index" => idx-1,
        "dist" => avg_dist,
        "quantity" => quantity,
        "complexity" => complexity
      ))
    end

    criteria = Vector{Dict{String,Any}}()
    push!(criteria, Dict(
      "is_complex_when_larger" => true,
      "data" => [(float(m["dist"]), Int(m["index"])) for m in indexed_metrics]
    ))
    push!(criteria, Dict(
      "is_complex_when_larger" => false,
      "data" => [(float(m["quantity"]), Int(m["index"])) for m in indexed_metrics]
    ))
    push!(criteria, Dict(
      "is_complex_when_larger" => true,
      "data" => [(float(m["complexity"]), Int(m["index"])) for m in indexed_metrics]
    ))

    result_index = find_complex_candidate_by_value(criteria, float(target_val))
    # result_index is 0-based idx into candidates
    result_value = candidates[result_index + 1]

    push!(results, result_value)
    add_data_point_permanently!(manager, result_value)
    update_caches_permanently!(manager, qarr)
  end

  timeline = clusters_to_timeline(manager.clusters, min_window_size)
  processing_time_s = round(time() - t0; digits=2)

  # align to StreamsRoll: first_elements are missing, then targets
  complexity_transition_stream = Any[missing for _ in first_elements]
  append!(complexity_transition_stream, complexity_targets)

  return Dict(
    "clusteredSubsequences" => timeline,
    "timeSeries" => results,
    "complexityTransition" => complexity_transition_stream,
    "clusters" => clusters_to_dict(manager.clusters),
    "processingTime" => processing_time_s
  )
end

"""
POST /api/web/time_series/generate_polyphonic

Rails compatible payload (nested):
  { generate_polyphonic: { job_id, stream_counts, initial_context, ... } }

Stage5 scope:
- Parse payload and normalize `initial_context` (step-major) to Rails-compatible structure.
- Initialize polyphonic managers (global/stream) from the initial history.

NOTE:
The full generation loop (global/stream/conc scoring, STM roughness + shift search)
is implemented in later stages to keep changes isolated to one file per delivery.
"""
function array_param(raw::Dict{String,Any}, key::String, idx0::Int)
  raw === nothing && return nothing
  val = get(raw, key, nothing)
  val === nothing && return nothing

  if val isa AbstractVector
    # idx0 is 0-based (Rails-compatible). Clamp to last.
    i = idx0 + 1
    if i < 1
      return val[1]
    elseif i > length(val)
      return val[end]
    else
      return val[i]
    end
  else
    return val
  end
end

function generate_centered_targets(n::Int, center::Real, spread::Real)::Vector{Float64}
  n = max(n, 1)
  if n == 1
    return [clamp(float(center), 0.0, 1.0)]
  end

  c = clamp(float(center), 0.0, 1.0)
  s = clamp(float(spread), 0.0, 1.0)

  halfw = s / 2.0
  startv = clamp(c - halfw, 0.0, 1.0)
  endv   = clamp(c + halfw, 0.0, 1.0)

  out = Vector{Float64}(undef, n)
  for i in 1:n
    t = (i - 1) / float(n - 1)
    out[i] = clamp(startv + (endv - startv) * t, 0.0, 1.0)
  end
  return out
end

"""Rails-like repeated_combination(values, n) returning all non-decreasing length-n vectors."""
function repeated_combinations(values::Vector{T}, n::Int) where {T}
  n <= 0 && return Vector{Vector{T}}()
  n == 1 && return [[v] for v in values]

  vals = sort(values)
  m = length(vals)
  m == 0 && return Vector{Vector{T}}()

  idxs = fill(1, n)
  out = Vector{Vector{T}}()

  while true
    push!(out, [vals[i] for i in idxs])

    pos = n
    while pos >= 1 && idxs[pos] == m
      pos -= 1
    end
    pos < 1 && break

    next_i = idxs[pos] + 1
    for k in pos:n
      idxs[k] = next_i
    end
  end

  return out
end

struct CandidateMetric
  ordered_cand::Vector{Float64}   # per-stream scalar values (already ordered)
  global_dist::Float64
  global_qty::Float64
  global_comp::Float64
  stream_dists::Vector{Float64}   # Hungarian assignment distance (0..1)  ※ジャンプ量
  stream_comps::Vector{Float64}   # Cluster-derived complexity01 (0..1)  ★これを追加
  discordance::Float64
end

struct NoteShiftMetric
  shift::Int
  global_dist::Float64
  global_qty::Float64
  global_comp::Float64
  stream_dists01::Vector{Float64}
  stream_complexities_raw::Vector{Float64}
  discordance::Float64
  chords_for_streams::Vector{Vector{Int}}
  global_value::Vector{Int}
end

# Note shift metric (Rails generate_polyphonic note block)

function select_best_polyphonic_candidate_unified_with_cost(
  metrics::Vector{CandidateMetric},
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64;
  stream_dist_max::Float64 = 1.0
)
  best_i = 1
  min_cost = Inf

  g_dists, _ = normalize_scores([m.global_dist for m in metrics], true)
  g_qtys,  _ = normalize_scores([m.global_qty  for m in metrics], false)
  g_comps, _ = normalize_scores([m.global_comp for m in metrics], true)

  # keep for backward compatibility (only used when stream_comps is empty)
  sdm = stream_dist_max
  sdm = (sdm <= 0.0) ? 1.0 : sdm

  for (i, m) in enumerate(metrics)
    current_global = (g_dists[i] + g_qtys[i] + g_comps[i]) / 3.0
    cost_a = abs(current_global - global_target)

    # --- FIX: stream cost should be based on cluster-derived complexity01, not dist jump ---
    cost_b = 0.0
    if !isempty(stream_targets)
      # Prefer stream_comps (complexity01). Fallback to stream_dists if comps not available.
      if !isempty(m.stream_comps)
        n = min(length(stream_targets), length(m.stream_comps))
        if n > 0
          for s_idx in 1:n
            comp01 = clamp(m.stream_comps[s_idx], 0.0, 1.0)
            cost_b += abs(comp01 - stream_targets[s_idx])
          end
          cost_b /= float(n)
        end
      else
        # fallback (legacy): dist-only
        n = min(length(stream_targets), length(m.stream_dists))
        if n > 0
          for s_idx in 1:n
            raw_dist = m.stream_dists[s_idx]
            dist01 = clamp(raw_dist / sdm, 0.0, 1.0)
            cost_b += abs(dist01 - stream_targets[s_idx])
          end
          cost_b /= float(n)
        end
      end
    end

    cost_c = (concordance_weight < 0.0) ? 0.0 : (m.discordance * concordance_weight)

    total = cost_a + cost_b + cost_c
    if total < min_cost
      min_cost = total
      best_i = i
    end
  end

  return best_i, min_cost
end


function select_best_chord_for_dimension_with_cost(
  mgrs::Dict{Symbol,Any},
  candidates::Vector{<:AbstractVector{<:Real}},
  stream_costs,
  q_array::Vector{Int},
  global_target::Float64,
  stream_targets::Vector{Float64},
  concordance_weight::Float64,
  n::Int,
  range_vec::Vector{<:Real};
  absolute_bases::Union{Nothing,Vector{Int}} = nothing,
  active_note_counts::Union{Nothing,Vector{Int}} = nothing,
  active_total_notes::Union{Nothing,Int} = nothing,
  max_simultaneous_notes::Int = last(PolyphonicConfig.CHORD_SIZE_RANGE)
)
  max_simul = max(max_simultaneous_notes, 1)

  total_notes = active_total_notes === nothing ? 0 : Int(active_total_notes)
  density01 = (n <= 0) ? 0.0 : clamp(total_notes / float(max_simul * n), 0.0, 1.0)

  assignment_distance_weight   = density01
  assignment_complexity_weight = 1.0 - density01

  vmin = float(minimum(range_vec))
  vmax = float(maximum(range_vec))
  range_width = abs(vmax - vmin)
  range_width = range_width <= 0.0 ? 1.0 : range_width

  metrics = CandidateMetric[]

  for cand_set in candidates
    ordered_polysets, stream_metric = MultiStreamManager.resolve_mapping_and_score(
      mgrs[:stream],
      cand_set,
      stream_costs;
      absolute_bases=absolute_bases,
      active_note_counts=active_note_counts,
      active_total_notes=active_total_notes,
      distance_weight=assignment_distance_weight,
      complexity_weight=assignment_complexity_weight,
    )

    # ordered scalar values (for global manager)
    ordered_vals = Float64[]
    for v in ordered_polysets
      if v isa AbstractVector && !isempty(v)
        push!(ordered_vals, float(v[1]))
      else
        push!(ordered_vals, 0.0)
      end
    end

    g_dist, g_qty, g_comp = PolyphonicClusterManager.simulate_add_and_calculate(mgrs[:global], ordered_vals, q_array)

    disc = (maximum(ordered_vals) - minimum(ordered_vals)) / range_width

    stream_dists = Float64[]
    stream_comps = Float64[]
    if stream_metric !== nothing && hasproperty(stream_metric, :individual_scores)
      for sc in stream_metric.individual_scores
        push!(stream_dists, float(sc.dist))
        push!(stream_comps, float(sc.complexity01))
      end
    end
    if length(stream_dists) < n
      append!(stream_dists, fill(0.0, n - length(stream_dists)))
    end

    push!(metrics, CandidateMetric(ordered_vals, g_dist, g_qty, g_comp, stream_dists, stream_comps, disc))
  end

  isempty(metrics) && return (Float64[], Inf)

  # stream_dist_max selection (Rails behavior)
  max_raw_dist = 0.0
  for m in metrics
    for d in m.stream_dists
      max_raw_dist = max(max_raw_dist, d)
    end
  end

  base_stream_dist_max = absolute_bases === nothing ? range_width : float(PolyphonicConfig.abs_pitch_width())
  stream_dist_max_for_cost = max_raw_dist <= 1.000001 ? 1.0 : base_stream_dist_max

  best_i, best_cost = select_best_polyphonic_candidate_unified_with_cost(
    metrics,
    global_target,
    stream_targets,
    concordance_weight;
    stream_dist_max=stream_dist_max_for_cost
  )

  best = metrics[best_i]
  return best.ordered_cand, best_cost
end

function generate_polyphonic()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "generate_polyphonic")

  # --- basic params ---
  stream_counts_raw = get(p, "stream_counts", Any[])
  stream_counts = Int[]
  if stream_counts_raw isa AbstractVector
    for x in stream_counts_raw
      push!(stream_counts, _parse_int(x))
    end
  else
    push!(stream_counts, _parse_int(stream_counts_raw))
  end
  isempty(stream_counts) && push!(stream_counts, 1)

  strength_targets_raw = get(p, "stream_strength_target", Any[])
  strength_spreads_raw = get(p, "stream_strength_spread", Any[])

  strength_targets = Float64[]
  if strength_targets_raw isa AbstractVector
    for x in strength_targets_raw
      push!(strength_targets, _parse_float(x))
    end
  end

  strength_spreads = Float64[]
  if strength_spreads_raw isa AbstractVector
    for x in strength_spreads_raw
      push!(strength_spreads, _parse_float(x))
    end
  end

  # dissonance_target (for note / roughness)
  dissonance_targets_raw = get(p, "dissonance_target", nothing)
  dissonance_targets = Float64[]
  if dissonance_targets_raw isa AbstractVector
    for x in dissonance_targets_raw
      push!(dissonance_targets, _parse_float(x))
    end
  elseif dissonance_targets_raw !== nothing
    push!(dissonance_targets, _parse_float(dissonance_targets_raw))
  end

  # --- initial_context (step-major) ---
  ctx_raw = get(p, "initial_context", Any[])

  # JSON-facing structure is kept as Vector{Vector{Vector{Any}}}
  results = Vector{Vector{Vector{Any}}}()
  if ctx_raw isa AbstractVector
    for step in ctx_raw
      streams = Vector{Vector{Any}}()
      if step isa AbstractVector
        for st in step
          if st isa AbstractVector
            push!(streams, Any[st...])
          else
            push!(streams, Any[st])
          end
        end
      end
      push!(results, streams)
    end
  end

  if isempty(results)
    push!(results, [Any[4, [0], 1.0, 0.0, 0.0, 0.0]])
  end

  # Normalize NOTE field to Vector{Int} pitch classes (Rails exact: compact + mod, no sort/uniq)
  normalize_pcs = function (x)
    if x isa AbstractVector
      pcs = Int[]
      for v in x
        v === nothing && continue
        push!(pcs, (_parse_int(v) % 12))
      end
    else
      pcs = Int[(_parse_int(x) % 12)]
    end
    if isempty(pcs)
      pcs = Int[PolyphonicConfig.NOTE_RANGE.start]
    end
    return pcs
  end

  for step in results
    for st in step
      length(st) >= 2 || continue
      st[2] = normalize_pcs(st[2])
    end
  end

  # Fixed parameters (Rails exact)
  merge_threshold_ratio = 0.1
  min_window = 2
  max_simultaneous_notes = last(PolyphonicConfig.CHORD_SIZE_RANGE)

  # Indices in result vectors
  oct_idx  = 1
  note_idx = 2
  vol_idx  = 3
  bri_idx  = 4
  hrd_idx  = 5
  tex_idx  = 6

  # --- Build history matrices for scalar dims ---
  function matrix_for_idx(idx::Int)
    return [ [ (length(st) >= idx ? st[idx] : 0) for st in step ] for step in results ]
  end

  hist_oct = matrix_for_idx(oct_idx)
  hist_vol = matrix_for_idx(vol_idx)
  hist_bri = matrix_for_idx(bri_idx)
  hist_hrd = matrix_for_idx(hrd_idx)
  hist_tex = matrix_for_idx(tex_idx)

  # Ensure at least min_window + 1 rows (Rails padding)
  function pad_history!(mat, fallback_row)
    if length(mat) < (min_window + 1)
      last_row = !isempty(mat) ? deepcopy(mat[end]) : deepcopy(fallback_row)
      for _ in 1:((min_window + 1) - length(mat))
        push!(mat, deepcopy(last_row))
      end
    end
    return mat
  end

  first_streams = max(get(stream_counts, 1, 1), 1)

  pad_history!(hist_oct, [first(PolyphonicConfig.OCTAVE_RANGE) for _ in 1:first_streams])
  pad_history!(hist_vol, [PolyphonicConfig.FLOAT_STEPS[1] for _ in 1:first_streams])
  pad_history!(hist_bri, [PolyphonicConfig.FLOAT_STEPS[1] for _ in 1:first_streams])
  pad_history!(hist_hrd, [PolyphonicConfig.FLOAT_STEPS[1] for _ in 1:first_streams])
  pad_history!(hist_tex, [PolyphonicConfig.FLOAT_STEPS[1] for _ in 1:first_streams])

  # --- note histories (for placeholder output + lifecycle) ---
  note_stream_history = [ [ normalize_pcs(st[note_idx]) for st in step ] for step in results ]

  note_global_history = Vector{Vector{Int}}()
  for step in results
    pcs = Int[]
    for st in step
      append!(pcs, normalize_pcs(st[note_idx]))
    end
    pcs = unique(pcs)
    sort!(pcs)
    isempty(pcs) && (pcs = [PolyphonicConfig.NOTE_RANGE.start])
    push!(note_global_history, pcs)
  end

  pad_history!(note_stream_history, [ [PolyphonicConfig.NOTE_RANGE.start] for _ in 1:first_streams ])
  pad_history!(note_global_history, [PolyphonicConfig.NOTE_RANGE.start])

  # --- chord_size history (not generated yet; for lifecycle parity) ---
  chord_history = Vector{Vector{Int}}()
  for step in results
    row = Int[]
    for st in step
      pcs = normalize_pcs(st[note_idx])
      cs = clamp(length(pcs), 1, max_simultaneous_notes)
      push!(row, cs)
    end
    push!(chord_history, row)
  end
  pad_history!(chord_history, [1 for _ in 1:first_streams])

  # --- init managers dict (Rails-like structure) ---
  managers = Dict{String,Dict{Symbol,Any}}()

  function global_series_from_matrix(mat)
    series = Vector{Vector{Float64}}()
    for row in mat
      push!(series, Float64[float(x) for x in row])
    end
    return series
  end

  # octave
  s_oct = MultiStreamManager.Manager(hist_oct, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(PolyphonicConfig.OCTAVE_RANGE))
  g_oct = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_oct), merge_threshold_ratio, min_window; value_min=first(PolyphonicConfig.OCTAVE_RANGE), value_max=last(PolyphonicConfig.OCTAVE_RANGE))
  PolyphonicClusterManager.process_data!(g_oct)
  PolyphonicClusterManager.update_caches_permanently(g_oct, create_quadratic_integer_array(0, float(last(PolyphonicConfig.OCTAVE_RANGE)-first(PolyphonicConfig.OCTAVE_RANGE)) * length(g_oct.data), length(g_oct.data)))
  managers["octave"] = Dict(:global => g_oct, :stream => s_oct)

  # vol (track_presence)
  s_vol = MultiStreamManager.Manager(hist_vol, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS, track_presence=true)
  g_vol = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_vol), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_vol)
  PolyphonicClusterManager.update_caches_permanently(g_vol, create_quadratic_integer_array(0, 1.0 * length(g_vol.data), length(g_vol.data)))
  managers["vol"] = Dict(:global => g_vol, :stream => s_vol)

  # bri
  s_bri = MultiStreamManager.Manager(hist_bri, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS)
  g_bri = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_bri), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_bri)
  PolyphonicClusterManager.update_caches_permanently(g_bri, create_quadratic_integer_array(0, 1.0 * length(g_bri.data), length(g_bri.data)))
  managers["bri"] = Dict(:global => g_bri, :stream => s_bri)

  # hrd
  s_hrd = MultiStreamManager.Manager(hist_hrd, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS)
  g_hrd = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_hrd), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_hrd)
  PolyphonicClusterManager.update_caches_permanently(g_hrd, create_quadratic_integer_array(0, 1.0 * length(g_hrd.data), length(g_hrd.data)))
  managers["hrd"] = Dict(:global => g_hrd, :stream => s_hrd)

  # tex
  s_tex = MultiStreamManager.Manager(hist_tex, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS)
  g_tex = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_tex), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_tex)
  PolyphonicClusterManager.update_caches_permanently(g_tex, create_quadratic_integer_array(0, 1.0 * length(g_tex.data), length(g_tex.data)))
  managers["tex"] = Dict(:global => g_tex, :stream => s_tex)

  # note
  s_note = MultiStreamManager.Manager(note_stream_history, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(PolyphonicConfig.NOTE_RANGE), max_set_size=max_simultaneous_notes)
  g_note_series = Vector{Vector{Float64}}()
  for pcs in note_global_history
    push!(g_note_series, Float64[float(x) for x in pcs])
  end
  g_note = PolyphonicClusterManager.Manager(g_note_series, merge_threshold_ratio, min_window; value_min=float(first(PolyphonicConfig.NOTE_RANGE)), value_max=float(last(PolyphonicConfig.NOTE_RANGE)), max_set_size=max_simultaneous_notes)
  PolyphonicClusterManager.process_data!(g_note)
  PolyphonicClusterManager.update_caches_permanently(g_note, create_quadratic_integer_array(0, 11.0 * length(g_note.data), length(g_note.data)))
  managers["note"] = Dict(:global => g_note, :stream => s_note)

  # chord_size
  s_cs = MultiStreamManager.Manager(chord_history, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(PolyphonicConfig.CHORD_SIZE_RANGE))
  g_cs = PolyphonicClusterManager.Manager(global_series_from_matrix(chord_history), merge_threshold_ratio, min_window; value_min=float(first(PolyphonicConfig.CHORD_SIZE_RANGE)), value_max=float(last(PolyphonicConfig.CHORD_SIZE_RANGE)), max_set_size=max_simultaneous_notes)
  PolyphonicClusterManager.process_data!(g_cs)
  PolyphonicClusterManager.update_caches_permanently(g_cs, create_quadratic_integer_array(0, float(last(PolyphonicConfig.CHORD_SIZE_RANGE)-first(PolyphonicConfig.CHORD_SIZE_RANGE)) * length(g_cs.data), length(g_cs.data)))
  managers["chord_size"] = Dict(:global => g_cs, :stream => s_cs)

  # --- STM manager ---
  stm_mgr = DissonanceStmManager.Manager(
    memory_span=1.5,
    memory_weight=1.0,
    n_partials=8,
    amp_profile=0.88
  )

  step_duration = 0.25
  for (i, step) in enumerate(results)
    midi_notes = Int[]
    amps = Float64[]

    for st in step
      oct = _parse_int(st[oct_idx])
      pcs = normalize_pcs(st[note_idx])
      vol = clamp(_parse_float(st[vol_idx]), 0.0, 1.0)
      base_c = PolyphonicConfig.base_c_midi(oct)
      a_each = isempty(pcs) ? vol : (vol / float(length(pcs)))
      for pc in pcs
        push!(midi_notes, base_c + (pc % PolyphonicConfig.STEPS_PER_OCTAVE))
        push!(amps, a_each)
      end
    end

    onset = (i - 1) * step_duration
    DissonanceStmManager.commit!(stm_mgr, midi_notes, amps, onset)
  end

  # --- generation loop (Rails) ---
  steps_to_generate = length(stream_counts)
  base_step_index = length(results)

  for step_idx in 1:steps_to_generate
    desired_stream_count = max(stream_counts[step_idx], 1)

    st_target = step_idx <= length(strength_targets) ? strength_targets[step_idx] : 0.5
    st_spread = step_idx <= length(strength_spreads) ? strength_spreads[step_idx] : 0.0

    # lifecycle plan derived from vol
    vol_mgr = managers["vol"][:stream]
    plan = MultiStreamManager.build_stream_lifecycle_plan(vol_mgr, desired_stream_count; target=st_target, spread=st_spread)

    for (_k, mgrs) in managers
      MultiStreamManager.apply_stream_lifecycle_plan!(mgrs[:stream], plan)
    end

    # output step scaffold
    current_step_values = [ Any[0, Int[], 0.0, 0.0, 0.0, 0.0] for _ in 1:desired_stream_count ]
    step_decisions = Dict{String,Any}()

    idx0 = step_idx - 1

    # dimension order (Rails)
    dim_order = [
      ("vol",        PolyphonicConfig.FLOAT_STEPS,                 vol_idx, true),
      ("octave",     collect(PolyphonicConfig.OCTAVE_RANGE),       oct_idx, false),
      ("chord_size", collect(PolyphonicConfig.CHORD_SIZE_RANGE),   0,       false),
      ("bri",        PolyphonicConfig.FLOAT_STEPS,                 bri_idx, true),
      ("hrd",        PolyphonicConfig.FLOAT_STEPS,                 hrd_idx, true),
      ("tex",        PolyphonicConfig.FLOAT_STEPS,                 tex_idx, true),
    ]

    chord_sizes_for_step = fill(1, desired_stream_count)

    for (key, range_vec, out_idx, is_float_dim) in dim_order
      mgrs = managers[key]

      g_target = clamp(_parse_float(array_param(p, "$(key)_global", idx0)), 0.0, 1.0)
      s_center = clamp(_parse_float(array_param(p, "$(key)_center", idx0)), 0.0, 1.0)
      s_spread = clamp(_parse_float(array_param(p, "$(key)_spread", idx0)), 0.0, 1.0)
      conc_w  = _parse_float(array_param(p, "$(key)_conc", idx0))

      stream_targets = generate_centered_targets(desired_stream_count, s_center, s_spread)

      # q_array length depends on current global history length + 1
      gl = mgrs[:global]
      vmin = float(minimum(range_vec))
      vmax = float(maximum(range_vec))
      width = abs(vmax - vmin)
      width = width <= 0.0 ? 1.0 : width
      len_next = length(gl.data) + 1
      q_array = create_quadratic_integer_array(0, width * len_next, len_next)

      stream_costs = MultiStreamManager.precalculate_costs(mgrs[:stream], range_vec, q_array, desired_stream_count)
      candidates = repeated_combinations(range_vec, desired_stream_count)

      best_chord, _ = select_best_chord_for_dimension_with_cost(
        mgrs,
        candidates,
        stream_costs,
        q_array,
        g_target,
        stream_targets,
        conc_w,
        desired_stream_count,
        range_vec;
        max_simultaneous_notes=max_simultaneous_notes
      )

      # commit
      PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], Float64[float(x) for x in best_chord])
      PolyphonicClusterManager.update_caches_permanently(mgrs[:global], q_array)

      if key == "vol"
        MultiStreamManager.commit_state!(mgrs[:stream], best_chord, q_array; strength_params=(target=st_target, spread=st_spread))
      else
        MultiStreamManager.commit_state!(mgrs[:stream], best_chord, q_array)
      end
      MultiStreamManager.update_caches_permanently!(mgrs[:stream], q_array)

      # output
      if key == "chord_size"
        chord_sizes_for_step = [clamp(Int(trunc(best_chord[i])), 1, max_simultaneous_notes) for i in 1:desired_stream_count]
        step_decisions[key] = chord_sizes_for_step
      else
        step_decisions[key] = best_chord
        for s_i in 1:desired_stream_count
          if key == "octave"
            current_step_values[s_i][out_idx] = Int(trunc(best_chord[s_i]))
          else
            current_step_values[s_i][out_idx] = clamp(float(best_chord[s_i]), 0.0, 1.0)
          end
        end
      end
    end

    # =============================================================================
    # NOTE generation (方式1: A=roughnessで幅を作る → その候補内でB=複雑度コスト最小化)
    # =============================================================================

    note_mgrs = managers["note"]

    # targets
    note_global_target = clamp(_parse_float(array_param(p, "note_global", idx0)), 0.0, 1.0)
    note_stream_center = clamp(_parse_float(array_param(p, "note_center", idx0)), 0.0, 1.0)
    note_stream_spread = clamp(_parse_float(array_param(p, "note_spread", idx0)), 0.0, 1.0)
    note_conc_w        = _parse_float(array_param(p, "note_conc", idx0))

    note_stream_targets = generate_centered_targets(desired_stream_count, note_stream_center, note_stream_spread)

    # q_array
    note_range_vec = collect(PolyphonicConfig.NOTE_RANGE)
    note_vmin = float(minimum(note_range_vec))
    note_vmax = float(maximum(note_range_vec))
    note_width = abs(note_vmax - note_vmin)
    note_width = note_width <= 0.0 ? 1.0 : note_width
    note_len_next = length(note_mgrs[:global].data) + 1
    note_q_array = create_quadratic_integer_array(0, note_width * note_len_next, note_len_next)

    # chord_size / octave / vol already decided
    chord_sizes_int = Int[clamp(Int(chord_sizes_for_step[i]), 1, max_simultaneous_notes) for i in 1:desired_stream_count]

    oct_vals = get(step_decisions, "octave", Float64[])
    octaves_int = Int[clamp(Int(trunc(oct_vals[i])), first(PolyphonicConfig.OCTAVE_RANGE), last(PolyphonicConfig.OCTAVE_RANGE)) for i in 1:desired_stream_count]

    vol_vals = get(step_decisions, "vol", Float64[])
    vols_float = Float64[clamp(float(vol_vals[i]), 0.0, 1.0) for i in 1:desired_stream_count]

    # k = maximum chord size in this step
    k = maximum(chord_sizes_int)
    k = k < 1 ? 1 : k
    k = k > PolyphonicConfig.STEPS_PER_OCTAVE ? PolyphonicConfig.STEPS_PER_OCTAVE : k

    onset = float(base_step_index + idx0) * step_duration

    # dissonance target in 0..1
    dis_target_raw = array_param(p, "dissonance_target", idx0)
    target01 = dis_target_raw === nothing ? 0.5 : clamp(_parse_float(dis_target_raw), 0.0, 1.0)

    pitch_classes = Int[pc for pc in note_range_vec]

    function _combinations(vals::Vector{Int}, kk::Int)
      n = length(vals)
      if kk <= 0 || kk > n
        return Vector{Vector{Int}}()
      end
      idxs = collect(1:kk)
      out = Vector{Vector{Int}}()
      while true
        push!(out, [vals[i] for i in idxs])
        pos = kk
        while pos >= 1 && idxs[pos] == (n - kk + pos)
          pos -= 1
        end
        pos < 1 && break
        idxs[pos] += 1
        for j in (pos+1):kk
          idxs[j] = idxs[j-1] + 1
        end
      end
      return out
    end

    combos = _combinations(pitch_classes, k)

    # --- A1: combo roughnessを全列挙して評価 ---
    combo_roughness = Float64[]
    combo_candidates = Vector{Any}()
    sizehint!(combo_roughness, length(combos))
    sizehint!(combo_candidates, length(combos))

    for combo in combos
      ordered = DissonanceStmManager.order_pitch_classes_by_contribution(
        stm_mgr,
        combo;
        octaves=octaves_int,
        vols=vols_float,
        onset=onset
      )

      # streamごとのchord作成（貢献順の先頭からcs個）
      chords_pcs = Vector{Vector{Int}}(undef, desired_stream_count)
      for s in 1:desired_stream_count
        cs = chord_sizes_int[s]
        cs = cs < 1 ? 1 : cs
        cs = cs > length(ordered) ? length(ordered) : cs
        chords_pcs[s] = ordered[1:cs]
      end

      midi_notes, amps = DissonanceStmManager.build_chord_midi_and_amps_for_all_streams(
        octaves_int,
        vols_float,
        nothing,
        chord_sizes_int;
        chords_pcs=chords_pcs
      )

      d = DissonanceStmManager.evaluate(stm_mgr, midi_notes, amps, onset)
      push!(combo_roughness, float(d))
      push!(combo_candidates, (; ordered=ordered, rough=float(d)))
    end

    # combo roughness を0..1正規化して target に近い順
    min_cd = isempty(combo_roughness) ? 0.0 : minimum(combo_roughness)
    max_cd = isempty(combo_roughness) ? 0.0 : maximum(combo_roughness)
    cspan  = (max_cd - min_cd)
    cspan  = cspan == 0.0 ? 1.0 : cspan

    combo_cost = Float64[]
    sizehint!(combo_cost, length(combo_roughness))
    for d in combo_roughness
      norm = clamp((d - min_cd) / cspan, 0.0, 1.0)
      push!(combo_cost, abs(norm - target01))
    end

    # chord_size * K で幅（TopK）
    # ※必要ならここをパラメータ化してください
    ROUGH_TOPK_BASE = 8
    topk_combo = clamp(k * ROUGH_TOPK_BASE, 1, max(1, length(combo_candidates)))

    combo_perm = sortperm(combo_cost)  # 小さい方が良い
    selected_combo_idxs = combo_perm[1:topk_combo]

    # --- A2: selected combo のみ shift(0..11)展開し、roughnessを再評価して幅を作る ---
    absolute_bases = Int[PolyphonicConfig.base_c_midi(o) for o in octaves_int]

    function _compute_abs_width(bases::Vector{Int})::Float64
      bb = Float64[float(x) for x in bases]
      pc_width = abs(float(last(PolyphonicConfig.NOTE_RANGE)) - float(first(PolyphonicConfig.NOTE_RANGE)))
      pc_width = pc_width <= 0.0 ? 1.0 : pc_width
      w = abs(maximum(bb) - minimum(bb)) + pc_width
      return w <= 0.0 ? 1.0 : w
    end

    abs_width = _compute_abs_width(absolute_bases)

    function _set_distance01(a_raw::Vector{Int}, b_raw::Vector{Int}; width::Real, max_count::Int)::Float64
      return MultiStreamManager.set_distance01(a_raw, b_raw; width=width, max_count=max_count)
    end

    function _average_pairwise_distance(chords::Vector{Vector{Int}}; width::Real, max_count::Int)::Float64
      n = length(chords)
      n < 2 && return 0.0
      sumv = 0.0
      cnt = 0
      for i in 1:(n-1)
        for j in (i+1):n
          sumv += _set_distance01(chords[i], chords[j]; width=width, max_count=max_count)
          cnt += 1
        end
      end
      return cnt > 0 ? (sumv / float(cnt)) : 0.0
    end

    active_total_notes = sum(chord_sizes_int)
    density01 = desired_stream_count <= 0 ? 0.0 : clamp(active_total_notes / float(max_simultaneous_notes * desired_stream_count), 0.0, 1.0)
    distance_weight = density01
    complexity_weight = 1.0 - density01

    containers = MultiStreamManager.active_stream_containers(note_mgrs[:stream], desired_stream_count)

    note_pc_width = abs(float(last(PolyphonicConfig.NOTE_RANGE)) - float(first(PolyphonicConfig.NOTE_RANGE)))
    note_pc_width = note_pc_width <= 0.0 ? 1.0 : note_pc_width

    # shift候補（selected combos × 12 shifts）
    shift_candidates = Vector{Any}()
    shift_roughness = Float64[]

    for ci in selected_combo_idxs
      ordered = combo_candidates[ci].ordered

      for shift in 0:(PolyphonicConfig.STEPS_PER_OCTAVE - 1)
        # 貢献順を保持したまま shift
        shifted_contrib = Int[(pc + shift) % PolyphonicConfig.STEPS_PER_OCTAVE for pc in ordered]

        # streamごとのchord作成（貢献順先頭からcs個）
        chords_for_streams = Vector{Vector{Int}}(undef, desired_stream_count)
        for s in 1:desired_stream_count
          cs = chord_sizes_int[s]
          cs = cs < 1 ? 1 : cs
          cs = cs > length(shifted_contrib) ? length(shifted_contrib) : cs
          chords_for_streams[s] = shifted_contrib[1:cs]
        end

        # global_value は set表現として安定のため sort/uniq
        global_value = unique(copy(shifted_contrib))
        sort!(global_value)

        # このshift候補のroughness（Aの本体）
        midi_notes_r, amps_r = DissonanceStmManager.build_chord_midi_and_amps_for_all_streams(
          octaves_int,
          vols_float,
          nothing,
          chord_sizes_int;
          chords_pcs=chords_for_streams
        )
        d_shift = float(DissonanceStmManager.evaluate(stm_mgr, midi_notes_r, amps_r, onset))
        push!(shift_roughness, d_shift)

        # Bに必要な複雑度情報もここで計算して保持（決定論）
        g_dist, g_qty, g_comp = PolyphonicClusterManager.simulate_add_and_calculate(
          note_mgrs[:global],
          Float64[float(x) for x in global_value],
          note_q_array
        )

        stream_dists01 = Float64[]
        stream_complexities_raw = Float64[]
        sizehint!(stream_dists01, desired_stream_count)
        sizehint!(stream_complexities_raw, desired_stream_count)

        for s in 1:desired_stream_count
          pcs = chords_for_streams[s]
          base = absolute_bases[s]
          cand_abs = Int[base + (pc % PolyphonicConfig.STEPS_PER_OCTAVE) for pc in pcs]

          last_abs = containers[s].last_abs_pitch
          if last_abs === nothing
            last_val = containers[s].last_value
            last_pcs = Int[Int(trunc(pc)) % PolyphonicConfig.STEPS_PER_OCTAVE for pc in last_val]
            last_abs = Int[base + pc for pc in last_pcs]
          end

          dist01 = _set_distance01(cand_abs, last_abs; width=abs_width, max_count=max_simultaneous_notes)
          push!(stream_dists01, dist01)

          d_s, _q_s, c_s = PolyphonicClusterManager.simulate_add_and_calculate(
            containers[s].manager,
            Float64[float(x) for x in pcs],
            note_q_array
          )
          raw = isfinite(c_s) ? c_s : (isfinite(d_s) ? d_s : 0.0)
          push!(stream_complexities_raw, float(raw))
        end

        discordance = _average_pairwise_distance(chords_for_streams; width=note_pc_width, max_count=max_simultaneous_notes)

        push!(shift_candidates, (;
          shift=shift,
          rough=d_shift,
          global_dist=float(g_dist),
          global_qty=float(g_qty),
          global_comp=float(g_comp),
          stream_dists01=stream_dists01,
          stream_comps_raw=stream_complexities_raw,
          discordance=float(discordance),
          chords_for_streams=chords_for_streams,
          global_value=global_value
        ))
      end
    end

    # shift roughness 正規化 → target に近い順で TopK
    min_sd = isempty(shift_roughness) ? 0.0 : minimum(shift_roughness)
    max_sd = isempty(shift_roughness) ? 0.0 : maximum(shift_roughness)
    sspan  = (max_sd - min_sd)
    sspan  = sspan == 0.0 ? 1.0 : sspan

    shift_cost = Float64[]
    sizehint!(shift_cost, length(shift_candidates))
    for cand in shift_candidates
      norm = clamp((cand.rough - min_sd) / sspan, 0.0, 1.0)
      push!(shift_cost, abs(norm - target01))
    end

    topk_shift = clamp(k * ROUGH_TOPK_BASE, 1, max(1, length(shift_candidates)))
    shift_perm = sortperm(shift_cost)
    allowed_shift_idxs = shift_perm[1:topk_shift]

    # --- B: allowed の中だけで複雑度コスト最小（global + stream + discordance） ---
    # stream complexity の 0..1 正規化（全shift候補を母集団にする）
    n_shifts_all = length(shift_candidates)
    complexity01 = Array{Float64}(undef, desired_stream_count, n_shifts_all)

    for s in 1:desired_stream_count
      raws = Float64[shift_candidates[i].stream_comps_raw[s] for i in 1:n_shifts_all]
      min_r = minimum(raws)
      max_r = maximum(raws)
      span_r = abs(max_r - min_r)
      span_r = span_r <= 0.0 ? 1.0 : span_r
      for i in 1:n_shifts_all
        complexity01[s, i] = clamp((raws[i] - min_r) / span_r, 0.0, 1.0)
      end
    end

    allowed_metrics = CandidateMetric[]
    sizehint!(allowed_metrics, length(allowed_shift_idxs))

    for idx in allowed_shift_idxs
      cand = shift_candidates[idx]

      # streamスコアは dist01 と complexity01 を混合（密度で重み変化）
      stream_mixed = Float64[]
      sizehint!(stream_mixed, desired_stream_count)
      for s in 1:desired_stream_count
        dist01 = cand.stream_dists01[s]
        comp01 = complexity01[s, idx]
        mixed01 = (distance_weight * dist01) + (complexity_weight * comp01)
        push!(stream_mixed, clamp(mixed01, 0.0, 1.0))
      end

      # ★追加：ordered_vals と stream_comps を用意して 7引数にする
      ordered_vals = Float64[float(x) for x in cand.global_value]   # shift後のglobal音群
      stream_comps = Float64[]
      sizehint!(stream_comps, desired_stream_count)
      for s in 1:desired_stream_count
        push!(stream_comps, clamp(complexity01[s, idx], 0.0, 1.0))
      end

      push!(allowed_metrics, CandidateMetric(
        ordered_vals,
        cand.global_dist,
        cand.global_qty,
        cand.global_comp,
        stream_mixed,
        stream_comps,
        cand.discordance
      ))
    end


    best_local_i, _best_cost = select_best_polyphonic_candidate_unified_with_cost(
      allowed_metrics,
      note_global_target,
      note_stream_targets,
      note_conc_w;
      stream_dist_max=1.0
    )

    best_shift_idx = allowed_shift_idxs[best_local_i]
    best_cand = shift_candidates[best_shift_idx]

    # commit STM
    midi_notes, amps = DissonanceStmManager.build_chord_midi_and_amps_for_all_streams(
      octaves_int,
      vols_float,
      nothing,
      chord_sizes_int;
      chords_pcs=best_cand.chords_for_streams
    )
    DissonanceStmManager.commit!(stm_mgr, midi_notes, amps, onset)

    # update managers
    PolyphonicClusterManager.add_data_point_permanently(note_mgrs[:global], Float64[float(x) for x in best_cand.global_value])
    PolyphonicClusterManager.update_caches_permanently(note_mgrs[:global], note_q_array)

    MultiStreamManager.commit_state!(note_mgrs[:stream], best_cand.chords_for_streams, note_q_array; absolute_bases=absolute_bases)
    MultiStreamManager.update_caches_permanently!(note_mgrs[:stream], note_q_array)

    # output
    for s_i in 1:desired_stream_count
      current_step_values[s_i][note_idx] = normalize_pcs(best_cand.chords_for_streams[s_i])
    end
    step_decisions["note"] = best_cand.global_value
    push!(results, current_step_values)
  end

  # --- final normalization (Rails) ---
  for step in results
    for vec in step
      vec[oct_idx] = clamp(_parse_int(vec[oct_idx]), first(PolyphonicConfig.OCTAVE_RANGE), last(PolyphonicConfig.OCTAVE_RANGE))
      vec[vol_idx] = clamp(_parse_float(vec[vol_idx]), 0.0, 1.0)
      vec[bri_idx] = clamp(_parse_float(vec[bri_idx]), 0.0, 1.0)
      vec[hrd_idx] = clamp(_parse_float(vec[hrd_idx]), 0.0, 1.0)
      vec[tex_idx] = clamp(_parse_float(vec[tex_idx]), 0.0, 1.0)
      vec[note_idx] = normalize_pcs(vec[note_idx])
    end
  end

  processing_time_s = round(time() - t0; digits=2)

  # --- cluster payload (Rails-compatible) ---
  cluster_payload = Dict{String,Any}()
  for key in ["octave", "note", "vol", "bri", "hrd", "tex", "chord_size"]
    mgrs = get(managers, key, nothing)
    mgrs === nothing && continue

    g_mgr = mgrs[:global]
    s_mgr = mgrs[:stream]

    global_timeline = PolyphonicClusterManager.clusters_to_timeline(g_mgr.clusters, min_window)

    streams_hash = Dict{Int,Any}()
    for container in s_mgr.stream_pool
      streams_hash[container.id] = PolyphonicClusterManager.clusters_to_timeline(container.manager.clusters, min_window)
    end

    cluster_payload[key] = Dict(
      "global" => global_timeline,
      "streams" => streams_hash,
    )
  end

  return Dict(
    "timeSeries" => results,
    "clusters" => cluster_payload,
    "processingTime" => processing_time_s,
    "streamStrengths" => nothing
  )
end


# ------------------------------------------------------------
# GitHub Actions workflow_dispatch integration
# ------------------------------------------------------------
function _env_required(key::AbstractString)
  val = get(ENV, key, "")
  isempty(val) && error("Missing required environment variable: $(key)")
  return val
end

function _github_headers()
  token = _env_required("GITHUB_TOKEN")
  return [
    "Authorization" => "Bearer $(token)",
    "Accept" => "application/vnd.github+json",
    "User-Agent" => "TimeseriesClusteringAPI",
    "X-GitHub-Api-Version" => "2022-11-28",
    "Content-Type" => "application/json",
  ]
end

function _github_repo_base(owner::AbstractString, repo::AbstractString)
  return "https://api.github.com/repos/$(owner)/$(repo)"
end

function _github_dispatch_workflow!(; workflow::AbstractString, ref::AbstractString, inputs::Dict{String,String})
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/dispatches"
  body = JSON.json(Dict("ref" => ref, "inputs" => inputs))
  res = HTTP.request("POST", url, _github_headers(); body=body)
  return res
end

function _github_list_workflow_runs(; workflow::AbstractString, ref::AbstractString, per_page::Int=10)
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  # NOTE: event filter keeps noise down; branch further narrows.
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/runs?event=workflow_dispatch&branch=$(ref)&per_page=$(per_page)"
  res = HTTP.request("GET", url, _github_headers())
  res.status == 200 || return nothing
  return JSON.parse(String(res.body))
end

function _find_new_run_after(obj, dispatched_at_utc::DateTime)
  obj === nothing && return nothing
  runs = get(obj, "workflow_runs", Any[])
  for r in runs
    created = get(r, "created_at", "")
    isempty(created) && continue
    # created_at: 2026-01-28T01:23:45Z
    created_dt = try
      DateTime(created[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
    catch
      continue
    end
    # allow a few seconds skew
    if created_dt >= (dispatched_at_utc - Dates.Second(5))
      return r
    end
  end
  return nothing
end

"""
POST /api/web/time_series/dispatch_generate_polyphonic

Receives the same JSON payload as /generate_polyphonic, and forwards it to GitHub Actions via workflow_dispatch.

Required ENV (local only; keep in .env and out of git):
  - GITHUB_TOKEN
  - GITHUB_OWNER
  - GITHUB_REPO
  - GITHUB_WORKFLOW   (workflow filename, e.g. polyphonic_generate.yml)
  - GITHUB_REF        (branch, e.g. main)
"""
function dispatch_generate_polyphonic()
  payload = _payload()
  payload_dict = _to_string_dict(payload)
  gp = get(payload_dict, "generate_polyphonic", Dict{String,Any}())
  gp_dict = _to_string_dict(gp)

  request_id = string(get(gp_dict, "job_id", uuid4()))
  # ensure job_id exists (useful for run naming)
  gp_dict["job_id"] = request_id
  payload_dict["generate_polyphonic"] = gp_dict

  workflow = _env_required("GITHUB_WORKFLOW")
  ref = _env_required("GITHUB_REF")

  params_json = JSON.json(payload_dict)
  params_b64 = base64encode(params_json)

  dispatched_at = now(UTC)

  # 1) dispatch
  res = try
    _github_dispatch_workflow!(workflow=workflow, ref=ref, inputs=Dict(
      "request_id" => request_id,
      "params_b64" => params_b64,
    ))
  catch e
    return Dict("ok" => false, "error" => string(e))
  end

  # GitHub documents 204; some environments return 200 with a body.
  run_id = nothing
  run_url = nothing
  html_url = nothing

  if res.status == 200 && !isempty(String(res.body))
    try
      body = JSON.parse(String(res.body))
      run_id = get(body, "workflow_run_id", nothing)
      run_url = get(body, "run_url", nothing)
      html_url = get(body, "html_url", nothing)
    catch
      # ignore and fall back to polling
    end
  end

  workflow_page_url = "https://github.com/$(_env_required("GITHUB_OWNER"))/$(_env_required("GITHUB_REPO"))/actions/workflows/$(workflow)"

  # 2) best-effort: poll latest runs to find the one we just dispatched
  if html_url === nothing
    for _ in 1:8
      obj = _github_list_workflow_runs(workflow=workflow, ref=ref, per_page=10)
      r = _find_new_run_after(obj, dispatched_at)
      if r !== nothing
        run_id = get(r, "id", run_id)
        html_url = get(r, "html_url", html_url)
        run_url = get(r, "url", run_url)
        break
      end
      sleep(1.0)
    end
  end

  return Dict(
    "ok" => (res.status == 204 || res.status == 200),
    "request_id" => request_id,
    "workflow" => workflow,
    "ref" => ref,
    "workflow_page_url" => workflow_page_url,
    "run_id" => run_id,
    "run_url" => run_url,
    "run_html_url" => html_url,
    "http_status" => res.status,
  )
end

end # module