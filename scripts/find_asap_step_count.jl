if !isdefined(Main, :TimeseriesClusteringAPI)
  include(joinpath(@__DIR__, "..", "src", "TimeseriesClusteringAPI.jl"))
end

const MA = Main.TimeseriesClusteringAPI.MusicAnalysis

function main()
  dataset_dir = length(ARGS) >= 1 ? abspath(ARGS[1]) : error("dataset directory required")
  target_steps = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : 2352

  sources = MA.list_asap_sources(dataset_dir)
  println("asap_source_count=", length(sources))

  matches = Any[]
  failures = 0
  for (index, source) in enumerate(sources)
    xml_score = string(source["xml_score"])
    path = joinpath(dataset_dir, split(xml_score, '/')...)
    isfile(path) || continue
    try
      parsed = MA.parse_musicxml_text(read(path, String))
      grid_den = MA.rhythm_denominator(parsed)
      total_steps_r = parsed.total_q * grid_den
      denominator(total_steps_r) == 1 || continue
      steps = Int(numerator(total_steps_r))
      if steps == target_steps
        item = Dict(
          "composer" => string(source["composer"]),
          "title" => string(source["title"]),
          "folder" => string(source["folder"]),
          "xml_score" => xml_score,
          "note_events" => length(parsed.notes),
          "total_quarters" => float(parsed.total_q),
          "grid_denominator" => grid_den,
          "step_count" => steps,
          "xml_bytes" => filesize(path),
        )
        push!(matches, item)
        println("asap_2352_match=", item)
      end
    catch err
      failures += 1
      println(stderr, "parse_failed index=", index, " path=", xml_score, " error=", sprint(showerror, err))
    end
  end

  println("asap_2352_summary=", Dict(
    "target_steps" => target_steps,
    "matches" => length(matches),
    "failures" => failures,
  ))
  isempty(matches) && exit(2)
end

main()
