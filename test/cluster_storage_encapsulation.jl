using Test

@testset "compressed cluster storage stays encapsulated" begin
  src_root = normpath(joinpath(@__DIR__, "..", "src"))
  manager_path = normpath(joinpath(src_root, "polyphonic", "polyphonic_cluster_manager.jl"))
  forbidden = [
    "cluster_spans",
    "SpanClusterRef",
    "CompressedClusterSpan",
    "PolyClusterNode",
  ]

  violations = String[]
  for (root, _, files) in walkdir(src_root)
    for file in files
      endswith(file, ".jl") || continue
      path = normpath(joinpath(root, file))
      path == manager_path && continue
      source = read(path, String)
      for token in forbidden
        occursin(token, source) || continue
        push!(violations, "$(relpath(path, src_root)): $(token)")
      end
    end
  end

  @test isempty(violations)
end
