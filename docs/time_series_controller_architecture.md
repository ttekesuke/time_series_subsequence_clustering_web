# TimeSeriesController architecture

`TimeSeriesController` keeps the public endpoint names used by `routes.jl`, but
the implementation is split by responsibility under
`src/controllers/time_series/`.

The split is intentionally internal: all files are included into the same Julia
module, so existing callers and endpoint names remain unchanged.

## Responsibility map

| File | Responsibility |
| --- | --- |
| `time_series_controller.jl` | Public module shell, shared low-level utilities/types, GitHub dispatch, and MusicXML response helpers. |
| `generate_polyphonic_validation.jl` | `generate_polyphonic` request/resource/evaluation-budget validation. |
| `polyphonic_generation.jl` | Polyphonic generation parameter handling, candidate evaluation orchestration, stream lifecycle, voice-token planning, cache commits, and response assembly. |
| `github_dispatch.jl` | GitHub Actions workflow dispatch, run discovery, payload compression, and dispatch endpoint response handling. |
| `musicxml_response.jl` | ASAP MusicXML file access, phrase slicing, match highlighting, note-position extraction, and DB-point-to-score mapping endpoints. |
| `scalar_actions.jl` | Scalar `analyse` and `generate` endpoints. |
| `generation_scoring.jl` | Metric calibration, predictive/occurrence/structural scoring, dissonance candidate selection, and initial scoring-cache setup. |
| `similarity_search.jl` | `query_db` orchestration, note/volume query strategy, and octave-invariant matching strategy. |
| `query_match_filter.jl` | Exact match expansion, deduplication, containment filtering, and match score ordering. |
| `query_memory_budget.jl` | Query series chunk sizing from environment, system memory, and cgroup limits. |
| `influx_config.jl` | Influx mode/environment/database/bucket/token configuration. |
| `influx_transport.jl` | v1-compatible HTTP query transport and authentication retry order. |
| `influx_dbrp.jl` | Cloud DBRP mapping and bucket lookup. |
| `influx_sql.jl` | Influx SQL query, JSONL parsing, SQL escaping, and SQL repository operations. |
| `influx_flux.jl` | Influx v2/Flux query transport, CSV parsing, and Flux repository operations. |
| `influx_repository.jl` | Query-mode dispatch and InfluxQL/v1-compatible series repository operations. |
| `analyse_music_source.jl` | Uploaded/ASAP MusicXML source validation and loading. |
| `analyse_music_action.jl` | Synchronous MusicAnalyse endpoint and shared analysis execution. |
| `analyse_music_jobs.jl` | Persistent MusicAnalyse jobs, progress, cancellation, restart handling, and saved results. |

## Dependency direction

The intended dependency direction is:

```text
routes.jl
  -> TimeSeriesController public actions
      -> request/source validation
      -> endpoint orchestration
          -> repository / transport
          -> exact search / scoring helpers
          -> PolyphonicClusterManager / MusicAnalysis
      -> response assembly
```

For DB search:

```text
similarity_search
  -> influx_repository
      -> influx_config
      -> influx_transport
      -> influx_dbrp
      -> influx_sql / influx_flux / InfluxQL helpers
  -> query_memory_budget
  -> query_match_filter
  -> PolyphonicClusterManager
```

For MusicAnalyse:

```text
analyse_music_action / analyse_music_jobs
  -> analyse_music_source
  -> MusicAnalysis
```

For scalar generation:

```text
scalar_actions
  -> generation_scoring
  -> PolyphonicClusterManager
```

For polyphonic generation:

```text
polyphonic_generation
  -> generate_polyphonic_validation
  -> generation_scoring
  -> MultiStreamManager / DissonanceStmManager / VoiceTokenGeneration
  -> PolyphonicClusterManager
```

The include files should not call endpoint wrappers in the opposite direction.
Shared helpers may be used by endpoint orchestration, but transport/repository
layers must not depend on UI- or route-specific response handling.

## Exactness contract

This refactor is structural. It must not change:

- candidate sets or candidate ordering;
- clustering windows;
- containment rules;
- distance/scoring formulae;
- recurrence/occurrence calculations;
- tie-break order;
- DB query ordering or result ordering;
- response field names and endpoint names.

Performance work may cache or incrementally maintain values only when existing
oracle tests prove equality with the original calculation.

## Verification

Every refactor PR runs the same repository CI:

- full Julia backend regression suite;
- compression oracle/equivalence tests;
- bounded generation/cache/indexing benchmarks;
- exact quadratic-vs-indexed query-match comparison;
- MusicAnalyse HTTP JSON smoke test;
- frontend typecheck/build;
- VOICEVOX worker tests.

Relevant focused tests include:

- `test/query_match_filter.jl`
- `test/normalize_octave_invariance.jl`
- `test/generate_polyphonic_validation.jl`
- `test/metric_calibration_and_chord_greedy.jl`
- `test/predictive_complexity.jl`
- `test/occurrence_interval_complexity.jl`
- `test/analyse_music.jl`
- `test/analyse_music_jobs.jl`
- `test/analyse_music_source.jl`
- `test/polyphonic_compression_equivalence.jl`

### DB-mode coverage

The repository contains three DB query modes:

- v1-compatible InfluxQL (default);
- SQL (`INFLUX_QUERY_MODE=sql`);
- Flux (`INFLUX_QUERY_MODE=flux`).

Mode-specific parsing and repository logic are physically separated, while
`influx_repository.jl` owns dispatch. The similarity-search pipeline consumes
the same normalized series-stat/grouped-series shapes regardless of mode.

The structural refactor is covered by the full regression suite on every PR.
A live external Influx instance is intentionally not required by normal CI.
If #36 is to be closed under the strict interpretation of “all DB modes response
equivalence”, add deterministic HTTP fixtures for InfluxQL, SQL, and Flux and
exercise `query_db` through each mode before closing the issue.

## Adding new code

Prefer adding logic to the responsibility file that already owns it instead of
growing `time_series_controller.jl` again. New endpoint-specific validation
should happen before long-running computation, and DB-specific response parsing
should stay inside the corresponding repository implementation.
