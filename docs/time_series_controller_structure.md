# TimeSeriesController internal structure

`TimeSeriesController` keeps the existing HTTP-facing function names, but large
responsibilities are being moved to focused source files incrementally.

## Current split

- `src/controllers/time_series_controller.jl`
  - request orchestration and the legacy/public controller entry points;
  - shared parsing helpers that have not yet been extracted;
  - database search and music generation paths that will be split in later steps.
- `src/controllers/time_series/analyse_music_jobs.jl`
  - persistent MusicAnalyse job registry;
  - job metadata/result file lifecycle;
  - progress, cancellation, restart recovery and result response handling.

The job file is included **inside the `TimeSeriesController` module**. This is a
physical responsibility split only: function names, module globals, routes and
response shapes are unchanged.

## Dependency direction

`routes.jl`
→ `TimeSeriesController` public entry points
→ focused controller files / domain modules
→ `MusicAnalysis`, cluster managers, repositories and external clients.

Focused controller files may use shared helpers defined by
`TimeSeriesController` while migration is in progress. New cross-cutting logic
should not be copied back into the monolithic controller; when a dependency
becomes stable, move it behind a narrower module/function boundary.

## Migration rule

Each extraction should preserve the existing API and use existing regression
fixtures as an equivalence oracle. Algorithmic changes belong in their own issue
rather than being mixed into structural moves.
