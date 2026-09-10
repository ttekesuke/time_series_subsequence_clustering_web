from pathlib import Path

path = Path("src/controllers/time_series_controller.jl")
lines = path.read_text().splitlines()


def one(exact, start=0, end=None, label="line"):
    stop = len(lines) if end is None else end
    hits = [i for i in range(start, stop) if lines[i] == exact]
    if len(hits) != 1:
        raise SystemExit(f"{label}: expected one exact line, found {len(hits)}: {exact!r}")
    return hits[0]


def insert_before(index, block):
    lines[index:index] = block


# Transaction helpers beside the existing fail-fast simulation wrapper.
wrapper_start = one("function _safe_simulate_add_and_calculate_all_extended(", label="wrapper start")
wrapper_end = one("end", start=wrapper_start + 1, end=wrapper_start + 12, label="wrapper end")
lines[wrapper_end + 1:wrapper_end + 1] = [
    "",
    "function _set_generation_failure_context!(",
    "  context::Dict{Symbol,Any};",
    "  operation::AbstractString,",
    "  dimension=nothing,",
    "  stream_id=nothing,",
    "  candidate=nothing,",
    ")::Dict{Symbol,Any}",
    "  context[:operation] = String(operation)",
    "  context[:dimension] = dimension",
    "  context[:stream_id] = stream_id",
    "  context[:candidate] = candidate",
    "  return context",
    "end",
    "",
    "function _stage_generate_polyphonic_step_state(managers, stm_mgr, stream_axis, voice_state)",
    "  # Copy one graph so manager dictionaries keep the same staged StableStreamAxis.",
    "  return deepcopy((",
    "    managers=managers,",
    "    stm_mgr=stm_mgr,",
    "    stream_axis=stream_axis,",
    "    voice_state=voice_state,",
    "  ))",
    "end",
    "",
    "function _log_generate_polyphonic_step_failure(err, bt, step_idx::Int, context::Dict{Symbol,Any})::Nothing",
    "  @error \"generate_polyphonic step failed; staged state discarded\" step=step_idx operation=get(context, :operation, nothing) dimension=get(context, :dimension, nothing) stream_id=get(context, :stream_id, nothing) candidate=get(context, :candidate, nothing) exception=(err, bt)",
    "  return nothing",
    "end",
]

# Candidate-level trace context for the common greedy dimension selector.
greedy_start = one("function select_best_values_for_dimension_greedy(", label="greedy start")
main_marker = one("# generate_polyphonic (main)", start=greedy_start, label="main marker")
priority_i = one(
    "  priority_order::Union{Nothing,Vector{Int}} = nothing",
    start=greedy_start,
    end=main_marker,
    label="greedy priority keyword",
)
lines[priority_i] += ","
lines.insert(priority_i + 1, "  trace_context::Union{Nothing,Dict{Symbol,Any}} = nothing")
main_marker += 1

global_vals_i = one(
    "      global_vals = _encode_streamwise_row(stream_axis, partial_ids, ordered_vals, g_offset)",
    start=greedy_start,
    end=main_marker,
    label="greedy global row",
)
global_metrics_i = one(
    "      global_metrics =",
    start=global_vals_i,
    end=main_marker,
    label="greedy global metrics",
)
insert_before(global_metrics_i, [
    "      if trace_context !== nothing",
    "        _set_generation_failure_context!(",
    "          trace_context;",
    "          operation=\"simulate_candidate\",",
    "          stream_id=(stream_idx <= length(actives) ? actives[stream_idx].id : nothing),",
    "          candidate=float(cand),",
    "        )",
    "      end",
    "",
])

# Every future step executes against a staged copy. The previous committed graph is
# rebound only on failure; success naturally promotes the staged graph to the next step.
main_loop = one("  for step_idx in 1:steps_to_generate", label="future loop")
insert_before(main_loop + 1, [
    "    committed_step_state = (",
    "      managers=managers,",
    "      stm_mgr=stm_mgr,",
    "      stream_axis=stream_axis,",
    "      voice_state=voice_state,",
    "    )",
    "    staged_step_state = _stage_generate_polyphonic_step_state(managers, stm_mgr, stream_axis, voice_state)",
    "    managers = staged_step_state.managers",
    "    stm_mgr = staged_step_state.stm_mgr",
    "    stream_axis = staged_step_state.stream_axis",
    "    voice_state = staged_step_state.voice_state",
    "",
    "    results_len_before_step = length(results)",
    "    stream_ids_len_before_step = length(result_stream_ids)",
    "    voice_plan_len_before_step = length(voice_plan)",
    "    previous_step_by_id_before = deepcopy(previous_step_by_id)",
    "    failure_context = Dict{Symbol,Any}(",
    "      :operation => \"step_setup\",",
    "      :dimension => nothing,",
    "      :stream_id => nothing,",
    "      :candidate => nothing,",
    "    )",
    "",
    "    try",
])

lifecycle_i = one(
    "    plan = MultiStreamManager.build_stream_lifecycle_plan(lifecycle_mgr, desired_stream_count; target=st_target, spread=st_spread)",
    start=main_loop,
    label="lifecycle plan",
)
insert_before(lifecycle_i, ["    _set_generation_failure_context!(failure_context; operation=\"lifecycle_plan\")"])

apply_i = one(
    "      MultiStreamManager.apply_stream_lifecycle_plan!(stream_mgr, plan)",
    start=main_loop,
    label="lifecycle apply",
)
insert_before(apply_i, [
    "      _set_generation_failure_context!(",
    "        failure_context;",
    "        operation=\"lifecycle_apply\",",
    "        dimension=manager_key,",
    "      )",
])

recency_i = one("    _apply_step_recency!(idx0, desired_stream_count)", start=main_loop, label="recency")
insert_before(recency_i, ["    _set_generation_failure_context!(failure_context; operation=\"apply_recency\")"])

dim_loop_i = one("    for (key, range_vec, out_idx) in dim_order", start=main_loop, label="dimension loop")
insert_before(dim_loop_i + 1, [
    "      _set_generation_failure_context!(",
    "        failure_context;",
    "        operation=\"dimension_prepare\",",
    "        dimension=key,",
    "      )",
])

call_i = one("        priority_order=step_stream_order,", start=dim_loop_i, label="greedy call priority")
lines.insert(call_i + 1, "        trace_context=failure_context,")

dim_global_add = one(
    "      PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], global_vals)",
    start=dim_loop_i,
    label="dimension global append",
)
insert_before(dim_global_add, [
    "      _set_generation_failure_context!(failure_context; operation=\"commit_global\", dimension=key, candidate=copy(best_vals))",
])
dim_global_cache = one(
    "      PolyphonicClusterManager.update_caches_permanently(mgrs[:global])",
    start=dim_global_add,
    label="dimension global cache",
)
insert_before(dim_global_cache, [
    "      _set_generation_failure_context!(failure_context; operation=\"commit_global_cache\", dimension=key, candidate=copy(best_vals))",
])
dim_if = one("      if key == \"vol\"", start=dim_global_cache, label="dimension stream commit branch")
insert_before(dim_if, [
    "      _set_generation_failure_context!(failure_context; operation=\"commit_streams\", dimension=key, candidate=copy(best_vals))",
])
dim_stream_cache = one(
    "      MultiStreamManager.update_caches_permanently!(mgrs[:stream])",
    start=dim_if,
    label="dimension stream cache",
)
insert_before(dim_stream_cache, [
    "      _set_generation_failure_context!(failure_context; operation=\"commit_stream_caches\", dimension=key, candidate=copy(best_vals))",
])

# AREA candidate evaluation and commits.
area_stage1 = one(
    "      PolyphonicClusterManager.simulate_add_and_calculate_all_extended(sm, Float64[float(a)])",
    start=dim_stream_cache,
    label="area stage1 simulation",
)
insert_before(area_stage1 - 1, [
    "    _set_generation_failure_context!(",
    "      failure_context;",
    "      operation=\"simulate_candidate\",",
    "      dimension=\"area\",",
    "      stream_id=(s <= length(plan.active_ids) ? plan.active_ids[s] : nothing),",
    "      candidate=a,",
    "    )",
])

area_stage2 = one(
    "        metrics = _safe_simulate_add_and_calculate_all_extended(area_gl, enc)",
    start=area_stage1,
    label="area stage2 simulation",
)
insert_before(area_stage2, [
    "        _set_generation_failure_context!(",
    "          failure_context;",
    "          operation=\"simulate_candidate\",",
    "          dimension=\"area\",",
    "          stream_id=plan.active_ids[stream_idx],",
    "          candidate=cand_anchor,",
    "        )",
])

area_global_add = one(
    "    PolyphonicClusterManager.add_data_point_permanently(area_gl, enc_best)",
    start=area_stage2,
    label="area global append",
)
insert_before(area_global_add, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_global\", dimension=\"area\", candidate=copy(chosen_area))",
])
area_global_cache = one(
    "    PolyphonicClusterManager.update_caches_permanently(area_gl)",
    start=area_global_add,
    label="area global cache",
)
insert_before(area_global_cache, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_global_cache\", dimension=\"area\", candidate=copy(chosen_area))",
])
area_stream_commit = one(
    "    MultiStreamManager.commit_state!(area_mgrs[:stream], chosen_area_f)",
    start=area_global_cache,
    label="area stream commit",
)
insert_before(area_stream_commit, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_streams\", dimension=\"area\", candidate=copy(chosen_area))",
])
area_stream_cache = one(
    "    MultiStreamManager.update_caches_permanently!(area_mgrs[:stream])",
    start=area_stream_commit,
    label="area stream cache",
)
insert_before(area_stream_cache, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_stream_caches\", dimension=\"area\", candidate=copy(chosen_area))",
])

# NOTE candidate evaluation, STM, and note-manager commits.
note_cand = one("        cand_anchor = float(_anchor_from_abs(cand))", start=area_stream_cache, label="note candidate")
insert_before(note_cand + 1, [
    "        _set_generation_failure_context!(",
    "          failure_context;",
    "          operation=\"simulate_candidate\",",
    "          dimension=\"note\",",
    "          stream_id=(stream_idx <= length(plan.active_ids) ? plan.active_ids[stream_idx] : nothing),",
    "          candidate=copy(cand),",
    "        )",
])

stm_commit = one(
    "    DissonanceStmManager.commit!(stm_mgr, midi_notes_all, amps_all, onset)",
    start=note_cand,
    label="stm commit",
)
insert_before(stm_commit, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_stm\", dimension=\"note\", candidate=copy(midi_notes_all))",
])
note_global_add = one(
    "    PolyphonicClusterManager.add_data_point_permanently(note_mgrs[:global], Float64[float(global_anchor_note)])",
    start=stm_commit,
    label="note global append",
)
insert_before(note_global_add, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_global\", dimension=\"note\", candidate=global_anchor_note)",
])
note_global_cache = one(
    "    PolyphonicClusterManager.update_caches_permanently(note_mgrs[:global])",
    start=note_global_add,
    label="note global cache",
)
insert_before(note_global_cache, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_global_cache\", dimension=\"note\", candidate=global_anchor_note)",
])
note_stream_commit = one(
    "    MultiStreamManager.commit_state!(note_mgrs[:stream], stream_anchors)",
    start=note_global_cache,
    label="note stream commit",
)
insert_before(note_stream_commit, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_streams\", dimension=\"note\", candidate=copy(stream_anchors))",
])
note_stream_cache = one(
    "    MultiStreamManager.update_caches_permanently!(note_mgrs[:stream])",
    start=note_stream_commit,
    label="note stream cache",
)
insert_before(note_stream_cache, [
    "    _set_generation_failure_context!(failure_context; operation=\"commit_stream_caches\", dimension=\"note\", candidate=copy(stream_anchors))",
])

# TIE candidate evaluation and commits.
tie_loop = one("        for bit in candidate_bits", start=note_stream_cache, label="tie candidate loop")
insert_before(tie_loop + 1, [
    "          _set_generation_failure_context!(",
    "            failure_context;",
    "            operation=\"simulate_candidate\",",
    "            dimension=\"tie\",",
    "            stream_id=stream_id,",
    "            candidate=bit,",
    "          )",
])
tie_global_add = one(
    "        PolyphonicClusterManager.add_data_point_permanently(tie_global_mgr, Float64[global_tie_value])",
    start=tie_loop,
    label="tie global append",
)
insert_before(tie_global_add, [
    "        _set_generation_failure_context!(failure_context; operation=\"commit_global\", dimension=\"tie\", candidate=global_tie_value)",
])
tie_global_cache = one(
    "        PolyphonicClusterManager.update_caches_permanently!(tie_global_mgr)",
    start=tie_global_add,
    label="tie global cache",
)
insert_before(tie_global_cache, [
    "        _set_generation_failure_context!(failure_context; operation=\"commit_global_cache\", dimension=\"tie\", candidate=global_tie_value)",
])
tie_stream_add = one(
    "          PolyphonicClusterManager.add_data_point_permanently(container.manager, Float64[bit])",
    start=tie_global_cache,
    label="tie stream append",
)
insert_before(tie_stream_add, [
    "          _set_generation_failure_context!(failure_context; operation=\"commit_stream\", dimension=\"tie\", stream_id=stream_id, candidate=bit)",
])
tie_stream_cache = one(
    "          PolyphonicClusterManager.update_caches_permanently!(container.manager)",
    start=tie_stream_add,
    label="tie stream cache",
)
insert_before(tie_stream_cache, [
    "          _set_generation_failure_context!(failure_context; operation=\"commit_stream_cache\", dimension=\"tie\", stream_id=stream_id, candidate=bit)",
])

# Voice-token generation mutates its own managers, which are part of the staged graph.
voice_generate = one(
    "      generated_voice_tokens = VoiceTokenGeneration.generate_tokens!(",
    start=tie_stream_cache,
    label="voice generation",
)
insert_before(voice_generate, [
    "      _set_generation_failure_context!(",
    "        failure_context;",
    "        operation=\"generate_tokens\",",
    "        dimension=\"voice_token\",",
    "        candidate=copy(voice_ids),",
    "      )",
])

# Roll back every externally visible step-local binding on failure.
progress_line = one(
    '    println("[generate_polyphonic] step $(step_idx)/$(steps_to_generate) elapsed=$(elapsed)s")',
    start=voice_generate,
    label="step progress",
)
flush_i = one("    flush(stdout)", start=progress_line, end=progress_line + 4, label="step flush")
loop_end = one("  end", start=flush_i + 1, end=flush_i + 4, label="future loop end")
insert_before(loop_end, [
    "    catch err",
    "      managers = committed_step_state.managers",
    "      stm_mgr = committed_step_state.stm_mgr",
    "      stream_axis = committed_step_state.stream_axis",
    "      voice_state = committed_step_state.voice_state",
    "      resize!(results, results_len_before_step)",
    "      resize!(result_stream_ids, stream_ids_len_before_step)",
    "      resize!(voice_plan, voice_plan_len_before_step)",
    "      previous_step_by_id = previous_step_by_id_before",
    "      _log_generate_polyphonic_step_failure(err, catch_backtrace(), step_idx, failure_context)",
    "      rethrow()",
    "    end",
])

path.write_text("\n".join(lines) + "\n")
