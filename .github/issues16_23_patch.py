from pathlib import Path
import re

ROOT = Path('.')

def read(path):
    return (ROOT / path).read_text()

def write(path, text):
    p = ROOT / path
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(text)

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one occurrence, found {count}')
    return text.replace(old, new, 1)

def sub_once(text, pattern, repl, label, flags=0):
    out, count = re.subn(pattern, repl, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly one regex match, found {count}')
    return out

# ---------------------------------------------------------------------------
# #19 BPM: backend canonical default follows the existing UI/runtime contract.
# Keep POLYPHONIC_BPM as a compatibility alias.
# ---------------------------------------------------------------------------
path = 'src/config.jl'
text = read(path)
text = replace_once(
    text,
    'const POLYPHONIC_BPM::Float64 = 240.0\nconst POLYPHONIC_STEP_DURATION::Float64 = SECONDS_PER_MINUTE / POLYPHONIC_BPM',
    'const POLYPHONIC_BPM_DEFAULT::Float64 = 480.0\nconst POLYPHONIC_BPM::Float64 = POLYPHONIC_BPM_DEFAULT\nconst POLYPHONIC_STEP_DURATION::Float64 = SECONDS_PER_MINUTE / POLYPHONIC_BPM_DEFAULT',
    'config BPM default',
)
write(path, text)

# ---------------------------------------------------------------------------
# #17: canonicalize every Dissonance STM boundary to C4 pitch classes.
# ---------------------------------------------------------------------------
path = 'src/polyphonic/dissonance_stm_manager.jl'
text = read(path)
marker = '# ---- public api ----\n\n'
insert = '''# Dissonance STM uses a pitch-class-canonical coordinate system.  Absolute\n# register is intentionally ignored so seed, preview, commit, and memory\n# interference all measure the same interval structure.\n@inline canonical_midi_note(note::Integer)::Int =\n  Config.MIDI_C4 + mod(Int(note), Config.STEPS_PER_OCTAVE)\n\nfunction canonical_midi_notes(midi_notes::Vector{Int})::Vector{Int}\n  return Int[canonical_midi_note(note) for note in midi_notes]\nend\n\n'''
text = replace_once(text, marker, insert + marker, 'STM canonical helper')
text = replace_once(
    text,
    '''function evaluate(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64)::Float64\n  d_current = dissonance_current(mgr, midi_notes, amps)\n  return d_current + memory_interference(mgr, midi_notes, amps, onset, d_current)\nend\n\nfunction commit!(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64)::Float64\n  d_current = dissonance_current(mgr, midi_notes, amps)\n  d_total = d_current + memory_interference(mgr, midi_notes, amps, onset, d_current)\n\n  prune!(mgr, onset)\n\n  push!(mgr.memory, MemoryEvent(float(onset), copy(midi_notes), copy(amps), d_current))\n  return d_total\nend''',
    '''function evaluate(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64)::Float64\n  canonical_notes = canonical_midi_notes(midi_notes)\n  d_current = dissonance_current(mgr, canonical_notes, amps)\n  return d_current + memory_interference(mgr, canonical_notes, amps, onset, d_current)\nend\n\nfunction commit!(mgr::Manager, midi_notes::Vector{Int}, amps::Vector{Float64}, onset::Float64)::Float64\n  canonical_notes = canonical_midi_notes(midi_notes)\n  d_current = dissonance_current(mgr, canonical_notes, amps)\n  d_total = d_current + memory_interference(mgr, canonical_notes, amps, onset, d_current)\n\n  prune!(mgr, onset)\n\n  push!(mgr.memory, MemoryEvent(float(onset), copy(canonical_notes), copy(amps), d_current))\n  return d_total\nend''',
    'STM evaluate/commit canonicalization',
)
write(path, text)

# ---------------------------------------------------------------------------
# #22: no phantom root before a real min_window subsequence exists.
# ---------------------------------------------------------------------------
path = 'src/polyphonic/polyphonic_cluster_manager.jl'
text = read(path)
old = '''  # seed representative = first subsequence (Ruby fix)\n  seed_as =\n    if length(data) >= min_window_size\n      deep_copy_seq(data[1:min_window_size])\n    else\n      [Float64[] for _ in 1:min_window_size]\n    end\n\n  clusters = Dict{Int,PolyClusterNode}(0 => PolyClusterNode([0], Dict{Int,PolyClusterNode}(), seed_as))\n\n  updated_dist = Dict{Int,Set{Int}}(min_window_size => Set([0]))\n  updated_qty  = Dict{Int,Set{Int}}(min_window_size => Set([0]))\n\n  dist_cache = Dict{Int,Dict{Tuple{Int,Int},Float64}}(min_window_size => Dict{Tuple{Int,Int},Float64}())\n  qty_cache  = Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}())\n  comp_cache = Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}())'''
new = '''  # A root represents the first real min-window subsequence.  Short inputs\n  # have no such subsequence and therefore start with an empty tree.\n  has_root = length(data) >= min_window_size\n  clusters = Dict{Int,PolyClusterNode}()\n  if has_root\n    seed_as = deep_copy_seq(data[1:min_window_size])\n    clusters[0] = PolyClusterNode([0], Dict{Int,PolyClusterNode}(), seed_as)\n  end\n\n  updated_dist = has_root ? Dict{Int,Set{Int}}(min_window_size => Set([0])) : Dict{Int,Set{Int}}()\n  updated_qty  = has_root ? Dict{Int,Set{Int}}(min_window_size => Set([0])) : Dict{Int,Set{Int}}()\n\n  dist_cache = has_root ? Dict{Int,Dict{Tuple{Int,Int},Float64}}(min_window_size => Dict{Tuple{Int,Int},Float64}()) : Dict{Int,Dict{Tuple{Int,Int},Float64}}()\n  qty_cache  = has_root ? Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}()) : Dict{Int,Dict{Int,Float64}}()\n  comp_cache = has_root ? Dict{Int,Dict{Int,Float64}}(min_window_size => Dict{Int,Float64}()) : Dict{Int,Dict{Int,Float64}}()\n  cluster_id_counter = has_root ? 1 : 0'''
text = replace_once(text, old, new, 'PCM short constructor')
text = replace_once(text, '    clusters,\n    1,\n    Tuple{Vector{Int},Int}[],', '    clusters,\n    cluster_id_counter,\n    Tuple{Vector{Int},Int}[],', 'PCM cluster counter')
marker = '# Distance functions (Rails 1:1)\n'
helper = '''function _initialize_root_cluster_if_ready!(mgr::Manager)::Bool\n  !isempty(mgr.clusters) && return false\n  length(mgr.data) >= mgr.min_window_size || return false\n  seed_as = deep_copy_seq(mgr.data[1:mgr.min_window_size])\n  mgr.clusters[0] = PolyClusterNode([0], Dict{Int,PolyClusterNode}(), seed_as)\n  mgr.cluster_id_counter = max(mgr.cluster_id_counter, 1)\n  mgr.updated_cluster_ids_per_window_for_calculate_distance[mgr.min_window_size] = Set([0])\n  mgr.updated_cluster_ids_per_window_for_calculate_quantities[mgr.min_window_size] = Set([0])\n  get!(mgr.cluster_distance_cache, mgr.min_window_size, Dict{Tuple{Int,Int},Float64}())\n  get!(mgr.cluster_quantity_cache, mgr.min_window_size, Dict{Int,Float64}())\n  get!(mgr.cluster_complexity_cache, mgr.min_window_size, Dict{Int,Float64}())\n  return true\nend\n\n'''
text = replace_once(text, marker, helper + marker, 'PCM root initializer')
text = replace_once(
    text,
    '''function process_data!(mgr::Manager)\n  for i in 1:length(mgr.data)\n    data_index = i - 1\n    if data_index <= mgr.min_window_size - 1\n      continue\n    end\n    clustering_subsequences_incremental!(mgr, data_index)\n  end\nend\n\nfunction add_data_point_permanently!(mgr::Manager, val::PolySet)\n  push!(mgr.data, val)\n  clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)\nend''',
    '''function process_data!(mgr::Manager)\n  _initialize_root_cluster_if_ready!(mgr)\n  isempty(mgr.clusters) && return nothing\n  for i in 1:length(mgr.data)\n    data_index = i - 1\n    if data_index <= mgr.min_window_size - 1\n      continue\n    end\n    clustering_subsequences_incremental!(mgr, data_index)\n  end\n  return nothing\nend\n\nfunction add_data_point_permanently!(mgr::Manager, val::PolySet)\n  push!(mgr.data, val)\n  length(mgr.data) < mgr.min_window_size && return nothing\n  _initialize_root_cluster_if_ready!(mgr) && return nothing\n  clustering_subsequences_incremental!(mgr, length(mgr.data) - 1)\n  return nothing\nend''',
    'PCM process/add short handling',
)
write(path, text)

# ---------------------------------------------------------------------------
# #20: voice token complexity uses the same predictive+structural definition.
# ---------------------------------------------------------------------------
path = 'src/voice/voice_token_generation.jl'
text = read(path)
pattern = r'''function _candidate_complexity_scores\(\n  manager::PolyphonicClusterManager\.Manager,\n  candidates::Vector\{Vector\{Float64\}\},\n\)::Vector\{Float64\}\n.*?\nend\n\nconst _KANA_VOWEL_GROUPS'''
replacement = '''function _candidate_complexity_scores(\n  manager::PolyphonicClusterManager.Manager,\n  candidates::Vector{Vector{Float64}},\n)::Vector{Float64}\n  isempty(candidates) && return Float64[]\n  distribution = PolyphonicClusterManager.build_predictive_distribution(manager)\n  calibrator = PolyphonicClusterManager.build_extended_metric_calibrator(manager)\n  predictive_scores = Float64[]\n  raw_distance = Float64[]\n  raw_quantity = Float64[]\n  raw_complexity = Float64[]\n  temporal_metrics = PolyphonicClusterManager.OccurrenceIntervalMetrics[]\n\n  for candidate in candidates\n    metrics = PolyphonicClusterManager.simulate_add_and_calculate_all_extended(manager, candidate)\n    predictive = PolyphonicClusterManager.predictive_surprise_score(manager, distribution, candidate)\n    push!(predictive_scores, predictive === nothing ? NaN : float(predictive))\n    push!(raw_distance, metrics.distance)\n    push!(raw_quantity, metrics.quantity)\n    push!(raw_complexity, metrics.complexity)\n    push!(temporal_metrics, metrics.occurrence_intervals)\n  end\n\n  return PolyphonicClusterManager.combine_predictive_structural_scores(\n    predictive_scores,\n    raw_distance,\n    raw_quantity,\n    raw_complexity,\n    temporal_metrics;\n    calibrator=calibrator,\n  )\nend\n\nconst _KANA_VOWEL_GROUPS'''
# Common scoring helpers currently live in the controller module, not PCM.  The
# imports are adjusted below so voice uses that same implementation directly.
# First patch function using controller-qualified names instead of PCM names.
replacement = replacement.replace('PolyphonicClusterManager.build_extended_metric_calibrator', 'TimeSeriesScoring.build_extended_metric_calibrator')
replacement = replacement.replace('PolyphonicClusterManager.combine_predictive_structural_scores', 'TimeSeriesScoring.combine_predictive_structural_scores')
text = sub_once(text, pattern, replacement, 'voice scoring function', flags=re.S)
# Add a narrow parent-module alias to avoid copying the scoring implementation.
text = replace_once(text, 'using ..PolyphonicClusterManager\n', 'using ..PolyphonicClusterManager\nimport ..TimeSeriesController as TimeSeriesScoring\n', 'voice scoring import')
write(path, text)

# ---------------------------------------------------------------------------
# Controller: #16 fixed snapshot, #18 lifecycle source, #21 response/no-op,
# #23 validation and candidate selection defense.
# ---------------------------------------------------------------------------
path = 'src/controllers/time_series_controller.jl'
text = read(path)

text = replace_once(
    text,
    '''Base.showerror(io::IO, err::GeneratePolyphonicRequestError) = print(io, err.message)\n\n@noinline function _invalid_generate_polyphonic_request(code::AbstractString, message::AbstractString)\n  throw(GeneratePolyphonicRequestError(String(code), String(message)))\nend''',
    '''Base.showerror(io::IO, err::GeneratePolyphonicRequestError) = print(io, err.message)\n\nstruct GenerateRequestError <: Exception\n  code::String\n  message::String\nend\n\nBase.showerror(io::IO, err::GenerateRequestError) = print(io, err.message)\n\n@noinline function _invalid_generate_polyphonic_request(code::AbstractString, message::AbstractString)\n  throw(GeneratePolyphonicRequestError(String(code), String(message)))\nend\n\n@noinline function _invalid_generate_request(code::AbstractString, message::AbstractString)\n  throw(GenerateRequestError(String(code), String(message)))\nend''',
    'generate request error type',
)

text = replace_once(
    text,
    '''function select_candidate_by_complexity_score(scores::Vector{Float64}, target_val::Float64)::Int\n  best_index = 0''',
    '''function select_candidate_by_complexity_score(scores::Vector{Float64}, target_val::Float64)::Int\n  isempty(scores) && throw(ArgumentError("candidate complexity scores must not be empty"))\n  best_index = 0''',
    'empty candidate selector defense',
)

text = replace_once(
    text,
    '''  candidate_min_master = _parse_int(get(p, "range_min", Config.DEFAULT_RANGE_MIN))\n  candidate_max_master = _parse_int(get(p, "range_max", Config.DEFAULT_RANGE_MAX))\n\n  min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE''',
    '''  candidate_min_master = _parse_int(get(p, "range_min", Config.DEFAULT_RANGE_MIN))\n  candidate_max_master = _parse_int(get(p, "range_max", Config.DEFAULT_RANGE_MAX))\n  candidate_min_master <= candidate_max_master || _invalid_generate_request(\n    "invalid_range",\n    "generate.range_min must be less than or equal to generate.range_max.",\n  )\n\n  min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE''',
    'generate range validation',
)

# Work only inside generate_polyphonic for the remaining replacements.
gp_start = text.index('function generate_polyphonic()')
prefix, gp = text[:gp_start], text[gp_start:]

# #21 remove inert debug parsing block.
gp = re.sub(
    r'''\n  debug_poly = false\n  try\n    debug_poly = .*?\n  catch\n    debug_poly = false\n  end\n''',
    '\n',
    gp,
    count=1,
    flags=re.S,
)

# #16 create closure binding before resolver definitions.
needle = '  function _resolved_fixed_value_for_stream'
if needle not in gp:
    raise SystemExit('fixed resolver marker missing')
gp = gp.replace(needle, '  initial_last_step_snapshot = Any[]\n\n' + needle, 1)
old = 'if spec.fixed_source == :initial_context_last_step && !isempty(results)\n      last_step = results[end]'
count = gp.count(old)
if count != 2:
    raise SystemExit(f'fixed snapshot resolver: expected 2 mutable-result references, found {count}')
gp = gp.replace(old, 'if spec.fixed_source == :initial_context_last_step && !isempty(initial_last_step_snapshot)\n      last_step = initial_last_step_snapshot')

# Snapshot after initial notes/CR/DEN have been normalized/inferred.
marker = '  merge_threshold_ratio = _parse_float(get(gp, "merge_threshold_ratio", Config.DEFAULT_POLYPHONIC_MERGE_THRESHOLD_RATIO))'
gp = replace_once(
    gp,
    marker,
    '  initial_last_step_snapshot = isempty(results) ? Any[] : deepcopy(results[end])\n\n' + marker,
    'initial last-step snapshot assignment',
)

# #18 always maintain a volume/presence manager, even when volume is fixed.
setup_start = gp.index('  for (key, history, track_presence) in (')
setup_end = gp.index('  cr_values = collect', setup_start)
setup = gp[setup_start:setup_end]
setup = replace_once(setup, '    if get(dim_accept, key, true)', '    if key == "vol" || get(dim_accept, key, true)', 'always create vol manager')
gp = gp[:setup_start] + setup + gp[setup_end:]
gp = replace_once(
    gp,
    '    lifecycle_mgr = haskey(managers, "vol") ? managers["vol"][:stream] : managers["note"][:stream]',
    '    lifecycle_mgr = managers["vol"][:stream]',
    'lifecycle volume source',
)

# Commit fixed volume into the dedicated presence history before continuing.
dim_start = gp.index('    for (key, range_vec, out_idx) in dim_order')
mgr_get = gp.index('      mgrs = get(managers, key, nothing)', dim_start)
fixed_segment = gp[dim_start:mgr_get]
anchor = '        end\n        continue\n      end\n\n'
pos = fixed_segment.rfind(anchor)
if pos < 0:
    raise SystemExit('fixed-dimension continue anchor missing')
commit_fixed_vol = '''        end\n        if key == "vol"\n          mgrs = managers["vol"]\n          g_offset = get(mgrs, :global_offset, 0.0)\n          global_vals = _encode_streamwise_row(stream_axis, plan.active_ids, fixed_vals, g_offset)\n          _set_generation_failure_context!(failure_context; operation="commit_global", dimension="vol", candidate=copy(fixed_vals))\n          PolyphonicClusterManager.add_data_point_permanently(mgrs[:global], global_vals)\n          PolyphonicClusterManager.update_caches_permanently(mgrs[:global])\n          _set_generation_failure_context!(failure_context; operation="commit_streams", dimension="vol", candidate=copy(fixed_vals))\n          MultiStreamManager.commit_state!(mgrs[:stream], fixed_vals, (target=st_target, spread=st_spread))\n          MultiStreamManager.update_caches_permanently!(mgrs[:stream])\n        end\n        continue\n      end\n\n'''
fixed_segment = fixed_segment[:pos] + commit_fixed_vol + fixed_segment[pos + len(anchor):]
gp = gp[:dim_start] + fixed_segment + gp[mgr_get:]

# #21 expose real stable-ID volume/presence strengths.
response_marker = '  return Dict(\n    "timeSeries" => results,'
strength_code = '''  strength_report = MultiStreamManager.stream_strengths_report(managers["vol"][:stream])\n  stream_strengths = Dict{String,Any}(\n    string(stream_id) => Dict(\n      "active" => entry.active,\n      "presenceAvg" => entry.presence_avg,\n      "presenceCount" => entry.presence_count,\n      "lastValue" => copy(entry.last_value),\n    )\n    for (stream_id, entry) in strength_report\n  )\n\n'''
gp = replace_once(gp, response_marker, strength_code + response_marker, 'stream strength report')
gp = replace_once(gp, '    "streamStrengths" => nothing,', '    "streamStrengths" => stream_strengths,', 'stream strength response')

text = prefix + gp
write(path, text)

# ---------------------------------------------------------------------------
# Routes: structured 422 for generate invalid range.
# ---------------------------------------------------------------------------
path = 'routes.jl'
text = read(path)
marker = '''function _with_polyphonic_request_errors(f::Function)\n  try\n    return f()\n  catch err\n    if err isa TimeSeriesController.GeneratePolyphonicRequestError\n      return json(Dict(\n        "ok" => false,\n        "error" => "invalid_generate_polyphonic_request",\n        "code" => err.code,\n        "message" => err.message,\n      ); status=422)\n    end\n    rethrow()\n  end\nend\n'''
addition = marker + '''\nfunction _with_generate_request_errors(f::Function)\n  try\n    return f()\n  catch err\n    if err isa TimeSeriesController.GenerateRequestError\n      return json(Dict(\n        "ok" => false,\n        "error" => "invalid_generate_request",\n        "code" => err.code,\n        "message" => err.message,\n      ); status=422)\n    end\n    rethrow()\n  end\nend\n'''
text = replace_once(text, marker, addition, 'generate route error wrapper')
text = replace_once(
    text,
    '''route("/api/web/time_series/generate", method=POST) do\n  TimeSeriesController.generate() |> json\nend''',
    '''route("/api/web/time_series/generate", method=POST) do\n  _with_generate_request_errors() do\n    TimeSeriesController.generate() |> json\n  end\nend''',
    'generate route wrapper',
)
write(path, text)

# ---------------------------------------------------------------------------
# Frontend: #19 shared BPM constant, #21 remove no-op request fields.
# ---------------------------------------------------------------------------
write('frontend/src/constants/musicDefaults.ts', '''// Contract-checked against src/config.jl by test/issues_16_23_regressions.jl.\nexport const POLYPHONIC_BPM_DEFAULT = 480\n''')

for path, import_path in [
    ('frontend/src/components/dialog/MusicGenerateDialog.vue', '../../constants/musicDefaults'),
    ('frontend/src/components/features/MusicGenerate.vue', '../../constants/musicDefaults'),
]:
    text = read(path)
    text = replace_once(
        text,
        '<script setup lang="ts">\n',
        f'<script setup lang="ts">\nimport {{ POLYPHONIC_BPM_DEFAULT }} from \'{import_path}\'\n',
        f'{path} BPM import',
    )
    text = replace_once(text, 'const DEFAULT_BPM = 480', 'const DEFAULT_BPM = POLYPHONIC_BPM_DEFAULT', f'{path} BPM default')
    write(path, text)

path = 'frontend/src/components/dialog/MusicGenerateDialog.vue'
text = read(path)
for line in [
    '      use_recent_position_weight: false,\n',
    '      debug_score: true,\n',
    "      debug_score_key: 'vol',\n",
    '      debug_score_top_n: 20,\n',
]:
    if line not in text:
        raise SystemExit(f'frontend no-op field missing before removal: {line.strip()}')
    text = text.replace(line, '')
write(path, text)

# ---------------------------------------------------------------------------
# Docs: replace stale active-contract statements and append explicit contracts.
# ---------------------------------------------------------------------------
path = 'docs/generate_polyphonic.md'
text = read(path)
text = text.replace('Config.POLYPHONIC_BPM = 240', 'Config.POLYPHONIC_BPM_DEFAULT = 480')
text = text.replace('`Config.POLYPHONIC_BPM = 240`', '`Config.POLYPHONIC_BPM_DEFAULT = 480`')
text = text.replace('"streamStrengths": null', '"streamStrengths": { "1": { "active": true, "presenceAvg": 0.8, "presenceCount": 4, "lastValue": [0.8] } }')
text = text.replace('- dissonance候補previewはpitch-class正規化、STM seed/commitはabsolute MIDIです。', '- dissonance STMはseed / candidate preview / commit / memory interferenceをすべて `MIDI_C4 + mod(note, 12)` のpitch-class canonical表現で評価します。octave差そのものはroughnessへ入れません。')
text = text.replace('- `streamStrengths` は現在nullです。', '- `streamStrengths` はstable stream IDごとのvolume/presence履歴（`active`, `presenceAvg`, `presenceCount`, `lastValue`）を返します。')
text = re.sub(r'^- `use_recent_position_weight`.*\n', '', text, flags=re.M)
text = re.sub(r'^- `debug_score`.*\n', '', text, flags=re.M)
text += '''\n\n## 現行contract補足（Issue #16〜#21）\n\n- `dimension_policy.fixed_value_source = "initial_context_last_step"` は、正規化・CR/DEN推論が完了した**初期context最終stepのsnapshot**だけを参照します。future生成結果へ追従しません。`manual_input` は従来どおりpolicyのfixed valueを使います。\n- stream lifecycleのstrength sourceは、volumeが生成対象かfixedかに関係なく `vol` の0..1 presence履歴です。note/pitch managerへのfallbackはありません。\n- dissonance STMのnote座標系はpitch-class canonical（C4基準）です。seed・preview・commit・memory eventで共通です。\n- BPM未指定時はbackend/frontendとも `480 BPM` です。`stepDuration = 60 / BPM` なのでdefaultは `0.125 s` です。\n- voice tokenのcomplexity targetは通常dimensionと同じ `prediction + diversity(distance) + shape(complexity) + occurrence + mass(quantity)` の共通scoreです。predictionが利用不能ならprediction軸を除外して残りを再正規化します。\n- `use_recent_position_weight`, `debug_score`, `debug_score_key`, `debug_score_top_n`, `debug_poly` は公開生成parameterとして扱いません。frontend payloadからも送信しません。\n'''
write(path, text)

path = 'docs/generate.md'
text = read(path)
text += '''\n\n## 入力境界と短いseed\n\n`range_min <= range_max` は必須です。違反時は `invalid_generate_request / invalid_range` としてHTTP 422を返し、空candidate配列へ進みません。内部の `select_candidate_by_complexity_score` も空score配列を `ArgumentError` にして二重防御します。`range_min == range_max` は1候補として正常に生成します。\n\n`first_elements` が `Config.SUBSEQUENCE_MIN_WINDOW_SIZE` 未満でも入力自体は許可します。その時点では実在するsubsequenceがないためcluster treeは空です。future値の追加で初めてmin windowに到達した時点でroot clusterを作ります。\n'''
write(path, text)

path = 'docs/analyse.md'
text = read(path)
text += '''\n\n## 0件・1件の短系列\n\n`time_series` が `Config.SUBSEQUENCE_MIN_WINDOW_SIZE`（現在2）未満の場合、存在しないwindowを表すphantom rootは作りません。`timeSeries` は入力をそのまま返し、`clusteredSubsequences` と `clusters` は空になります。2件以上の通常入力では従来どおり最初の実在するwindowをrootとして開始します。\n'''
write(path, text)

path = 'docs/generate_polyphonic_requirements.md'
text = read(path)
text += '''\n\n## 監査指摘 #16〜#21 の解消後contract\n\nこの文書中のAUD-009〜AUD-012およびno-op surfaceに関する記述は調査時点の指摘です。現行実装では、`initial_context_last_step` は不変snapshot、dissonance STMはpitch-class canonical、lifecycle strengthは常時volume/presence、BPM defaultは480、voice token complexityは通常dimension共通score、`streamStrengths` は実値responseです。`use_recent_position_weight` と `debug_score*` / `debug_poly` は公開payloadから削除されています。\n'''
write(path, text)

# ---------------------------------------------------------------------------
# Regression tests (#17/#19/#20/#22/#23 + source-contract guards for #16/#18/#21)
# ---------------------------------------------------------------------------
test = r'''using Test

const IssuesController = Main.TimeseriesClusteringAPI.TimeSeriesController
const IssuesPCM = Main.TimeseriesClusteringAPI.PolyphonicClusterManager
const IssuesMSM = Main.TimeseriesClusteringAPI.MultiStreamManager
const IssuesSTM = Main.TimeseriesClusteringAPI.DissonanceStmManager
const IssuesVoice = Main.TimeseriesClusteringAPI.VoiceTokenGeneration
const IssuesConfig = Main.TimeseriesClusteringAPI.Config

@testset "#17 dissonance STM is pitch-class canonical" begin
  a = IssuesSTM.Manager()
  b = IssuesSTM.Manager()
  amps = [0.5, 0.5]
  da = IssuesSTM.commit!(a, [48, 55], amps, 0.0)
  db = IssuesSTM.commit!(b, [60, 67], amps, 0.0)
  @test da ≈ db atol=1e-12
  @test a.memory[1].midi_notes == [60, 67]
  @test b.memory[1].midi_notes == [60, 67]
  ea = IssuesSTM.evaluate(a, [50, 57], amps, 0.25)
  eb = IssuesSTM.evaluate(b, [62, 69], amps, 0.25)
  @test ea ≈ eb atol=1e-12
end

function _issue_manager(values)
  m = IssuesPCM.Manager(
    Vector{Float64}[Float64[v] for v in values],
    0.3,
    2;
    range_min=0.0,
    range_max=10.0,
    max_set_size=1,
  )
  IssuesPCM.process_data!(m)
  IssuesPCM.update_caches_permanently!(m)
  return m
end

function _expected_voice_scores(manager, candidates)
  distribution = IssuesPCM.build_predictive_distribution(manager)
  calibrator = IssuesController.build_extended_metric_calibrator(manager)
  predictive = Float64[]
  d = Float64[]
  q = Float64[]
  c = Float64[]
  temporal = IssuesPCM.OccurrenceIntervalMetrics[]
  for candidate in candidates
    metrics = IssuesPCM.simulate_add_and_calculate_all_extended(manager, candidate)
    p = IssuesPCM.predictive_surprise_score(manager, distribution, candidate)
    push!(predictive, p === nothing ? NaN : float(p))
    push!(d, metrics.distance)
    push!(q, metrics.quantity)
    push!(c, metrics.complexity)
    push!(temporal, metrics.occurrence_intervals)
  end
  return IssuesController.combine_predictive_structural_scores(
    predictive, d, q, c, temporal; calibrator=calibrator,
  ), predictive
end

@testset "#20 voice token complexity uses common score ready/not-ready" begin
  candidates = Vector{Float64}[[0.0], [4.0], [9.0]]

  not_ready = _issue_manager([1.0, 2.0])
  actual_nr = IssuesVoice._candidate_complexity_scores(not_ready, candidates)
  expected_nr, predictive_nr = _expected_voice_scores(not_ready, candidates)
  @test actual_nr ≈ expected_nr atol=1e-12
  @test any(!isfinite, predictive_nr) || length(unique(round.(predictive_nr; digits=10))) <= 1

  ready = _issue_manager([1.0, 2.0, 1.0, 3.0, 1.0, 5.0, 1.0, 7.0])
  actual_r = IssuesVoice._candidate_complexity_scores(ready, candidates)
  expected_r, predictive_r = _expected_voice_scores(ready, candidates)
  @test actual_r ≈ expected_r atol=1e-12
  @test length(actual_r) == length(candidates)
  @test all(x -> 0.0 <= x <= 1.0, actual_r)
end

@testset "#22 short series has no phantom root and initializes when ready" begin
  empty_mgr = IssuesPCM.Manager(Vector{Float64}[], 0.3, 2)
  IssuesPCM.process_data!(empty_mgr)
  @test isempty(empty_mgr.clusters)
  @test isempty(IssuesPCM.clusters_to_timeline(empty_mgr.clusters, 2))

  one_mgr = IssuesPCM.Manager(Vector{Float64}[[3.0]], 0.3, 2)
  IssuesPCM.process_data!(one_mgr)
  @test isempty(one_mgr.clusters)
  IssuesPCM.add_data_point_permanently!(one_mgr, [4.0])
  @test haskey(one_mgr.clusters, 0)
  @test one_mgr.clusters[0].si == [0]
  @test one_mgr.clusters[0].as == [[3.0], [4.0]]

  normal_mgr = IssuesPCM.Manager(Vector{Float64}[[3.0], [4.0]], 0.3, 2)
  IssuesPCM.process_data!(normal_mgr)
  @test haskey(normal_mgr.clusters, 0)
  @test normal_mgr.clusters[0].si == [0]
end

@testset "#23 candidate selector rejects empty scores and accepts singleton" begin
  @test_throws ArgumentError IssuesController.select_candidate_by_complexity_score(Float64[], 0.5)
  @test IssuesController.select_candidate_by_complexity_score([0.25], 0.9) == 0
end

@testset "#19 BPM frontend/backend contract" begin
  @test IssuesConfig.POLYPHONIC_BPM_DEFAULT == 480.0
  @test IssuesConfig.POLYPHONIC_BPM == IssuesConfig.POLYPHONIC_BPM_DEFAULT
  frontend_default = read(joinpath(pwd(), "frontend", "src", "constants", "musicDefaults.ts"), String)
  @test occursin("POLYPHONIC_BPM_DEFAULT = 480", frontend_default)
end

@testset "#16/#18/#21 source contracts" begin
  controller = read(joinpath(pwd(), "src", "controllers", "time_series_controller.jl"), String)
  dialog = read(joinpath(pwd(), "frontend", "src", "components", "dialog", "MusicGenerateDialog.vue"), String)
  @test occursin("initial_last_step_snapshot", controller)
  @test !occursin("haskey(managers, \"vol\") ? managers[\"vol\"][:stream] : managers[\"note\"][:stream]", controller)
  @test occursin("lifecycle_mgr = managers[\"vol\"][:stream]", controller)
  @test occursin("stream_strengths_report(managers[\"vol\"][:stream])", controller)
  @test !occursin("use_recent_position_weight:", dialog)
  @test !occursin("debug_score_key:", dialog)
  @test !occursin("debug_score_top_n:", dialog)
end
'''
write('test/issues_16_23_regressions.jl', test)

print('issues16_23 patch applied successfully')
