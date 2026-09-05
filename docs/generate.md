# `generate` アクション詳細

このドキュメントは、サーバサイドの `TimeSeriesController.generate()` が行う単音系列生成を、現在の実装に沿って整理したものです。

`generate()` は、既存の初期系列をクラスタリングした上で、候補値を 1 つずつ仮追加し、候補ごとの単純/複雑スコアが `complexity_transition` の目標値に近いものを選びます。

現在の単純/複雑スコアは、現在末尾が属する複数 window size のクラスタから作る predictive surprise を主軸に、クラスタ間距離による多様性、クラスタ代表系列の形状複雑度、occurrence interval complexityを合成します。後続例がなく予測分布を作れない場合は、`distance`、`quantity`、`complexity` をfallbackに使います。

## 1. エンドポイント

- ルート: `POST /api/web/time_series/generate`
- ルーティング先: `TimeSeriesController.generate()`
- 主な実装:
  - [src/controllers/time_series_controller.jl]
  - [src/polyphonic/polyphonic_cluster_manager.jl]

## 2. 入力ペイロード

`generate` は `generate` キー配下を読みます。

```json
{
  "generate": {
    "first_elements": "0,0,0",
    "complexity_transition": "0.0,0.25,0.5,0.75,1.0",
    "merge_threshold_ratio": 0.3,
    "range_min": 0,
    "range_max": 9,
    "recency_center": "0.0,0.5,1.0,0.5,0.0"
  }
}
```

- `generate.first_elements`
  - CSV 文字列です。
  - `_parse_csv_ints` で `Int[]` に変換されます。
- `generate.complexity_transition`
  - CSV 文字列です。
  - `_parse_csv_floats` で `Float64[]` に変換されます。
  - 各値は 0.0 から 1.0 の目標複雑度として使われます。
- `generate.merge_threshold_ratio`
  - クラスタ統合閾値です。
  - デフォルトは `Config.DEFAULT_MERGE_THRESHOLD_RATIO`。
- `generate.range_min`, `generate.range_max`
  - 候補値の範囲です。
  - 例えば `0..9` なら各ステップで候補 `0,1,2,...,9` を全て試算します。
- `generate.recency_center`
  - CSV 文字列または配列です。
  - 各 step で直近の履歴をどれくらい強く見るかを 0.0 から 1.0 で指定します。
  - 未指定なら全 step で `0.0` です。

`contextual_min_width` も読み込まれますが、現在の `generate()` は `scale_mode = :range_fixed` なので、距離スケールには `range_min/range_max` が使われます。

## 3. 全体の流れ

`generate()` の処理順は次です。

1. `first_elements` と `complexity_transition` を CSV から配列へ変換する。
2. 候補範囲 `range_min:range_max` を決める。
3. `PolyphonicClusterManager.Manager` を作る。
   - 単音値は `Float64[value]` に変換される。
   - `scale_mode = :range_fixed`
   - `range_min/range_max` を manager に渡す。
4. 初期系列 `first_elements` を `process_data!` でクラスタリングする。
5. 初期クラスタから距離・量・複雑度キャッシュを作る。
6. 各 window size の最新クラスタから過去の後続値を集め、予測分布を作る。
7. `complexity_transition` の各 target について、候補値の predictive surprise を計算する。
8. target に最も近い候補を選ぶ。
9. 選ばれた値を本当に manager に追加し、キャッシュを更新する。
10. 生成終了後、timeline と cluster tree を返す。

仮追加は `simulate_add_and_calculate(manager, Float64[candidate])` で行います。この関数は rollback transaction を使うため、候補試算後に manager の状態は元に戻ります。

## 4. 初期クラスタリングと `range_fixed`

現在の `generate()` は `range_fixed` です。

```julia
PolyphonicClusterManager.Manager(
  Vector{Float64}[[float(v)] for v in first_elements],
  merge_threshold_ratio,
  min_window_size,
  false;
  scale_mode = :range_fixed,
  range_min = candidate_min_master,
  range_max = candidate_max_master,
  ...
)
```

`range_fixed` では `value_width = abs(range_max - range_min)` になります。例えば `range_min=0`, `range_max=9` なら `value_width=9` です。

単音候補 `3` と既存代表 `0` の 1 ステップ距離は概ね次です。

```text
abs(3 - 0) / 9 = 0.333...
```

この正規化距離は、過去に観測した後続値の周辺へ確率を滑らかに広げるときに使います。

## 5. 複数 window の予測分布

候補を追加する前に、各 window size の最新部分列が属するクラスタを調べます。そのクラスタの過去の start index ごとに、部分列の直後に実際に現れた値を後続例として集めます。

各 window は後続例の合計が 1 になるように正規化し、次の積で window 間の重みを決めます。

```text
window_weight = window_size * support_reliability * context_cohesion
support_reliability = support / (support + 2)
```

長い文脈、後続例が多い文脈、現在末尾と過去文脈がよく似るクラスタほど強くなります。最大 context length は32、各contextの履歴は直近64件です。

## 6. 候補の predictive surprise

各後続値の周辺へ Gaussian kernel で確率を広げ、全 window の分布を合成します。候補と後続値の距離は manager と同じ `range_fixed` 距離を使い、bandwidth は0.22です。

```text
likelihood(candidate) = Σ mass * exp(-0.5 * (distance / 0.22)^2)
surprise(candidate) = 1 - likelihood(candidate) / peak_likelihood
```

最も典型的な既知の後続は surprise 0、予測分布から遠い候補ほど1へ近づきます。複数の後続パターンがあれば分布は複数の山を持ちます。

予測に使える過去の後続例が一件もない場合だけ、従来の4基本指標と occurrence interval complexity の合成scoreへfallbackします。

## 7. target へのマッチング

predictive surpriseに3つの構造軸を合成します。

```text
combined = (
  6 * predictive_surprise
  + 1 * cluster_diversity
  + 1 * cluster_shape_complexity
  + 1 * occurrence_interval_complexity
) / active_weights
```

`cluster_diversity`は候補追加後のクラスタ代表間距離、`cluster_shape_complexity`はクラスタ代表系列内の変化量です。各構造軸は候補集合内で0..1化し、候補間に差がない軸は合成から外します。

`occurrence_interval_complexity`も、出現間隔を正規化した時系列に同じ方式を適用して計算します。

```text
occurrence_interval_complexity = (
  6 * interval_predictive_surprise
  + 1 * interval_cluster_diversity
  + 1 * interval_cluster_shape_complexity
) / active_weights
```

区間の後続分布をまだ作れない段階ではoccurrence軸全体を合成から外します。候補ごとにoccurrence intervalが未準備の場合はpredictive surpriseをその軸の値として使い、未準備自体を単純・複雑のどちらにも決めつけません。合成後も候補集合内で0..1へ揃えます。

全候補について次を最小化します。

```text
abs(combined_complexity(candidate) - target_val)
```

`complexity_transition=0`は最も典型的な反復の継続、`1`は予測分布から最も外れた候補を意味します。

## 8. 直近性ウェイト

`recency_center > 0` の場合、各windowの後続分布を作る際に、最近観測した後続例ほど強く投票します。

ユーザ入力 `x` はそのまま直線では使わず、次の smoothstep カーブで内部値 `r` に変換します。

```text
r = x * x * (3 - 2 * x)
```

`r` からそのまま直近性ウェイトを作ります。

```text
span = exp((1 - r) * log(64))
weight = (1 - r) + r * exp(-age / span)
```

開始 index `start_index` の重みは次です。

```text
age = now_index - start_index
weight = (1 - r) + r * exp(-age / span)
```

例:

```text
recency_center = 0.0
r = 0.0
age がいくつでも weight = 1.0

recency_center = 0.5
r = 0.5
span = 8
age = 0  -> weight = 1.0
age = 8  -> weight = 0.5 + 0.5 * exp(-1) = 0.6839
age = 16 -> weight = 0.5 + 0.5 * exp(-2) = 0.5677

recency_center = 1.0
r = 1.0
span = 1
age = 0 -> weight = 1.0
age = 1 -> weight = exp(-1) = 0.3679
age = 2 -> weight = exp(-2) = 0.1353
```

`recency_center=0.0` なら常に重み `1.0` になり、古い後続例と新しい後続例が同じ強さで投票します。

直近性は prune ではありません。古いクラスタを消すのではなく、予測分布を作る際の投票ウェイトを下げます。

## 9. キャッシュと rollback

`generate()` は候補数だけ `simulate_add_and_calculate` を呼ぶため、毎回全クラスタを完全再計算すると重くなります。そのため manager は次のキャッシュを持ちます。

- `cluster_distance_cache`
- `cluster_quantity_cache`
- `cluster_complexity_cache`

初期系列のクラスタリング後、`initial_calc_values!` がキャッシュを seed します。

候補試算では次の流れになります。

1. transaction 開始。
2. 候補を一時的に `mgr.data` へ追加。
3. 追加分だけクラスタリング。
4. 更新されたクラスタのキャッシュを更新。
5. `dist/quantity/complexity` を集計して返す。
6. rollback して試算前の状態へ戻す。

候補が選ばれた後だけ、`add_data_point_permanently!` と `update_caches_permanently!` で本当に状態を進めます。

## 10. レスポンス形式

`generate()` は次のキーを返します。

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

- `timeSeries`
  - `first_elements` と生成結果を結合した系列です。
- `complexityTransition`
  - 初期値部分は `missing`、JSON では通常 `null` 相当です。
  - 生成部分に target 値が入ります。
- `clusteredSubsequences`
  - `clusters_to_timeline` の結果です。
- `clusters`
  - `clusters_to_dict` の結果です。

## 11. 実装上の注意

- `generate()` は `range_fixed` なので、候補範囲が距離スケールを決めます。
- `complexity_transition` は候補値そのものではなく、候補追加後の構造スコアの目標です。
- 初期値が完全反復の場合、低 target では既存反復に乗る候補が強く選ばれやすくなります。
- `recency_center=0.0` で直近性ウェイトは無効、`1.0` で直近性を最大反映します。
