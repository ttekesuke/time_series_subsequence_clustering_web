# Test and benchmark entry points

Run every backend regression test with `julia --project=. test/runtests.jl` from
the repository root. The runner discovers every top-level `test/*.jl` file except
itself, so a new test joins CI without another workflow edit. To run one file,
pass its name, for example `julia --project=. test/runtests.jl voicevox_client.jl`.
The CI backend job also creates a deliberately failing test and checks that the
runner exits with an error.

`Verify Compressed Cluster Integration` runs the complete Julia test set, the
VOICEVOX worker's Python request tests, a bounded MusicAnalyse HTTP JSON test,
the frontend typecheck/build, and the existing bounded staging/event-index
benchmarks. The HTTP test uses a two-step uploaded score and checks both a
serialized success response and the invalid-file 422 response. It does not need
the ASAP dataset or a VOICEVOX Engine.

The other workflows have narrower purposes:

| Workflow | Scope |
| --- | --- |
| Verify Compression Oracle | Compression equivalence and observed MusicAnalyse metrics on pull requests and main. |
| Verify Compressed Cluster Consumers | Independent Julia test-file matrix and frontend build on main; the full suite above covers newly added files on pull requests. |
| Verify Physical Cluster Migration | Manually triggered historical migration checks. |
| Benchmark Lossless Clustering | Manually triggered, heavier legacy comparison; excluded from routine CI. |
| Polyphonic Generate | Generation artifact workflow; requires its own services and is not a general test runner. |

`scripts/benchmark_music_event_index.jl` uses at most 512 synthetic grid points
and three parts. It prints the tested Git SHA, fixture size, measured allocation
bytes, elapsed time for each mode, and total wall time. Keep long real-score
measurements optional and separate from the short CI suite. An example CI run
before this change measured about 17 seconds for that benchmark step; measured
algorithm times exclude Julia startup and compilation. The HTTP smoke test also
prints its response size, elapsed time, and SHA. Neither bounded fixture stands
in for a long MusicXML performance test.
