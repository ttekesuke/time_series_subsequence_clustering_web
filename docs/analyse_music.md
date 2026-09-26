# analyse_music

POST /api/web/time_series/analyse_music analyses an existing MusicXML score with the same subsequence-clustering concepts used by generate_polyphonic.

Input sources:
- Uploaded .xml or .musicxml text from the MusicAnalyse dialog.
- A score in data/asap-dataset selected from metadata.csv.
- Compressed .mxl is intentionally unsupported.

Rhythm is kept exact. MusicXML durations are converted to rational quarter-note units, and the least common denominator of all event boundaries is computed before clustering starts. If that denominator exceeds 60, the request is rejected with HTTP 422 and code rhythm_resolution_exceeded. Therefore 3:4:5 is accepted at denominator 60, while combinations requiring a finer exact grid are not silently approximated.

Analysed musical dimensions:
- note: median MIDI pitch of each sounding stream, with the full chord retained in the piano roll.
- area: the same four-semitone register band convention as generate_polyphonic.
- chord_range and density: inferred with the same helper used to seed generate_polyphonic.
- vol: MusicXML dynamics mapped to 0..1; rests are 0. Dynamics carry forward and wedges are interpolated when possible.
- tie: 0 for re-articulation, 0.5 for partial continuation, 1 for complete continuation.
- dissonance: the same pitch-class-canonical DissonanceStmManager used by generate_polyphonic.
- stream_count: number of sounding part/staff/voice streams at each exact step.

Acoustic-only generation dimensions (brightness, noise, harmonicity, attack, decay/sustain, release) and composition-control parameters (recency, stream strength, register freedom) are not inferred from MusicXML.

For each dimension, global and per-stream managers are analysed incrementally. The score at step t is evaluated from the committed history before t, then the observed value is committed. The response exposes Prediction, Diversity, Shape, Occurrence, Mass and Combined axes. These reuse the existing calibrators, predictive distribution and cluster metrics. Combined uses the same server-owned polyphonic weights as generate_polyphonic.

Concordance is an observed 0..1 agreement series derived from pairwise normalized distances between simultaneously sounding stream values. It is reported with each dimension but is not a composition target.

The response also includes cluster timelines for global and per-stream scopes, a MIDI-number piano-roll representation, exact timing metadata, raw structural metrics, and score metadata. The MusicAnalyse UI can switch between Complexity and Cluster modes; cluster hover highlights all matching score ranges in the piano roll. The complete response can be downloaded as music-analysis.json.


## Performance bound for subsequence clustering

Full MusicXML scores can contain thousands of exact-grid steps. The generic
subsequence cluster manager normally allows a repeated window to grow almost
to the full series length, which makes later observed steps increasingly
expensive.

MusicXML analysis therefore caps clustering windows at
`MUSIC_ANALYSIS_MAX_CLUSTER_WINDOW_SIZE = 32` steps. Prediction already uses
`PREDICTIVE_MAX_CONTEXT_LENGTH = 32`, so observed complexity and cluster
visualization use the same bounded context scale. The exact rhythmic grid and
all displayed score values are still retained; only the maximum subsequence
window considered by clustering is bounded.
