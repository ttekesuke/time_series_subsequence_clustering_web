module TimeSeriesController

using Genie.Requests
using Dates
using HTTP
using JSON3
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

    cache = get!(manager.cluster_distance_cache, window_size, Dict{Tuple{Int,Int},Float64}())
    for i in 1:length(all_ids)
      for j in (i+1):length(all_ids)
        cid1 = all_ids[i]
        cid2 = all_ids[j]
        as1 = same_ws[cid1]["as"]
        as2 = same_ws[cid2]["as"]
        key = cid1 < cid2 ? (cid1,cid2) : (cid2,cid1)
        cache[key] = euclidean_distance(as1, as2)
      end
    end

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
      c_cache[cid] = calculate_cluster_complexity(cluster)
    end
  end

  return nothing
end

# ------------------------------------------------------------
# Actions
# ------------------------------------------------------------

function analyse()
  t0 = time()

  payload = _payload()
  p = _subhash(payload, "analyse")

  raw_series = get(p, "time_series", Any[])
  data = Int[]
  for v in raw_series
    try
      push!(data, _parse_int(v))
    catch
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
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

  results = copy(first_elements)

  for target_val in complexity_targets
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
    result_value = candidates[result_index + 1]

    push!(results, result_value)
    add_data_point_permanently!(manager, result_value)
    update_caches_permanently!(manager, qarr)
  end

  timeline = clusters_to_timeline(manager.clusters, min_window_size)
  processing_time_s = round(time() - t0; digits=2)

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

# ------------------------------------------------------------
# Polyphonic helpers
# ------------------------------------------------------------

# 0-based index read (Rails compatible)
function array_param(raw::Dict{String,Any}, key::String, idx0::Int)
  raw === nothing && return nothing
  val = get(raw, key, nothing)
  val === nothing && return nothing

  if val isa AbstractVector
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

# Accept JSON3.Object / Dict{Symbol,Any} etc.
function array_param(raw::AbstractDict, key::String, idx0::Int)
  return array_param(_to_string_dict(raw), key, idx0)
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
  ordered_cand::Vector{Float64}
  global_dist::Float64
  global_qty::Float64
  global_comp::Float64
  stream_dists::Vector{Float64}
  stream_comps::Vector{Float64}
  discordance::Float64
end

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

  sdm = stream_dist_max
  sdm = (sdm <= 0.0) ? 1.0 : sdm

  for (i, m) in enumerate(metrics)
    current_global = (g_dists[i] + g_qtys[i] + g_comps[i]) / 3.0
    cost_a = abs(current_global - global_target)

    cost_b = 0.0
    if !isempty(stream_targets)
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

    conc_t = clamp(concordance_weight, 0.0, 1.0)
    concord01 = 1.0 - clamp(m.discordance, 0.0, 1.0)
    cost_c = abs(concord01 - conc_t)

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

# ------------------------------------------------------------
# generate_polyphonic (main)
# ------------------------------------------------------------
function generate_polyphonic()
  t0 = time()

  payload = _payload()
  gp = _subhash(payload, "generate_polyphonic")   # ← params辞書は gp に統一（p をやめる）

  stream_counts_raw = get(gp, "stream_counts", Any[])
  stream_counts = Int[]
  if stream_counts_raw isa AbstractVector
    for x in stream_counts_raw
      push!(stream_counts, _parse_int(x))
    end
  else
    push!(stream_counts, _parse_int(stream_counts_raw))
  end
  isempty(stream_counts) && push!(stream_counts, 1)

  strength_targets_raw = get(gp, "stream_strength_target", Any[])
  strength_spreads_raw = get(gp, "stream_strength_spread", Any[])

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

  dissonance_targets_raw = get(gp, "dissonance_target", nothing)
  dissonance_targets = Float64[]
  if dissonance_targets_raw isa AbstractVector
    for x in dissonance_targets_raw
      push!(dissonance_targets, _parse_float(x))
    end
  elseif dissonance_targets_raw !== nothing
    push!(dissonance_targets, _parse_float(dissonance_targets_raw))
  end

  ctx_raw = get(gp, "initial_context", Any[])

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

  normalize_pcs = function (x)
    pcs = Int[]
    if x isa AbstractVector
      for v in x
        v === nothing && continue
        push!(pcs, (_parse_int(v) % 12))
      end
    else
      pcs = Int[(_parse_int(x) % 12)]
    end
    isempty(pcs) && (pcs = Int[PolyphonicConfig.NOTE_RANGE.start])
    return pcs
  end

  for step in results
    for st in step
      length(st) >= 2 || continue
      st[2] = normalize_pcs(st[2])
    end
  end

  merge_threshold_ratio = 0.1
  min_window = 2
  max_simultaneous_notes = last(PolyphonicConfig.CHORD_SIZE_RANGE)

  oct_idx  = 1
  note_idx = 2
  vol_idx  = 3
  bri_idx  = 4
  hrd_idx  = 5
  tex_idx  = 6

  function matrix_for_idx(idx::Int)
    return [ [ (length(st) >= idx ? st[idx] : 0) for st in step ] for step in results ]
  end

  hist_oct = matrix_for_idx(oct_idx)
  hist_vol = matrix_for_idx(vol_idx)
  hist_bri = matrix_for_idx(bri_idx)
  hist_hrd = matrix_for_idx(hrd_idx)
  hist_tex = matrix_for_idx(tex_idx)

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

  managers = Dict{String,Dict{Symbol,Any}}()

  function global_series_from_matrix(mat)
    series = Vector{Vector{Float64}}()
    for row in mat
      push!(series, Float64[float(x) for x in row])
    end
    return series
  end

  s_oct = MultiStreamManager.Manager(hist_oct, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(PolyphonicConfig.OCTAVE_RANGE))
  g_oct = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_oct), merge_threshold_ratio, min_window; value_min=first(PolyphonicConfig.OCTAVE_RANGE), value_max=last(PolyphonicConfig.OCTAVE_RANGE))
  PolyphonicClusterManager.process_data!(g_oct)
  PolyphonicClusterManager.update_caches_permanently(g_oct, create_quadratic_integer_array(0, float(last(PolyphonicConfig.OCTAVE_RANGE)-first(PolyphonicConfig.OCTAVE_RANGE)) * length(g_oct.data), length(g_oct.data)))
  managers["octave"] = Dict(:global => g_oct, :stream => s_oct)

  s_vol = MultiStreamManager.Manager(hist_vol, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS, track_presence=true)
  g_vol = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_vol), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_vol)
  PolyphonicClusterManager.update_caches_permanently(g_vol, create_quadratic_integer_array(0, 1.0 * length(g_vol.data), length(g_vol.data)))
  managers["vol"] = Dict(:global => g_vol, :stream => s_vol)

  s_bri = MultiStreamManager.Manager(hist_bri, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS)
  g_bri = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_bri), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_bri)
  PolyphonicClusterManager.update_caches_permanently(g_bri, create_quadratic_integer_array(0, 1.0 * length(g_bri.data), length(g_bri.data)))
  managers["bri"] = Dict(:global => g_bri, :stream => s_bri)

  s_hrd = MultiStreamManager.Manager(hist_hrd, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS)
  g_hrd = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_hrd), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_hrd)
  PolyphonicClusterManager.update_caches_permanently(g_hrd, create_quadratic_integer_array(0, 1.0 * length(g_hrd.data), length(g_hrd.data)))
  managers["hrd"] = Dict(:global => g_hrd, :stream => s_hrd)

  s_tex = MultiStreamManager.Manager(hist_tex, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=PolyphonicConfig.FLOAT_STEPS)
  g_tex = PolyphonicClusterManager.Manager(global_series_from_matrix(hist_tex), merge_threshold_ratio, min_window; value_min=0.0, value_max=1.0)
  PolyphonicClusterManager.process_data!(g_tex)
  PolyphonicClusterManager.update_caches_permanently(g_tex, create_quadratic_integer_array(0, 1.0 * length(g_tex.data), length(g_tex.data)))
  managers["tex"] = Dict(:global => g_tex, :stream => s_tex)

  s_note = MultiStreamManager.Manager(note_stream_history, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(PolyphonicConfig.NOTE_RANGE), max_set_size=max_simultaneous_notes)
  g_note_series = Vector{Vector{Float64}}()
  for pcs in note_global_history
    push!(g_note_series, Float64[float(x) for x in pcs])
  end
  g_note = PolyphonicClusterManager.Manager(g_note_series, merge_threshold_ratio, min_window; value_min=float(first(PolyphonicConfig.NOTE_RANGE)), value_max=float(last(PolyphonicConfig.NOTE_RANGE)), max_set_size=max_simultaneous_notes)
  PolyphonicClusterManager.process_data!(g_note)
  PolyphonicClusterManager.update_caches_permanently(g_note, create_quadratic_integer_array(0, 11.0 * length(g_note.data), length(g_note.data)))
  managers["note"] = Dict(:global => g_note, :stream => s_note)

  s_cs = MultiStreamManager.Manager(chord_history, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(PolyphonicConfig.CHORD_SIZE_RANGE))
  g_cs = PolyphonicClusterManager.Manager(global_series_from_matrix(chord_history), merge_threshold_ratio, min_window; value_min=float(first(PolyphonicConfig.CHORD_SIZE_RANGE)), value_max=float(last(PolyphonicConfig.CHORD_SIZE_RANGE)), max_set_size=max_simultaneous_notes)
  PolyphonicClusterManager.process_data!(g_cs)
  PolyphonicClusterManager.update_caches_permanently(g_cs, create_quadratic_integer_array(0, float(last(PolyphonicConfig.CHORD_SIZE_RANGE)-first(PolyphonicConfig.CHORD_SIZE_RANGE)) * length(g_cs.data), length(g_cs.data)))
  managers["chord_size"] = Dict(:global => g_cs, :stream => s_cs)

  result_path = get(ENV, "POLYPHONIC_RESULT_PATH", "result.json")

  function _build_cluster_payload()
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
    return cluster_payload
  end

  function _build_result_payload(processing_time_s::Float64)
    return Dict(
      "timeSeries" => results,
      "clusters" => _build_cluster_payload(),
      "processingTime" => processing_time_s,
      "streamStrengths" => nothing
    )
  end

  function _write_result_json_payload!(payload::Dict{String,Any})
    isempty(result_path) && return
    try
      tmp_path = result_path * ".tmp"
      open(tmp_path, "w") do io
        write(io, JSON3.write(payload))
      end
      mv(tmp_path, result_path; force=true)
    catch e
      println("[generate_polyphonic] warning: failed to write $(result_path): $(e)")
    end
  end

  stm_mgr = DissonanceStmManager.Manager(
    memory_span=1.5,
    memory_weight=1.0,
    n_partials=8,
    amp_profile=0.88
  )

  step_duration = 0.125
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

  steps_to_generate = length(stream_counts)
  base_step_index = length(results)

  for step_idx in 1:steps_to_generate
    desired_stream_count = max(stream_counts[step_idx], 1)

    st_target = step_idx <= length(strength_targets) ? strength_targets[step_idx] : 0.5
    st_spread = step_idx <= length(strength_spreads) ? strength_spreads[step_idx] : 0.0

    vol_mgr = managers["vol"][:stream]
    plan = MultiStreamManager.build_stream_lifecycle_plan(vol_mgr, desired_stream_count; target=st_target, spread=st_spread)

    for (_k, mgrs) in managers
      MultiStreamManager.apply_stream_lifecycle_plan!(mgrs[:stream], plan)
    end

    current_step_values = [ Any[0, Int[], 0.0, 0.0, 0.0, 0.0] for _ in 1:desired_stream_count ]
    step_decisions = Dict{String,Any}()

    idx0 = step_idx - 1

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

      g_target = clamp(_parse_float(array_param(gp, "$(key)_global", idx0)), 0.0, 1.0)
      s_center = clamp(_parse_float(array_param(gp, "$(key)_center", idx0)), 0.0, 1.0)
      s_spread = clamp(_parse_float(array_param(gp, "$(key)_spread", idx0)), 0.0, 1.0)
      conc_w  = _parse_float(array_param(gp, "$(key)_conc", idx0))

      stream_targets = generate_centered_targets(desired_stream_count, s_center, s_spread)

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

      PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], Float64[float(x) for x in best_chord])
      PolyphonicClusterManager.update_caches_permanently(mgrs[:global], q_array)

      if key == "vol"
        MultiStreamManager.commit_state!(mgrs[:stream], best_chord, q_array; strength_params=(target=st_target, spread=st_spread))
      else
        MultiStreamManager.commit_state!(mgrs[:stream], best_chord, q_array)
      end
      MultiStreamManager.update_caches_permanently!(mgrs[:stream], q_array)

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
    # NOTE generation
    # =============================================================================
    note_mgrs = managers["note"]

    note_global_target = clamp(_parse_float(array_param(gp, "note_global", idx0)), 0.0, 1.0)
    note_stream_center = clamp(_parse_float(array_param(gp, "note_center", idx0)), 0.0, 1.0)
    note_stream_spread = clamp(_parse_float(array_param(gp, "note_spread", idx0)), 0.0, 1.0)
    note_conc_w        = _parse_float(array_param(gp, "note_conc", idx0))

    note_stream_targets = generate_centered_targets(desired_stream_count, note_stream_center, note_stream_spread)

    note_range_vec = collect(PolyphonicConfig.NOTE_RANGE)
    note_vmin = float(minimum(note_range_vec))
    note_vmax = float(maximum(note_range_vec))
    note_width = abs(note_vmax - note_vmin)
    note_width = note_width <= 0.0 ? 1.0 : note_width
    note_len_next = length(note_mgrs[:global].data) + 1
    note_q_array = create_quadratic_integer_array(0, note_width * note_len_next, note_len_next)

    chord_sizes_int = Int[clamp(Int(chord_sizes_for_step[i]), 1, max_simultaneous_notes) for i in 1:desired_stream_count]

    oct_vals = get(step_decisions, "octave", Float64[])
    octaves_int = Int[clamp(Int(trunc(oct_vals[i])), first(PolyphonicConfig.OCTAVE_RANGE), last(PolyphonicConfig.OCTAVE_RANGE)) for i in 1:desired_stream_count]

    vol_vals = get(step_decisions, "vol", Float64[])
    vols_float = Float64[clamp(float(vol_vals[i]), 0.0, 1.0) for i in 1:desired_stream_count]

    # --- IMPORTANT FIX ---
    # pool size must be > chord_size to allow different streams to pick different subsets.
    cs_max = maximum(chord_sizes_int)
    POOL_EXTRA = 3
    pool_k = clamp(cs_max + POOL_EXTRA, 2, 8)  # 2..8 (safe)
    # ---------------------

    onset = float(base_step_index + idx0) * step_duration

    dis_target_raw = array_param(gp, "dissonance_target", idx0)
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

    combos = _combinations(pitch_classes, pool_k)

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

      # roughness approx: use top cs from ordered for each stream (cheap proxy)
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

    ROUGH_TOPK_BASE = 4
    topk_combo = clamp(pool_k * ROUGH_TOPK_BASE, 1, max(1, length(combo_candidates)))
    combo_perm = sortperm(combo_cost)
    selected_combo_idxs = combo_perm[1:topk_combo]

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

    active_total_notes = sum(chord_sizes_int)
    density01 = desired_stream_count <= 0 ? 0.0 : clamp(active_total_notes / float(max_simultaneous_notes * desired_stream_count), 0.0, 1.0)
    distance_weight = density01
    complexity_weight = 1.0 - density01

    containers = MultiStreamManager.active_stream_containers(note_mgrs[:stream], desired_stream_count)

    note_pc_width = abs(float(last(PolyphonicConfig.NOTE_RANGE)) - float(first(PolyphonicConfig.NOTE_RANGE)))
    note_pc_width = note_pc_width <= 0.0 ? 1.0 : note_pc_width

    shift_candidates = Vector{Any}()
    shift_roughness = Float64[]

    JOINT_TOPK_PER_SHIFT = 4
    PER_STREAM_TOPK      = 12
    BEAM_WIDTH           = 24

    function _pcs_mask(pcs::Vector{Int})::UInt16
      m::UInt16 = 0
      for pc in pcs
        pc2 = Int(pc % PolyphonicConfig.STEPS_PER_OCTAVE)
        m |= (UInt16(1) << UInt16(pc2))
      end
      return m
    end

    function _mask_to_pcs(mask::UInt16)::Vector{Int}
      out = Int[]
      for pc in 0:(PolyphonicConfig.STEPS_PER_OCTAVE - 1)
        if (mask & (UInt16(1) << UInt16(pc))) != 0
          push!(out, pc)
        end
      end
      return out
    end

    for ci in selected_combo_idxs
      ordered0 = combo_candidates[ci].ordered

      for shift in 0:(PolyphonicConfig.STEPS_PER_OCTAVE - 1)
        pool = Int[(pc + shift) % PolyphonicConfig.STEPS_PER_OCTAVE for pc in ordered0]
        pool_len = length(pool)
        pool_len == 0 && continue

        per_stream_opts = Vector{Any}(undef, desired_stream_count)

        for s in 1:desired_stream_count
          cs = chord_sizes_int[s]
          cs = cs < 1 ? 1 : cs
          cs = cs > pool_len ? pool_len : cs

          subsets = _combinations(pool, cs)

          pcs_list = Vector{Vector{Int}}()
          dist_list = Float64[]
          comp_raw_list = Float64[]
          mask_list = UInt16[]

          sizehint!(pcs_list, length(subsets))
          sizehint!(dist_list, length(subsets))
          sizehint!(comp_raw_list, length(subsets))
          sizehint!(mask_list, length(subsets))

          base = absolute_bases[s]

          last_abs = containers[s].last_abs_pitch
          if last_abs === nothing
            last_val = containers[s].last_value
            last_pcs = Int[Int(trunc(pc)) % PolyphonicConfig.STEPS_PER_OCTAVE for pc in last_val]
            last_abs = Int[base + pc for pc in last_pcs]
          end

          for pcs in subsets
            cand_abs = Int[base + (pc % PolyphonicConfig.STEPS_PER_OCTAVE) for pc in pcs]
            dist01 = _set_distance01(cand_abs, last_abs; width=abs_width, max_count=max_simultaneous_notes)

            d_s, _q_s, c_s = PolyphonicClusterManager.simulate_add_and_calculate(
              containers[s].manager,
              Float64[float(x) for x in pcs],
              note_q_array
            )
            raw = isfinite(c_s) ? c_s : (isfinite(d_s) ? d_s : 0.0)

            push!(pcs_list, pcs)
            push!(dist_list, dist01)
            push!(comp_raw_list, float(raw))
            push!(mask_list, _pcs_mask(pcs))
          end

          min_r = isempty(comp_raw_list) ? 0.0 : minimum(comp_raw_list)
          max_r = isempty(comp_raw_list) ? 0.0 : maximum(comp_raw_list)
          span_r = abs(max_r - min_r)
          span_r = span_r <= 0.0 ? 1.0 : span_r

          costs = Float64[]
          sizehint!(costs, length(comp_raw_list))

          target_s = s <= length(note_stream_targets) ? note_stream_targets[s] : note_global_target

          for raw in comp_raw_list
            comp01 = clamp((raw - min_r) / span_r, 0.0, 1.0)
            push!(costs, abs(comp01 - target_s))
          end

          perm = sortperm(costs)
          topk = min(PER_STREAM_TOPK, length(perm))

          opts = Vector{Any}()
          sizehint!(opts, topk)

          for j in 1:topk
            ii = perm[j]
            push!(opts, (;
              pcs=pcs_list[ii],
              mask=mask_list[ii],
              dist01=dist_list[ii],
              comp_raw=comp_raw_list[ii],
              cost=float(costs[ii])
            ))
          end
          per_stream_opts[s] = opts
        end

        conc_target = clamp(note_conc_w, 0.0, 1.0)

        beam = Vector{Any}()
        push!(beam, (;
          score=0.0,
          chords=Vector{Vector{Int}}(),
          mask=UInt16(0),
          sum_cost=0.0,
          sum_pair=0.0,
          pair_cnt=0,
          stream_dists01=Float64[],
          stream_comps_raw=Float64[]
        ))

        for s in 1:desired_stream_count
          opts = per_stream_opts[s]
          isempty(opts) && continue

          new_beam = Vector{Any}()

          for b in beam
            for opt in opts
              sum_pair = b.sum_pair
              pair_cnt = b.pair_cnt
              for prev in b.chords
                sum_pair += _set_distance01(prev, opt.pcs; width=note_pc_width, max_count=max_simultaneous_notes)
                pair_cnt += 1
              end

              chords2 = copy(b.chords)
              push!(chords2, opt.pcs)

              sd2 = copy(b.stream_dists01)
              push!(sd2, opt.dist01)

              sc2 = copy(b.stream_comps_raw)
              push!(sc2, opt.comp_raw)

              sum_cost2 = b.sum_cost + opt.cost
              disc = pair_cnt > 0 ? (sum_pair / float(pair_cnt)) : 0.0
              concord01 = 1.0 - clamp(disc, 0.0, 1.0)
              cost_conc = abs(concord01 - conc_target)

              score = (sum_cost2 / float(s)) + cost_conc

              push!(new_beam, (;
                score=score,
                chords=chords2,
                mask=(b.mask | opt.mask),
                sum_cost=sum_cost2,
                sum_pair=sum_pair,
                pair_cnt=pair_cnt,
                stream_dists01=sd2,
                stream_comps_raw=sc2
              ))
            end
          end

          isempty(new_beam) && break
          perm2 = sortperm([x.score for x in new_beam])
          keep = min(BEAM_WIDTH, length(perm2))
          beam = [new_beam[perm2[i]] for i in 1:keep]
        end

        isempty(beam) && continue

        perm_beam = sortperm([x.score for x in beam])
        take = min(JOINT_TOPK_PER_SHIFT, length(perm_beam))

        for jj in 1:take
          b = beam[perm_beam[jj]]
          chords_for_streams = b.chords

          global_value = _mask_to_pcs(b.mask)
          sort!(global_value)

          midi_notes_r, amps_r = DissonanceStmManager.build_chord_midi_and_amps_for_all_streams(
            octaves_int,
            vols_float,
            nothing,
            chord_sizes_int;
            chords_pcs=chords_for_streams
          )
          d_shift = float(DissonanceStmManager.evaluate(stm_mgr, midi_notes_r, amps_r, onset))
          push!(shift_roughness, d_shift)

          g_dist, g_qty, g_comp = PolyphonicClusterManager.simulate_add_and_calculate(
            note_mgrs[:global],
            Float64[float(x) for x in global_value],
            note_q_array
          )

          discordance = b.pair_cnt > 0 ? (b.sum_pair / float(b.pair_cnt)) : 0.0

          push!(shift_candidates, (;
            shift=shift,
            rough=d_shift,
            global_dist=float(g_dist),
            global_qty=float(g_qty),
            global_comp=float(g_comp),
            stream_dists01=b.stream_dists01,
            stream_comps_raw=b.stream_comps_raw,
            discordance=float(discordance),
            chords_for_streams=chords_for_streams,
            global_value=global_value
          ))
        end
      end
    end

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

    topk_shift = clamp(pool_k * ROUGH_TOPK_BASE, 1, max(1, length(shift_candidates)))
    shift_perm = sortperm(shift_cost)
    allowed_shift_idxs = shift_perm[1:topk_shift]

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

      stream_mixed = Float64[]
      sizehint!(stream_mixed, desired_stream_count)
      for s in 1:desired_stream_count
        dist01 = cand.stream_dists01[s]
        comp01 = complexity01[s, idx]
        mixed01 = (distance_weight * dist01) + (complexity_weight * comp01)
        push!(stream_mixed, clamp(mixed01, 0.0, 1.0))
      end

      ordered_vals = Float64[float(x) for x in cand.global_value]
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

    midi_notes, amps = DissonanceStmManager.build_chord_midi_and_amps_for_all_streams(
      octaves_int,
      vols_float,
      nothing,
      chord_sizes_int;
      chords_pcs=best_cand.chords_for_streams
    )
    DissonanceStmManager.commit!(stm_mgr, midi_notes, amps, onset)

    PolyphonicClusterManager.add_data_point_permanently(note_mgrs[:global], Float64[float(x) for x in best_cand.global_value])
    PolyphonicClusterManager.update_caches_permanently(note_mgrs[:global], note_q_array)

    MultiStreamManager.commit_state!(note_mgrs[:stream], best_cand.chords_for_streams, note_q_array; absolute_bases=absolute_bases)
    MultiStreamManager.update_caches_permanently!(note_mgrs[:stream], note_q_array)

    for s_i in 1:desired_stream_count
      current_step_values[s_i][note_idx] = normalize_pcs(best_cand.chords_for_streams[s_i])
    end
    step_decisions["note"] = best_cand.global_value
    push!(results, current_step_values)

    _write_result_json_payload!(_build_result_payload(round(time() - t0; digits=2)))
  end

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
  payload = _build_result_payload(processing_time_s)
  _write_result_json_payload!(payload)
  return payload
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
  body = JSON3.write(Dict("ref" => ref, "inputs" => inputs))
  res = HTTP.request("POST", url, _github_headers(); body=body)
  return res
end

function _github_list_workflow_runs(; workflow::AbstractString, ref::AbstractString, per_page::Int=10)
  owner = _env_required("GITHUB_OWNER")
  repo  = _env_required("GITHUB_REPO")
  url = "$(_github_repo_base(owner, repo))/actions/workflows/$(workflow)/runs?event=workflow_dispatch&branch=$(ref)&per_page=$(per_page)"
  res = HTTP.request("GET", url, _github_headers())
  res.status == 200 || return nothing
  return JSON3.read(String(res.body))
end

function _find_new_run_after(obj, dispatched_at_utc::DateTime)
  obj === nothing && return nothing
  runs = get(obj, "workflow_runs", Any[])
  for r in runs
    created = get(r, "created_at", "")
    isempty(created) && continue
    created_dt = try
      DateTime(created[1:19], dateformat"yyyy-mm-ddTHH:MM:SS")
    catch
      continue
    end
    if created_dt >= (dispatched_at_utc - Dates.Second(5))
      return r
    end
  end
  return nothing
end

function dispatch_generate_polyphonic()
  payload = _payload()
  payload_dict = _to_string_dict(payload)
  gp = get(payload_dict, "generate_polyphonic", Dict{String,Any}())
  gp_dict = _to_string_dict(gp)

  request_id = string(get(gp_dict, "job_id", uuid4()))
  gp_dict["job_id"] = request_id
  payload_dict["generate_polyphonic"] = gp_dict

  workflow = _env_required("GITHUB_WORKFLOW")
  ref = _env_required("GITHUB_REF")

  params_json = JSON3.write(payload_dict)
  params_b64 = base64encode(params_json)

  dispatched_at = now(UTC)

  res = try
    _github_dispatch_workflow!(workflow=workflow, ref=ref, inputs=Dict(
      "request_id" => request_id,
      "params_b64" => params_b64,
    ))
  catch e
    return Dict("ok" => false, "error" => string(e))
  end

  run_id = nothing
  run_url = nothing
  html_url = nothing

  if res.status == 200 && !isempty(String(res.body))
    try
      body = JSON3.read(String(res.body))
      run_id = get(body, "workflow_run_id", nothing)
      run_url = get(body, "run_url", nothing)
      html_url = get(body, "html_url", nothing)
    catch
    end
  end

  workflow_page_url = "https://github.com/$(_env_required("GITHUB_OWNER"))/$(_env_required("GITHUB_REPO"))/actions/workflows/$(workflow)"

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
