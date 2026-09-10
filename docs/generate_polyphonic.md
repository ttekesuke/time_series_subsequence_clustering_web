# `generate_polyphonic` アクション詳細

このドキュメントは、`TimeSeriesController.generate_polyphonic()` の現在の処理を、その先で呼ばれる `MultiStreamManager`、`PolyphonicClusterManager`、`DissonanceStmManager`、`Dissonance`、`DissonanceModels`、`VoiceTokenGeneration` まで追って整理したものです。

主な実装:

- [`src/controllers/time_series_controller.jl`](../src/controllers/time_series_controller.jl)
- [`src/polyphonic/multi_stream_manager.jl`](../src/polyphonic/multi_stream_manager.jl)
- [`src/polyphonic/polyphonic_cluster_manager.jl`](../src/polyphonic/polyphonic_cluster_manager.jl)
- [`src/polyphonic/dissonance_stm_manager.jl`](../src/polyphonic/dissonance_stm_manager.jl)
- [`src/polyphonic/dissonance.jl`](../src/polyphonic/dissonance.jl)
- [`src/polyphonic/dissonance_models.jl`](../src/polyphonic/dissonance_models.jl)
- [`src/voice/voice_token_generation.jl`](../src/voice/voice_token_generation.jl)
- [`src/config.jl`](../src/config.jl)
- [`src/controllers/supercolliders_controller.jl`](../src/controllers/supercolliders_controller.jl)

## 1. エンドポイント

直接生成:

```text
POST /api/web/time_series/generate_polyphonic
```

ルーティング先:

```julia
TimeSeriesController.generate_polyphonic()
```

別にGitHub Actionsへdispatchする入口があります。

```text
POST /api/web/time_series/dispatch_generate_polyphonic
```

こちらはpayloadをgzip+base64化してworkflowへ渡すラッパーで、生成アルゴリズム本体は最終的に同じ `generate_polyphonic()` です。

## 2. strict stream record

`initial_context` と生成結果の各streamは**11要素固定**です。

```text
[
  abs_notes,
  vol,
  brightness,
  noise,
  harmonicity,
  attack,
  decay_sustain,
  release,
  chord_range,
  density,
  tie
]
```

意味:

| index | field | 型/範囲 |
| ---: | --- | --- |
| 1 | `abs_notes` | MIDI note配列。36..120へclamp |
| 2 | `vol` | 0..1 |
| 3 | `brightness` | 0..1 |
| 4 | `noise` | 0..1 |
| 5 | `harmonicity` | 0..1 |
| 6 | `attack` | 0..1 |
| 7 | `decay_sustain` | 0..1 |
| 8 | `release` | 0..1 |
| 9 | `chord_range` | 0..24 |
| 10 | `density` | 0..1 |
| 11 | `tie` | 0 / 0.5 / 1へ量子化 |

`initial_context[step][stream]` がこのrecordです。record長が11でない場合はエラーになります。

初期contextが空なら、1step・1streamのdefault recordをサーバ側で作ります。

## 3. 生成step数とstream数

`stream_counts` の長さが future生成step数です。

```text
steps_to_generate = length(stream_counts)
```

`stream_counts` 自体を省略した場合は `[1]` が補われます。ただし、明示的に空配列 `[]` を送ると422です。

backend入口では各値を `1..16`（default）として検証し、future step数もdefault 256以下に制限します。これらのlimitは環境変数で変更できます。

各stepの `desired_stream_count` は検証済みの `stream_counts[step]` そのものです。

## 4. 初期contextの検証と正規化

高コストなmanager初期化より前に、`initial_context` をrequest境界で検証します。

- 各stepは非空のstream配列
- 各streamは11要素固定
- `abs_notes` は非空、整数、MIDI 36..120
- vol/timbre/density/tieはfiniteな0..1
- `chord_range` は整数0..24
- defaultではinitial contextは256step以下、1stepは16stream以下、1streamは85note以下、全initial context合計は32768note以下
- NaN / Inf（文字列sentinelを含む）は拒否

違反はdirect API/dispatch APIとも422になります。検証通過後も `_normalize_stream!` は防御的な正規化として残ります。

その後、初期contextの `chord_range` と `density` は入力placeholderをそのまま使わず、`abs_notes` から再推定されます。

### chord_range推定

chord内median noteから4-semitone AREA bandを求め、そのbandから最低音/最高音がどれだけはみ出すかをCRにします。

```text
chord_range = max(
  band_low - lowest_note,
  highest_note - band_high,
  0
)
```

0..24へclampします。

### density推定

推定CR込みでnote pool幅を出し、実際のnote数をpool slot数で割ります。

```text
density = note_count / slot_count
```

### resource budget

候補評価にはrequest単位のhard budgetがあります。defaultはdimension候補100,000、note候補8,000です。超過時は現在stepのstaged stateを破棄して422を返します。

上限は以下の環境変数で正の整数へ上書きできます。

- `POLYPHONIC_MAX_FUTURE_STEPS`
- `POLYPHONIC_MAX_STREAMS_PER_STEP`
- `POLYPHONIC_MAX_INITIAL_CONTEXT_STEPS`
- `POLYPHONIC_MAX_NOTES_PER_STREAM`
- `POLYPHONIC_MAX_TOTAL_INITIAL_NOTES`
- `POLYPHONIC_MAX_DIMENSION_EVALUATIONS`
- `POLYPHONIC_MAX_NOTE_EVALUATIONS`

## 5. dimension policy

managed dimension:

```text
area
chord_range
density
vol
brightness
noise
harmonicity
attack
decay_sustain
release
```

`dimension_policy` またはlegacy alias `default_dim_policy` を受け取ります。

各dimensionは概ね:

```json
{
  "accept_params": true,
  "fixed_value": 0.5,
  "fixed_value_source": "manual_input"
}
```

で指定できます。

`accept_params=false` なら探索せず固定値を使います。

`fixed_value_source` は:

- `manual_input`
- `initial_context_last_step`

を認識します。

### サーバ内部default

直接APIでpolicyを送らない場合の内部defaultは、画面初期値とは異なります。

- `vol`: 探索有効
- `area`, `chord_range`, `density`, timbre各種: 多くが固定

画面から明示的な `dimension_policy` が送られる通常利用では、その指定が優先されます。

## 6. BPMと時間軸

backend default BPM:

```text
Config.POLYPHONIC_BPM_DEFAULT = 480
```

`bpm` をfallbackとして、`initial_context_bpm` と `future_bpm` をそれぞれstep数へ正規化します。配列が短い場合は最後の値を繰り返します。

BPMは最低1以上へsanitizeされ、

```text
step_duration = 60 / bpm
```

です。

initial/futureそれぞれのstep onsetを累積し、dissonance STMの時刻にも使います。

## 7. history padding

各dimensionの初期履歴は、`POLYPHONIC_MIN_WINDOW_SIZE + 1` 未満なら最後のrowを複製してpaddingされます。

現在:

```text
POLYPHONIC_MIN_WINDOW_SIZE = 2
```

なので最低3stepにします。

これはクラスタリング・予測分布用の内部履歴を確保するためです。

## 8. global managerとstream manager

ほぼ各dimensionについて2種類のmanagerを持ちます。

```text
global manager
stream manager
```

### stream manager

`MultiStreamManager.Manager` がstable stream IDごとに個別の `PolyphonicClusterManager.Manager` を持ちます。

### global manager

同時stream値を1stepのpolyphonic rowとしてクラスタリングします。

通常dimensionでは、stable stream IDごとに固定axis slotを割り当て、値にoffsetを加えてencodeします。

```text
encoded = raw_value + (slot - 1) * offset
offset = raw_range_width + 1
```

同じ値でもstream identityが違えば別slotとして扱われます。

global側の距離はencoded数値の単純nearest距離ではなく、decodeしたidentity slot同士を対応させる `streamwise_surface_distance01` です。あるIDが片方にだけ存在する場合、そのslot距離は1として扱います。

## 9. stable stream lifecycle

各future stepの先頭で `MultiStreamManager.build_stream_lifecycle_plan` を呼びます。

### stream数を減らす

`stream_strength_target/spread` から削除targetを作り、active streamの `presence_avg` がtargetに近いstreamをinactive化します。

### stream数を増やす

追加targetごとに:

- inactive streamをrevive
- active streamをforkして新stable IDを発行

のどちらかを、strength距離が近い方から選びます。

active streamは同じsourceから複数回fork可能です。inactive streamは1step内で同じIDを複数回reviveしません。

inactive streamのstrengthはplanningごとに `INACTIVE_STRENGTH_DECAY = 0.98` で減衰します。

作った1つのlifecycle planを全dimension managerへ適用するため、dimensionごとにstream IDがずれないようにしています。

## 10. stream priority

step内のgreedy順は `presence_avg` の高いstreamからです。

通常は `vol` stream managerをlifecycle/priority sourceに使います。`vol` managerが存在しない場合は `note` stream managerをfallbackとして使います。

このpriority順を:

- 通常dimension
- AREA
- note/dissonance

で共有します。

## 11. recency

`recency_center` と `recency_spread` からstreamごとのrecency targetを作ります。

```text
stream_recencies = generate_centered_targets(n, center, spread)
global_recency = mean(stream_recencies)
```

global managerにはglobal平均、各stream managerにはstream別値を設定します。

内部curve:

```text
r = x*x*(3-2*x)
span = exp((1-r)*log(64))
weight = (1-r) + r*exp(-age/span)
```

recencyはpredictive successor票だけでなく、`recency>0` のときのdistance / quantity / shape集計にも作用します。

## 12. 通常dimensionの生成順

通常dimensionは次の順です。

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

候補集合:

| dimension | 候補 |
| --- | --- |
| `vol` | **`[0.0, 1.0]`** |
| `chord_range` | `0..12` |
| `density` | `0.0, 0.1, ..., 1.0` |
| timbre各種 | `0.0, 0.1, ..., 1.0` |

`vol` に0.5候補はありません。3値なのはtieです。

### target window

`area` を除く通常dimensionでは:

```text
{dim}_value_target
{dim}_value_radius
```

でcandidate rangeを絞れます。

legacy alias:

```text
{dim}_target
{dim}_target_spread
```

です。

filter後0件なら、targetに最も近い元候補1つへfallbackします。

## 13. 通常dimensionのcomplexity target

canonical parameter:

```text
{dim}_global_complexity_target
{dim}_stream_complexity_center
{dim}_stream_complexity_span
{dim}_concordance
```

legacy alias:

```text
{dim}_global
{dim}_center
{dim}_spread
{dim}_conc
```

stream targetはcenter/spanから均等配置します。

通常dimensionはstream全組合せを列挙せず、stream priority順に1streamずつ値を固定します。

候補costは概念的に:

```text
abs(global_complexity_score - global_target)
+ abs(stream_complexity_score - stream_target)
+ concordance_cost
```

です。

`vol` が複数streamの場合のみ `use_global_score=false` となり、global complexity termを外します。

## 14. complexity scoreの中身

通常dimension、AREA、note anchor、clustered tieで使う基本scoreは共通です。

候補を `simulate_add_and_calculate_all_extended` で仮追加して:

- distance
- quantity
- shape complexity
- occurrence interval metrics

を得ます。

さらにcommit済みmanagerからmulti-window predictive distributionを作り、候補のpredictive surpriseを求めます。

基本5軸:

```text
prediction : diversity : shape : occurrence : mass
= 6 : 1 : 1 : 1 : 1
```

各軸は候補集合内で正規化され、候補間に差がない軸は除外されます。

### metric weight parameter

通常dimensionはglobal/streamそれぞれについて:

```text
{dim}_{scope}_dist_weight
{dim}_{scope}_qty_weight
{dim}_{scope}_comp_weight
```

を読みます。

なければgeneric:

```text
{scope}_dist_weight
{scope}_qty_weight
{scope}_comp_weight
```

へfallbackします。

`distance` / `quantity` / `complexity` の長いaliasも受理します。

これらは5軸のうち diversity / mass / shape の倍率に使われ、predictionとoccurrenceの基本重みは別のConfig定数です。

## 15. predictive distribution

`PolyphonicClusterManager.build_predictive_distribution` は、現在末尾が属する複数window sizeのクラスタから過去successorを集めます。

主要定数:

```text
max context = 32
history per context = 64
support prior = 2
context bandwidth = 0.10
successor bandwidth = 0.22
```

window weight:

```text
window_size * support_reliability * context_cohesion
```

successor occurrenceの票にはrecencyとcontext similarityが掛かります。

候補surprise:

```text
1 - likelihood(candidate) / peak_likelihood
```

## 16. occurrence interval complexity

同じクラスタの出現start index間隔を別時系列として扱います。

最低3 occurrenceが必要です。

間隔系列は最大64件を保持し、最大4種類のbase scaleを選んで評価します。

occurrence axis内部は:

- interval prediction
- interval diversity
- interval shape

を合成します。interval quantityは計算されますが、この内部合成には直接入りません。

## 17. AREA生成

AREAは実noteそのものではなく4-semitone band下端です。

```text
AREA_BAND_SIZE = 4
```

### 候補

前回area anchorへ `AREA_MOVE_BINS` のdeltaを足し、4-semitone bandへ量子化します。

範囲外候補は端へclampせず捨てます。

`note_register_freedom < 1` の場合は、最近のnote anchor median付近へcandidateを制限します。

register履歴は直近最大16stepです。

### 2段階greedy

Stage 1では各stream単独のscoreを計算し、targetに近いAREA候補だけ残します。

- 1stream: top 1
- multi-stream: top 3

同cost時は、target>=0.5なら大きいjump、target<0.5なら小さいjumpを優先します。

Stage 2ではstream priority順にglobal + stream + concordance + register costを合算してanchorを決めます。

```text
total = global_cost + stream_cost + conc_cost + register_cost
```

`area` fixed policyならgreedy結果を使わず固定bandを使用しますが、決定値自体はAREA managerへcommitされます。

## 18. chord_range / densityからnote poolを作る

各streamで:

```text
band_low  = area
band_high = band_low + 3
low       = band_low  - chord_range
high      = band_high + chord_range
```

MIDI 36..120へ制限します。

```text
slot_count = high-low+1
note_count = round(density*slot_count)
note_count = clamp(note_count, 1, slot_count)
```

したがって `density=0` でも最低1音鳴ります。

## 19. voice streamのnote range

VOICEVOXが有効で、`voice_stream_counts` が指定されている場合:

- `voice_stream_counts` は `stream_counts` と同じ長さ必須
- 各値は0以上
- 各stepで `voice_stream_counts[i] <= stream_counts[i]`

です。

voice対象stable IDは、前stepからvoiceだったIDを優先し、その後stream priority順で必要数を補います。

voice streamのnote poolはA3..E5:

```text
MIDI 57..76
```

へ制限します。

AREA/CR poolと57..76が重ならない場合は、57..76全体へfallbackします。単一の境界音へ固定しません。

## 20. 実note選択

note候補は和音組合せ全列挙ではなく、**1音ずつ追加するgreedy** です。

stream priority順に処理し、各stream内で必要note数まで繰り返します。

候補追加ごとに:

1. register window制約
2. dissonance STM score
3. global note complexity
4. stream note complexity

を評価します。

### 重要: note選択costはdissonanceだけではない

現在の一次costは:

```text
abs(dissonance01 - dissonance_target)
+ complexity_weight * note_complexity_penalty
```

です。

`complexity_weight` は現在1.0です。

note complexity penaltyは:

```text
abs(global_note_score - area_global_target)
+ abs(stream_note_score - area_stream_target)
```

です。

つまり最終note/chordは、**不協和度目標とnote-manager側のglobal/stream構造目標の両方**で決まります。

同cost時のtie-breakは:

1. register centerへの距離
2. AREA band centerへの距離
3. MIDI note番号

です。

## 21. note manager

note managerはchord全体を保存せずanchorを保存します。

- stream note manager: chord内median note
- global note manager: 全stream全noteをまとめたmedian note

これを次stepの:

- note complexity評価
- register center計算
- cluster timeline
- vol managerがない場合のlifecycle fallback

に使います。

## 22. dissonance STM

`DissonanceStmManager.evaluate` は:

```text
current roughness + short-term-memory interference
```

を返します。

### current roughness

各MIDI noteを周波数へ変換し、現在は8 partial生成します。

```text
partial_freq = f0 * partial_number
partial_amp  = note_amp * 0.88^partial_number
```

ampが `1e-6` 未満のpartialは除外します。

全partialを周波数昇順にし、全ペアについてSethares 1993 modelを合計します。

pair contribution:

```text
s = D_MAX / (S1*f1 + S2)
x = s*(f2-f1)
d = a1*a2*(exp(-A*x)-exp(-B*x))
```

### STM interference

過去eventごとに:

```text
weight = exp(-dt / memory_span)
```

を掛けます。現在 `memory_span=1.5s`、`memory_weight=1.0` です。

現在chordと過去chordを結合したroughnessから、現在単独roughness・過去単独roughnessを引いた差をinterferenceとして加えます。

重みが0.01未満の過去eventは無視・pruneします。

### candidate評価時のpitch class正規化

note候補比較時だけ:

```text
MIDI_C4 + (midi_note mod 12)
```

へ変換してdissonanceを評価します。

これによりoctave距離そのものが候補rankingを支配しにくくします。

ただし初期STM seedと最終commitには**実際のabsolute MIDI note**を使います。

## 23. dissonance calibrator

candidate比較前に、commit済みSTM memoryの `dissonance_current` 正値をsortし、そのmedianをscaleとして固定します。

memoryに正値がなければscale=1.0です。

```text
roughness01 = roughness / (roughness + scale)
```

候補ごとにscaleを変えないため、同step内の比較尺度を固定します。

## 24. STMとnote managerへのcommit

全streamの実note決定後:

- absolute MIDI noteをSTMへcommit
- global median anchorをglobal note managerへcommit
- stream別median anchorをstream note managerへcommit

します。

volumeは各streamのchord音数で割り、1noteあたりampとしてSTMへ渡します。

## 25. tie

### 3値

現在のtie候補は:

```text
TIE_STEPS = [0.0, 0.5, 1.0]
```

です。

- 0: 再アタック
- 0.5: 軽いattack accent付き継続
- 1: 再アタックなし継続

### clustered modeの有効条件

次のどれか1つでもpayloadにあればclustered modeです。

```text
tie_global_complexity_target
tie_stream_complexity_center
tie_stream_complexity_span
tie_concordance
tie_value_target
tie_value_radius
tie_rate_target   # legacy alias
```

何もなければlegacy `tie_center/tie_spread` modeです。

### eligible boundary

clustered tieを評価できるのは、同stable IDの直前streamが存在し、render compatibilityを満たす場合だけです。

条件:

- note集合が同じ
- 前後とも可聴volume
- vol / brightness / noise / harmonicity / attack / decay_sustain が同じ

releaseはtail側で更新できるためcompatibility比較から除外されています。

eligibleでないboundaryはtie=0です。

### clustered tie cost

eligible streamだけをpriority順にgreedy選択します。

候補は `tie_value_target ± tie_value_radius` で絞ります。

cost:

```text
abs(global_tie_complexity - global_target)
+ abs(stream_tie_complexity - stream_target)
+ tie_concordance_cost
```

global tie managerにはeligible tie値の平均を1 scalarとしてcommitします。stream tie managerにはstable ID別のtie値をcommitします。

ineligible boundaryはtie履歴へ通常のOFFとしてcommitしません。

## 26. voice token生成

voice streamがある場合、音程決定後に `VoiceTokenGeneration.generate_tokens!` を呼びます。

### inventory

`voice_inventory_id` default:

```text
ja_voicevox_all
```

IDには英数字・underscore・hyphenのみ許可します。

inventory tokenは:

- id
- text
- phones
- 0..1へ正規化済みembedding

を持ちます。

voice token clusteringではembeddingをunordered setではなく**ordered vector**として距離計算します。

### initial lyric seed

`initial_context_voice_plan` に初期歌詞があれば、そのtextと一致するinventory tokenをstream/global token managerへcommitし、future token生成履歴へ反映します。

null/空textはsynth扱いです。

### voice対象ID

前stepでvoiceだったstable IDを優先して維持し、その後priority順で補います。

### token complexity

各token embeddingを候補として `simulate_add_and_calculate_all_extended` し、predictive surpriseが使える場合は:

```text
(6 * prediction + distance + complexity) / 8
```

を候補集合内で0..1正規化します。

predictive distributionがなければdistanceをprediction代替にします。

このvoice token専用scoreは、通常dimensionで使う5軸合成とは別実装です。

### token選択順位

stream tokenについて、まず:

```text
abs(stream_score - stream_target)
```

を最優先で最小化します。

完全同等の場合だけ:

- global token complexity
- voice token concordance
- previous tokenからのembedding transition cost

をtie-breakに使います。

`voice_token_concordance <= -0.999` かつ十分なtoken種類がある場合、同stepのvoice stream間でtext重複を避けます。

### tie=1でvoice継続

同stable ID・同note集合・直前もvoice・現在tie=1なら、直前tokenの最後のかな母音を調べ、その母音tokenがinventoryにあればforced continuation tokenとして使います。

## 27. output

主なresponse:

```json
{
  "timeSeries": [],
  "streamIds": [],
  "voicePlan": [],
  "voiceStreamCounts": [],
  "voiceInventory": null,
  "clusters": {},
  "processingTime": 0.0,
  "streamStrengths": { "1": { "active": true, "presenceAvg": 0.8, "presenceCount": 4, "lastValue": [0.8] } },
  "timbreSeries": {},
  "bpm": 480,
  "stepDuration": 0.125,
  "initialContextBpm": [],
  "futureBpm": [],
  "bpmSeries": [],
  "stepDurations": []
}
```

### `timeSeries`

初期context + future生成stepです。各streamはstrict 11要素recordです。

### `streamIds`

`timeSeries` と同じstep/slot構造でstable stream IDを返します。

### `voicePlan`

各step/streamについて:

```text
streamId
mode = synth | voice
token
text
phones
carrierNote
notes
```

を返します。

### `clusters`

存在するmanagerについて:

```text
note
area
vol
brightness
noise
harmonicity
attack
decay_sustain
release
chord_range
density
tie
voice_token
```

が入り得ます。

各通常dimension:

```json
{
  "global": [],
  "streams": {
    "1": [],
    "2": []
  }
}
```

です。

### `timbreSeries`

```text
brightness
noise
harmonicity
attack
decay_sustain
release
tie
```

をstepごとのstream配列として返します。

### `streamStrengths`

現在は常に `nothing` / JSON null相当です。

## 28. SuperCollider renderとの境界

`generate_polyphonic()` 自体は音声ファイルを作りません。

生成結果を実音化するのは `SupercollidersController.render_polyphonic()` 側です。

rendererもstrict 11要素recordとstable stream IDを受け取ります。

tieはrenderer側でrun接続へ変換されます。stable IDがrun identityのkeyになります。

## 29. 現行実装上の注意

- 探索はglobal optimumではなくgreedyです。
- 通常dimension・AREA・stream間note決定はstream priority順に先行決定を固定します。
- noteは各stream内でも1音ずつ追加するgreedyです。
- `vol` 候補は `[0,1]` で、0.5はありません。
- tieは `[0,0.5,1]` の3値です。
- note選択はdissonanceだけではなくnote complexity penaltyも加えます。
- dissonance STMはseed / candidate preview / commit / memory interferenceをすべて `MIDI_C4 + mod(note, 12)` のpitch-class canonical表現で評価します。octave差そのものはroughnessへ入れません。
- `density=0` でも最低1音です。
- fixed dimensionの値も時系列状態へ反映されます。
- `streamStrengths` はstable stream IDごとのvolume/presence履歴（`active`, `presenceAvg`, `presenceCount`, `lastValue`）を返します。
- `_safe_simulate_add_and_calculate_all_extended` や `MultiStreamManager.safe_*` は一部例外を0 metric化/握りつぶす経路を持ちます。これは現行挙動であり、正常系アルゴリズムの仕様とは分けて考える必要があります。


## 現行contract補足（Issue #16〜#21）

- `dimension_policy.fixed_value_source = "initial_context_last_step"` は、正規化・CR/DEN推論が完了した**初期context最終stepのsnapshot**だけを参照します。future生成結果へ追従しません。`manual_input` は従来どおりpolicyのfixed valueを使います。
- stream lifecycleのstrength sourceは、volumeが生成対象かfixedかに関係なく `vol` の0..1 presence履歴です。note/pitch managerへのfallbackはありません。
- dissonance STMのnote座標系はpitch-class canonical（C4基準）です。seed・preview・commit・memory eventで共通です。
- BPM未指定時はbackend/frontendとも `480 BPM` です。`stepDuration = 60 / BPM` なのでdefaultは `0.125 s` です。
- voice tokenのcomplexity targetは通常dimensionと同じ `prediction + diversity(distance) + shape(complexity) + occurrence + mass(quantity)` の共通scoreです。predictionが利用不能ならprediction軸を除外して残りを再正規化します。
- `use_recent_position_weight`, `debug_score`, `debug_score_key`, `debug_score_top_n`, `debug_poly` は公開生成parameterとして扱いません。frontend payloadからも送信しません。
