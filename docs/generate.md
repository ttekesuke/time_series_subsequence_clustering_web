# `generate` アクション詳細

このドキュメントは、`TimeSeriesController.generate()` が行う単音時系列生成を、現在の Julia 実装と、その先で呼ばれる `PolyphonicClusterManager` の処理まで含めて整理したものです。

`generate()` は初期系列を部分列クラスタリングした後、各生成 step で候補値を1つずつ**仮追加**し、候補追加後の構造がユーザー指定の `complexity_transition` に最も近くなる値を選びます。

現在の複雑度 score は、次の5軸を候補集合内で正規化して合成します。

- prediction: 現在文脈から予測される後続値に対する surprise
- diversity: クラスタ代表間距離
- shape: クラスタ代表系列内部の変化量
- occurrence: クラスタの出現間隔系列の構造
- mass: 反復クラスタ量（quantity）

基本重みは `prediction:diversity:shape:occurrence:mass = 6:1:1:1:1` です。候補間で変化しない軸や、まだ計算できない軸は除外し、残った重みだけで再正規化します。

## 1. エンドポイント

- ルート: `POST /api/web/time_series/generate`
- ルーティング先: `TimeSeriesController.generate()`
- 主な実装:
  - [`src/controllers/time_series_controller.jl`](../src/controllers/time_series_controller.jl)
  - [`src/polyphonic/polyphonic_cluster_manager.jl`](../src/polyphonic/polyphonic_cluster_manager.jl)
  - [`src/config.jl`](../src/config.jl)

## 2. 入力ペイロード

`generate` キー配下を読みます。

```json
{
  "generate": {
    "first_elements": "0,0,0",
    "complexity_transition": "0.0,0.25,0.5,0.75,1.0",
    "recency_center": "0.0,0.5,1.0,0.5,0.0",
    "merge_threshold_ratio": 0.3,
    "contextual_min_width": 1.0,
    "range_min": 0,
    "range_max": 9
  }
}
```

### `first_elements`

CSV文字列を `_parse_csv_ints` で `Int[]` にします。これが生成前の初期文脈です。

### `complexity_transition`

CSV文字列を `_parse_csv_floats` で `Float64[]` にします。配列長が生成 step 数です。各値は通常 0..1 の複雑度目標として使いますが、サーバ側で明示的 clamp はしていません。

### `recency_center`

CSV文字列を `_parse_csv_floats` で読みます。stepごとに manager の `recency` に設定され、0..1へ clamp されます。配列が生成stepより短い場合、残りは `0.0` です。

### `merge_threshold_ratio`

部分列を既存クラスタへ統合する距離比閾値です。未指定時は `Config.DEFAULT_MERGE_THRESHOLD_RATIO = 0.3` です。

### `range_min` / `range_max`

候補値の整数範囲で、同時に `scale_mode=:range_fixed` の距離正規化幅も決めます。未指定時は `0..24` です。

各 step で候補集合はそのまま次です。

```text
range_min:range_max
```

### `contextual_min_width`

値は manager に渡されますが、`generate()` は `scale_mode=:range_fixed` なので通常の距離スケール決定には使われません。

## 3. 全体処理

`generate()` は次の順で動きます。

1. payloadから各入力を読み込む。
2. 初期値を `Float64[value]` という1要素 `PolySet` に変換する。
3. `PolyphonicClusterManager.Manager` を `scale_mode=:range_fixed` で作る。
4. `process_data!` で初期系列を部分列クラスタリングする。
5. `transform_clusters` と `initial_calc_values!` で距離・quantity・shape complexity の初期キャッシュを作る。
6. 各生成 step で `recency` を設定する。
7. commit済み状態から metric calibrator と predictive distribution を構築する。
8. `range_min:range_max` の各候補について `simulate_add_and_calculate_all_extended` を実行する。
9. 候補ごとに prediction / diversity / shape / occurrence / mass を合成する。
10. `abs(score-target)` が最小の候補を選ぶ。
11. 選ばれた候補だけを `add_data_point_permanently!` で本当に追加する。
12. `update_caches_permanently!` で永続キャッシュと occurrence interval 状態を更新する。
13. 全step終了後、timeline、cluster tree、生成系列を返す。

重要なのは、候補評価に現在使われている関数が **`simulate_add_and_calculate_all_extended`** であることです。これは通常の3 metricだけでなく `OccurrenceIntervalMetrics` も返します。

## 4. 初期クラスタリング

単音値も `PolyphonicClusterManager` では集合として扱います。

```text
0 -> [0.0]
3 -> [3.0]
```

`PolySet = Vector{Float64}`、部分列は `PolySeq = Vector{PolySet}` です。

最小 window は `Config.SUBSEQUENCE_MIN_WINDOW_SIZE = 2` です。`process_data!` は時系列を先頭から走査し、`clustering_subsequences_incremental!` へ渡します。

クラスタ木は root が window=2、その子が window=3、さらにその子が window=4 ... という構造です。

クラスタ統合判定は概ね次です。

```text
distance = euclidean_distance(candidate_seq, representative)
ratio = distance / sqrt(window_size)
ratio <= merge_threshold_ratio -> merge
```

既存クラスタへ統合された部分列だけが `tasks` を介して次の長さへ伸長されます。

## 5. `range_fixed` の距離

`generate()` は次の manager を作ります。

```julia
PolyphonicClusterManager.Manager(
  Vector{Float64}[[float(v)] for v in first_elements],
  merge_threshold_ratio,
  min_window_size,
  false;
  scale_mode = :range_fixed,
  range_min = candidate_min_master,
  range_max = candidate_max_master,
  contextual_min_width = contextual_min_width,
  recency = 0.0
)
```

`range_fixed` では

```text
value_width = abs(range_max - range_min)
```

で、0なら内部的に1へ補正されます。

単音同士では `min_avg_distance` は実質

```text
abs(a-b) / value_width
```

です。

## 6. キャッシュ

manager は window size ごとに次を保持します。

- `cluster_distance_cache`
- `cluster_quantity_cache`
- `cluster_complexity_cache`

`initial_calc_values!` は初期クラスタについてこれらを全seedします。

quantityは

```text
cluster_size * window_size
```

shape complexity はクラスタ代表系列 `as` の隣接step間距離の平均です。

生成中は、実際に変化したクラスタのIDだけを更新対象として追跡し、全クラスタを毎候補で再計算しない構成です。

## 7. 候補仮追加と rollback

候補評価は `simulate_add_and_calculate_all_extended(manager, candidate)` です。

内部では:

1. `start_transaction!`
2. 更新ID集合をsimulation用にreset
3. candidateを `mgr.data` に仮push
4. `clustering_subsequences_incremental!`
5. 変更クラスタの距離・quantity・shape cacheだけ更新
6.全windowの metric を集計
7. occurrence interval metric を計算
8. `finally` で `rollback!`

という流れです。

rollback journalには、data push、`si`追加、代表系列更新、root/child cluster追加、各cache書換えが記録されます。そのため候補試算後は、候補追加前の manager 状態へ戻ります。

## 8. commit済み状態から metric calibrator を固定する

各生成stepの候補比較前に `build_extended_metric_calibrator(manager)` を1回作ります。

基準値には現在のcommit済みmanagerの

- distance
- quantity
- complexity
- occurrence interval側のdistance/quantity/complexity

を使います。

各raw metricは `atan` ベースで0..1へ写像されます。

```text
z = direction * (raw-center) / scale
score = 0.5 + atan(z)/pi
```

distance と shape complexity は大きいほど複雑側、quantityは大きいほど反復が多いので `direction=-1` です。

calibratorは候補ごとに作り直さず、同じstepの全候補比較で固定します。

## 9. predictive distribution

`build_predictive_distribution` は現在末尾を含む複数window sizeのクラスタを使います。

各windowについて:

1. 現在末尾の context が属するクラスタを見つける。
2. 同じクラスタに属した過去 context の開始位置を取る。
3. その直後に実際に現れた値を successor として集める。
4. 過去contextと現在contextの距離を Gaussian similarity にする。
5. recency weight と掛けて各 occurrence の票にする。
6. そのwindow内で票を合計1へ正規化する。
7. window長、support reliability、context cohesionからwindow自体の重みを決める。
8. 全windowの successor distribution を合成する。

主要定数は次です。

```text
PREDICTIVE_MAX_CONTEXT_LENGTH = 32
PREDICTIVE_HISTORY_LIMIT_PER_CONTEXT = 64
PREDICTIVE_SUPPORT_PRIOR = 2.0
PREDICTIVE_CONTEXT_DISTANCE_BANDWIDTH = 0.10
PREDICTIVE_SUCCESSOR_DISTANCE_BANDWIDTH = 0.22
```

window重みは

```text
reliability = support / (support + 2)
cohesion = mean(context_similarity)
scale_weight = window_size * reliability * cohesion
```

です。

## 10. predictive surprise

候補と各successorの距離へGaussian kernelをかけます。

```text
likelihood(candidate)
  = sum(successor_mass * exp(-0.5*(distance/0.22)^2))

surprise
  = 1 - likelihood(candidate) / peak_likelihood
```

既知の典型的な後続に近いほど0、予測分布から外れるほど1へ近づきます。

predictive distributionを構築できない場合、prediction軸は利用不可です。

## 11. recency

`manager.recency` は各stepの `recency_center` から設定されます。

内部カーブは:

```text
r = x*x*(3-2*x)
```

その後:

```text
age = now_index - start_index
span = exp((1-r) * log(64))
weight = (1-r) + r*exp(-age/span)
```

となります。

`recency=0` では全 occurrence が等重みです。

recency は predictive distribution の投票だけでなく、`recency>0` 時の distance / quantity / shape metric 集計にも反映されます。

- distance: クラスタ同士のrecency weightの幾何平均で重み付け
- quantity: 各 occurrence のrecency weightを加算
- complexity: クラスタの最終出現位置に基づいて重み付け

したがって「recencyはpredictionだけに作用する」わけではありません。

## 12. occurrence interval complexity

現在末尾を含み、出現回数が `OCCURRENCE_INTERVAL_MIN_OCCURRENCES = 3` 以上のクラスタについて、開始index列から出現間隔を作ります。

```text
starts = [2, 7, 11, 18]
gaps   = [5, 4, 7]
```

これを初期間隔scaleで正規化し、最大 `OCCURRENCE_INTERVAL_RATIO_MAX = 4.0` へclampして、別の `PolyphonicClusterManager` に投入します。

interval manager自身は再帰的にoccurrence intervalを作らないよう `enable_occurrence_intervals=false` です。

候補追加によって新しい出現間隔が生じる場合、その間隔についても

- prediction
- diversity
- shape

を評価します。interval quantityは診断値として計算されますが、`combine_occurrence_interval_scores` の最終3軸合成には直接入りません。

利用可能なbase windowが多い場合は最大 `OCCURRENCE_INTERVAL_MAX_BASE_SCALES = 4` スケールへ間引いて平均します。

## 13. 5軸score合成

各候補について得たraw値は:

- `metrics.distance`
- `metrics.quantity`
- `metrics.complexity`
- `metrics.occurrence_intervals`
- `predictive_surprise`

です。

`combine_predictive_structural_scores` は候補集合内で各軸を0..1化します。

基本重み:

```text
prediction = 6
diversity  = 1
shape      = 1
occurrence = 1
mass       = 1
```

概念的には:

```text
combined = (
  6 * prediction
  + 1 * diversity
  + 1 * shape
  + 1 * occurrence
  + 1 * mass
) / active_weight_sum
```

です。

ただし実装では候補間にspanがない軸は無効になります。またpredictionが全候補で利用できないとprediction weightは0です。occurrenceが準備できない場合もその軸は0 weightになります。

occurrence内部は概念的に:

```text
6 * interval_prediction
+ 1 * interval_diversity
+ 1 * interval_shape
```

を利用可能軸だけで再正規化します。

## 14. targetに最も近い候補を選ぶ

`select_candidate_by_complexity_score` は候補順に走査し、

```text
abs(score[candidate] - target_val)
```

が最小の候補indexを返します。

strictに小さいときだけbestを更新するため、完全同点なら先に列挙された小さい候補値が残ります。

選ばれた値は:

```julia
PolyphonicClusterManager.add_data_point_permanently!(manager, Float64[result_value])
PolyphonicClusterManager.update_caches_permanently!(manager)
```

でcommitされ、次stepの履歴になります。

## 15. レスポンス

```json
{
  "clusteredSubsequences": [
    {
      "window_size": 2,
      "cluster_id": "0",
      "indices": [0, 1, 2]
    }
  ],
  "timeSeries": [0, 0, 0, 4, 7],
  "complexityTransition": [null, null, null, 0.3, 0.8],
  "clusters": {
    "0": {
      "si": [0, 1, 2],
      "as": [[0.0], [0.0]],
      "cc": {}
    }
  },
  "processingTime": 0.01
}
```

- `timeSeries`: 初期系列 + 生成値
- `complexityTransition`: 初期系列の長さ分は `missing`（JSONではnull相当）、生成部分は入力target
- `clusteredSubsequences`: `clusters_to_timeline`
- `clusters`: `clusters_to_dict`
- `processingTime`: `Config.PROCESSING_TIME_DIGITS=2` 桁へroundした秒数

## 16. 実装上の注意

- `generate()` は単音生成ですが、内部は `PolyphonicClusterManager` を使います。
- 候補試算は `simulate_add_and_calculate_all_extended` で、occurrence intervalまで含みます。
- `range_min/range_max` は候補集合と距離scaleの両方を決めます。
- recencyはpredictive successor票だけでなく、通常のdistance/quantity/shape集計にも作用します。
- predictionが作れない初期段階でも、残りの構造軸で候補比較できます。
- quantityは大きいほど単純側としてcalibrateされます。
- scoreの各軸はabsoluteな0..1尺度だけではなく、候補集合内で再正規化される部分があります。
- 生成値は整数候補だけです。


## 入力境界と短いseed

`range_min <= range_max` は必須です。違反時は `invalid_generate_request / invalid_range` としてHTTP 422を返し、空candidate配列へ進みません。内部の `select_candidate_by_complexity_score` も空score配列を `ArgumentError` にして二重防御します。`range_min == range_max` は1候補として正常に生成します。

`first_elements` が `Config.SUBSEQUENCE_MIN_WINDOW_SIZE` 未満でも入力自体は許可します。その時点では実在するsubsequenceがないためcluster treeは空です。future値の追加で初めてmin windowに到達した時点でroot clusterを作ります。
