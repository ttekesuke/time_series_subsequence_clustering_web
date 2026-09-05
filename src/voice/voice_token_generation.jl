module VoiceTokenGeneration

using JSON3
using ..PolyphonicClusterManager

struct VoiceToken
  id::String
  text::String
  phones::Vector{String}
  embedding::Vector{Float64}
end

struct VoiceInventory
  id::String
  model_id::String
  feature_version::String
  source::String
  dimensions::Int
  tokens::Vector{VoiceToken}
end

mutable struct VoiceTokenState
  inventory::VoiceInventory
  global_manager::PolyphonicClusterManager.Manager
  stream_managers::Dict{Int,PolyphonicClusterManager.Manager}
  previous_voice_ids::Set{Int}
  last_token_by_stream::Dict{Int,VoiceToken}
end

_string_dict(raw) = Dict{String,Any}(string(k) => v for (k, v) in pairs(raw))

function load_inventory(path::AbstractString)::VoiceInventory
  isfile(path) || error("Voice inventory not found: $(path)")
  raw = _string_dict(JSON3.read(read(path, String)))
  inventory_id = strip(string(get(raw, "inventory_id", "")))
  isempty(inventory_id) && error("Voice inventory must define inventory_id.")
  model_id = strip(string(get(raw, "model_id", "unknown")))
  feature_version = strip(string(get(raw, "feature_version", "unknown")))
  source = strip(string(get(raw, "source", "unknown")))
  dimensions = Int(get(raw, "dimensions", 0))
  dimensions > 0 || error("Voice inventory dimensions must be positive.")

  tokens = VoiceToken[]
  seen_ids = Set{String}()
  for item_raw in get(raw, "tokens", Any[])
    item = _string_dict(item_raw)
    id = strip(string(get(item, "id", "")))
    text = string(get(item, "text", id))
    isempty(id) && error("Voice inventory contains a token without an id.")
    id in seen_ids && error("Duplicate voice token id: $(id)")
    phones = String[string(phone) for phone in get(item, "phones", Any[])]
    isempty(phones) && error("Voice token $(id) has no phones.")
    embedding = Float64[float(value) for value in get(item, "embedding", Any[])]
    length(embedding) == dimensions || error(
      "Voice token $(id) has $(length(embedding)) dimensions; expected $(dimensions).",
    )
    all(isfinite, embedding) || error("Voice token $(id) contains a non-finite embedding value.")
    all(value -> 0.0 <= value <= 1.0, embedding) || error(
      "Voice token $(id) embedding values must be normalized to 0..1.",
    )
    push!(tokens, VoiceToken(id, text, phones, embedding))
    push!(seen_ids, id)
  end
  isempty(tokens) && error("Voice inventory must contain at least one token.")
  sort!(tokens; by=token -> token.id)
  return VoiceInventory(inventory_id, model_id, feature_version, source, dimensions, tokens)
end

function _new_manager(
  inventory::VoiceInventory,
  merge_threshold_ratio::Real,
  min_window_size::Int,
)::PolyphonicClusterManager.Manager
  seed_length = max(min_window_size + 1, 1)
  seed = Vector{Vector{Float64}}()
  for i in 1:seed_length
    push!(seed, copy(inventory.tokens[mod1(i, length(inventory.tokens))].embedding))
  end
  manager = PolyphonicClusterManager.Manager(
    seed,
    merge_threshold_ratio,
    min_window_size;
    value_min=0.0,
    value_max=1.0,
    range_min=0.0,
    range_max=1.0,
    max_set_size=inventory.dimensions,
    point_distance_mode=:ordered_vector,
    point_axis_ranges=fill(1.0, inventory.dimensions),
    recency=0.0,
  )
  PolyphonicClusterManager.process_data!(manager)
  PolyphonicClusterManager.update_caches_permanently(manager)
  return manager
end

function VoiceTokenState(
  inventory::VoiceInventory,
  initial_stream_ids,
  merge_threshold_ratio::Real,
  min_window_size::Int,
)::VoiceTokenState
  global_manager = _new_manager(inventory, merge_threshold_ratio, min_window_size)
  stream_managers = Dict{Int,PolyphonicClusterManager.Manager}()
  for raw_id in initial_stream_ids
    id = Int(raw_id)
    stream_managers[id] = _new_manager(inventory, merge_threshold_ratio, min_window_size)
  end
  return VoiceTokenState(
    inventory,
    global_manager,
    stream_managers,
    Set{Int}(),
    Dict{Int,VoiceToken}(),
  )
end

function apply_lifecycle!(state::VoiceTokenState, plan)::Nothing
  for (source_id, new_id) in plan.fork_pairs
    source = get(state.stream_managers, source_id, nothing)
    state.stream_managers[new_id] = source === nothing ?
      _new_manager(state.inventory, state.global_manager.merge_threshold_ratio, state.global_manager.min_window_size) :
      deepcopy(source)
  end
  for id in plan.active_ids
    haskey(state.stream_managers, id) && continue
    state.stream_managers[id] = _new_manager(
      state.inventory,
      state.global_manager.merge_threshold_ratio,
      state.global_manager.min_window_size,
    )
  end
  return nothing
end

"""Seed token histories from the editable initial-context voice plan."""
function seed_initial_tokens!(state::VoiceTokenState, initial_voice_plan)::Nothing
  initial_voice_plan isa AbstractVector || return nothing
  token_by_text = Dict(token.text => token for token in state.inventory.tokens)
  for raw_step in initial_voice_plan
    raw_step isa AbstractVector || continue
    step_embeddings = Vector{Vector{Float64}}()
    for raw_entry in raw_step
      entry = try _string_dict(raw_entry) catch; continue end
      lowercase(string(get(entry, "mode", "voice"))) == "voice" || continue
      token = get(token_by_text, strip(string(get(entry, "text", ""))), nothing)
      token === nothing && continue
      stream_id = try Int(entry["streamId"]) catch; continue end
      manager = get(state.stream_managers, stream_id, nothing)
      if manager === nothing
        manager = _new_manager(state.inventory, state.global_manager.merge_threshold_ratio, state.global_manager.min_window_size)
        state.stream_managers[stream_id] = manager
      end
      PolyphonicClusterManager.add_data_point_permanently(manager, copy(token.embedding))
      PolyphonicClusterManager.update_caches_permanently(manager)
      state.last_token_by_stream[stream_id] = token
      push!(step_embeddings, token.embedding)
    end
    isempty(step_embeddings) && continue
    PolyphonicClusterManager.add_data_point_permanently(
      state.global_manager,
      _mean_embedding(step_embeddings, state.inventory.dimensions),
    )
    PolyphonicClusterManager.update_caches_permanently(state.global_manager)
  end
  return nothing
end

function select_voice_ids!(
  state::VoiceTokenState,
  active_ids::Vector{Int},
  requested_count::Int,
  priority_slots::Vector{Int},
)::Vector{Int}
  count = clamp(requested_count, 0, length(active_ids))
  count == 0 && (empty!(state.previous_voice_ids); return Int[])

  ordered_ids = Int[]
  for slot in priority_slots
    1 <= slot <= length(active_ids) || continue
    push!(ordered_ids, active_ids[slot])
  end
  for id in active_ids
    id in ordered_ids || push!(ordered_ids, id)
  end

  selected = Int[id for id in ordered_ids if id in state.previous_voice_ids]
  resize!(selected, min(length(selected), count))
  for id in ordered_ids
    length(selected) >= count && break
    id in selected || push!(selected, id)
  end
  state.previous_voice_ids = Set(selected)
  return selected
end

@inline function embedding_distance(a::Vector{Float64}, b::Vector{Float64})::Float64
  dims = max(length(a), length(b), 1)
  total = 0.0
  for i in 1:dims
    av = i <= length(a) ? a[i] : 0.0
    bv = i <= length(b) ? b[i] : 0.0
    total += (av - bv)^2
  end
  return clamp(sqrt(total / float(dims)), 0.0, 1.0)
end

function _mean_embedding(values::Vector{Vector{Float64}}, dimensions::Int)::Vector{Float64}
  isempty(values) && return zeros(Float64, dimensions)
  result = zeros(Float64, dimensions)
  for value in values, i in 1:dimensions
    result[i] += value[i]
  end
  result ./= float(length(values))
  return result
end

function _normalize_scores(raw::Vector{Float64})::Vector{Float64}
  isempty(raw) && return Float64[]
  finite = Float64[value for value in raw if isfinite(value)]
  isempty(finite) && return zeros(Float64, length(raw))
  low, high = minimum(finite), maximum(finite)
  high - low <= 1e-12 && return zeros(Float64, length(raw))
  return Float64[isfinite(value) ? clamp((value - low) / (high - low), 0.0, 1.0) : 0.0 for value in raw]
end

function _candidate_complexity_scores(
  manager::PolyphonicClusterManager.Manager,
  candidates::Vector{Vector{Float64}},
)::Vector{Float64}
  distribution = PolyphonicClusterManager.build_predictive_distribution(manager)
  raw = Float64[]
  for candidate in candidates
    metrics = PolyphonicClusterManager.simulate_add_and_calculate_all_extended(manager, candidate)
    predictive = PolyphonicClusterManager.predictive_surprise_score(manager, distribution, candidate)
    prediction = predictive === nothing ? metrics.distance : predictive
    push!(raw, (6.0 * prediction + metrics.distance + metrics.complexity) / 8.0)
  end
  return _normalize_scores(raw)
end

const _KANA_VOWEL_GROUPS = Dict(
  "あ" => "あぁかさたなはまやらわがざだばぱアァカサタナハマヤラワガザダバパ",
  "い" => "いぃきしちにひみりぎじぢびぴイィキシチニヒミリギジヂビピ",
  "う" => "うぅくすつぬふむゆるぐずづぶぷゅウゥクスツヌフムユルグズヅブプュヴ",
  "え" => "えぇけせてねへめれげぜでべぺエェケセテネヘメレゲゼデベペヱヵヶ",
  "お" => "おぉこそとのほもよろをごぞどぼぽょをオォコソトノホモヨロゴゾドボポョヲ",
)
const _KANA_TO_VOWEL = Dict{Char,String}(
  c => vowel for (vowel, chars) in _KANA_VOWEL_GROUPS for c in chars
)

function continuation_token(state::VoiceTokenState, stream_id::Int)::Union{Nothing,VoiceToken}
  previous = get(state.last_token_by_stream, stream_id, nothing)
  previous === nothing && return nothing
  vowel = nothing
  for c in previous.text
    mapped = get(_KANA_TO_VOWEL, c, nothing)
    mapped === nothing || (vowel = mapped)
  end
  vowel === nothing && return nothing
  for token in state.inventory.tokens
    token.text == vowel && return token
  end
  return nothing
end

function _concordance_cost(
  candidate::Vector{Float64},
  chosen::Vector{Vector{Float64}},
  concordance::Real,
)::Float64
  isempty(chosen) && return 0.0
  mean_distance = sum(embedding_distance(candidate, value) for value in chosen) / float(length(chosen))
  target_distance = float(concordance) >= 0.0 ? 0.0 : 1.0
  return abs(clamp(float(concordance), -1.0, 1.0)) * abs(mean_distance - target_distance)
end

function generate_tokens!(
  state::VoiceTokenState,
  voice_ids::Vector{Int};
  global_target::Real=0.0,
  stream_targets::Dict{Int,Float64}=Dict{Int,Float64}(),
  concordance::Real=0.0,
  transition_weight::Real=0.0,
  recency::Real=0.0,
  forced_tokens::Dict{Int,VoiceToken}=Dict{Int,VoiceToken}(),
)::Dict{Int,VoiceToken}
  isempty(voice_ids) && return Dict{Int,VoiceToken}()
  state.global_manager.recency = clamp(float(recency), 0.0, 1.0)
  tokens = state.inventory.tokens
  candidates = Vector{Float64}[token.embedding for token in tokens]
  chosen_tokens = Dict{Int,VoiceToken}()
  chosen_embeddings = Vector{Float64}[]
  chosen_texts = Set{String}()
  require_distinct_text = float(concordance) <= -0.999 &&
    length(unique(token.text for token in tokens)) >= length(voice_ids)

  for stream_id in voice_ids
    manager = state.stream_managers[stream_id]
    forced = get(forced_tokens, stream_id, nothing)
    if forced !== nothing
      chosen_tokens[stream_id] = forced
      push!(chosen_embeddings, forced.embedding)
      push!(chosen_texts, forced.text)
      PolyphonicClusterManager.add_data_point_permanently(manager, copy(forced.embedding))
      PolyphonicClusterManager.update_caches_permanently(manager)
      state.last_token_by_stream[stream_id] = forced
      continue
    end
    manager.recency = clamp(float(recency), 0.0, 1.0)
    stream_scores = _candidate_complexity_scores(manager, candidates)
    global_candidates = Vector{Float64}[
      _mean_embedding(vcat(chosen_embeddings, Vector{Float64}[candidate]), state.inventory.dimensions)
      for candidate in candidates
    ]
    global_scores = _candidate_complexity_scores(state.global_manager, global_candidates)
    stream_target = clamp(get(stream_targets, stream_id, float(global_target)), 0.0, 1.0)
    previous = get(state.last_token_by_stream, stream_id, nothing)

    best_index = 1
    best_target_distance = Inf
    best_tiebreak_cost = Inf
    for i in eachindex(tokens)
      if require_distinct_text && tokens[i].text in chosen_texts
        continue
      end
      transition_cost = previous === nothing ? 0.0 :
        clamp(float(transition_weight), 0.0, 1.0) * embedding_distance(previous.embedding, candidates[i])
      # The per-stream complexity center is the user's direct target. Choose
      # the candidate nearest to it first; global complexity, concordance, and
      # transition history only resolve ties between equally close candidates.
      target_distance = abs(stream_scores[i] - stream_target)
      tiebreak_cost =
        abs(global_scores[i] - clamp(float(global_target), 0.0, 1.0)) +
        _concordance_cost(candidates[i], chosen_embeddings, concordance) +
        transition_cost
      if target_distance < best_target_distance - 1e-12 ||
         (abs(target_distance - best_target_distance) <= 1e-12 && tiebreak_cost < best_tiebreak_cost - 1e-12)
        best_target_distance = target_distance
        best_tiebreak_cost = tiebreak_cost
        best_index = i
      end
    end

    token = tokens[best_index]
    chosen_tokens[stream_id] = token
    push!(chosen_embeddings, token.embedding)
    push!(chosen_texts, token.text)
    PolyphonicClusterManager.add_data_point_permanently(manager, copy(token.embedding))
    PolyphonicClusterManager.update_caches_permanently(manager)
    state.last_token_by_stream[stream_id] = token
  end

  global_value = _mean_embedding(chosen_embeddings, state.inventory.dimensions)
  PolyphonicClusterManager.add_data_point_permanently(state.global_manager, global_value)
  PolyphonicClusterManager.update_caches_permanently(state.global_manager)
  return chosen_tokens
end

function clusters_payload(state::VoiceTokenState, min_window::Int)::Dict{String,Any}
  streams = Dict{Int,Any}()
  for (id, manager) in state.stream_managers
    streams[id] = PolyphonicClusterManager.clusters_to_timeline(manager.clusters, min_window)
  end
  return Dict(
    "global" => PolyphonicClusterManager.clusters_to_timeline(state.global_manager.clusters, min_window),
    "streams" => streams,
  )
end

end
