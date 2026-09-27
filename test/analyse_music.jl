using Test

const MA = Main.TimeseriesClusteringAPI.MusicAnalysis
const TC = Main.TimeseriesClusteringAPI.TimeSeriesController
const PCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager

@testset "observed append matches candidate simulation metrics" begin
  seed = Vector{Float64}[Float64[0.0], Float64[1.0]]
  manager = PCM.Manager(seed, 0.02, 2, false;
    range_min=0.0, range_max=1.0, max_set_size=1, recency=0.0)
  PCM.process_data!(manager)
  TC.initial_calc_values!(manager, PCM.transform_clusters(manager))
  empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)

  for index in 1:40
    value = Float64[float((index ÷ 3) % 2)]
    before = length(manager.data)
    simulated = PCM.simulate_add_and_calculate_all_extended(manager, value)
    @test length(manager.data) == before
    committed = PCM.add_observed_and_calculate_all_extended!(manager, value)
    @test length(manager.data) == before + 1
    for field in (:distance, :quantity, :complexity)
      @test isapprox(getfield(committed, field), getfield(simulated, field); atol=1e-8, rtol=1e-8)
    end
    expected_occurrence = simulated.occurrence_intervals
    actual_occurrence = committed.occurrence_intervals
    @test actual_occurrence.ready == expected_occurrence.ready
    if expected_occurrence.ready
      for field in (:distance, :quantity, :complexity, :prediction)
        expected = getfield(expected_occurrence, field)
        actual = getfield(actual_occurrence, field)
        @test isequal(actual, expected) || isapprox(actual, expected; atol=1e-8, rtol=1e-8)
      end
    end
  end
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
  @test haskey(
    result["dimensions"]["note"]["analysis"]["global"]["axes"],
    "combined",
  )
  @test !haskey(result["dimensions"]["dissonance"], "analysis")
  @test !haskey(result["dimensions"]["stream_count"], "analysis")
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
