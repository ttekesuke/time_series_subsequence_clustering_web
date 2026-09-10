from pathlib import Path


def replace_once(path: str, old: str, new: str, label: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    p.write_text(text.replace(old, new, 1))


# ---------------------------------------------------------------------------
# Configurable request/resource limits.
# ---------------------------------------------------------------------------
replace_once(
    "src/config.jl",
    '''# safety caps
const MAX_NOTE_CANDIDATES::Int = 8_000
const DEFAULT_DEBUG_TOP_N::Int = 10
const DETAILED_DEBUG_TOP_N::Int = 20
''',
    '''# safety caps
const MAX_NOTE_CANDIDATES::Int = 8_000
const POLYPHONIC_MAX_FUTURE_STEPS_DEFAULT::Int = 256
const POLYPHONIC_MAX_STREAMS_PER_STEP_DEFAULT::Int = 16
const POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS_DEFAULT::Int = 256
const POLYPHONIC_MAX_NOTES_PER_STREAM_DEFAULT::Int = MIDI_NOTE_MAX - MIDI_NOTE_MIN + 1
const POLYPHONIC_MAX_TOTAL_INITIAL_NOTES_DEFAULT::Int = 32_768
const POLYPHONIC_MAX_DIMENSION_EVALUATIONS_DEFAULT::Int = 100_000
const POLYPHONIC_MAX_NOTE_EVALUATIONS_DEFAULT::Int = MAX_NOTE_CANDIDATES
const DEFAULT_DEBUG_TOP_N::Int = 10
const DETAILED_DEBUG_TOP_N::Int = 20

"""Read a positive integer resource limit from ENV, falling back on invalid/missing values."""
function polyphonic_resource_limit(env_key::AbstractString, default::Integer)::Int
  raw = strip(get(ENV, String(env_key), ""))
  isempty(raw) && return Int(default)
  parsed = tryparse(Int, raw)
  return (parsed === nothing || parsed <= 0) ? Int(default) : parsed
end
''',
    "config safety caps",
)

# ---------------------------------------------------------------------------
# Controller validation and budget primitives. These are intentionally defined
# near the imports so earlier note-selection helpers can call the budget helpers.
# ---------------------------------------------------------------------------
replace_once(
    "src/controllers/time_series_controller.jl",
    '''import ..DissonanceStmManager
import ..VoiceTokenGeneration

"""Run-local stable mapping from stream IDs to synthetic global-axis slots."""
''',
    '''import ..DissonanceStmManager
import ..VoiceTokenGeneration

struct GeneratePolyphonicRequestError <: Exception
  code::String
  message::String
end

Base.showerror(io::IO, err::GeneratePolyphonicRequestError) = print(io, err.message)

@noinline function _invalid_generate_polyphonic_request(code::AbstractString, message::AbstractString)
  throw(GeneratePolyphonicRequestError(String(code), String(message)))
end

mutable struct PolyphonicEvaluationBudget
  dimension_evaluations::Int
  note_evaluations::Int
  dimension_limit::Int
  note_limit::Int
end

function _generate_polyphonic_limits()
  return (
    future_steps=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_FUTURE_STEPS",
      Config.POLYPHONIC_MAX_FUTURE_STEPS_DEFAULT,
    ),
    streams_per_step=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_STREAMS_PER_STEP",
      Config.POLYPHONIC_MAX_STREAMS_PER_STEP_DEFAULT,
    ),
    initial_context_steps=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS",
      Config.POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS_DEFAULT,
    ),
    notes_per_stream=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_NOTES_PER_STREAM",
      Config.POLYPHONIC_MAX_NOTES_PER_STREAM_DEFAULT,
    ),
    total_initial_notes=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_TOTAL_INITIAL_NOTES",
      Config.POLYPHONIC_MAX_TOTAL_INITIAL_NOTES_DEFAULT,
    ),
    dimension_evaluations=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_DIMENSION_EVALUATIONS",
      Config.POLYPHONIC_MAX_DIMENSION_EVALUATIONS_DEFAULT,
    ),
    note_evaluations=Config.polyphonic_resource_limit(
      "POLYPHONIC_MAX_NOTE_EVALUATIONS",
      Config.POLYPHONIC_MAX_NOTE_EVALUATIONS_DEFAULT,
    ),
  )
end

function _request_finite_float(raw, path::AbstractString)::Float64
  raw isa Bool && _invalid_generate_polyphonic_request(
    "invalid_type",
    "$(path) must be numeric, not Bool.",
  )
  value = if raw isa Real
    float(raw)
  elseif raw isa AbstractString
    parsed = tryparse(Float64, strip(raw))
    parsed === nothing && _invalid_generate_polyphonic_request(
      "invalid_number",
      "$(path) must be numeric.",
    )
    parsed
  else
    _invalid_generate_polyphonic_request(
      "invalid_type",
      "$(path) must be numeric.",
    )
  end
  isfinite(value) || _invalid_generate_polyphonic_request(
    "non_finite_number",
    "$(path) must be finite.",
  )
  return value
end

function _request_finite_int(raw, path::AbstractString)::Int
  value = _request_finite_float(raw, path)
  isinteger(value) || _invalid_generate_polyphonic_request(
    "invalid_integer",
    "$(path) must be an integer.",
  )
  typemin(Int) <= value <= typemax(Int) || _invalid_generate_polyphonic_request(
    "invalid_integer",
    "$(path) is outside the supported integer range.",
  )
  return Int(round(value))
end

function _reject_nonfinite_request_values!(raw, path::AbstractString="generate_polyphonic")::Nothing
  if raw isa AbstractFloat
    isfinite(raw) || _invalid_generate_polyphonic_request(
      "non_finite_number",
      "$(path) must be finite.",
    )
  elseif raw isa AbstractString
    sentinel = lowercase(strip(raw))
    if sentinel in ("nan", "+nan", "-nan", "inf", "+inf", "-inf", "infinity", "+infinity", "-infinity")
      _invalid_generate_polyphonic_request(
        "non_finite_number",
        "$(path) must be finite.",
      )
    end
  elseif raw isa AbstractVector
    for (index, value) in enumerate(raw)
      _reject_nonfinite_request_values!(value, "$(path)[$(index)]")
    end
  elseif raw isa AbstractDict
    for (key, value) in pairs(raw)
      _reject_nonfinite_request_values!(value, "$(path).$(key)")
    end
  end
  return nothing
end

function _validate_generate_polyphonic_request!(raw_gp)
  gp = _to_string_dict(raw_gp)
  limits = _generate_polyphonic_limits()
  _reject_nonfinite_request_values!(gp)

  raw_stream_counts = get(gp, "stream_counts", nothing)
  stream_counts = Int[]
  if raw_stream_counts === nothing
    push!(stream_counts, 1)
  elseif raw_stream_counts isa AbstractVector
    isempty(raw_stream_counts) && _invalid_generate_polyphonic_request(
      "empty_stream_counts",
      "generate_polyphonic.stream_counts must not be empty when provided.",
    )
    length(raw_stream_counts) <= limits.future_steps || _invalid_generate_polyphonic_request(
      "limit_exceeded",
      "generate_polyphonic.stream_counts has $(length(raw_stream_counts)) future steps; limit is $(limits.future_steps).",
    )
    for (index, raw_count) in enumerate(raw_stream_counts)
      push!(stream_counts, _request_finite_int(raw_count, "generate_polyphonic.stream_counts[$(index)]"))
    end
  else
    push!(stream_counts, _request_finite_int(raw_stream_counts, "generate_polyphonic.stream_counts"))
  end

  for (index, count) in enumerate(stream_counts)
    1 <= count <= limits.streams_per_step || _invalid_generate_polyphonic_request(
      "limit_exceeded",
      "generate_polyphonic.stream_counts[$(index)]=$(count) must be within 1..$(limits.streams_per_step).",
    )
  end

  if Config.voicevox_enabled() && haskey(gp, "voice_stream_counts")
    raw_voice_counts = gp["voice_stream_counts"]
    raw_voice_counts isa AbstractVector || _invalid_generate_polyphonic_request(
      "invalid_type",
      "generate_polyphonic.voice_stream_counts must be an Array.",
    )
    length(raw_voice_counts) == length(stream_counts) || _invalid_generate_polyphonic_request(
      "length_mismatch",
      "generate_polyphonic.voice_stream_counts must have the same length as stream_counts.",
    )
    for (index, raw_count) in enumerate(raw_voice_counts)
      count = _request_finite_int(raw_count, "generate_polyphonic.voice_stream_counts[$(index)]")
      0 <= count <= stream_counts[index] || _invalid_generate_polyphonic_request(
        "out_of_range",
        "generate_polyphonic.voice_stream_counts[$(index)]=$(count) must be within 0..$(stream_counts[index]).",
      )
    end
  end

  ctx = get(gp, "initial_context", Any[])
  ctx isa AbstractVector || _invalid_generate_polyphonic_request(
    "invalid_type",
    "generate_polyphonic.initial_context must be an Array of steps.",
  )
  length(ctx) <= limits.initial_context_steps || _invalid_generate_polyphonic_request(
    "limit_exceeded",
    "generate_polyphonic.initial_context has $(length(ctx)) steps; limit is $(limits.initial_context_steps).",
  )

  total_notes = 0
  unit_indices = (2, 3, 4, 5, 6, 7, 8, 10, 11)
  for (step_index, step) in enumerate(ctx)
    step isa AbstractVector || _invalid_generate_polyphonic_request(
      "ragged_initial_context",
      "generate_polyphonic.initial_context[$(step_index)] must be an Array of streams.",
    )
    isempty(step) && _invalid_generate_polyphonic_request(
      "empty_initial_context_step",
      "generate_polyphonic.initial_context[$(step_index)] must contain at least one stream.",
    )
    length(step) <= limits.streams_per_step || _invalid_generate_polyphonic_request(
      "limit_exceeded",
      "generate_polyphonic.initial_context[$(step_index)] has $(length(step)) streams; limit is $(limits.streams_per_step).",
    )

    for (stream_index, stream) in enumerate(step)
      path = "generate_polyphonic.initial_context[$(step_index)][$((stream_index))]"
      stream isa AbstractVector || _invalid_generate_polyphonic_request(
        "ragged_initial_context",
        "$(path) must be an Array in the strict 11-element format.",
      )
      length(stream) == 11 || _invalid_generate_polyphonic_request(
        "invalid_stream_record",
        "$(path) must contain exactly 11 elements.",
      )

      notes = stream[1]
      notes isa AbstractVector || _invalid_generate_polyphonic_request(
        "invalid_notes",
        "$(path)[1] must be a note Array.",
      )
      isempty(notes) && _invalid_generate_polyphonic_request(
        "empty_notes",
        "$(path)[1] must contain at least one MIDI note.",
      )
      length(notes) <= limits.notes_per_stream || _invalid_generate_polyphonic_request(
        "limit_exceeded",
        "$(path)[1] has $(length(notes)) notes; per-stream limit is $(limits.notes_per_stream).",
      )
      total_notes += length(notes)
      total_notes <= limits.total_initial_notes || _invalid_generate_polyphonic_request(
        "limit_exceeded",
        "generate_polyphonic.initial_context contains more than $(limits.total_initial_notes) total notes.",
      )
      for (note_index, raw_note) in enumerate(notes)
        note = _request_finite_int(raw_note, "$(path)[1][$(note_index)]")
        Config.MIDI_NOTE_MIN <= note <= Config.MIDI_NOTE_MAX || _invalid_generate_polyphonic_request(
          "out_of_range",
          "$(path)[1][$(note_index)]=$(note) must be within MIDI $(Config.MIDI_NOTE_MIN)..$(Config.MIDI_NOTE_MAX).",
        )
      end

      for field_index in unit_indices
        value = _request_finite_float(stream[field_index], "$(path)[$(field_index)]")
        0.0 <= value <= 1.0 || _invalid_generate_polyphonic_request(
          "out_of_range",
          "$(path)[$(field_index)]=$(value) must be within 0..1.",
        )
      end
      chord_range = _request_finite_int(stream[9], "$(path)[9]")
      Config.CHORD_RANGE_VALUE_MIN <= chord_range <= Config.CHORD_RANGE_VALUE_MAX || _invalid_generate_polyphonic_request(
        "out_of_range",
        "$(path)[9]=$(chord_range) must be within $(Config.CHORD_RANGE_VALUE_MIN)..$(Config.CHORD_RANGE_VALUE_MAX).",
      )
    end
  end

  return (stream_counts=stream_counts, limits=limits)
end

function _consume_dimension_evaluations!(budget::PolyphonicEvaluationBudget, count::Integer; context::AbstractString="dimension")::Nothing
  n = max(Int(count), 0)
  next_count = budget.dimension_evaluations + n
  next_count <= budget.dimension_limit || _invalid_generate_polyphonic_request(
    "resource_budget_exceeded",
    "generate_polyphonic $(context) evaluation budget exceeded: $(next_count) > $(budget.dimension_limit).",
  )
  budget.dimension_evaluations = next_count
  return nothing
end

function _consume_note_evaluations!(budget::PolyphonicEvaluationBudget, count::Integer; context::AbstractString="note")::Nothing
  n = max(Int(count), 0)
  next_count = budget.note_evaluations + n
  next_count <= budget.note_limit || _invalid_generate_polyphonic_request(
    "resource_budget_exceeded",
    "generate_polyphonic $(context) evaluation budget exceeded: $(next_count) > $(budget.note_limit).",
  )
  budget.note_evaluations = next_count
  return nothing
end

"""Run-local stable mapping from stream IDs to synthetic global-axis slots."""
''',
    "controller validation primitives",
)

# Empty arrays must never fall through to val[end].
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  if val isa AbstractVector
    i = idx0 + 1
''',
    '''  if val isa AbstractVector
    isempty(val) && return nothing
    i = idx0 + 1
''',
    "array_param empty vector guard",
)

# Note candidate request budget.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  complexity_cost_batch = nothing,
  complexity_weight::Real = 1.0,
)::Vector{Int}
''',
    '''  complexity_cost_batch = nothing,
  complexity_weight::Real = 1.0,
  evaluation_budget = nothing,
)::Vector{Int}
''',
    "note greedy budget keyword",
)
replace_once(
    "src/controllers/time_series_controller.jl",
    '''    batch_complexity_penalties =
      complexity_cost_batch === nothing ?
''',
    '''    evaluation_budget === nothing || _consume_note_evaluations!(
      evaluation_budget,
      length(eligible);
      context="note candidate",
    )

    batch_complexity_penalties =
      complexity_cost_batch === nothing ?
''',
    "note greedy budget consume",
)

# Common dimension candidate budget.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  priority_order::Union{Nothing,Vector{Int}} = nothing,
  trace_context::Union{Nothing,Dict{Symbol,Any}} = nothing
)::Vector{Float64}
''',
    '''  priority_order::Union{Nothing,Vector{Int}} = nothing,
  trace_context::Union{Nothing,Dict{Symbol,Any}} = nothing,
  evaluation_budget = nothing
)::Vector{Float64}
''',
    "dimension greedy budget keyword",
)
replace_once(
    "src/controllers/time_series_controller.jl",
    '''      global_metrics =
        _safe_simulate_add_and_calculate_all_extended(mgrs[:global], global_vals)
''',
    '''      if evaluation_budget !== nothing
        dimension_name = trace_context === nothing ? "dimension" : string(get(trace_context, :dimension, "dimension"))
        _consume_dimension_evaluations!(evaluation_budget, 1; context="$(dimension_name) candidate")
      end

      global_metrics =
        _safe_simulate_add_and_calculate_all_extended(mgrs[:global], global_vals)
''',
    "dimension greedy budget consume",
)

# Validate before any expensive setup and use validated stream counts directly.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  gp = _subhash(payload, "generate_polyphonic")
  debug_poly = false
''',
    '''  gp = _subhash(payload, "generate_polyphonic")
  validated_request = _validate_generate_polyphonic_request!(gp)
  evaluation_budget = PolyphonicEvaluationBudget(
    0,
    0,
    validated_request.limits.dimension_evaluations,
    validated_request.limits.note_evaluations,
  )
  debug_poly = false
''',
    "generate validation entry",
)
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  stream_counts_raw = get(gp, "stream_counts", Any[])
  stream_counts = Int[]
  if stream_counts_raw isa AbstractVector
    for x in stream_counts_raw
      push!(stream_counts, _parse_int(x))
    end
  else
    push!(stream_counts, _parse_int(stream_counts_raw))
  end
  isempty(stream_counts) && push!(stream_counts, 1)
''',
    '''  stream_counts = copy(validated_request.stream_counts)
''',
    "validated stream counts",
)

# Pass the request budget into ordinary dimension candidate selection.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''        priority_order=step_stream_order,
        trace_context=failure_context,
      )
''',
    '''        priority_order=step_stream_order,
        trace_context=failure_context,
        evaluation_budget=evaluation_budget,
      )
''',
    "dimension greedy budget call",
)

# AREA candidate evaluations use the same dimension budget.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  for a in anchors
    _set_generation_failure_context!(
''',
    '''  for a in anchors
    _consume_dimension_evaluations!(evaluation_budget, 1; context="area stage-1 candidate")
    _set_generation_failure_context!(
''',
    "area stage1 budget",
)
replace_once(
    "src/controllers/time_series_controller.jl",
    '''      for cand_anchor in anchors
        partial_ids = Int[]
''',
    '''      for cand_anchor in anchors
        _consume_dimension_evaluations!(evaluation_budget, 1; context="area stage-2 candidate")
        partial_ids = Int[]
''',
    "area stage2 budget",
)

# Pass the request budget into note selection; eligible chord count is consumed in
# select_notes_by_single_addition_greedy before structural/dissonance evaluation.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''        complexity_cost_batch=evaluate_note_complexity_cost_batch,
        complexity_weight=1.0,
      )
''',
    '''        complexity_cost_batch=evaluate_note_complexity_cost_batch,
        complexity_weight=1.0,
        evaluation_budget=evaluation_budget,
      )
''',
    "note budget call",
)

# TIE candidate bits are dimension candidate evaluations too.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''        for bit in candidate_bits
          _set_generation_failure_context!(
''',
    '''        for bit in candidate_bits
          _consume_dimension_evaluations!(evaluation_budget, 1; context="tie candidate")
          _set_generation_failure_context!(
''',
    "tie budget",
)

# Dispatch path gets the same preflight validation before consuming a GitHub run.
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  if !Config.voicevox_enabled()
    for key in (
''',
    '''  if !Config.voicevox_enabled()
    for key in (
''',
    "dispatch voice block anchor",
)
replace_once(
    "src/controllers/time_series_controller.jl",
    '''  request_id = string(get(gp_dict, "job_id", uuid4()))
''',
    '''  _validate_generate_polyphonic_request!(gp_dict)

  request_id = string(get(gp_dict, "job_id", uuid4()))
''',
    "dispatch validation",
)

# ---------------------------------------------------------------------------
# HTTP 422 mapping for request validation/budget errors.
# ---------------------------------------------------------------------------
replace_once(
    "routes.jl",
    '''using Genie.Requests
using Dates
''',
    '''using Genie.Requests
import Genie.Responses
using Dates
''',
    "routes responses import",
)
replace_once(
    "routes.jl",
    '''using TimeseriesClusteringAPI.SupercollidersController

# ------------------------------------------------------------
# Health check (frontend proxy / readiness check)
''',
    '''using TimeseriesClusteringAPI.SupercollidersController

function _with_polyphonic_request_errors(f::Function)
  try
    return f()
  catch err
    if err isa TimeSeriesController.GeneratePolyphonicRequestError
      Responses.setstatus(422)
      return Dict(
        "ok" => false,
        "error" => "invalid_generate_polyphonic_request",
        "code" => err.code,
        "message" => err.message,
      ) |> json
    end
    rethrow()
  end
end

# ------------------------------------------------------------
# Health check (frontend proxy / readiness check)
''',
    "routes validation helper",
)
replace_once(
    "routes.jl",
    '''route("/api/web/time_series/generate_polyphonic", method=POST) do
  TimeSeriesController.generate_polyphonic() |> json
end
''',
    '''route("/api/web/time_series/generate_polyphonic", method=POST) do
  _with_polyphonic_request_errors() do
    TimeSeriesController.generate_polyphonic() |> json
  end
end
''',
    "direct polyphonic route",
)
replace_once(
    "routes.jl",
    '''route("/api/web/time_series/dispatch_generate_polyphonic", method = POST) do
  TimeSeriesController.dispatch_generate_polyphonic()
end
''',
    '''route("/api/web/time_series/dispatch_generate_polyphonic", method = POST) do
  _with_polyphonic_request_errors() do
    TimeSeriesController.dispatch_generate_polyphonic()
  end
end
''',
    "dispatch polyphonic route",
)

# ---------------------------------------------------------------------------
# Docs: reflect endpoint validation and hard limits.
# ---------------------------------------------------------------------------
replace_once(
    "docs/generate_polyphonic.md",
    '''`stream_counts` が空なら `[1]` が補われます。

各stepで:

```text
desired_stream_count = max(stream_counts[step], 1)
```

となります。
''',
    '''`stream_counts` 自体を省略した場合は `[1]` が補われます。ただし、明示的に空配列 `[]` を送ると422です。

backend入口では各値を `1..16`（default）として検証し、future step数もdefault 256以下に制限します。これらのlimitは環境変数で変更できます。

各stepの `desired_stream_count` は検証済みの `stream_counts[step]` そのものです。
''',
    "docs stream count validation",
)
replace_once(
    "docs/generate_polyphonic.md",
    '''## 4. 初期contextの正規化

各recordは `_normalize_stream!` で正規化されます。

- noteは整数化・36..120へclamp・sort
- timbre/volume/densityは0..1へclamp
- chord_rangeは0以上
- tieは0..1へclamp
''',
    '''## 4. 初期contextの検証と正規化

高コストなmanager初期化より前に、`initial_context` をrequest境界で検証します。

- 各stepは非空のstream配列
- 各streamは11要素固定
- `abs_notes` は非空、整数、MIDI 36..120
- vol/timbre/density/tieはfiniteな0..1
- `chord_range` は整数0..24
- defaultではinitial contextは256step以下、1stepは16stream以下、1streamは85note以下、全initial context合計は32768note以下
- NaN / Inf（文字列sentinelを含む）は拒否

違反はdirect API/dispatch APIとも422になります。検証通過後も `_normalize_stream!` は防御的な正規化として残ります。
''',
    "docs initial validation",
)

insert_marker = '''## 5. dimension policy
'''
text = Path("docs/generate_polyphonic.md").read_text()
if text.count(insert_marker) != 1:
    raise SystemExit("docs budget section anchor mismatch")
text = text.replace(
    insert_marker,
    '''### resource budget\n\n候補評価にはrequest単位のhard budgetがあります。defaultはdimension候補100,000、note候補8,000です。超過時は現在stepのstaged stateを破棄して422を返します。\n\n上限は以下の環境変数で正の整数へ上書きできます。\n\n- `POLYPHONIC_MAX_FUTURE_STEPS`\n- `POLYPHONIC_MAX_STREAMS_PER_STEP`\n- `POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS`\n- `POLYPHONIC_MAX_NOTES_PER_STREAM`\n- `POLYPHONIC_MAX_TOTAL_INITIAL_NOTES`\n- `POLYPHONIC_MAX_DIMENSION_EVALUATIONS`\n- `POLYPHONIC_MAX_NOTE_EVALUATIONS`\n\n## 5. dimension policy\n''',
    1,
)
Path("docs/generate_polyphonic.md").write_text(text)

# ---------------------------------------------------------------------------
# Permanent regression tests.
# ---------------------------------------------------------------------------
Path("test/generate_polyphonic_validation.jl").write_text(r'''const _gpv_controller = Main.TimeseriesClusteringAPI.TimeSeriesController

function _valid_gp_payload()
  return Dict{String,Any}(
    "stream_counts" => Any[1, 2],
    "initial_context" => Any[
      Any[
        Any[Any[60, 64], 1.0, 0.5, 0.2, 1.0, 0.1, 0.4, 0.5, 0, 0.0, 0.0],
      ],
    ],
  )
end

function _validation_error(payload)
  try
    _gpv_controller._validate_generate_polyphonic_request!(payload)
    return nothing
  catch err
    return err
  end
end

@testset "generate_polyphonic request validation accepts canonical payload" begin
  validated = _gpv_controller._validate_generate_polyphonic_request!(_valid_gp_payload())
  @test validated.stream_counts == [1, 2]
  @test validated.limits.streams_per_step >= 2
end

@testset "generate_polyphonic malformed input is rejected before generation" begin
  cases = Dict{String,Any}[]

  p = _valid_gp_payload(); p["stream_counts"] = Any[]; push!(cases, p)
  p = _valid_gp_payload(); p["stream_counts"] = Any[0]; push!(cases, p)
  p = _valid_gp_payload(); p["stream_counts"] = Any[17]; push!(cases, p)
  p = _valid_gp_payload(); p["initial_context"] = Any[Any[]]; push!(cases, p)
  p = _valid_gp_payload(); p["initial_context"][1][1] = Any[Any[], 1.0, 0.5, 0.2, 1.0, 0.1, 0.4, 0.5, 0, 0.0, 0.0]; push!(cases, p)
  p = _valid_gp_payload(); p["initial_context"][1][1] = Any[Any[35], 1.0, 0.5, 0.2, 1.0, 0.1, 0.4, 0.5, 0, 0.0, 0.0]; push!(cases, p)
  p = _valid_gp_payload(); p["initial_context"][1][1] = Any[Any[60], 1.1, 0.5, 0.2, 1.0, 0.1, 0.4, 0.5, 0, 0.0, 0.0]; push!(cases, p)
  p = _valid_gp_payload(); p["initial_context"][1][1] = Any[Any[60], NaN, 0.5, 0.2, 1.0, 0.1, 0.4, 0.5, 0, 0.0, 0.0]; push!(cases, p)
  p = _valid_gp_payload(); p["recency_center"] = Any["Inf"]; push!(cases, p)
  p = _valid_gp_payload(); pop!(p["initial_context"][1][1]); push!(cases, p)

  for payload in cases
    err = _validation_error(payload)
    @test err isa _gpv_controller.GeneratePolyphonicRequestError
  end
end

@testset "generate_polyphonic configured structural limits are enforced" begin
  withenv("POLYPHONIC_MAX_FUTURE_STEPS" => "2") do
    p = _valid_gp_payload()
    p["stream_counts"] = Any[1, 1, 1]
    err = _validation_error(p)
    @test err isa _gpv_controller.GeneratePolyphonicRequestError
    @test err.code == "limit_exceeded"
  end

  withenv("POLYPHONIC_MAX_NOTES_PER_STREAM" => "1") do
    err = _validation_error(_valid_gp_payload())
    @test err isa _gpv_controller.GeneratePolyphonicRequestError
    @test err.code == "limit_exceeded"
  end
end

@testset "empty vector array_param no longer indexes val[end]" begin
  @test _gpv_controller.array_param(Dict{String,Any}("x" => Any[]), "x", 5) === nothing
end

@testset "candidate evaluation budgets fail with request errors" begin
  budget = _gpv_controller.PolyphonicEvaluationBudget(0, 0, 2, 3)
  _gpv_controller._consume_dimension_evaluations!(budget, 2)
  @test budget.dimension_evaluations == 2
  err = try
    _gpv_controller._consume_dimension_evaluations!(budget, 1)
    nothing
  catch e
    e
  end
  @test err isa _gpv_controller.GeneratePolyphonicRequestError
  @test err.code == "resource_budget_exceeded"

  err = try
    _gpv_controller._consume_note_evaluations!(budget, 4)
    nothing
  catch e
    e
  end
  @test err isa _gpv_controller.GeneratePolyphonicRequestError
  @test err.code == "resource_budget_exceeded"
end

@testset "note greedy consumes budget before expensive candidate evaluation" begin
  budget = _gpv_controller.PolyphonicEvaluationBudget(0, 0, 100, 2)
  evaluate_calls = Ref(0)
  err = try
    _gpv_controller.select_notes_by_single_addition_greedy(
      Int[60, 62, 64],
      1,
      0.0,
      _gpv_controller.DissonanceCalibrator(1.0),
      chord -> begin
        evaluate_calls[] += 1
        0.0
      end;
      register_center=62.0,
      register_allowance=12.0,
      tie_center=62.0,
      evaluation_budget=budget,
    )
    nothing
  catch e
    e
  end
  @test err isa _gpv_controller.GeneratePolyphonicRequestError
  @test err.code == "resource_budget_exceeded"
  @test evaluate_calls[] == 0
end
''')
