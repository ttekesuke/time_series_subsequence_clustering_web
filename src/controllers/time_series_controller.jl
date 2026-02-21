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

const SUBSEQUENCE_MIN_WINDOW_SIZE = 2

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
function _parse_int(x)
  if x isa Integer
    return Int(x)
  elseif x isa Real
    return Int(trunc(x))
  elseif x === nothing
    return 0
  else
    s = strip(string(x))
    isempty(s) && return 0
    i = tryparse(Int, s)
    i !== nothing && return i
    f = tryparse(Float64, s)
    f !== nothing && return Int(trunc(f))
    return parse(Int, s)  # keep previous error behavior for truly invalid input
  end
end
function _parse_bool(x, default::Bool=false)::Bool
  x === nothing && return default
  x isa Bool && return x
  x isa Integer && return x != 0
  if x isa AbstractString
    s = lowercase(strip(String(x)))
    s in ("1", "true", "t", "yes", "y", "on", "enable", "enabled") && return true
    s in ("0", "false", "f", "no", "n", "off", "disable", "disabled") && return false
  end
  return default
end

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
  skip_empty = _parse_bool(get(p, "skip_empty", true), true)
  data = Int[]
  for v in raw_series
    if v === nothing || v === missing || (v isa AbstractString && isempty(strip(v)))
      if skip_empty
        continue
      else
        push!(data, 0)
        continue
      end
    end
    try
      push!(data, _parse_int(v))
    catch
      if !skip_empty
        push!(data, 0)
      end
    end
  end

  if isempty(data)
    processing_time_s = round(time() - t0; digits=2)
    return Dict(
      "clusteredSubsequences" => Any[],
      "timeSeries" => Int[],
      "clusters" => Dict{String,Any}(),
      "processingTime" => processing_time_s,
      "skippedEmpty" => true
    )
  end

  merge_threshold_ratio = _parse_float(get(p, "merge_threshold_ratio", 0.3))
  min_window_size = SUBSEQUENCE_MIN_WINDOW_SIZE
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

  min_window_size = SUBSEQUENCE_MIN_WINDOW_SIZE
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

    g_offset = get(mgrs, :global_offset, 0.0)
    global_vals = Float64[]
    sizehint!(global_vals, length(ordered_vals))
    for (i, v) in enumerate(ordered_vals)
      push!(global_vals, float(v) + (i - 1) * float(g_offset))
    end
    g_dist, g_qty, g_comp = PolyphonicClusterManager.simulate_add_and_calculate(mgrs[:global], global_vals, q_array)
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
  gp = _subhash(payload, "generate_polyphonic")
  debug_poly = false
  try
    debug_poly = get(gp, "debug_poly", false) == true || get(ENV, "ZIP_DEBUG_POLY", "0") == "1"
  catch
    debug_poly = get(ENV, "ZIP_DEBUG_POLY", "0") == "1"
  end

  # ----------------------------------------------------------
  # Params
  # ----------------------------------------------------------
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

  bpm = PolyphonicConfig.sanitize_bpm(_parse_float(get(gp, "bpm", PolyphonicConfig.POLYPHONIC_BPM)))
  step_duration = PolyphonicConfig.step_duration_from_bpm(bpm)

  ctx_raw = get(gp, "initial_context", Any[])

  # Stream record (REQUIRED):
  #   [abs_notes::Vector{Int}, vol, bri, hrd, tex, chord_range::Int, density::Float64, sustain::Float64]
  #
  # initial_context MUST be a 3-level array:
  #   initial_context[step][stream] = stream_record
  results = Vector{Vector{Vector{Any}}}()

  if !(ctx_raw isa AbstractVector)
    error("generate_polyphonic.initial_context must be an Array of steps; each step is an Array of streams; each stream is [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain].")
  end

  for step in ctx_raw
    step isa AbstractVector || error("generate_polyphonic.initial_context: each step must be an Array of streams.")
    streams = Vector{Vector{Any}}()
    for st in step
      st isa AbstractVector || error("generate_polyphonic.initial_context: each stream must be an Array [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain].")
      push!(streams, Any[st...])
    end
    push!(results, streams)
  end

  # Defaults
  if isempty(results)
    push!(results, [Any[[Int(PolyphonicConfig.abs_pitch_min())], 1.0, 0.0, 0.0, 0.0, 0, 0.0, 0.5]])
  end

  # Indices for NEW format
  note_abs_idx    = 1
  vol_idx         = 2
  bri_idx         = 3
  hrd_idx         = 4
  tex_idx         = 5
  chord_range_idx = 6
  density_idx     = 7
  sustain_idx     = 8

  # --- MIDI range (keep consistent across AREA/tmp_anchor and NOTE) ---
  ABS_MIN = Int(PolyphonicConfig.abs_pitch_min())
  ABS_MAX = Int(PolyphonicConfig.abs_pitch_max())

  BAND_SIZE = PolyphonicConfig.AREA_BAND_SIZE
  BAND_LOW_MIN = PolyphonicConfig.area_band_low_min()
  BAND_LOW_MAX = PolyphonicConfig.area_band_low_max()
  BAND_WIDTH  = max(float(BAND_LOW_MAX - BAND_LOW_MIN), 1.0)
  CHORD_RANGE_MIN = PolyphonicConfig.CHORD_RANGE_VALUE_MIN
  CHORD_RANGE_MAX = PolyphonicConfig.CHORD_RANGE_VALUE_MAX

  function _quantize_sustain(x)::Float64
    return PolyphonicConfig.quantize_sustain(_parse_float(x))
  end

  function _canonical_dim_key(raw_key)::Union{Nothing,String}
    s = lowercase(strip(string(raw_key)))
    s in ("area",) && return "area"
    s in ("cr", "chord_range", "chordrange", "chord-range") && return "chord_range"
    s in ("den", "density") && return "density"
    s in ("sus", "sustain") && return "sustain"
    s in ("vol", "volume") && return "vol"
    s in ("bri", "brightness") && return "bri"
    s in ("hrd", "hardness") && return "hrd"
    s in ("tex", "texture") && return "tex"
    return nothing
  end

  function _normalize_fixed_value_for_dim(key::String, raw)
    if key == "chord_range"
      return float(clamp(_parse_int(raw), CHORD_RANGE_MIN, CHORD_RANGE_MAX))
    elseif key == "sustain"
      return _quantize_sustain(raw)
    elseif key == "area" || key == "density" || key == "vol" || key == "bri" || key == "hrd" || key == "tex"
      return clamp(_parse_float(raw), 0.0, 1.0)
    else
      return _parse_float(raw)
    end
  end

  managed_dims = ["area", "chord_range", "density", "sustain", "vol", "bri", "hrd", "tex"]
  dim_accept = Dict{String,Bool}()
  dim_fixed = Dict{String,Float64}()

  # Internal default policy:
  # - vol/bri/hrd/tex: disabled by default to reduce clustering/search cost in pitch-focused experiments
  # - others: enabled
  default_dim_policy = Dict{String,Dict{String,Any}}(
    "area" => Dict("accept_params" => true,  "fixed_value" => 0.5),
    "chord_range" => Dict("accept_params" => true, "fixed_value" => 0.0),
    "density" => Dict("accept_params" => true, "fixed_value" => 0.0),
    "sustain" => Dict("accept_params" => true, "fixed_value" => 0.5),
    "vol" => Dict("accept_params" => true, "fixed_value" => 1.0),
    "bri" => Dict("accept_params" => true, "fixed_value" => 0.0),
    "hrd" => Dict("accept_params" => true, "fixed_value" => 0.0),
    "tex" => Dict("accept_params" => true, "fixed_value" => 0.0),
  )
  for key in managed_dims
    d = default_dim_policy[key]
    dim_accept[key] = _parse_bool(get(d, "accept_params", true), true)
    dim_fixed[key] = _normalize_fixed_value_for_dim(key, get(d, "fixed_value", 0.0))
  end

  # Optional request-time override:
  # generate_polyphonic.dimension_policy = {
  #   vol: { accept_params: false, fixed_value: 1.0 }, cr: {...}, den: {...}, sus: {...}, ...
  # }
  raw_dim_policy = _to_string_dict(get(gp, "dimension_policy", nothing))
  for (raw_key, raw_val) in raw_dim_policy
    key = _canonical_dim_key(raw_key)
    key === nothing && continue

    if raw_val isa AbstractDict
      p = _to_string_dict(raw_val)
      accept_src =
        haskey(p, "accept_params") ? p["accept_params"] :
        haskey(p, "receive_params") ? p["receive_params"] :
        haskey(p, "enabled") ? p["enabled"] :
        haskey(p, "use_user_params") ? p["use_user_params"] : nothing
      fixed_src =
        haskey(p, "fixed_value") ? p["fixed_value"] :
        haskey(p, "fallback_value") ? p["fallback_value"] :
        haskey(p, "value") ? p["value"] : nothing

      if accept_src !== nothing
        dim_accept[key] = _parse_bool(accept_src, dim_accept[key])
      end
      if fixed_src !== nothing
        dim_fixed[key] = _normalize_fixed_value_for_dim(key, fixed_src)
      end
    elseif raw_val isa Bool
      dim_accept[key] = raw_val
    elseif raw_val !== nothing
      dim_fixed[key] = _normalize_fixed_value_for_dim(key, raw_val)
    end
  end

  function _apply_fixed_dimension_values!(st::Vector{Any})
    if !get(dim_accept, "vol", true)
      st[vol_idx] = dim_fixed["vol"]
    end
    if !get(dim_accept, "bri", true)
      st[bri_idx] = dim_fixed["bri"]
    end
    if !get(dim_accept, "hrd", true)
      st[hrd_idx] = dim_fixed["hrd"]
    end
    if !get(dim_accept, "tex", true)
      st[tex_idx] = dim_fixed["tex"]
    end
    if !get(dim_accept, "chord_range", true)
      st[chord_range_idx] = Int(round(clamp(dim_fixed["chord_range"], float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX))))
    end
    if !get(dim_accept, "density", true)
      st[density_idx] = dim_fixed["density"]
    end
    if !get(dim_accept, "sustain", true)
      st[sustain_idx] = _quantize_sustain(dim_fixed["sustain"])
    end
    return st
  end

  function _fixed_area_band_low()::Int
    v01 = clamp(dim_fixed["area"], 0.0, 1.0)
    n_bins = max(Int(fld(BAND_LOW_MAX - BAND_LOW_MIN, BAND_SIZE)), 0)
    idx = clamp(round(Int, v01 * n_bins), 0, n_bins)
    return clamp(BAND_LOW_MIN + (idx * BAND_SIZE), BAND_LOW_MIN, BAND_LOW_MAX)
  end


  function _normalize_abs_notes(x)::Vector{Int}
    out = Int[]
    if x isa AbstractVector
      for v in x
        v === nothing && continue
        push!(out, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
      end
    elseif x === nothing
      # noop
    else
      push!(out, clamp(_parse_int(x), ABS_MIN, ABS_MAX))
    end
    sort!(out)
    isempty(out) && push!(out, Int(PolyphonicConfig.abs_pitch_min()))
    return out
  end
  function _normalize_pcs(x)::Vector{Int}
    pcs = Int[]
    if x isa AbstractVector
      for v in x
        v === nothing && continue
        push!(pcs, ((_parse_int(v) % 12) + 12) % 12)
      end
    elseif x === nothing
      # noop
    else
      push!(pcs, ((_parse_int(x) % 12) + 12) % 12)
    end
    isempty(pcs) && push!(pcs, 0)
    sort!(pcs)
    return pcs
  end
  function _normalize_stream!(st::Vector{Any})
    # Accept both:
    # - strict: [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain]
    # - legacy: [octave, pcs, vol, bri, hrd, tex, (optional sustain)]
    length(st) >= 6 || error("generate_polyphonic.initial_context stream record must be strict [abs_notes, vol, bri, hrd, tex, chord_range, density, sustain] or legacy [octave, pcs, vol, bri, hrd, tex, sustain?].")

    abs_notes = Int[]
    vol = 1.0
    bri = 0.0
    hrd = 0.0
    tex = 0.0
    cr  = 0
    den = 0.0
    sus = 0.5

    if st[1] isa AbstractVector
      # strict
      abs_notes = _normalize_abs_notes(st[1])
      vol = clamp(_parse_float(length(st) >= 2 ? st[2] : 1.0), 0.0, 1.0)
      bri = clamp(_parse_float(length(st) >= 3 ? st[3] : 0.0), 0.0, 1.0)
      hrd = clamp(_parse_float(length(st) >= 4 ? st[4] : 0.0), 0.0, 1.0)
      tex = clamp(_parse_float(length(st) >= 5 ? st[5] : 0.0), 0.0, 1.0)
      cr  = max(_parse_int(length(st) >= 6 ? st[6] : 0), 0)
      den = clamp(_parse_float(length(st) >= 7 ? st[7] : 0.0), 0.0, 1.0)
      sus = length(st) >= 8 ? _quantize_sustain(st[8]) : 0.5
    else
      # legacy
      oct = _parse_int(st[1])
      pcs = _normalize_pcs(st[2])
      base_c = PolyphonicConfig.base_c_midi(oct)
      abs_notes = _normalize_abs_notes(Int[base_c + pc for pc in pcs])
      vol = clamp(_parse_float(length(st) >= 3 ? st[3] : 1.0), 0.0, 1.0)
      bri = clamp(_parse_float(length(st) >= 4 ? st[4] : 0.0), 0.0, 1.0)
      hrd = clamp(_parse_float(length(st) >= 5 ? st[5] : 0.0), 0.0, 1.0)
      tex = clamp(_parse_float(length(st) >= 6 ? st[6] : 0.0), 0.0, 1.0)
      # legacy slot 7 is treated as sustain when in [0,1], otherwise ignored
      if length(st) >= 7
        v7 = _parse_float(st[7])
        if 0.0 <= v7 <= 1.0
          sus = _quantize_sustain(v7)
        end
      end
    end

    empty!(st)
    push!(st, abs_notes, vol, bri, hrd, tex, cr, den, sus)
    return st
  end

  for step in results
    for st in step
      _normalize_stream!(st)
      _apply_fixed_dimension_values!(st)
    end
  end

  merge_threshold_ratio = _parse_float(get(gp, "merge_threshold_ratio", PolyphonicConfig.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO))
  min_window = PolyphonicConfig.POLYPHONIC_MIN_WINDOW_SIZE

  function pad_history!(mat, fallback_row)
    if length(mat) < (min_window + 1)
      last_row = !isempty(mat) ? deepcopy(mat[end]) : deepcopy(fallback_row)
      for _ in 1:((min_window + 1) - length(mat))
        push!(mat, deepcopy(last_row))
      end
    end
    return mat
  end

  function pad_series!(ser::Vector{Vector{Float64}}, fallback::Vector{Float64})
    if length(ser) < (min_window + 1)
      last_row = !isempty(ser) ? deepcopy(ser[end]) : deepcopy(fallback)
      for _ in 1:((min_window + 1) - length(ser))
        push!(ser, deepcopy(last_row))
      end
    end
    return ser
  end

  function _anchor_from_abs(abs_notes)::Int
    if abs_notes isa AbstractVector && !isempty(abs_notes)
      s = sort(Int[_parse_int(x) for x in abs_notes])
      return clamp(s[cld(length(s), 2)], ABS_MIN, ABS_MAX)
    else
      return Int(PolyphonicConfig.abs_pitch_min())
    end
  end

  function _global_anchor_from_step(step)::Int
    alln = Int[]
    for st in step
      abs_notes = st[note_abs_idx]
      if abs_notes isa AbstractVector
        for v in abs_notes
          push!(alln, clamp(_parse_int(v), ABS_MIN, ABS_MAX))
        end
      end
    end
    isempty(alln) && push!(alln, Int(PolyphonicConfig.abs_pitch_min()))
    sort!(alln)
    return alln[cld(length(alln), 2)]
  end

  # ----------------------------------------------------------
  # Histories
  # ----------------------------------------------------------
  function matrix_for_idx(idx::Int)
    return [ [ (length(st) >= idx ? st[idx] : 0) for st in step ] for step in results ]
  end

  hist_vol  = matrix_for_idx(vol_idx)
  hist_bri  = matrix_for_idx(bri_idx)
  hist_hrd  = matrix_for_idx(hrd_idx)
  hist_tex  = matrix_for_idx(tex_idx)
  hist_cr   = matrix_for_idx(chord_range_idx)
  hist_den  = matrix_for_idx(density_idx)
  hist_sus  = matrix_for_idx(sustain_idx)

  hist_note_anchor = Vector{Vector{Int}}()
  note_global_series = Vector{Vector{Float64}}()

  for step in results
    row = Int[]
    for st in step
      push!(row, _anchor_from_abs(st[note_abs_idx]))
    end
    push!(hist_note_anchor, row)
    push!(note_global_series, Float64[float(_global_anchor_from_step(step))])
  end

    # area(tmp_anchor) history: 4-semitone band base (0..124)
  hist_area_tmp_anchor = Vector{Vector{Int}}()
  for row in hist_note_anchor
    tmp = Int[]
    for a in row
      push!(tmp, PolyphonicConfig.area_band_low(a))
    end
    push!(hist_area_tmp_anchor, tmp)
  end


  first_streams = max(get(stream_counts, 1, 1), 1)

  pad_history!(hist_vol,  [1.0 for _ in 1:first_streams])
  pad_history!(hist_bri,  [0.0 for _ in 1:first_streams])
  pad_history!(hist_hrd,  [0.0 for _ in 1:first_streams])
  pad_history!(hist_tex,  [0.0 for _ in 1:first_streams])
  pad_history!(hist_cr,   [0   for _ in 1:first_streams])
  pad_history!(hist_den,  [0.0 for _ in 1:first_streams])
  pad_history!(hist_sus,  [0.5 for _ in 1:first_streams])
  pad_history!(hist_note_anchor, [Int(PolyphonicConfig.abs_pitch_min()) for _ in 1:first_streams])
  pad_history!(hist_area_tmp_anchor, [PolyphonicConfig.area_band_low(PolyphonicConfig.abs_pitch_min()) for _ in 1:first_streams])

  pad_series!(note_global_series, Float64[float(PolyphonicConfig.abs_pitch_min())])

  max_streams = first_streams
  if !isempty(stream_counts)
    max_streams = max(max_streams, maximum(stream_counts))
  end
  for step in results
    max_streams = max(max_streams, length(step))
  end

  # ----------------------------------------------------------
  # Managers
  # ----------------------------------------------------------
  managers = Dict{String,Dict{Symbol,Any}}()

  function _safe_width(vmin::Real, vmax::Real)::Float64
    width = abs(float(vmax) - float(vmin))
    return width <= 0.0 ? 1.0 : width
  end

  function offset_for_range(vmin::Real, vmax::Real)::Float64
    return _safe_width(vmin, vmax) + 1.0
  end

  function global_series_from_matrix(mat, offset::Real)
    series = Vector{Vector{Float64}}()
    for row in mat
      vals = Float64[]
      sizehint!(vals, length(row))
      for (i, x) in enumerate(row)
        push!(vals, float(x) + (i - 1) * float(offset))
      end
      push!(series, vals)
    end
    return series
  end

  function _setup_dimension_manager!(
    key::String,
    history,
    value_range;
    value_min::Real,
    value_max::Real,
    track_presence::Bool=false
  )
    offset = offset_for_range(value_min, value_max)
    s_mgr = MultiStreamManager.Manager(
      history,
      merge_threshold_ratio,
      min_window;
      use_complexity_mapping=true,
      value_range=value_range,
      track_presence=track_presence
    )
    g_mgr = PolyphonicClusterManager.Manager(
      global_series_from_matrix(history, offset),
      merge_threshold_ratio,
      min_window;
      value_min=float(value_min),
      value_max=float(value_max) + (float(max_streams - 1) * offset),
      max_set_size=max_streams
    )
    PolyphonicClusterManager.process_data!(g_mgr)
    PolyphonicClusterManager.update_caches_permanently(
      g_mgr,
      create_quadratic_integer_array(0, _safe_width(value_min, value_max) * length(g_mgr.data), length(g_mgr.data))
    )
    managers[key] = Dict(:global => g_mgr, :stream => s_mgr, :global_offset => offset)
  end

  for (key, history, track_presence) in (
    ("vol", hist_vol, true),
    ("bri", hist_bri, false),
    ("hrd", hist_hrd, false),
    ("tex", hist_tex, false)
  )
    if get(dim_accept, key, true)
      _setup_dimension_manager!(
        key,
        history,
        PolyphonicConfig.FLOAT_STEPS;
        value_min=0.0,
        value_max=1.0,
        track_presence=track_presence
      )
    end
  end

  cr_values = collect(PolyphonicConfig.CHORD_RANGE_SEARCH_RANGE)
  cr_min = float(first(PolyphonicConfig.CHORD_RANGE_SEARCH_RANGE))
  cr_max = float(last(PolyphonicConfig.CHORD_RANGE_SEARCH_RANGE))
  if get(dim_accept, "chord_range", true)
    _setup_dimension_manager!(
      "chord_range",
      hist_cr,
      cr_values;
      value_min=cr_min,
      value_max=cr_max,
      track_presence=true
    )
  end

  if get(dim_accept, "density", true)
    _setup_dimension_manager!(
      "density",
      hist_den,
      PolyphonicConfig.FLOAT_STEPS;
      value_min=0.0,
      value_max=1.0,
      track_presence=true
    )
  end

  if get(dim_accept, "sustain", true)
    _setup_dimension_manager!(
      "sustain",
      hist_sus,
      PolyphonicConfig.SUSTAIN_LEVELS;
      value_min=0.0,
      value_max=1.0,
      track_presence=true
    )
  end

  area_min = float(BAND_LOW_MIN)
  area_max = float(BAND_LOW_MAX)
  _setup_dimension_manager!(
    "area",
    hist_area_tmp_anchor,
    collect(BAND_LOW_MIN:BAND_SIZE:BAND_LOW_MAX);
    value_min=area_min,
    value_max=area_max,
    track_presence=true
  )

  # note (global: scalar anchor, stream: anchor per stream)
  note_min = float(ABS_MIN)
  note_max = float(ABS_MAX)
  s_note = MultiStreamManager.Manager(hist_note_anchor, merge_threshold_ratio, min_window; use_complexity_mapping=true, value_range=collect(ABS_MIN:ABS_MAX), track_presence=true)
  g_note = PolyphonicClusterManager.Manager(note_global_series, merge_threshold_ratio, min_window; value_min=note_min, value_max=note_max, max_set_size=1)
  PolyphonicClusterManager.process_data!(g_note)
  PolyphonicClusterManager.update_caches_permanently(g_note, create_quadratic_integer_array(0, (note_max - note_min) * length(g_note.data), length(g_note.data)))
  managers["note"] = Dict(:global => g_note, :stream => s_note)

  # ----------------------------------------------------------
  # Dissonance STM seed
  # ----------------------------------------------------------
  stm_mgr = DissonanceStmManager.Manager(
    memory_span=PolyphonicConfig.DISSONANCE_STM_MEMORY_SPAN,
    memory_weight=PolyphonicConfig.DISSONANCE_STM_MEMORY_WEIGHT,
    n_partials=PolyphonicConfig.DISSONANCE_STM_N_PARTIALS,
    amp_profile=PolyphonicConfig.DISSONANCE_STM_AMP_PROFILE
  )

  for (i, step) in enumerate(results)
    midi_notes = Int[]
    amps = Float64[]
    for st in step
      abs_notes = _normalize_abs_notes(st[note_abs_idx])
      vol = clamp(_parse_float(st[vol_idx]), 0.0, 1.0)
      a_each = isempty(abs_notes) ? vol : (vol / float(length(abs_notes)))
      for n in abs_notes
        push!(midi_notes, n)
        push!(amps, a_each)
      end
    end
    onset = (i - 1) * step_duration
    DissonanceStmManager.commit!(stm_mgr, midi_notes, amps, onset)
  end

  steps_to_generate = length(stream_counts)
  base_step_index = length(results)
  flush(stdout)

  function _iter_combinations_range(low::Int, high::Int, k::Int)
    # returns Vector{Vector{Int}} of combinations from [low..high], size k
    n = (high - low + 1)
    if k <= 0 || k > n
      return Vector{Vector{Int}}()
    end
    idxs = collect(1:k)
    out = Vector{Vector{Int}}()
    while true
      push!(out, [low + (i - 1) for i in idxs])
      pos = k
      while pos >= 1 && idxs[pos] == (n - k + pos)
        pos -= 1
      end
      pos < 1 && break
      idxs[pos] += 1
      for j in (pos+1):k
        idxs[j] = idxs[j-1] + 1
      end
    end
    return out
  end

  function _restrict_candidates_with_target_window(
    key::String,
    search_values::Vector{Float64},
    idx0::Int
  )::Vector{Float64}
    if !(key == "vol" || key == "bri" || key == "hrd" || key == "tex" || key == "chord_range" || key == "density" || key == "sustain")
      return search_values
    end

    isempty(search_values) && return search_values

    target_raw = array_param(gp, "$(key)_target", idx0)
    spread_raw = array_param(gp, "$(key)_target_spread", idx0)
    if target_raw === nothing && spread_raw === nothing
      return search_values
    end

    vmin = minimum(search_values)
    vmax = maximum(search_values)
    default_target = (vmin + vmax) / 2.0
    default_spread = (vmax - vmin)

    target = clamp(_parse_float(target_raw === nothing ? default_target : target_raw), vmin, vmax)
    spread = abs(_parse_float(spread_raw === nothing ? default_spread : spread_raw))

    low = clamp(target - spread, vmin, vmax)
    high = clamp(target + spread, vmin, vmax)

    filtered = Float64[v for v in search_values if v >= (low - 1e-9) && v <= (high + 1e-9)]
    if !isempty(filtered)
      return filtered
    end

    nearest_idx = 1
    nearest_dist = Inf
    for (i, v) in enumerate(search_values)
      d = abs(v - target)
      if d < nearest_dist
        nearest_dist = d
        nearest_idx = i
      end
    end
    return Float64[search_values[nearest_idx]]
  end

  # ----------------------------------------------------------
  # Main generation loop
  # ----------------------------------------------------------
  for step_idx in 1:steps_to_generate
    desired_stream_count = max(stream_counts[step_idx], 1)

    st_target = step_idx <= length(strength_targets) ? strength_targets[step_idx] : PolyphonicConfig.DEFAULT_TARGET_01
    st_spread = step_idx <= length(strength_spreads) ? strength_spreads[step_idx] : PolyphonicConfig.DEFAULT_SPREAD_01

    lifecycle_mgr = haskey(managers, "vol") ? managers["vol"][:stream] : managers["note"][:stream]
    plan = MultiStreamManager.build_stream_lifecycle_plan(lifecycle_mgr, desired_stream_count; target=st_target, spread=st_spread)
    for (_k, mgrs) in managers
      MultiStreamManager.apply_stream_lifecycle_plan!(mgrs[:stream], plan)
    end

    current_step_values = [
      Any[
        Int[],
        clamp(dim_fixed["vol"], 0.0, 1.0),
        clamp(dim_fixed["bri"], 0.0, 1.0),
        clamp(dim_fixed["hrd"], 0.0, 1.0),
        clamp(dim_fixed["tex"], 0.0, 1.0),
        Int(round(clamp(dim_fixed["chord_range"], float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))),
        clamp(dim_fixed["density"], 0.0, 1.0),
        _quantize_sustain(dim_fixed["sustain"])
      ] for _ in 1:desired_stream_count
    ]
    step_decisions = Dict{String,Any}()

    idx0 = step_idx - 1

    vol_search_values = Float64[float(v) for v in PolyphonicConfig.FLOAT_STEPS]
    density_search_values = Float64[float(v) for v in PolyphonicConfig.FLOAT_STEPS]
    chord_range_search_values = Float64[float(v) for v in cr_values]
    sustain_search_values = Float64[float(v) for v in PolyphonicConfig.SUSTAIN_LEVELS]

    dim_order = [
      ("vol",         vol_search_values,         vol_idx),
      ("chord_range", chord_range_search_values, chord_range_idx),
      ("density",     density_search_values,     density_idx),
      ("sustain",     sustain_search_values,     sustain_idx),
      ("bri",         Float64[float(v) for v in PolyphonicConfig.FLOAT_STEPS], bri_idx),
      ("hrd",         Float64[float(v) for v in PolyphonicConfig.FLOAT_STEPS], hrd_idx),
      ("tex",         Float64[float(v) for v in PolyphonicConfig.FLOAT_STEPS], tex_idx),
    ]

    for (key, range_vec, out_idx) in dim_order
      if !get(dim_accept, key, true)
        fixed_v =
          if key == "chord_range"
            float(Int(round(clamp(dim_fixed["chord_range"], float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX)))))
          elseif key == "sustain"
            _quantize_sustain(dim_fixed["sustain"])
          else
            clamp(dim_fixed[key], 0.0, 1.0)
          end
        fixed_vals = fill(float(fixed_v), desired_stream_count)
        step_decisions[key] = fixed_vals
        for s_i in 1:desired_stream_count
          if key == "chord_range"
            current_step_values[s_i][out_idx] = Int(round(fixed_v))
          else
            current_step_values[s_i][out_idx] = fixed_v
          end
        end
        continue
      end

      mgrs = get(managers, key, nothing)
      mgrs === nothing && error("managers[\"$(key)\"] is missing while the dimension is enabled.")

      g_target = clamp(_parse_float(array_param(gp, "$(key)_global", idx0)), 0.0, 1.0)
      s_center = clamp(_parse_float(array_param(gp, "$(key)_center", idx0)), 0.0, 1.0)
      s_spread = clamp(_parse_float(array_param(gp, "$(key)_spread", idx0)), 0.0, 1.0)
      conc_w   = _parse_float(array_param(gp, "$(key)_conc", idx0))

      stream_targets = generate_centered_targets(desired_stream_count, s_center, s_spread)

      gl = mgrs[:global]
      vmin = float(minimum(range_vec))
      vmax = float(maximum(range_vec))
      width = abs(vmax - vmin)
      width = width <= 0.0 ? 1.0 : width
      len_next = length(gl.data) + 1
      q_array = create_quadratic_integer_array(0, width * len_next, len_next)

      restricted_range = _restrict_candidates_with_target_window(key, range_vec, idx0)
      isempty(restricted_range) && (restricted_range = range_vec)

      stream_costs = MultiStreamManager.precalculate_costs(mgrs[:stream], restricted_range, q_array, desired_stream_count)

      candidates = Vector{Vector{Float64}}()
      if desired_stream_count == 1
        candidates = [Float64[float(v)] for v in restricted_range]
      elseif key == "chord_range" || key == "density"
        # enforce global scalar: all streams share the same value (search space reduced)
        candidates = [Float64[fill(float(v), desired_stream_count)...] for v in restricted_range]
      else
        candidates = repeated_combinations(Float64[float(v) for v in restricted_range], desired_stream_count)
      end

      best_vals, _ = select_best_chord_for_dimension_with_cost(
        mgrs,
        candidates,
        stream_costs,
        q_array,
        g_target,
        stream_targets,
        conc_w,
        desired_stream_count,
        Float64[float(v) for v in restricted_range]
      )

      # commit (global manager expects stream-offset encoding)
      g_offset = get(mgrs, :global_offset, 0.0)
      global_vals = Float64[float(best_vals[i]) + (i - 1) * float(g_offset) for i in 1:desired_stream_count]
      PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], global_vals)
      PolyphonicClusterManager.update_caches_permanently(mgrs[:global], q_array)

      if key == "vol"
        MultiStreamManager.commit_state!(mgrs[:stream], best_vals, q_array; strength_params=(target=st_target, spread=st_spread))
      else
        MultiStreamManager.commit_state!(mgrs[:stream], best_vals, q_array)
      end
      MultiStreamManager.update_caches_permanently!(mgrs[:stream], q_array)

      step_decisions[key] = best_vals

      for s_i in 1:desired_stream_count
        if key == "chord_range"
          current_step_values[s_i][out_idx] = Int(trunc(best_vals[s_i]))
        else
          current_step_values[s_i][out_idx] = clamp(float(best_vals[s_i]), 0.0, 1.0)
        end
      end
    end

    # --------------------------------------------------------
    # NOTE generation (AREA tmp_anchor manager -> chord_range/density -> dissonance)
    #   - Evaluate/commit AREA using tmp_anchor clusters (managers["area"])
    #   - Then decide realized notes per stream by dissonance within the allowed band expanded by chord_range/density
    # --------------------------------------------------------
    area_mgrs = get(managers, "area", nothing)
    area_mgrs === nothing && error("managers[\"area\"] is missing. Please add AREA(tmp_anchor) managers before the main loop.")
    note_mgrs = managers["note"]

    # ---- AREA targets (same style as other dims) ----

    area_enabled = get(dim_accept, "area", true)
    area_fixed_target = clamp(dim_fixed["area"], 0.0, 1.0)
    area_global_target = area_enabled ? clamp(_parse_float(array_param(gp, "area_global", idx0)), 0.0, 1.0) : area_fixed_target
    area_center        = area_enabled ? clamp(_parse_float(array_param(gp, "area_center", idx0)), 0.0, 1.0) : area_fixed_target
    area_spread        = area_enabled ? clamp(_parse_float(array_param(gp, "area_spread", idx0)), 0.0, 1.0) : 0.0
    area_conc_w        = area_enabled ? _parse_float(array_param(gp, "area_conc", idx0)) : 1.0

    area_stream_targets = generate_centered_targets(desired_stream_count, area_center, area_spread)
    stream_pool = area_mgrs[:stream].stream_pool

    # AREA is an intermediate decision (4-semitone band base). If we base the next AREA on realized notes,
    # dissonance/chord_range/density can "drag" the anchor and collapse AREA complexity.
    prev_tmp_anchors = Int[]
    sizehint!(prev_tmp_anchors, desired_stream_count)
    for s in 1:desired_stream_count
      if s <= length(stream_pool)
        lv = stream_pool[s].last_value
        a = isempty(lv) ? float(BAND_LOW_MIN) : lv[1]
        push!(prev_tmp_anchors, clamp(trunc(Int, a), BAND_LOW_MIN, BAND_LOW_MAX))
      else
        push!(prev_tmp_anchors, BAND_LOW_MIN)
      end
    end

  # ---- helper: build bin-derived tmp_anchor candidates (skip out-of-range; NO clamp-to-edge) ----
  # tmp_anchor is band_low (4-semitone band base)
  per_stream_anchor_candidates = Vector{Vector{Int}}()
  sizehint!(per_stream_anchor_candidates, desired_stream_count)

  for s in 1:desired_stream_count
    pa = prev_tmp_anchors[s]
    cand = Int[]
    seen = Set{Int}()
    for (lo, hi) in PolyphonicConfig.AREA_MOVE_BINS
      for d in lo:hi
        a = pa + d
        # skip deltas that go out of configured MIDI range (no clamp, no sticking)
        (a < ABS_MIN || a > ABS_MAX) && continue

        # quantize to AREA band base
        band_low = PolyphonicConfig.area_band_low(a)
        if !(band_low in seen)
          push!(cand, band_low)
          push!(seen, band_low)
        end
      end
    end

    if isempty(cand)
      # fallback: stay at current anchor's band
      push!(cand, PolyphonicConfig.area_band_low(pa))
    end

    sort!(cand)
    push!(per_stream_anchor_candidates, cand)
  end


# ---- Stage 1: prune each stream's bins using AGREEMENT of (d,q,c) ----

# NOTE:
# - Stage1 は「候補枝刈り」なので、multi-stream なら TOP>=3 を推奨
# - 1stream だけなら TOP=1 でもOK
top_bins_per_stream =
  desired_stream_count == 1 ?
  PolyphonicConfig.AREA_TOP_BINS_PER_STREAM_SINGLE :
  PolyphonicConfig.AREA_TOP_BINS_PER_STREAM_MULTI

per_stream_comp01 = Vector{Dict{Int,Float64}}()
top_anchors = Vector{Vector{Int}}()
sizehint!(per_stream_comp01, desired_stream_count)
sizehint!(top_anchors, desired_stream_count)

for s in 1:desired_stream_count
  sm = stream_pool[s].manager
  anchors = per_stream_anchor_candidates[s]

  # q-array for THIS stream manager length
  len_next_s = length(sm.data) + 1
  q_s = create_quadratic_integer_array(0, (note_max - note_min) * len_next_s, len_next_s)

  raw_d = Float64[]  # avg_dist (complex when larger)
  raw_q = Float64[]  # quantity (complex when smaller)
  raw_c = Float64[]  # complexity (complex when larger)
  sizehint!(raw_d, length(anchors))
  sizehint!(raw_q, length(anchors))
  sizehint!(raw_c, length(anchors))

  pa = prev_tmp_anchors[s]

  for a in anchors
    _d, _q, c = PolyphonicClusterManager.simulate_add_and_calculate(sm, Float64[float(a)], q_s)

    dval = (isfinite(_d) ? float(_d) : 0.0)
    qval = (isfinite(_q) ? float(_q) : 0.0)
    cval = (isfinite(c)  ? float(c)  : 0.0)

    push!(raw_d, dval)
    push!(raw_q, qval)
    push!(raw_c, cval)
  end

  # normalize each criterion like generate():
  # d: larger => complex
  # q: smaller => complex
  # c: larger => complex
  d01, wd = normalize_scores(raw_d, true)
  q01, wq = normalize_scores(raw_q, false)
  c01, wc = normalize_scores(raw_c, true)

  # unweight back to 0..1 (normalize_scores は weight を掛けて返してくる想定)
  if wd > 0.0; d01 = d01 ./ wd; end
  if wq > 0.0; q01 = q01 ./ wq; end
  if wc > 0.0; c01 = c01 ./ wc; end

  # agreement (weighted by each criterion's reliability weight)
  denom = wd + wq + wc
  denom = (denom > 0.0) ? denom : 1.0

  m = Dict{Int,Float64}()
  for (i, a) in enumerate(anchors)
    score =
      (wd * d01[i] + wq * q01[i] + wc * c01[i]) / denom
    m[a] = clamp(score, 0.0, 1.0)
  end
  push!(per_stream_comp01, m)

  # rank by |score - target|
  t = area_stream_targets[s]
  prefer_big_jump = t >= 0.5

  ranked = Vector{Tuple{Float64,Float64,Int}}()  # (cost, tiebreak, anchor)
  sizehint!(ranked, length(anchors))

  for a in anchors
    cost = abs(m[a] - t)
    jump = abs(float(a) - float(pa))          # 実ジャンプ量
    tb   = prefer_big_jump ? -jump : jump     # target高いなら大ジャンプ優先
    push!(ranked, (cost, tb, a))
  end
  sort!(ranked, by=x->(x[1], x[2], x[3]))

  keep = Int[]
  for i in 1:min(top_bins_per_stream, length(ranked))
    push!(keep, ranked[i][3])
  end
  isempty(keep) && push!(keep, anchors[1])
  sort!(keep)
  push!(top_anchors, keep)

end

# ---- Stage 2: build candidate vectors (cartesian over pruned bins) ----

    # ---- Stage 2: build candidate vectors (cartesian over pruned bins) ----
    area_candidates = Vector{Vector{Int}}()
    area_candidates = [Int[]]
    for s in 1:desired_stream_count
      newc = Vector{Vector{Int}}()
      for base in area_candidates
        for a in top_anchors[s]
          push!(newc, vcat(base, a))
        end
      end
      area_candidates = newc
    end

    # ---- Stage 3: evaluate candidates by GLOBAL area complexity + stream targets + conc ----
    area_gl = area_mgrs[:global]
    area_offset = float(get(area_mgrs, :global_offset, offset_for_range(area_min, area_max)))

    # q-array for global manager length
    len_next_g = length(area_gl.data) + 1
    q_g = create_quadratic_integer_array(0, (note_max - note_min) * len_next_g, len_next_g)

    global_raws = Float64[]
    sizehint!(global_raws, length(area_candidates))

    for cand in area_candidates
      enc = Float64[]
      sizehint!(enc, desired_stream_count)
      for i in 1:desired_stream_count
        push!(enc, float(cand[i]) + (i - 1) * area_offset)
      end

      _d, _q, c = PolyphonicClusterManager.simulate_add_and_calculate(area_gl, enc, q_g)
      push!(global_raws, isfinite(c) ? float(c) : 0.0)
    end

    global_comp01s, w = normalize_scores(global_raws, true)
    if w > 0.0
      global_comp01s = global_comp01s ./ w
    end

    best_area_idx = 1
    best_area_cost = Inf
    # tie-break policy: when target is high, prefer larger jumps (to realize "random-ish" area moves)
    target_mean = (area_global_target + (sum(area_stream_targets) / float(desired_stream_count))) / 2.0
    prefer_big_jump = target_mean >= 0.5

    best_area_tiebreak = prefer_big_jump ? -Inf : Inf

    for (i, cand) in enumerate(area_candidates)
      g_cost = abs(global_comp01s[i] - area_global_target)

      # stream cost: mean |comp01(stream, anchor) - target(stream)|
      s_cost_sum = 0.0
      for s in 1:desired_stream_count
        a = cand[s]
        c01 = get(per_stream_comp01[s], a, 0.0)
        s_cost_sum += abs(c01 - area_stream_targets[s])
      end
      s_cost = s_cost_sum / float(desired_stream_count)

      # conc cost (simple & deterministic):
      #   conc_w > 0 : prefer small spread
      #   conc_w < 0 : prefer large spread
      conc_cost = 0.0
      if desired_stream_count >= 2 && abs(area_conc_w) > 1e-12
        # mean pairwise distance normalized
        dist_sum = 0.0
        cnt = 0
        for a in 1:(desired_stream_count-1)
          for b in (a+1):desired_stream_count
            dist_sum += abs(float(cand[a]) - float(cand[b]))
            cnt += 1
          end
        end
        spread01 = cnt == 0 ? 0.0 : clamp((dist_sum / float(cnt)) / BAND_WIDTH, 0.0, 1.0)
        if area_conc_w > 0
          conc_cost = abs(area_conc_w) * spread01
        else
          conc_cost = abs(area_conc_w) * (1.0 - spread01)
        end
      end

      total = g_cost + s_cost + conc_cost

      # tie-break: smaller average jump vs prev
      jump = 0.0
      for s in 1:desired_stream_count
        jump += abs(float(cand[s]) - float(prev_tmp_anchors[s]))
      end
      jump = jump / float(desired_stream_count)

      tie_ok = prefer_big_jump ? (jump > best_area_tiebreak + 1e-12) : (jump < best_area_tiebreak - 1e-12)

      if (total < best_area_cost - 1e-12) || (abs(total - best_area_cost) <= 1e-12 && tie_ok)
        best_area_cost = total
        best_area_idx = i
        best_area_tiebreak = jump
      end
    end

    chosen_area = area_candidates[best_area_idx]  # Int per stream (tmp_anchor = band_low)
    if !area_enabled
      fixed_band = _fixed_area_band_low()
      chosen_area = Int[fill(fixed_band, desired_stream_count)...]
    end

    # ---- Commit AREA(tmp_anchor) managers (NOW consistent with evaluation) ----
    # global: stream-offset encoding
    enc_best = Float64[float(chosen_area[i]) + (i - 1) * area_offset for i in 1:desired_stream_count]
    PolyphonicClusterManager.add_data_point_permanently(area_gl, enc_best)
    PolyphonicClusterManager.update_caches_permanently(area_gl, q_g)

    # stream: commit per-stream anchors
    chosen_area_f = Float64[float(chosen_area[s]) for s in 1:desired_stream_count]
    MultiStreamManager.commit_state!(area_mgrs[:stream], chosen_area_f, q_g)
    MultiStreamManager.update_caches_permanently!(area_mgrs[:stream], q_g)

    # ---- Decide realized notes per stream (within band + chord_range, size by density, choose by dissonance LAST) ----
    onset = float(base_step_index + idx0) * step_duration

    dis_target_raw = array_param(gp, "dissonance_target", idx0)
    target01 = dis_target_raw === nothing ? PolyphonicConfig.DEFAULT_TARGET_01 : clamp(_parse_float(dis_target_raw), 0.0, 1.0)

    # vols for amplitude (already decided in dim_order)
    vols = Float64[clamp(_parse_float(current_step_values[s][vol_idx]), 0.0, 1.0) for s in 1:desired_stream_count]
    stream_chord_candidates = Vector{Vector{Vector{Int}}}(undef, desired_stream_count)
    selected_chords = Vector{Vector{Int}}(undef, desired_stream_count)

    for s in 1:desired_stream_count
      band_low  = chosen_area[s]
      band_high = min(band_low + (BAND_SIZE - 1), ABS_MAX)

      chord_range_val = clamp(Int(trunc(step_decisions["chord_range"][s])), CHORD_RANGE_MIN, CHORD_RANGE_MAX)
      density_val     = clamp(float(step_decisions["density"][s]), 0.0, 1.0)

      low  = clamp(band_low  - chord_range_val, ABS_MIN, ABS_MAX)
      high = clamp(band_high + chord_range_val, ABS_MIN, ABS_MAX)
      slot_count = max(high - low + 1, 1)

      n_notes = clamp(Int(round(density_val * float(slot_count))), 1, slot_count)

      chords = _iter_combinations_range(low, high, n_notes)
      if isempty(chords)
        chords = Vector{Vector{Int}}([Int[band_low]])
      end

      stream_chord_candidates[s] = chords
      selected_chords[s] = copy(chords[1])
    end

    function _build_global_notes(chords_per_stream::Vector{Vector{Int}})
      midi_notes_all = Int[]
      amps_all = Float64[]
      for s in 1:desired_stream_count
        chord = chords_per_stream[s]
        v = vols[s]
        a_each = isempty(chord) ? v : (v / float(length(chord)))
        for n in chord
          push!(midi_notes_all, n)
          push!(amps_all, a_each)
        end
      end
      return midi_notes_all, amps_all
    end

    # Dissonance selection is done on pitch-class-normalized MIDI notes so octave distance
    # does not dominate roughness ranking (e.g. 12 vs 60 are treated as same pitch class).
    function _pc_normalized_notes(midi_notes::Vector{Int})
      out = Int[]
      sizehint!(out, length(midi_notes))
      for n in midi_notes
        pc = mod(n, 12)
        push!(out, 60 + pc)  # C4 + pitch class
      end
      return out
    end

    # Evaluate global dissonance on full cartesian product of stream candidates.
    current_combo = Vector{Vector{Int}}(undef, desired_stream_count)
    best_combo = Vector{Vector{Int}}(undef, desired_stream_count)
    for s in 1:desired_stream_count
      best_combo[s] = copy(selected_chords[s])
    end

    function _enumerate_combinations!(s::Int, visitor)
      if s > desired_stream_count
        visitor(current_combo)
        return
      end
      cands = stream_chord_candidates[s]
      isempty(cands) && return
      for cand in cands
        current_combo[s] = cand
        _enumerate_combinations!(s + 1, visitor)
      end
    end

    min_r = Inf
    max_r = -Inf
    _enumerate_combinations!(1, combo -> begin
      midi_notes_all, amps_all = _build_global_notes(combo)
      eval_notes = _pc_normalized_notes(midi_notes_all)
      d = float(DissonanceStmManager.evaluate(stm_mgr, eval_notes, amps_all, onset))
      if d < min_r
        min_r = d
      end
      if d > max_r
        max_r = d
      end
    end)

    span = max_r - min_r
    span = span == 0.0 ? 1.0 : span
    best_cost = Inf

    _enumerate_combinations!(1, combo -> begin
      midi_notes_all, amps_all = _build_global_notes(combo)
      eval_notes = _pc_normalized_notes(midi_notes_all)
      d = float(DissonanceStmManager.evaluate(stm_mgr, eval_notes, amps_all, onset))
      norm = clamp((d - min_r) / span, 0.0, 1.0)
      c = abs(norm - target01)
      if c < best_cost - 1e-12
        best_cost = c
        for i in 1:desired_stream_count
          best_combo[i] = copy(combo[i])
        end
      end
    end)

    for s in 1:desired_stream_count
      selected_chords[s] = best_combo[s]
      best_chord = copy(selected_chords[s])
      sort!(best_chord)
      current_step_values[s][note_abs_idx] = best_chord
    end

    # ---- Commit STM using realized notes across all streams (NOT area tmp) ----
    midi_notes_all = Int[]
    amps_all = Float64[]
    for s in 1:desired_stream_count
      ns = current_step_values[s][note_abs_idx]
      v = vols[s]
      a_each = isempty(ns) ? v : (v / float(length(ns)))
      for n in ns
        push!(midi_notes_all, n)
        push!(amps_all, a_each)
      end
    end
    DissonanceStmManager.commit!(stm_mgr, midi_notes_all, amps_all, onset)

    # ---- Commit NOTE managers using realized anchors (global scalar + per-stream) ----
    global_anchor_note = _global_anchor_from_step(current_step_values)
    note_len_next = length(note_mgrs[:global].data) + 1
    note_q_array = create_quadratic_integer_array(0, (note_max - note_min) * note_len_next, note_len_next)

    PolyphonicClusterManager.add_data_point_permanently(note_mgrs[:global], Float64[float(global_anchor_note)])
    PolyphonicClusterManager.update_caches_permanently(note_mgrs[:global], note_q_array)

    stream_anchors = Float64[]
    sizehint!(stream_anchors, desired_stream_count)
    for s in 1:desired_stream_count
      push!(stream_anchors, float(_anchor_from_abs(current_step_values[s][note_abs_idx])))
    end
    MultiStreamManager.commit_state!(note_mgrs[:stream], stream_anchors, note_q_array)
    MultiStreamManager.update_caches_permanently!(note_mgrs[:stream], note_q_array)

    # store decisions
    step_decisions["area_tmp_anchor"] = chosen_area
    step_decisions["note_anchor"] = global_anchor_note

    push!(results, current_step_values)
    elapsed = round(time() - t0; digits=2)
    println("[generate_polyphonic] step $(step_idx)/$(steps_to_generate) elapsed=$(elapsed)s")
    flush(stdout)
  end

  # ----------------------------------------------------------
  # Post-process / clamp
  # ----------------------------------------------------------
  for step in results
    for vec in step
      vec[note_abs_idx] = _normalize_abs_notes(vec[note_abs_idx])
      vec[vol_idx] = get(dim_accept, "vol", true) ? clamp(_parse_float(vec[vol_idx]), 0.0, 1.0) : clamp(dim_fixed["vol"], 0.0, 1.0)
      vec[bri_idx] = get(dim_accept, "bri", true) ? clamp(_parse_float(vec[bri_idx]), 0.0, 1.0) : clamp(dim_fixed["bri"], 0.0, 1.0)
      vec[hrd_idx] = get(dim_accept, "hrd", true) ? clamp(_parse_float(vec[hrd_idx]), 0.0, 1.0) : clamp(dim_fixed["hrd"], 0.0, 1.0)
      vec[tex_idx] = get(dim_accept, "tex", true) ? clamp(_parse_float(vec[tex_idx]), 0.0, 1.0) : clamp(dim_fixed["tex"], 0.0, 1.0)
      vec[chord_range_idx] = get(dim_accept, "chord_range", true) ? clamp(_parse_int(vec[chord_range_idx]), CHORD_RANGE_MIN, CHORD_RANGE_MAX) : Int(round(clamp(dim_fixed["chord_range"], float(CHORD_RANGE_MIN), float(CHORD_RANGE_MAX))))
      vec[density_idx] = get(dim_accept, "density", true) ? clamp(_parse_float(vec[density_idx]), 0.0, 1.0) : clamp(dim_fixed["density"], 0.0, 1.0)
      vec[sustain_idx] = get(dim_accept, "sustain", true) ? _quantize_sustain(vec[sustain_idx]) : _quantize_sustain(dim_fixed["sustain"])
    end
  end

  processing_time_s = round(time() - t0; digits=2)

  timbre_series = Dict(
    "bri" => Any[
      Float64[clamp(_parse_float(st[bri_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "hrd" => Any[
      Float64[clamp(_parse_float(st[hrd_idx]), 0.0, 1.0) for st in step]
      for step in results
    ],
    "tex" => Any[
      Float64[clamp(_parse_float(st[tex_idx]), 0.0, 1.0) for st in step]
      for step in results
    ]
  )

  cluster_payload = Dict{String,Any}()
  for key in ["note", "area", "vol", "bri", "hrd", "tex", "chord_range", "density", "sustain"]
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
    "streamStrengths" => nothing,
    "timbreSeries" => timbre_series,
    "bpm" => bpm,
    "stepDuration" => step_duration
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
