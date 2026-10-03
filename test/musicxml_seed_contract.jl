using Test
using EzXML

if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

module MusicXmlSeedFixture
  include(joinpath(@__DIR__, "..", "scripts", "seed_influx.jl"))
end

const _seed_music = MusicXmlSeedFixture
const _analyse_music = Main.TimeseriesClusteringAPI.MusicAnalysis
const _xml_events = Main.TimeseriesClusteringAPI.MusicXmlEvents

const _contract_xml = """
<score-partwise version="4.0">
  <part-list>
    <score-part id="P1"><part-name>Piano</part-name></score-part>
    <score-part id="P2"><part-name>Flute</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes><divisions>4</divisions></attributes>
      <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><voice>1</voice><staff>1</staff></note>
      <note><chord/><pitch><step>E</step><alter>1</alter><octave>4</octave></pitch><duration>4</duration><voice>1</voice><staff>1</staff></note>
      <note><rest/><duration>2</duration><voice>1</voice></note>
      <direction><sound tempo="90"/></direction>
      <backup><duration>6</duration></backup>
      <note><pitch><step>G</step><octave>3</octave></pitch><duration>2</duration><voice>2</voice><staff>2</staff></note>
      <forward><duration>4</duration></forward>
      <note><pitch><step>D</step><octave>4</octave></pitch><duration>2</duration><voice>2</voice><staff>2</staff></note>
    </measure>
    <measure number="2">
      <attributes><divisions>6</divisions></attributes>
      <note><pitch><step>A</step><octave>4</octave></pitch><duration>3</duration><voice>1</voice></note>
      <note><pitch><step>B</step><alter>-1</alter><octave>4</octave></pitch><duration>3</duration><voice>1</voice></note>
    </measure>
  </part>
  <part id="P2">
    <measure number="1">
      <attributes><divisions>3</divisions></attributes>
      <note><pitch><step>E</step><octave>3</octave></pitch><duration>3</duration><voice>1</voice></note>
      <forward><duration>3</duration></forward>
      <note><pitch><step>F</step><octave>3</octave></pitch><duration>3</duration><voice>1</voice></note>
    </measure>
  </part>
</score-partwise>
"""

function _seed_fixture(work::Function, xml::AbstractString)
  mktemp() do path, io
    write(io, xml)
    close(io)
    work(_seed_music.parse_musicxml(path))
  end
end

@testset "MusicXML seed and analysis retain the same source events" begin
  parsed = _analyse_music.parse_musicxml_text(_contract_xml)
  common = mktemp() do path, io
    write(io, _contract_xml)
    close(io)
    _xml_events.parse_document(EzXML.readxml(path))
  end
  @test common.tick_scale == 12
  @test parsed.total_q == 3 // 1
  @test parsed.part_names == Dict("P1" => "Piano", "P2" => "Flute")
  @test [(e.time_q, e.bpm) for e in parsed.tempos] == [(3 // 2, 90.0)]

  expected = [
    (("P1", "1", "1"), 0 // 1, 1 // 1, 60),
    (("P1", "1", "1"), 0 // 1, 1 // 1, 65),
    (("P1", "2", "2"), 0 // 1, 1 // 2, 55),
    (("P1", "2", "2"), 3 // 2, 2 // 1, 62),
    (("P1", "1", "1"), 2 // 1, 5 // 2, 69),
    (("P1", "1", "1"), 5 // 2, 3 // 1, 70),
    (("P2", "1", "1"), 0 // 1, 1 // 1, 52),
    (("P2", "1", "1"), 2 // 1, 3 // 1, 53),
  ]
  note_key(event) = (event.stream_key, event.start_q, event.end_q, event.pitch)
  @test sort(note_key.(parsed.notes)) == sort(expected)

  _seed_fixture(_contract_xml) do (streams, measure_starts, names)
    @test names == parsed.part_names
    @test length(measure_starts) >= 2
    seed_events = [(key, event.start_tick // common.tick_scale,
      (event.start_tick + event.duration) // common.tick_scale, event.pitch)
      for (key, events) in streams for event in events]
    @test sort(seed_events) == sort(expected)
    @test measure_starts[1] == (0, "1")
    @test (24, "2") in measure_starts
    @test _seed_music.measure_at(measure_starts, 30) == ("2", 6)
    @test sum(length(phrase.points) for events in values(streams)
      for phrase in _seed_music.phrase_points(events, measure_starts)) == 7
  end
end

@testset "single division seed ticks and staff voice identity" begin
  xml = """
  <score-partwise><part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
  <part id="P1"><measure number="1"><attributes><divisions>4</divisions></attributes>
    <note><pitch><step>C</step><octave>4</octave></pitch><duration>4</duration><voice>1</voice></note>
    <note><pitch><step>D</step><octave>4</octave></pitch><duration>2</duration><voice>1</voice></note>
  </measure></part></score-partwise>
  """
  _seed_fixture(xml) do (streams, _, _)
    @test [event.start_tick for event in streams[("P1", "1", "1")]] == [0, 4]
    @test [event.duration for event in streams[("P1", "1", "1")]] == [4, 2]
  end
end

@testset "ASAP BWV846 two-measure excerpt shares events" begin
  path = joinpath(@__DIR__, "fixtures", "asap_bwv846_excerpt.musicxml")
  xml = read(path, String)
  analysis = _analyse_music.parse_musicxml_text(xml)
  common = _xml_events.parse_document(EzXML.readxml(path))
  streams, _, names = _seed_music.parse_musicxml(path)
  @test common.tick_scale == 16
  @test names == analysis.part_names
  @test length(analysis.notes) > 10
  @test sum(length, values(streams)) == length(analysis.notes)
  expected = sort([(event.stream_key, event.start_q, event.end_q, event.pitch)
    for event in analysis.notes])
  actual = sort([(key, event.start_tick // common.tick_scale,
    (event.start_tick + event.duration) // common.tick_scale, event.pitch)
    for (key, events) in streams for event in events])
  @test actual == expected
end
