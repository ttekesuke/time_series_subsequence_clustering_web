const _gpv_controller = Main.TimeseriesClusteringAPI.TimeSeriesController

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

@testset "text fields may legitimately contain nonfinite-looking words" begin
  payload = _valid_gp_payload()
  payload["voice_inventory_id"] = "Inf"
  payload["initial_context_voice_plan"] = Any[
    Any[Dict("mode" => "voice", "token" => "NaN", "text" => "Inf", "phones" => Any["Inf"])],
  ]
  validated = _gpv_controller._validate_generate_polyphonic_request!(payload)
  @test validated.stream_counts == [1, 2]

  payload["recency_center"] = Any["Inf"]
  err = _validation_error(payload)
  @test err isa _gpv_controller.GeneratePolyphonicRequestError
  @test err.code == "non_finite_number"
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
