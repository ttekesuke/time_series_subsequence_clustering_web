using Test
using JSON3

const MA = Main.TimeseriesClusteringAPI.MusicAnalysis
const TC = Main.TimeseriesClusteringAPI.TimeSeriesController
const PCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

function _exact_current_cluster_metrics(manager)
  distance = 0.0
  quantity = 0.0
  complexity = 0.0
  for (window_size, same_ws) in PCM.collect_clusters_each(manager)
    ids = collect(keys(same_ws))
    for i in 1:length(ids), j in (i + 1):length(ids)
      distance += PCM.euclidean_distance(manager,
        PCM._cluster_as_view(same_ws[ids[i]]),
        PCM._cluster_as_view(same_ws[ids[j]])) / float(window_size)
    end
    for node in values(same_ws)
      count = PCM._cluster_si_count(node)
      count > 1 || continue
      quantity += PCM.cluster_quantity_score(count, window_size)
      complexity += PCM.calculate_cluster_complexity(manager, PCM._cluster_as_view(node))
    end
  end
  return (distance=distance, quantity=quantity, complexity=complexity)
end

@testset "observed append matches exact committed clusters" begin
  seed = Vector{Float64}[Float64[0.0], Float64[1.0]]
  manager = PCM.Manager(seed, 0.02, 2, false;
    range_min=0.0, range_max=1.0, max_set_size=1,
    recency=0.0, enable_occurrence_intervals=false)
  PCM.process_data!(manager)
  TC.initial_calc_values!(manager, PCM.transform_clusters(manager))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
  distance_sums = Dict(window => sum(values(cache))
    for (window, cache) in manager.cluster_distance_cache)
  empty!(manager.cluster_distance_cache)

  for index in 1:40
    value = Float64[float((index ÷ 3) % 2)]
    before = length(manager.data)
    committed = PCM.add_observed_and_calculate_all_extended!(manager, value;
      observed_distance_sums=distance_sums)
    @test length(manager.data) == before + 1
    exact = _exact_current_cluster_metrics(manager)
    for field in (:distance, :quantity, :complexity)
      @test isapprox(getfield(committed, field), getfield(exact, field); atol=1e-8, rtol=1e-8)
    end
    @test isempty(manager.cluster_distance_cache)
  end

  next_value = Float64[0.0]
  observed = TC.evaluate_observed_complexity!(manager, next_value;
    observed_distance_sums=distance_sums)
  exact = _exact_current_cluster_metrics(manager)
  @test isapprox(observed["raw"]["distance"], exact.distance; atol=1e-8)
  @test isapprox(observed["raw"]["quantity"], exact.quantity; atol=1e-8)
  @test isapprox(observed["raw"]["complexity"], exact.complexity; atol=1e-8)
end

@testset "observed calibrator reuses the exact preceding committed metrics" begin
  function prepared_manager()
    seed = Vector{Float64}[Float64[0.0], Float64[1.0]]
    manager = PCM.Manager(seed, 0.02, 2, false;
      range_min=0.0, range_max=1.0, max_set_size=1, recency=0.0)
    PCM.process_data!(manager)
    TC.initial_calc_values!(manager, PCM.transform_clusters(manager))
    empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
    return manager
  end

  baseline = prepared_manager()
  cached = prepared_manager()
  baseline_preceding = Ref(PCM.current_extended_metrics(baseline))
  preceding = Ref(PCM.current_extended_metrics(cached))
  baseline_sums = Dict(window => sum(values(cache))
    for (window, cache) in baseline.cluster_distance_cache)
  empty!(baseline.cluster_distance_cache)
  distance_sums = Dict(window => sum(values(cache))
    for (window, cache) in cached.cluster_distance_cache)
  empty!(cached.cluster_distance_cache)
  for index in 1:24
    value = Float64[float((index ÷ 3) % 2)]
    expected = TC.evaluate_observed_complexity!(baseline, value;
      committed_metrics_ref=baseline_preceding, observed_distance_sums=baseline_sums)
    actual = TC.evaluate_observed_complexity!(cached, value;
      committed_metrics_ref=preceding, observed_distance_sums=distance_sums)
    for key in ("prediction", "diversity", "shape", "occurrence", "mass", "combined")
      left, right = expected[key], actual[key]
      @test isequal(left, right) ||
        (left !== nothing && right !== nothing && isapprox(left, right; atol=1e-8))
    end
    for key in keys(expected["raw"])
      left, right = expected["raw"][key], actual["raw"][key]
      @test isequal(left, right) ||
        (left !== nothing && right !== nothing && isapprox(left, right; atol=1e-8))
    end
    exact = _exact_current_cluster_metrics(cached)
    for field in (:distance, :quantity, :complexity)
      @test isapprox(getfield(preceding[], field), getfield(exact, field); atol=1e-8)
    end
    fresh_occurrence = PCM.current_occurrence_interval_metrics(baseline,
      PCM.collect_clusters_each(baseline), length(baseline.data) - 1)
    left, right = preceding[].occurrence_intervals, fresh_occurrence
    @test left.ready == right.ready
    if left.ready
      for field in (:distance, :quantity, :complexity, :prediction)
        a, b = getfield(left, field), getfield(right, field)
        @test isequal(a, b) || isapprox(a, b; atol=1e-8)
      end
    end
    @test isempty(cached.cluster_distance_cache)
    @test isempty(cached.occurrence_interval_states)
  end
end

@testset "MusicAnalyse disables occurrence interval work" begin
  manager = PCM.Manager(Vector{Float64}[Float64[0.0], Float64[0.0]],
    0.02, 2, false; range_min=0.0, range_max=1.0,
    enable_occurrence_intervals=false, recency=0.0)
  PCM.process_data!(manager)
  TC.initial_calc_values!(manager, PCM.transform_clusters(manager))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
  for _ in 1:12
    observed = TC.evaluate_observed_complexity!(manager, Float64[0.0])
    @test !haskey(observed, "occurrence")
    @test !haskey(observed, "combined")
    @test !haskey(observed["raw"], "occurrenceDistance")
    @test isempty(manager.occurrence_interval_states)
  end
end

@testset "streamwise distance and prefix totals match current clusters" begin
  function prepared_streamwise_manager()
    seed = Vector{Float64}[Float64[10.0, 134.0], Float64[20.0, 261.0]]
    manager = PCM.Manager(seed, 0.02, 2, false;
      range_min=0.0, range_max=386.0, max_set_size=3,
      use_streamwise_surface_average=true, stream_axis_offset=129.0,
      stream_axis_capacity=3, enable_occurrence_intervals=false, recency=0.0)
    PCM.process_data!(manager)
    TC.initial_calc_values!(manager, PCM.transform_clusters(manager))
    empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
    return manager
  end

  cached = prepared_streamwise_manager()
  a, b = Float64[10.0, 150.0], Float64[20.0, 288.0]
  expected_distance = (10.0 / 128.0 + 2.0) / 3.0
  @test isapprox(PCM.streamwise_surface_distance01(cached, a, b), expected_distance)
  @test isapprox(PCM.streamwise_surface_distance01(cached, reverse(a), b), expected_distance)
  @test_throws ErrorException PCM.streamwise_surface_distance01(cached, Float64[10.0, 12.0], b)

  preceding = Ref(PCM.current_extended_metrics(cached))
  distance_sums = Dict(window => sum(values(cache))
    for (window, cache) in cached.cluster_distance_cache)
  empty!(cached.cluster_distance_cache)
  rows = [Float64[10.0, 134.0], Float64[20.0, 261.0],
    Float64[15.0], Float64[11.0, 140.0, 268.0]]
  for index in 1:20
    row = rows[mod1(index, length(rows))]
    actual = TC.evaluate_observed_complexity!(cached, row;
      committed_metrics_ref=preceding, observed_distance_sums=distance_sums)
    exact = _exact_current_cluster_metrics(cached)
    for field in (:distance, :quantity, :complexity)
      @test isapprox(actual["raw"][string(field)], getfield(exact, field); atol=1e-8)
    end
    @test isempty(cached.cluster_distance_cache)
  end
end

@testset "observed distances follow changing cluster representatives" begin
  seed = Vector{Float64}[Float64[0.0], Float64[0.0]]
  manager = PCM.Manager(seed, 0.1, 2, false;
    range_min=0.0, range_max=1.0, max_set_size=1,
    enable_occurrence_intervals=false, recency=0.0)
  PCM.process_data!(manager)
  TC.initial_calc_values!(manager, PCM.transform_clusters(manager))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
  preceding = Ref(PCM.current_extended_metrics(manager))
  distance_sums = Dict(window => sum(values(cache))
    for (window, cache) in manager.cluster_distance_cache)
  empty!(manager.cluster_distance_cache)

  changed_with_other_clusters = false
  for value in (0.05, 0.8, 0.85, 0.05, 0.1, 0.8, 0.85, 0.0, 0.05)
    before = Dict((window_size, cluster_id) =>
      Vector{Float64}[copy(row) for row in PCM._cluster_as_view(node)]
      for (window_size, same_ws) in PCM.collect_clusters_each(manager)
      for (cluster_id, node) in same_ws)
    observed = TC.evaluate_observed_complexity!(manager, Float64[value];
      committed_metrics_ref=preceding, observed_distance_sums=distance_sums)
    expected = 0.0
    for (window_size, same_ws) in PCM.collect_clusters_each(manager)
      ids = collect(keys(same_ws))
      for (cluster_id, node) in same_ws
        previous = get(before, (window_size, cluster_id), nothing)
        changed_with_other_clusters |= previous !== nothing && length(ids) > 1 &&
          previous != PCM._cluster_as_view(node)
      end
      for i in 1:length(ids), j in (i + 1):length(ids)
        expected += PCM.euclidean_distance(
          manager, PCM._cluster_as_view(same_ws[ids[i]]),
          PCM._cluster_as_view(same_ws[ids[j]])) / float(window_size)
      end
    end
    @test isapprox(observed["raw"]["distance"], expected; atol=1e-8, rtol=1e-8)
  end
  @test changed_with_other_clusters
end

@testset "observed old distances reuse only exact parent prefixes" begin
  function check_prefix_case(; changed_prefix::Bool=false)
    manager = PCM.Manager(Vector{Float64}[Float64[0.0] for _ in 1:4],
      0.02, 2, false; range_min=0.0, range_max=1.0,
      max_set_size=1, enable_occurrence_intervals=false, recency=0.0)
    old_tail = changed_prefix ? 0.1 : 0.0
    manager.cluster_spans = PCM.CompressedClusterSpan[
      PCM.CompressedClusterSpan(2, 4, [0, 2, 4], [0, 1],
        [Float64[0.2] for _ in 1:4], [0, 0, 0], [4, 4, 4],
        PCM.CompressedClusterSpan[]),
      PCM.CompressedClusterSpan(2, 4, [1, 3, 5], [0, 1],
        [Float64[1.0] for _ in 1:4], [0, 0, 0], [4, 4, 4],
        PCM.CompressedClusterSpan[]),
    ]
    manager.cluster_id_counter = 6
    empty!(manager.cluster_quantity_cache)
    empty!(manager.cluster_complexity_cache)
    empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
    empty!(manager.updated_cluster_ids_per_window_for_calculate_quantities)
    old_representatives = Dict{Tuple{Int,Int},PCM.PolySeq}(
      (2, 0) => [Float64[0.0] for _ in 1:2],
      (3, 2) => [Float64[0.0] for _ in 1:3],
      (4, 4) => [Float64[old_tail], Float64[0.0], Float64[0.0], Float64[0.0]],
    )
    distance_sums = Dict{Int,Float64}(
      2 => sqrt(2.0), 3 => sqrt(3.0),
      4 => sqrt((1.0 - old_tail)^2 + 3.0),
    )
    timing_keys = (
      :cache_collect, :cache_windows, :cache_distance,
      :cache_distance_pairs, :cache_distance_revised_pairs,
      :cache_distance_prefix_hits, :cache_distance_new_prefix_s,
      :cache_distance_new_full_pairs, :cache_distance_new_full_rows,
      :cache_distance_new_full_s, :cache_distance_old_full_pairs,
      :cache_distance_old_full_rows, :cache_distance_old_full_s,
      :cache_distance_old_prefix_hits, :cache_distance_old_prefix_s,
      :cache_distance_old_prefix_check_s, :cache_quantity,
      :cache_complexity_evals, :cache_complexity_prefix_hits,
      :cache_complexity_prefix_s, :cache_complexity_full_rows,
      :cache_complexity_full_s, :cache_occurrence,
    )
    timings = Dict{Symbol,Float64}(key => 0.0 for key in timing_keys)
    PCM.update_caches_permanently!(manager;
      phase_timings=timings, observed_distance_sums=distance_sums,
      observed_old_representatives=old_representatives,
      observed_first_new_id=6)

    for window_size in 2:4
      @test isapprox(distance_sums[window_size], 0.8 * sqrt(float(window_size)); atol=1e-12)
    end
    exact = _exact_current_cluster_metrics(manager)
    @test isapprox(sum(distance_sums[window] / window for window in 2:4),
      exact.distance; atol=1e-12)
    @test timings[:cache_distance_revised_pairs] == 3.0
    @test timings[:cache_distance_old_prefix_hits] == (changed_prefix ? 1.0 : 2.0)
    @test timings[:cache_distance_old_full_pairs] == (changed_prefix ? 2.0 : 1.0)
    @test timings[:cache_distance_old_full_rows] == (changed_prefix ? 6.0 : 2.0)
    @test isempty(manager.cluster_distance_cache) ||
      all(isempty, values(manager.cluster_distance_cache))
  end

  check_prefix_case()
  check_prefix_case(changed_prefix=true)
end

function _score_with_divisions(divisions::Int, durations::Vector{Int})
  body = IOBuffer()
  for (index, duration) in enumerate(durations)
    if index > 1
      print(body, "<backup><duration>", durations[index - 1], "</duration></backup>")
    end
    print(body, """
      <note>
        <pitch><step>C</step><octave>4</octave></pitch>
        <duration>$(duration)</duration>
        <voice>$(index)</voice>
        <staff>1</staff>
      </note>
    """)
  end

  return """
  <score-partwise version="4.0">
    <part-list>
      <score-part id="P1"><part-name>Piano</part-name></score-part>
    </part-list>
    <part id="P1">
      <measure number="1">
        <attributes>
          <divisions>$(divisions)</divisions>
          <time><beats>4</beats><beat-type>4</beat-type></time>
        </attributes>
        <direction>
          <direction-type><dynamics><mf/></dynamics></direction-type>
        </direction>
        $(String(take!(body)))
      </measure>
    </part>
  </score-partwise>
  """
end

@testset "analyse_music exact rhythm denominator accepts 3:4:5" begin
  xml = _score_with_divisions(60, [20, 15, 12])
  parsed = MA.parse_musicxml_text(xml)
  @test MA.rhythm_denominator(parsed) == 60
end

@testset "analysis lanes reuse nonoverlapping source voices per staff" begin
  note(voice, staff, start, stop) = MA.NoteEvent(
    ("P1", staff, voice), "P1", start // 1, stop // 1, 60, false, false,
  )
  events = [
    note("5", "2", 0, 1),
    note("6", "2", 0, 2),
    note("7", "2", 2, 3),
    note("5", "2", 3, 4),
    note("5", "1", 0, 1),
  ]
  lanes, voices = MA._analysis_stream_lanes(events)
  @test lanes[("P1", "2", "5")] == lanes[("P1", "2", "7")]
  @test lanes[("P1", "2", "5")] != lanes[("P1", "2", "6")]
  @test lanes[("P1", "2", "5")] != lanes[("P1", "1", "5")]
  @test Set(voices[lanes[("P1", "2", "5")]]) == Set(["5", "7"])
end

@testset "analyse_music reports compacted stream metadata" begin
  xml = """
  <score-partwise version="4.0">
    <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
    <part id="P1"><measure number="1">
      <attributes><divisions>1</divisions></attributes>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>1</duration><voice>5</voice><staff>1</staff></note>
      <note><pitch><step>E</step><octave>4</octave></pitch><duration>1</duration><voice>7</voice><staff>1</staff></note>
    </measure></part>
  </score-partwise>
  """
  result = MA.analyse_music_payload(Dict{String,Any}(
    "source_type" => "upload", "musicxml_text" => xml, "compact_cluster_view" => true,
  ), TC)
  @test length(result["streams"]) == 1
  @test Set(result["streams"][1]["sourceVoices"]) == Set(["5", "7"])
  @test result["dimensions"]["stream_count"]["values"]["global"] == [1.0, 1.0]
end

@testset "analyse_music produces requested dimensions" begin
  xml = _score_with_divisions(1, [1])
  result = MA.analyse_music_payload(
    Dict{String,Any}(
      "source_type" => "upload",
      "filename" => "simple.musicxml",
      "musicxml_text" => xml,
    ),
    TC,
  )

  @test result["timing"]["gridDenominator"] == 1
  @test result["timing"]["exact"] == true
  @test result["dimensionOrder"] == [
    "note",
    "area",
    "chord_range",
    "density",
    "vol",
    "tie",
    "dissonance",
    "stream_count",
  ]
  axes = result["dimensions"]["note"]["analysis"]["global"]["axes"]
  raw = result["dimensions"]["note"]["analysis"]["global"]["raw"]
  @test Set(keys(axes)) == Set(["prediction", "diversity", "shape", "mass"])
  @test Set(keys(raw)) == Set(["distance", "quantity", "complexity"])
  for dim in ("chord_range", "density", "tie", "dissonance", "stream_count")
    @test Set(keys(result["dimensions"][dim])) == Set(["values"])
    @test length(result["dimensions"][dim]["values"]["global"]) == result["timing"]["stepCount"]
  end
  @test result["dimensions"]["chord_range"]["values"]["global"][1] == 0.0
  @test result["dimensions"]["density"]["values"]["global"][1] == 0.25
  @test result["dimensions"]["tie"]["values"]["global"][1] == 0.0
  @test result["dimensions"]["density"]["values"]["streams"]["1"][1] == 0.25
  @test result["dimensions"]["stream_count"]["values"]["global"][1] == 1.0
  @test length(result["dimensions"]["dissonance"]["values"]["global"]) == result["timing"]["stepCount"]
  @test length(result["pianoRoll"]["streams"]) == 1
end

@testset "analyse_music compact cluster view omits expanded timelines" begin
  result = MA.analyse_music_payload(
    Dict{String,Any}(
      "source_type" => "upload",
      "musicxml_text" => _score_with_divisions(1, [2]),
      "compact_cluster_view" => true,
    ),
    TC,
  )
  note_dimension = result["dimensions"]["note"]
  @test !haskey(note_dimension, "clusters")
  @test !isempty(note_dimension["compressedClusters"]["global"])
  @test haskey(note_dimension["compressedClusters"]["streams"], "1")
end

@testset "compressed cluster response is shallow even for deep trees" begin
  seed = Vector{Float64}[Float64[0.0], Float64[1.0]]
  manager = PCM.Manager(seed, 0.02, 2, false;
    range_min=0.0, range_max=1.0, max_set_size=1)
  root = PCM.CompressedClusterSpan(2, 2, Int[1], Int[0], seed,
    Int[0], Int[250], PCM.CompressedClusterSpan[])
  parent = root
  for window in 3:202
    child = PCM.CompressedClusterSpan(window, window, Int[window], Int[0], seed,
      Int[0], Int[250], PCM.CompressedClusterSpan[])
    push!(parent.children, child)
    parent = child
  end
  manager.cluster_spans = [root]
  payload = PCM.compressed_clusters_payload(manager)
  @test length(payload) == 201
  @test payload[1]["parent_index"] === nothing
  @test all(payload[i]["parent_index"] == i - 2 for i in 2:length(payload))
  @test all(!haskey(span, "children") for span in payload)
  @test length(JSON3.write(payload)) > 0
end

@testset "analyse_music rejects denominator above 60 before clustering" begin
  xml = _score_with_divisions(61, [1])
  err = try
    MA.analyse_music_payload(
      Dict{String,Any}("musicxml_text" => xml),
      TC,
    )
    nothing
  catch e
    e
  end

  @test err isa MA.RequestError
  @test err.code == "rhythm_resolution_exceeded"
end


@testset "ASAP metadata text can be listed without local submodule" begin
  csv = """
composer,title,folder,xml_score
Bach,Fugue_bwv_846,Bach/Fugue/bwv_846,Bach/Fugue/bwv_846/xml_score.musicxml
Bach,Fugue_bwv_846,Bach/Fugue/bwv_846,Bach/Fugue/bwv_846/xml_score.musicxml
"""
  sources = MA.list_asap_sources_from_csv_text(csv)
  @test length(sources) == 1
  @test sources[1]["composer"] == "Bach"
  @test sources[1]["xml_score"] == "Bach/Fugue/bwv_846/xml_score.musicxml"
end
