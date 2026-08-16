# `generate_polyphonic` アクション詳細

このドキュメントは、現在の実装に沿って `TimeSeriesController.generate_polyphonic()` と画面 `MusicGenerateDialog.vue` から送られるパラメータを整理したものです。

主な実装ファイル:

- `src/controllers/time_series_controller.jl`
- `src/polyphonic/multi_stream_manager.jl`
- `src/polyphonic/polyphonic_cluster_manager.jl`
- `src/polyphonic/dissonance_stm_manager.jl`
- `src/controllers/supercolliders_controller.jl`
- `src/supercollider/render_polyphonic.scd.tpl`
- `frontend/src/components/dialog/MusicGenerateDialog.vue`
- `frontend/src/components/features/MusicGenerate.vue`

## 1. エンドポイント

- 直接実行: `POST /api/web/time_series/generate_polyphonic`
- GitHub Actions dispatch: `POST /api/web/time_series/dispatch_generate_polyphonic`

画面の `RUN` は `VITE_RUN_GENERATE_POLYPHONIC_ON_GITHUB_ACTIONS` により、直接実行か GitHub Actions dispatch に切り替わります。どちらも生成本体に渡す payload は `generate_polyphonic` キー配下です。

## 2. 画面が送る payload

`MusicGenerateDialog.buildParamsPayload()` は概ね次の形を送ります。

```json
{
  "generate_polyphonic": {
    "job_id": "...uuid...",
    "bpm": 480,
    "future_bpm": [480, 480, 480],
    "stream_counts": [1, 2, 2],
    "tie_global_complexity_target": [0.0, 0.0, 0.0],
    "tie_stream_complexity_center": [0.0, 0.0, 0.0],
    "tie_stream_complexity_span": [0.0, 0.0, 0.0],
    "tie_concordance": [0.0, 0.0, 0.0],
    "tie_rate_target": [0.0, 0.0, 0.0],
    "recency_center": [0.0, 0.0, 0.0],
    "recency_spread": [0.0, 0.0, 0.0],
    "initial_context": [
      [
        [[60], 1.0, 0.5, 0.2, 0.5, 0.05, 0.2, 0.75, 0, 0.0, 0.0]
      ]
    ],
    "initial_context_bpm": [480],
    "dimension_policy": {
      "area": { "accept_params": true, "fixed_value": 0.5, "fixed_value_source": "manual_input" },
      "chord_range": { "accept_params": true, "fixed_value": 0, "fixed_value_source": "manual_input" },
      "density": { "accept_params": true, "fixed_value": 0, "fixed_value_source": "manual_input" },
      "vol": { "accept_params": true, "fixed_value": 1.0, "fixed_value_source": "manual_input" }
    },
    "merge_threshold_ratio": 0.02,
    "use_recent_position_weight": false,
    "stream_strength_target": [0.0, 0.0, 0.0],
    "stream_strength_spread": [0.0, 0.0, 0.0],
    "global_dist_weight": [0.2, 0.2, 0.2],
    "global_qty_weight": [2.0, 2.0, 2.0],
    "global_comp_weight": [2.0, 2.0, 2.0],
    "stream_dist_weight": [0.2, 0.2, 0.2],
    "stream_qty_weight": [2.0, 2.0, 2.0],
    "stream_comp_weight": [2.0, 2.0, 2.0],
    "note_register_freedom": [1.0, 1.0, 1.0],
    "debug_score": true,
    "debug_score_key": "vol",
    "debug_score_top_n": 20,
    "dissonance_target": [0.3, 0.3, 0.3],
    "area_global": [0.0, 0.0, 0.0],
    "area_center": [0.0, 0.0, 0.0],
    "area_spread": [0.0, 0.0, 0.0],
    "area_conc": [0.0, 0.0, 0.0],
    "vol_global_complexity_target": [0.0, 0.0, 0.0],
    "vol_stream_complexity_center": [0.0, 0.0, 0.0],
    "vol_stream_complexity_span": [0.0, 0.0, 0.0],
    "vol_concordance": [0.0, 0.0, 0.0],
    "vol_value_target": [0.5, 0.5, 0.5],
    "vol_value_radius": [1.0, 1.0, 1.0]
  }
}
```

配列パラメータは future step ごとの値です。サーバは `idx0 = step_idx - 1` で `array_param(gp, key, idx0)` を読みます。配列が短い場合は末尾値が使われます。画面側は通常 `genSteps` 長に正規化して送ります。

## 3. 画面から送る全パラメータ

### 3.1 payload 固定キー

| キー | 型 | 画面デフォルト | サーバでの扱い |
| --- | --- | --- | --- |
| `job_id` | string | UUID | dispatch / 進捗識別用。直接生成でも payload に含まれます。 |
| `bpm` | number | `future_bpm[0]` | 代表 BPM / fallback。 |
| `future_bpm` | number[] | `[480...]` | future step の BPM。step duration と dissonance STM onset に使います。 |
| `initial_context` | array | 画面の Initial Context | `initial_context[step][stream] = stream_record`。 |
| `initial_context_bpm` | number[] | `[480...]` | 初期文脈 step の BPM。STM seed の onset に使います。 |
| `dimension_policy` | object | 全 managed dimension が `accept_params=true` | 次元ごとに探索するか固定値にするかを決めます。 |
| `merge_threshold_ratio` | number | `0.02` | 全 manager のクラスタ merge threshold。 |
| `use_recent_position_weight` | boolean | `false` | 現在の `generate_polyphonic()` 本体では実質使いません。 |
| `debug_score` | boolean | `true` | `debug_poly` 判定に使われます。現在の greedy 経路では詳細 top 表示は限定的です。 |
| `debug_score_key` | string | `"vol"` | debug 用。 |
| `debug_score_top_n` | number | `20` | debug 用。 |

### 3.2 generation rows

画面の Generation Parameters grid から送るキーです。すべて future step ごとの配列です。

| キー | 範囲 | step | デフォルト | 意味 |
| --- | ---: | ---: | ---: | --- |
| `stream_counts` | 1..16 | 1 | 1 | 各 future step の stream 数。この長さが生成 step 数です。 |
| `tie_global_complexity_target` | 0..1 | 0.01 | 0 | eligible stream群のtie-on率系列に対するglobal complexity目標。 |
| `tie_stream_complexity_center` | 0..1 | 0.01 | 0 | stable stream別binary tie系列のcomplexity目標中心。 |
| `tie_stream_complexity_span` | 0..1 | 0.01 | 0 | stream complexity目標の全体幅。 |
| `tie_concordance` | -1..1 | 0.01 | 0 | 正値は同時ON/OFFを揃え、負値は分散させる。 |
| `tie_rate_target` | 0..1 | 0.01 | 0 | eligible境界でtieをONにする累積割合の目標。 |
| `recency_center` | 0..1 | 0.01 | 0 | 直近履歴をどれくらい重く見るか。 |
| `recency_spread` | 0..1 | 0.01 | 0 | stream 間の recency ばらつき。 |
| `stream_strength_target` | 0..1 | 0.01 | 0 | stream lifecycle で残す / 復活 / fork する stream 強度の中心。 |
| `stream_strength_spread` | 0..1 | 0.01 | 0 | stream lifecycle の強度 target 分布幅。 |
| `note_register_freedom` | 0..1 | 0.01 | 1 | 音域移動の自由度。低いほど直近 register 付近に制限。 |
| `global_dist_weight` | 0..5 | 0.01 | 0.2 | global score の distance 重み。 |
| `global_qty_weight` | 0..5 | 0.01 | 2 | global score の quantity 重み。 |
| `global_comp_weight` | 0..5 | 0.01 | 2 | global score の complexity 重み。 |
| `stream_dist_weight` | 0..5 | 0.01 | 0.2 | stream score の distance 重み。 |
| `stream_qty_weight` | 0..5 | 0.01 | 2 | stream score の quantity 重み。 |
| `stream_comp_weight` | 0..5 | 0.01 | 2 | stream score の complexity 重み。 |
| `dissonance_target` | 0..1 | 0.01 | 0.3 | 最終 chord の roughness target。0 は協和寄り、1 は不協和寄り。 |
| `future_bpm` | 1..960 | 1 | 480 | future step の BPM。 |

### 3.3 complexity dimension rows

`complexityDimensionKeys` は次の 10 個です。

```text
area, chord_range, density, vol,
brightness, noise, harmonicity, attack, decay_sustain, release
```

AREAは今回のcanonical化対象外で、既存の4キーを送ります。

```text
area_global, area_center, area_spread, area_conc
```

AREA以外の9 dimensionは次のcanonical keyを送ります。backendはcanonical keyを優先し、欠落時のみ右記のlegacy aliasを読みます。

| canonicalキー形式 | legacy alias | 範囲 | 意味 |
| --- | --- | ---: | --- |
| `${key}_global_complexity_target` | `${key}_global` | 0..1 | global managerの複雑度target。 |
| `${key}_stream_complexity_center` | `${key}_center` | 0..1 | stream target分布の中心。 |
| `${key}_stream_complexity_span` | `${key}_spread` | 0..1 | `center ± span / 2`で配置する全体幅。 |
| `${key}_concordance` | `${key}_conc` | -1..1 | stream間の一致/分散の好み。正は揃え、負は離す。 |

frontendはcanonical keyを保存・送信し、旧params JSONのimportではlegacy aliasを受理します。

### 3.4 target window rows

`targetWindowDimensionKeys` は次の 9 個です。

```text
vol, chord_range, density,
brightness, noise, harmonicity, attack, decay_sustain, release
```

画面は各target window dimensionについて次のcanonical keyを送ります。

| canonicalキー形式 | legacy alias | 意味 |
| --- | --- | --- |
| `${key}_value_target` | `${key}_target` | 実値候補の探索中心。 |
| `${key}_value_radius` | `${key}_target_spread` | `value_target ± value_radius` の探索窓半径。 |

| dimension | target 範囲 | target step | target default | spread 範囲 | spread default |
| --- | ---: | ---: | ---: | ---: | ---: |
| `vol` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `chord_range` | 0..12 | 1 | 6 | 0..12 | 12 |
| `density` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `brightness` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `noise` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `harmonicity` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `attack` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `decay_sustain` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |
| `release` | 0..1 | 0.1 | 0.5 | 0..1 | 1 |

canonical keyは各dimensionに対して`${key}_value_target`と`${key}_value_radius`です。旧`${key}_target`/`${key}_target_spread`はimport/API互換aliasとしてのみ受理します。

`area` にはtarget window rowはありません。tieは二値の専用cluster parameterを使うためvalue radiusを持たず、dimension policyにも含めません。新5 tie keyが一つもない旧requestでは、backendとfrontend importが`tie_center/tie_spread`の決定論的legacy modeを維持します。

### 3.5 dimension policy

画面が送る managed policy dimension は次の 10 個です。

```text
area, chord_range, density, vol,
brightness, noise, harmonicity, attack, decay_sustain, release
```

各 dimension の payload は次です。

```json
{
  "accept_params": true,
  "fixed_value": 0.5,
  "fixed_value_source": "manual_input"
}
```

| フィールド | 意味 |
| --- | --- |
| `accept_params` | `true`ならAREAは既存4キー、非AREAはcanonical complexity/concordance keyとvalue windowを使って探索します。`false`なら固定値を出力します。 |
| `fixed_value` | 固定時に使う値。 |
| `fixed_value_source` | `"manual_input"` なら `fixed_value`、`"initial_context_last_step"` なら初期文脈の最後の step から引き継ぎます。 |

画面上の policy 初期値は全て `accept_params=true` 相当です。

| dimension | fixed value 範囲 | default fixed value |
| --- | ---: | ---: |
| `area` | 0..1 | 0.5 |
| `chord_range` | 0..24 | 0 |
| `density` | 0..1 | 0 |
| `vol` | 0..1 | 1 |
| `brightness` | 0..1 | 0.5 |
| `noise` | 0..1 | 0.2 |
| `harmonicity` | 0..1 | 0.5 |
| `attack` | 0..1 | 0.05 |
| `decay_sustain` | 0..1 | 0.2 |
| `release` | 0..1 | 0.75 |

サーバ内部の default policy は画面初期値と違い、`vol` 以外は多くが固定です。ただし画面からは明示的に `dimension_policy` が送られるため、画面経由では上記の画面 policy が優先されます。

## 4. Initial Context

画面の Initial Context row は次です。

```text
abs_note, vol, brightness, noise, harmonicity, attack, decay_sustain, release, tie
```

payload の stream record は strict 形式です。

```text
[abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, tie]
```

- `abs_notes` は `Vector{Int}` です。例: `[60]`, `[60, 64, 67]`
- `chord_range` と `density` は画面入力 row にはありません。frontendはstrict record用のplaceholderを入れ、サーバが`abs_notes`からper-stream生成controlの初期値を推定します。
- サーバは11要素のrecordだけを受け付けます。

`chord_range` と `density` は生成controlです。初期文脈では入力値より`abs_notes`からの推定値を優先し、future生成値と同じper-stream schemaでmanagerへ投入します。実音から測った観測値が必要な場合は、このcontrol fieldとは別に扱います。

## 5. 処理の全体順

`generate_polyphonic()` の処理順は次です。

1. payload の `generate_polyphonic` を読む。
2. `stream_counts`, `stream_strength_target`, `stream_strength_spread`, BPM 系を正規化する。
3. `initial_context` を読み、空なら default 1 step / 1 stream を作る。
4. stream record を 11 要素 strict 形式へ正規化する。
5. 初期文脈の `chord_range` と `density` 生成controlを `abs_notes` からstream別に推定する。
6. `dimension_policy` を解決し、固定次元の固定値を決める。
7. 初期文脈から dimension ごとの履歴 matrix を作る。
8. 履歴が `POLYPHONIC_MIN_WINDOW_SIZE + 1` 未満なら padding する。
9. dimension ごとに global manager と stream manager を作る。
10. 初期文脈の実音を `DissonanceStmManager` に commit して短期記憶を seed する。
11. future step ごとに stream lifecycle を計画して全 manager に適用する。
12. step の `recency_center/spread` を stream ごとの recency に展開し、各 manager に適用する。
13. stream 優先順を決める。
14. `vol`, `chord_range`, `density`, timbre 系の順に通常 dimension を greedy に決める。
15. `area` を `tmp_anchor` として greedy に決める。
16. `area`, `chord_range`, `density` から各 stream の音域と音数を決める。
17. `dissonance_target` に近づく音を stream 優先順、各 stream 内は単音追加順の greedy で決める。
18. 実音を dissonance STM と note manager に commit する。
19. clustered modeではrender-compatibleな境界だけについて`0/1` tie候補をglobal/stream complexity、tie率、concordanceで評価する。legacy modeでは`tie_center/spread`を決定論的に展開する。
20. 出力値をclampし、`timeSeries`, `streamIds`, `clusters`, `timbreSeries`, BPM系を返す。

## 6. stream lifecycle と優先順

各 future step の最初に、`stream_counts[step]` に合わせて active stream を増減します。

- 減る場合: `presence_avg` と `stream_strength_target/spread` から、inactive にする stream を選びます。
- 増える場合: inactive stream を revive するか、active stream を fork します。
- 変わらない場合: active ids を維持します。

同じ lifecycle plan が全 dimension manager に適用されるため、dimension 間で stream id がずれません。global managerもrun-localで不変のstable ID→axis slot mapを共有し、初期履歴・候補simulation・commit・AREAのすべてを同じencoderへ通します。active順が変わっても同じIDは同じaxis slotを使い、inactive IDはそのstepのrowから省略されます。

identity axis capacityは、初期stream数と`stream_counts`の増加量からrequest開始時に確保します。これは1 stepの最大row要素数とは別の値であり、capacity外IDを既存slotへclampしません。

その後、step 内の stream 優先順を作ります。優先順は lifecycle に使った manager の active stream `presence_avg` 降順です。通常は `vol` manager が使われ、`vol` manager がなければ `note` 側が使われます。

```text
priority = presence_avg が高い stream から
```

この優先順は通常 dimension、AREA、dissonance のすべてで共通です。つまり強い stream を先に決め、後続 stream が既に決まった stream に重なる形で決まります。

## 7. recency

`recency_center` と `recency_spread` は future step ごとに読まれます。

```text
stream_recencies = generate_centered_targets(stream_count, recency_center, recency_spread)
global_recency = mean(stream_recencies)
```

- global manager には `global_recency`
- stream manager には stream ごとの recency

が設定されます。

`PolyphonicClusterManager.recency_curve()` は smoothstep です。

```text
r = x * x * (3 - 2 * x)
span = exp((1 - r) * log(64))
weight = (1 - r) + r * exp(-age / span)
```

`recency=0` は直近重視ではなく recency weighting 無効です。このとき全履歴が等重みになります。直近の音型を強く参照したい場合は `recency_center` を 1 側に寄せます。

この重みは、各windowの予測分布内で過去の後続値が投票するときに使われます。古いクラスタを削除するのではなく、古い後続例の票だけを下げます。予測分布を作れない場合のfallbackでは、従来どおり `dist`, `quantity`, `complexity`, `usage` の集計にも使われます。dissonance STM の roughness 計算には直接入りません。

### 7.1 複数windowの予測分布

global managerと各stream managerは同じ方式で予測分布を作ります。現在末尾が属する各window sizeのクラスタについて、過去の出現位置の直後にあった値を集めます。各window内の分布を一度正規化し、文脈長、支持数、現在文脈との類似度を掛けたwindow weightで合成します。

候補の基礎scoreは合成分布上のpredictive surpriseです。

```text
likelihood(candidate) = Σ mass * exp(-0.5 * (distance / 0.22)^2)
score(candidate) = 1 - likelihood(candidate) / peak_likelihood
```

このscoreへ、クラスタ代表間距離による多様性、クラスタ代表系列の形状複雑度、occurrence interval complexityを`6:1:1:1`で合成します。各構造軸は同じ候補集合内で0..1化し、候補間に差がない軸は除外します。

occurrence interval complexityの内部も通常系列と同じ方式です。正規化した出現間隔列に対して、`interval predictive surprise : interval cluster diversity : interval cluster shape complexity = 6:1:1`で合成します。旧`interval quantity`と`interval usage`はscoreには使いません。区間の後続分布をまだ作れない段階ではoccurrence軸全体を合成から外します。

globalとstreamで履歴は別ですが、分布構築、構造軸合成、score変換の関数は共通です。通常dimension、AREA、note complexity、clustered tieの候補評価に同じ方式を使います。

### 7.2 fallback metric

過去の後続例がなく予測分布を作れないmanagerだけ、予測軸を従来の `dist`, `quantity`, `complexity`, `usage` と occurrence interval complexityへfallbackします。画面のglobal/stream metric weightはこのfallback scoreに適用されます。多様性・形状・occurrenceの3構造軸は、予測軸がfallbackした場合も候補間に差があれば合成されます。

## 8. 通常 dimension の greedy 選択

通常 dimension の処理対象順は次です。

```text
vol
chord_range
density
brightness
noise
harmonicity
attack
decay_sustain
release
```

現在の通常 dimension は stream 全組み合わせの cartesian product を作りません。純 greedy です。

1. `dimension_policy` が固定なら、stream 数分の固定値を入れて次へ進む。
2. `${key}_global`, `${key}_center`, `${key}_spread`, `${key}_conc` を読む。
3. `${key}_target`, `${key}_target_spread` があれば候補値を絞る。
4. stream 優先順で 1 stream ずつ決める。
5. ある stream の候補を評価するときは、既に決まった stream 値 + 現候補だけを global manager に仮追加して評価する。
6. 対象 stream manager に現候補を仮追加して stream score を評価する。
7. best 候補をその stream に固定し、次 stream へ進む。
8. 全 stream 分が決まったら global manager と stream manager に commit する。

コストは概ね次です。

```text
total_cost =
  abs(global_score - global_target)
  + abs(stream_score - stream_target_for_this_stream)
  + concordance_cost(already_decided_values + current_candidate)
```

`vol` は複数 stream のとき `use_global_score=false` です。volume は stream 側 target window と stream score を主に使い、global score が支配しすぎないようにしています。

候補集合:

| dimension | 候補 |
| --- | --- |
| `vol` | `0.0, 0.5, 1.0` |
| `chord_range` | `0..12` |
| `density` | `0.0, 0.1, ..., 1.0` |
| timbre 系 | `0.0, 0.1, ..., 1.0` |

## 9. global / stream / conc

### global

global は同時に鳴っている stream を 1 つの polyphonic set として扱う複雑度です。

通常 dimension の global 値は stream index ごとに offset encode されます。

```text
encoded_value(stream i) = raw_value + (i - 1) * offset
offset = value_width + 1
```

例えば `vol` の範囲が 0..1 なら `offset = 2` です。stream 1 の `0.8` と stream 2 の `0.8` が同じ点として衝突しないようにしています。

### stream

stream は各声部を独立した時系列として見る複雑度です。`MultiStreamManager` は stream ごとに `PolyphonicClusterManager.Manager` を持ちます。

`stream_center` / `stream_spread` という payload 名はありません。各 dimension では `${key}_center` と `${key}_spread` から stream target を作ります。

### conc

`conc` は stream 間の一致 / 分散の重みです。

- `conc > 0`: 値をそろえる候補が有利。
- `conc < 0`: 値を離す候補が有利。
- `conc = 0`: 無効。

greedy では、既に決まった stream 値と今試している候補の spread から cost を計算します。

## 10. AREA 生成

`area` は実音ではなく、4 semitone band の下端 `tmp_anchor = band_low` です。

例: `AREA_BAND_SIZE = 4` の場合、MIDI 60, 61, 62, 63 は band low 60、MIDI 64 は band low 64 です。

AREA は通常 dimension とは別ロジックです。

1. 各 stream の note manager から直近 register center を取る。
2. 前回 `tmp_anchor` から `Config.AREA_MOVE_BINS` の delta を足して候補を作る。
3. 範囲外候補は clamp せず除外する。
4. `note_register_freedom < 1` なら register window で候補を絞る。
5. 各 stream で候補を仮追加して score を作り、top bins だけ残す。
6. stream 優先順で greedy に `chosen_area` を決める。

AREA greedy でも stream 全組み合わせは作りません。stream ごとに、既に決まった area + 今の area candidate を global manager に仮追加して評価します。

評価 cost:

```text
total = global_cost + stream_cost + conc_cost + register_cost
```

`area` が fixed policy の場合は、greedy 評価結果ではなく `_fixed_area_band_low_for_stream()` の値を使います。

## 11. chord_range / density と実音探索

AREA が決まったあと、各 stream の探索音域と必要音数を作ります。

```text
band_low = chosen_area[s]
band_high = band_low + AREA_BAND_SIZE - 1
low = band_low - chord_range
high = band_high + chord_range
slot_count = high - low + 1
n_notes = round(density * slot_count)
n_notes = clamp(n_notes, 1, slot_count)
note_pool = low..high
```

`density = 0` でも最低 1 音は出ます。

`combinations(note_pool, n_notes)` は作りません。現在のpartial chordへ未使用音を1音足す候補だけを評価し、1音確定してから次の音へ進みます。

`note_register_freedom < 1` の場合、追加後のpartial chordのanchorがregister window内にある候補へ絞ります。該当候補がない追加段階では、register centerに最も近い候補だけを残します。

## 12. dissonance

dissonance は最後の実音選択だけで使われます。`area`, `vol`, `chord_range`, `density`, timbre の complexity manager には直接入りません。

現在の dissonance 選択は、stream間とstream内の両方が純greedyです。

1. stream 優先順で 1 stream ずつ処理する。
2. そのstreamのpartial chordに追加可能な未使用音を1音ずつ試す。
3. 既に決まったstream chords + 追加後のpartial chordを`DissonanceStmManager.evaluate()`で評価する。
4. commit済みSTMから事前に固定したdissonance calibratorでroughnessを0..1化する。
5. `abs(score - dissonance_target)` が最小の音をpartial chordへ固定する。
6. 必要音数に達するまで2〜5を繰り返す。
7. 全streamが決まったら、実際のMIDI noteをSTMにcommitする。

dissonance calibrator は、STM memory にある commit 済み `dissonance_current` の中央値を scale として、step の音候補評価前に固定します。memory に正値がまだなければ `DISSONANCE_CALIBRATION_SCALE=1.0` を使います。

```text
score = roughness / (roughness + fixed_scale)
```

探索音数を `N`、選ぶ音数を `K` とすると、1 stream の評価回数は最大で次です。

```text
N + (N - 1) + ... + (N - K + 1) = O(NK)
```

旧方式の `combinations(N, K)` 個の和音列挙は行いません。

候補比較時の dissonance は pitch-class normalized note で評価します。

```text
eval_note = MIDI_C4 + (midi_note mod 12)
```

これにより octave 距離そのものが roughness ranking を支配しにくくなります。一方、STM への commit は最後に実際の MIDI note で行います。

## 13. note manager

実音 chord が決まったあと、note manager には chord 全体ではなく anchor が commit されます。

- global note manager: その step の全 stream 全 note の median anchor を 1 つ commit。
- stream note manager: 各 stream の chord 内 median anchor を commit。

note manager は実音選択時の global / stream complexity 評価、次 step の `note_register_freedom` 制限、cluster timeline 出力、stream lifecycle fallback に使われます。`area` は 4 semitone band の下端を決め、実音 `note_abs` はその band と `chord_range` / `density` から作った候補を、dissonance と note manager complexity の合算で選びます。

## 14. note反復とtie

noteの反復とtieは別の段階です。

1. note/AREAの候補評価で、recencyを高くし複雑度targetを低くすると、最近の反復パターンが選ばれやすくなります。
2. dissonance評価まで含めて各streamのnote/chordを確定します。
3. clustered modeでは`TIE_STEPS = [0, 1]`からtieを選びます。対象は、同じstable IDが直前stepにも存在し、note集合、可聴性、tie中に更新できない音響controlがrender-compatibleな境界だけです。
4. global/stream complexity、stable stream別の累積`tie_rate_target`、eligible stream間の`tie_concordance`を合算してgreedy選択します。ineligible境界は0を出力しmanager/rate履歴へcommitしません。
5. SuperCollider render時、同じstable IDの前stepとnote/chordが完全一致し、tieが`SC_TIE_THRESHOLD = 0.5`以上なら、再発音せず前の音響runを延長します。

新5 parameterは`tie_global_complexity_target`、`tie_stream_complexity_center`、`tie_stream_complexity_span`、`tie_concordance`、`tie_rate_target`です。新keyが一つもない旧requestだけは`tie_center/tie_spread`の決定論的legacy modeになります。tieはnote候補を固定したり、note探索を省略したりしません。standaloneの`sustain`生成dimensionとtieの`value_radius`はありません。

## 15. SuperCollider render との関係

`generate_polyphonic()` は音声ファイルを作りません。音声化は `SupercollidersController.render_polyphonic()` 側です。

render が読む stream record も 11 要素 strict 形式です。

```text
[abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, tie]
```

生成responseの`streamIds`はfrontendでslot対応を保ったままrender requestの`stream_ids`へ変換されます。voiceをfilterするときはIDも同時にfilterし、rendererの`active_runs`はstable IDをkeyにします。`build_score_events_scd`へIDを渡さない既存呼び出しは、従来どおりstep内slot indexへfallbackします。

SC synth では:

- `brightness`: 倍音量、LPF cutoff、HiShelf。
- `noise`: WhiteNoise 量と歪み混合。
- `harmonicity`: 部分音比率の整数倍音寄り度。
- `attack`: attack 時間比率。
- `decay_sustain`: decay 時間比率。
- `release`: sustain/release 時間比率。
- `tie`: 同音連続時の結合判定。0.5以上で前の音響runを延長。

低域の kick / bass が聞こえにくい問題に対して、render 側では低い MIDI note に amp 補正をかけ、SC synth 側でも 2倍 / 4倍成分、短い click、low shelf を足しています。

## 16. 出力

レスポンス例:

```json
{
  "timeSeries": [
    [
      [[60], 1.0, 0.5, 0.2, 0.5, 0.05, 0.2, 0.75, 0, 1.0, 0.0]
    ]
  ],
  "streamIds": [[1]],
  "clusters": {
    "note": { "global": [], "streams": {} },
    "area": { "global": [], "streams": {} },
    "vol": { "global": [], "streams": {} },
    "tie": { "global": [], "streams": {} }
  },
  "processingTime": 0.12,
  "streamStrengths": null,
  "timbreSeries": {
    "brightness": [],
    "noise": [],
    "harmonicity": [],
    "attack": [],
    "decay_sustain": [],
    "release": [],
    "tie": []
  },
  "bpm": 480,
  "stepDuration": 0.125,
  "initialContextBpm": [480],
  "futureBpm": [480],
  "bpmSeries": [480, 480],
  "stepDurations": [0.125, 0.125]
}
```

`timeSeries` は初期文脈と生成結果を連結した全 step です。各 stream record は 11 要素 strict 形式です。

```text
[abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, tie]
```

`clusters` は各 dimension の cluster timeline です。

- `global`: global manager の timeline
- `streams`: stream id ごとの stream manager timeline

cluster payload には、存在する manager について次のキーが入り得ます。

```text
note, area, vol, brightness, noise, harmonicity, attack,
decay_sustain, release, chord_range, density
```

`timbreSeries` は次を返します。

```text
brightness, noise, harmonicity, attack, decay_sustain, release, tie
```

## 17. 注意点

- 現在の通常 dimension / AREA / dissonance は stream 全組み合わせを作らず、stream 優先順の純 greedy です。dissonance は各 stream 内でも単音追加 greedy です。
- greedy なので、先に決まった stream は後続 stream の評価時に固定されます。
- complexity metric と dissonance roughness は、どちらも候補評価前に固定した calibrator で0..1化します。
- note反復はrecencyと低い複雑度で誘導します。tieはnote生成後の同音接続だけを制御します。
- standaloneのsustain生成dimensionはありません。strict recordの11番目はtieです。
