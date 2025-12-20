# time_series_subsequence_clustering_web

Time-series subsequence clustering, complexity-guided generation, and polyphonic music rendering — packaged as a web application.

This project scans an input time series from the beginning, discovers recurring subsequences across multiple window sizes, and exposes them as clusters you can inspect. Those clustering results can also be used as a “structural complexity” signal to drive greedy, step-by-step generation. For music use-cases, generated sequences can be mapped into multiple auditory streams (voices) with controls over octave, pitch class, loudness, and timbre.

## How it works

### 1) Incremental subsequence clustering
- The time series is processed **sequentially** (left to right).
- For each new point, the system builds/updates clusters of subsequences across increasing window sizes.
- Similar subsequences are merged into clusters, while new motifs form new clusters.

### 2) Cluster-derived “complexity” metrics
From the cluster structure, the system derives numerical scores that can be used to compare candidates:

- **Distance-based variation (cluster-to-cluster distance drift):**  
  Measures how much **the distance between clusters** changes as new subsequences are added.  
  Intuitively, if clusters that used to be “close” become “far” (or vice versa) over time, this metric grows.

- **Quantity / repetition structure:**  
  Captures how strongly motifs recur and how repetition structure evolves.

- **Internal complexity:**  
  Measures how much the average subsequence inside a cluster changes from step to step.

These act as a proxy for “how structured / complex the series looks” to the clustering model.

### 3) Greedy, search-based generation
- You provide a **target complexity trajectory** (e.g. 0→1 over time).
- For each step, the generator proposes candidate next values (or candidate chords in the polyphonic mode),
  simulates “what clustering would look like if we appended it,”
  and selects the candidate that best matches the target score.

### 4) Polyphonic parameter generation (music mode)
In polyphonic mode, generation happens across multiple dimensions (e.g. octave, pitch class, loudness, timbre).
- Stream-wise and global targets shape the output.
- A short-term-memory (STM) roughness/dissonance model can be used to select pitch-class sets that match a dissonance target.
- Results can be rendered/played via the web UI (and optionally via SuperCollider-based synthesis/rendering).

## Features

### Analysis
- Incremental subsequence clustering over multiple window sizes
- Cluster timeline output for visualization
- Structural metrics derived from clusters (cluster-distance drift / repetition / internal complexity)

### Generation
- Complexity-guided greedy generation for scalar time series
- Polyphonic generation across multiple streams (voices)
- Per-dimension controls (global / center / spread / conc) to shape:
  - octave
  - pitch class / note decisions
  - volume
  - timbre parameters (brightness / hardness / texture)
  - chord size (stream-wise chord tone count)

### Music / perception-oriented controls
- STM-based dissonance/roughness targeting (fast “virtual” estimation; currently using octave + volume + pitch class)
- Deterministic candidate selection (no randomness / probability sampling)

### Web app
- Vue + Vuetify frontend
- Rails API backend
- Progress updates via ActionCable

## Deployment

Production instance: https://time-series-subsequence-clustering-web.onrender.com/
