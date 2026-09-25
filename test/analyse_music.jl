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
