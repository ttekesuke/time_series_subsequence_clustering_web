# `generate` アクション詳細

このドキュメントは、サーバサイドの `TimeSeriesController.generate()` が行う単音系列生成を、現在の実装に沿って整理したものです。

`generate()` は、既存の初期系列をクラスタリングした上で、候補値を 1 つずつ仮追加し、候補ごとの単純/複雑スコアが `complexity_transition` の目標値に近いものを選びます。

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
    "recency_weight_strength": 0.1,
    "recency_tau_min": 64,
    "recency_tau_window_multiplier": 16
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
- `generate.recency_weight_strength`
  - 直近性ウェイトの強さです。
  - `0.0` なら旧来の全履歴集計、`1.0` なら直近性を最大反映します。
- `generate.recency_tau_min`
  - 直近性の時定数の下限です。
- `generate.recency_tau_window_multiplier`
  - window size から時定数を作る倍率です。

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
6. `complexity_transition` の各 target について、候補値を全て仮追加してスコアを計算する。
7. target に最も近い候補を選ぶ。
8. 選ばれた値を本当に manager に追加し、キャッシュを更新する。
9. 生成終了後、timeline と cluster tree を返す。

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

ただし、最終的な候補スコアはこの直接距離だけでは決まりません。候補を追加した結果としてできるクラスタ構造、クラスタ間距離、クラスタ内数量、代表系列の複雑度を集計した値で決まります。

## 5. 候補ごとの生スコア

各生成ステップで、候補 `range_min:range_max` を全て試します。

```julia
avg_dist, quantity, complexity =
  PolyphonicClusterManager.simulate_add_and_calculate(manager, Float64[candidate])
```

返る値は次です。

- `avg_dist`
  - クラスタ代表間距離の集計です。
  - 大きいほど複雑側として扱います。
- `quantity`
  - クラスタ内の数に基づく量スコアです。
  - 基本式は `cluster_size * window_size`。
  - 大きいほど反復・まとまりが強いので、複雑度判定では小さいほど複雑側として扱います。
- `complexity`
  - クラスタ代表系列そのものの隣接変化量です。
  - 大きいほど複雑側として扱います。

重要なのは、`avg_dist` は `abs(candidate - current_value) / range` の直接値ではないことです。候補追加後のクラスタ木とキャッシュを使った集計値です。

## 6. 正規化と信頼度ウェイト

候補ごとの生スコアは `normalize_scores` で 0..1 系のスコアに変換されます。

```text
unique raw value count <= 1  -> weight = 0.0
unique raw value count == 2  -> weight = 0.2
unique raw value count >= 3  -> weight = 1.0
```

正規化は候補集合内の min/max で行います。

```text
normalized = (value - min_value) / (max_value - min_value)
```

複雑側の向きは指標ごとに違います。

- `dist`: 大きいほど複雑
- `quantity`: 小さいほど複雑
- `complexity`: 大きいほど複雑

例えば候補 `0..4` に対して、ある指標の raw が次だったとします。

```text
raw = [10, 10, 20, 30, 30]
unique = 3 個なので weight = 1.0
normalized = [0.0, 0.0, 0.5, 1.0, 1.0]
```

この指標が「大きいほど複雑」ならそのままです。`quantity` のように「小さいほど複雑」なら次になります。

```text
[1.0, 1.0, 0.5, 0.0, 0.0]
```

## 7. target へのマッチング

`find_complex_candidate_by_value(criteria, target_val)` は、各候補の正規化済みスコアを合算し、信頼度ウェイト合計で割ります。

概念的には次です。

```text
candidate_score =
  (dist_score + quantity_score + complexity_score) / total_weight
```

そして次を最小化する候補を選びます。

```text
abs(candidate_score - target_val)
```

つまり `complexity_transition=0.3` は「候補値 3 を選ぶ」という意味ではありません。「現在のクラスタ構造から見た単純/複雑スコアが 0.3 に近い候補を選ぶ」という意味です。

## 8. 直近性ウェイト

`recency_weight_strength > 0` の場合、候補追加後の集計で直近のクラスタほど重く扱います。

時定数は window size ごとに次で決まります。

```text
tau = max(recency_tau_min, recency_tau_window_multiplier * window_size)
```

開始 index `start_index` の重みは次です。

```text
age = now_index - start_index
weight = (1 - strength) + strength * exp(-age / tau)
```

例:

```text
strength = 0.1
tau = 64
age = 0   -> weight = 1.0
age = 64  -> weight = 0.9 + 0.1 * exp(-1) = 0.9368
age = 128 -> weight = 0.9 + 0.1 * exp(-2) = 0.9135
```

`strength=0.0` なら常に重み `1.0` になり、旧来の全履歴集計に戻ります。

直近性は prune ではありません。古いクラスタを消すのではなく、集計時の重みを下げます。

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
- `recency_weight_strength=0.0` で直近性ウェイトは無効になります。
- 現地点から遠いクラスタを prune する処理は `generate()` にはありません。
- 旧 `q_array` や quadratic quantity weight のような処理は現在の `generate()` にはありません。
