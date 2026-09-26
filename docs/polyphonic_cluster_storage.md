# Lossless compressed cluster storage

## Purpose

`PolyphonicClusterManager` keeps the legacy clustering semantics while storing
long single-child repeat chains in a compact physical representation.

The fundamental rule is:

> Compression may change storage and computation reuse, but it must not change
> any logical cluster, window size, cluster id, start index, representative,
> score, prediction, occurrence metric, or simulation result.

The frozen legacy implementation under
`test/reference/polyphonic_cluster_manager_legacy.jl` is the behavioral oracle.

## Logical model

The public/logical model remains equivalent to the former tree:

```text
window=2  cluster A  si=...
  |
window=3  cluster B  si=...
  |
window=4  cluster C  si=...
```

Every logical window still exists. Nothing is discarded.

Consumers that need the old view use:

- `collect_clusters_each(manager)`
- `transform_clusters(manager)`
- `clusters_to_timeline(manager)`
- `clusters_to_dict(manager)`
- `logical_virtual_nodes(manager)`

These reconstruct or reference the same logical nodes from compressed storage.

## Physical model

The canonical physical store is:

```julia
Manager.cluster_spans::Vector{CompressedClusterSpan}
```

A span represents a losslessly compressible chain:

```text
CompressedClusterSpan
  window_min
  window_max
  cluster_ids
  si_min
  as_max
  versions
  fit_limits
  children
```

A logical node inside the span is addressed by `SpanClusterRef(span, offset)`.

The long representative is stored once in `as_max`. A shorter logical
representative is its exact prefix.

The start set is stored once in `si_min`. Per-window `fit_limits` preserve
the exact historical right-boundary condition, so the logical `si` for every
virtual window can be reconstructed even after the source time series grows.

## Compression condition

Two consecutive physical spans may be merged only if all of the following are
true:

1. They are consecutive window sizes.
2. The representative of the child exactly extends the parent representative.
3. Every logical child start set is exactly reconstructable from the parent's
   `si_min` and the child's own `fit_limit`.
4. The chain has no semantic branch that would be lost.

A non-prefix divergence causes only the affected logical node to be isolated
(copy-on-write); the rest of the path remains compressed.

## Mutation and compatibility

The clustering write path uses storage-independent logical accessors and
references rather than assuming a `PolyClusterNode` tree.

Important operations:

- `_find_cluster_ref`
- `_cluster_si_view`
- `_cluster_as_view`
- `_cluster_children`
- `_append_cluster_start!`
- `_replace_cluster_representative!`
- `_add_child_cluster!`
- `_add_root_cluster!`

This is what allows the physical representation to differ from the legacy tree
without changing clustering behavior.

Incremental ingestion compacts storage in batches. Bulk ingestion normalizes
once after the history has been processed. This avoids repeatedly splitting and
re-merging spans during every append.

## Simulation and rollback

Candidate simulation must be observationally pure.

A transaction snapshot includes:

- tasks
- cluster id counter
- updated cache-id sets
- compressed cluster spans
- cluster horizon

Rollback restores the compressed physical store as well as the logical result.

## Metric compatibility

The following continue to operate on every logical window exactly as before:

- cluster distance
- quantity/mass
- shape complexity
- recency weighting
- occurrence-interval analysis
- predictive distribution
- candidate simulation
- permanent commit

Distance calculations reuse prefix state where that reuse is mathematically
exact. Reuse is disabled when the representative version changes.

## API and UI compatibility

For now, API-facing cluster payloads remain backward compatible:

- `clusteredSubsequences` still contains one row per logical window/cluster.
- `clusters` still has the legacy nested JSON shape.

Therefore existing `ClustersRoll` hover/highlight behavior does not need to
change as part of the storage migration.

A compact payload is also available internally through
`compressed_clusters_payload(manager)`. It contains `window_min`,
`window_max`, logical cluster ids, shared indices, fit limits and children.
This is intended as the basis for a later UI redesign where long repeated
window chains can be rendered once instead of as many redundant horizontal
rows.

That future UI optimization is deliberately separate from the storage migration:
the current change preserves the old response contract first.

## Regression guarantee

`test/polyphonic_compression_equivalence.jl` runs the production manager and
the frozen legacy manager side by side over deterministic pattern families,
including:

- constant repetition
- alternating repetition
- periodic motifs
- branching extensions
- embedded long repeats
- rests / empty sets
- polyphonic chords
- changing chord cardinality
- approximate merges
- ordered vectors
- streamwise global surfaces
- recency
- seeded random scalar/polyphonic sequences

Both bulk and incremental paths are checked.

The comparison covers logical nodes, window sizes, cluster ids, `si`, `as`,
timeline output, transformed output, nested cluster JSON, caches, D/Q/C,
occurrence metrics, predictive distributions, candidate simulation and rollback.

Any future storage optimization should be rejected if this oracle diverges.
