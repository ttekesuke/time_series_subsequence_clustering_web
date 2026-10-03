# Run from any working directory with `julia --project=. test/runtests.jl`.
# Every new test/*.jl file is included automatically, except this runner.
# Pass one or more test filenames as arguments to run a subset.
ENV["GENIE_ENV"] = "test"
cd(normpath(joinpath(@__DIR__, "..")))

using Genie
using Test
Genie.loadapp()

all_tests = sort(filter(name -> endswith(name, ".jl") && name != "runtests.jl",
  readdir(@__DIR__)))
selected = if isempty(ARGS)
  all_tests
else
  requested = basename.(ARGS)
  for name in requested
    name in all_tests || error("Unknown test file: $(name)")
  end
  requested
end

@testset "Backend regression" begin
  for name in selected
    @testset "$name" begin
      include(joinpath(@__DIR__, name))
    end
  end
end
