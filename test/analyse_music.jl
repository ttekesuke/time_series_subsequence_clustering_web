using Test

const MA = Main.TimeseriesClusteringAPI.MusicAnalysis
const TC = Main.TimeseriesClusteringAPI.TimeSeriesController

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
  @test length(result["pianoRoll"]["streams"]) == 1
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


@testset "analyse_music caps subsequence window growth" begin
  series = [Float64[mod(i, 5)] for i in 1:40]
  analysed = MA._analyse_manager(
    series,
    TC;
    range_min=0.0,
    range_max=4.0,
    merge_threshold_ratio=0.02,
    metric_weights=Main.TimeseriesClusteringAPI.Config.POLYPHONIC_STREAM_METRIC_WEIGHTS,
    max_window_size=4,
  )
  windows = Int[Int(cluster["window_size"]) for cluster in analysed["clusters"]]
  @test isempty(windows) || maximum(windows) <= 4
end


@testset "committed-state metrics match simulation structural metrics" begin
  PCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
  Config = Main.TimeseriesClusteringAPI.Config
  seed = [Float64[1.0], Float64[2.0], Float64[1.0], Float64[2.0]]

  function prepared_manager()
    manager = PCM.Manager(
      deepcopy(seed),
      0.02,
      Config.POLYPHONIC_MIN_WINDOW_SIZE,
      false;
      range_min=0.0,
      range_max=4.0,
      enable_occurrence_intervals=false,
    )
    PCM.process_data!(manager)
    TC.initial_calc_values!(
      manager,
      PCM.transform_clusters(manager.clusters, Config.POLYPHONIC_MIN_WINDOW_SIZE),
    )
    empty!(manager.updated_cluster_ids_per_window_for_calculate_distance)
    empty!(manager.updated_cluster_ids_per_window_for_calculate_quantities)
    return manager
  end

  simulated_manager = prepared_manager()
  simulated = PCM.simulate_add_and_calculate_all_extended(simulated_manager, Float64[3.0])

  committed_manager = prepared_manager()
  PCM.add_data_point_permanently!(committed_manager, Float64[3.0])
  PCM.update_caches_permanently!(committed_manager)
  committed = PCM.calculate_all_extended_current_state(committed_manager)

  @test committed.distance ≈ simulated.distance
  @test committed.quantity ≈ simulated.quantity
  @test committed.complexity ≈ simulated.complexity
end
