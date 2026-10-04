# generate_polyphonic request validation and evaluation budgets.
# Included inside TimeSeriesController after shared payload utilities are defined.

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

function _polyphonic_text_field(key)::Bool
  normalized = lowercase(String(key))
  return normalized in (
    "text",
    "mode",
    "token",
    "phones",
    "voice_inventory_id",
    "job_id",
    "fixed_value_source",
    "fixed_source",
    "value_source",
  ) || endswith(normalized, "_id") || occursin("source", normalized)
end

function _reject_nonfinite_request_values!(
  raw,
  path::AbstractString="generate_polyphonic";
  allow_non_numeric_strings::Bool=false,
)::Nothing
  if raw isa AbstractFloat
    isfinite(raw) || _invalid_generate_polyphonic_request(
      "non_finite_number",
      "$(path) must be finite.",
    )
  elseif raw isa AbstractString && !allow_non_numeric_strings
    sentinel = lowercase(strip(raw))
    if sentinel in ("nan", "+nan", "-nan", "inf", "+inf", "-inf", "infinity", "+infinity", "-infinity")
      _invalid_generate_polyphonic_request(
        "non_finite_number",
        "$(path) must be finite.",
      )
    end
  elseif raw isa AbstractVector
    for (index, value) in enumerate(raw)
      _reject_nonfinite_request_values!(
        value,
        "$(path)[$(index)]";
        allow_non_numeric_strings=allow_non_numeric_strings,
      )
    end
  elseif raw isa AbstractDict
    for (key, value) in pairs(raw)
      _reject_nonfinite_request_values!(
        value,
        "$(path).$(key)";
        allow_non_numeric_strings=_polyphonic_text_field(key),
      )
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
