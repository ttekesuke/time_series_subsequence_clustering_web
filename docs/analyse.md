# `analyse` アクション詳細

このドキュメントは、サーバサイドの `TimeSeriesController.analyse()` が行う部分列クラスタリングを、現在の実装に沿って整理したものです。

現在の単音系列分析は、旧来の scalar 専用 manager ではなく `PolyphonicClusterManager` を使います。単音の各時点値は `Float64[value]` という 1 要素の `PolySet` として扱われます。

## 1. エンドポイント

- ルート: `POST /api/web/time_series/analyse`
- ルーティング先: `TimeSeriesController.analyse()`
- 主な実装:
  - [src/controllers/time_series_controller.jl](../src/controllers/time_series_controller.jl)
  - [src/polyphonic/polyphonic_cluster_manager.jl](../src/polyphonic/polyphonic_cluster_manager.jl)

## 2. 入力ペイロード

`analyse` は JSON またはフォームパラメータから `analyse` キー配下を読みます。

```json
{
  "analyse": {
    "time_series": [60, 62, 64, 65, 67],
    "merge_threshold_ratio": 0.3,
    "contextual_min_width": 1.0
  }
}
```

- `analyse.time_series`
  - 入力数値列です。
  - 各要素は `_parse_int` で `Int` に変換されます。
  - 空セルは考慮しません。フロント側で必ず値が入っていることを検証してから送信します。
- `analyse.merge_threshold_ratio`
  - 既存クラスタへ統合する距離比の閾値です。
  - デフォルトは `Config.DEFAULT_MERGE_THRESHOLD_RATIO`、現在は `0.3`。
- `analyse.contextual_min_width`
  - 文脈スケール幅が狭すぎる場合の最小幅です。
  - デフォルトは `Config.DEFAULT_CONTEXTUAL_MIN_WIDTH`、現在は `1.0`。

サーバ側では空値をスキップしません。`time_series` は全要素が数値として入ってくる前提です。

## 3. `analyse` 本体の流れ

`TimeSeriesController.analyse()` の処理順は次の通りです。

1. `_payload()` でリクエストを取得。
2. `_subhash(payload, "analyse")` で `analyse` 配下を取り出す。
3. `time_series` を `Int[]` に変換する。
4. `PolyphonicClusterManager.Manager` を作る。
   - `data = Vector{Float64}[[float(v)] for v in data]`
   - `min_window_size = Config.SUBSEQUENCE_MIN_WINDOW_SIZE`
   - `calculate_distance_when_added_subsequence_to_cluster = true`
   - `scale_mode = :contextual_global_halves`
5. `PolyphonicClusterManager.process_data!(manager)` で全系列を逐次クラスタリングする。
6. `clusters_to_timeline` と `clusters_to_dict` で返却用に整形する。
7. `processingTime` を付けて返す。

`analyse` では距離キャッシュ更新フラグを有効にしています。これは、クラスタ代表系列が変わったときに距離キャッシュ更新対象として記録するためです。

## 4. まず押さえるべきデータ構造

`PolyphonicClusterManager` は、部分列クラスタを木構造で持ちます。

- `PolySet = Vector{Float64}`
  - 1 時点の値集合です。
  - 単音分析では常に `[value]` の形です。
- `PolySeq = Vector{PolySet}`
  - 部分列です。
  - 例えば単音系列 `[60, 62]` は `[[60.0], [62.0]]` になります。
- `PolyClusterNode`
  - `si`: そのクラスタに属する部分列の開始 index 群。内部もレスポンスも 0-origin です。
  - `as`: 代表系列です。複数部分列が同じクラスタに入ると平均系列として更新されます。
  - `cc`: 子クラスタです。子は window size が 1 つ長いクラスタです。

`manager.clusters` の root は `min_window_size`、つまり現在は長さ 2 のクラスタ群です。子に進むたびに window size が 3、4、5... と伸びます。

### 4.1 具体イメージ

例えば次のような root クラスタがあるとします。

```text
cluster 10, window=2
  si = [1, 4, 7]
  as = [[62.0], [64.3]]
  cc:
    cluster 18, window=3
      si = [1, 4]
      as = [[62.0], [64.5], [65.5]]
```

これは次を意味します。

- index 1、4、7 から始まる長さ 2 の部分列が同じクラスタに入っている。
- そのうち index 1、4 から始まるものは、長さ 3 に伸ばしても同じ子クラスタに入っている。
- `as` は scalar 配列ではなく、各時点が `PolySet` になっている。

## 5. 逐次クラスタリング (`process_data!`)

`process_data!(mgr)` は `mgr.data` を先頭から走査します。

- `data_index` は 0-origin。
- `data_index <= min_window_size - 1` の間は、まだ新しい長さ 2 部分列が確定しないためスキップします。
- それ以降、`clustering_subsequences_incremental!(mgr, data_index)` を呼びます。

`clustering_subsequences_incremental!` は大きく 2 種類の処理をします。

- 既存 `tasks` の処理
  - 前回までに統合されたクラスタを、次の window size に伸ばして判定します。
  - 例えば window=2 のクラスタに入った部分列は、次回 window=3 の候補になります。
- root クラスタの処理
  - 最新の長さ 2 部分列を root クラスタへ入れるか、新規 root クラスタにします。

`tasks` は「この親クラスタを次回 1 つ長い window で調べる」という予約です。これにより、全 window を毎回総当たりせず、逐次的に木を伸ばします。

## 6. 距離判定ルール

距離計算は `PolyphonicClusterManager.euclidean_distance(mgr, seq_a, seq_b)` を使います。

単音の場合、1 ステップ同士の距離は概ね次になります。

```text
abs(a - b) / value_width
```

ただし実装上は `PolySet` 間距離 `min_avg_distance` を通ります。単音では各 `PolySet` が 1 要素なので、値差を `mgr.value_width` で割ったものになります。

`analyse` は `scale_mode = :contextual_global_halves` です。各更新時に `update_value_width!` が以下を計算します。

1. その時点までの全値の平均 `data_mean` を出す。
2. `data_mean` 以下の値の平均を `lower_half_average` とする。
3. `data_mean` 以上の値の平均を `upper_half_average` とする。
4. `delta = abs(upper_half_average - lower_half_average)` を出す。
5. `delta = max(delta, contextual_min_width)` にする。
6. `mgr.value_width = delta` にする。

クラスタ統合判定は次です。

```text
distance = euclidean_distance(candidate_seq, cluster.as)
max_distance = sqrt(window_size)
ratio = distance / max_distance

ratio <= merge_threshold_ratio なら既存クラスタに統合
それ以外なら新規クラスタ
```

`euclidean_distance` の各ステップ距離がすでに `value_width` で正規化されているため、window size に対する上限スケールは `sqrt(window_size)` になります。

## 7. 具体例A: root クラスタへ入る/入らない

前提:

- `merge_threshold_ratio = 0.30`
- `contextual_min_width = 1.0`
- 現在の `value_width = 10.0`
- root は window=2
- 既存 root クラスタ `0` の代表が `[[60.0], [62.0]]`

最新の長さ 2 部分列が `[[61.0], [63.0]]` の場合:

```text
step distance 1 = abs(61 - 60) / 10 = 0.1
step distance 2 = abs(63 - 62) / 10 = 0.1
euclidean_distance = sqrt(0.1^2 + 0.1^2) = 0.1414
max_distance = sqrt(2) = 1.4142
ratio = 0.1414 / 1.4142 = 0.10
```

`0.10 <= 0.30` なので、既存クラスタ `0` に統合されます。

最新部分列が `[[68.0], [70.0]]` の場合:

```text
step distance 1 = abs(68 - 60) / 10 = 0.8
step distance 2 = abs(70 - 62) / 10 = 0.8
euclidean_distance = sqrt(0.8^2 + 0.8^2) = 1.1314
ratio = 1.1314 / 1.4142 = 0.80
```

`0.80 > 0.30` なので、既存クラスタには入らず新規 root クラスタになります。

## 8. 具体例B: クラスタリング後に window が伸びる流れ

ここでは `tasks` の動きを見ます。

### 8.1 前提

直前ステップで、長さ 2 の最新部分列 `latest_start=5` が root クラスタ `0` に統合されたとします。

このとき `tasks` に次が積まれます。

```text
([0], 2)
```

意味は「次回、クラスタ path `[0]` を親として、長さ 3 に伸ばして判定する」です。

### 8.2 次のデータ点が来たとき

次の `data_index` で `clustering_subsequences_incremental!` は `tasks` を読みます。

```text
keys_to_parent = [0]
length0 = 2
new_length = 3
latest_start = data_index - 3 + 1
```

親クラスタ `0` の `si` から、長さ 3 が実際に切り出せる開始 index だけを `valid_si` として残します。最新自身の開始 index は比較対象から除外されます。

### 8.3 子クラスタがまだ無い場合

親クラスタにまだ子が無い場合、`process_new_clusters!` が呼ばれます。

`valid_si` の各開始 index について、長さ 3 の部分列を最新の長さ 3 部分列と比較します。

- 閾値以内なら `valid_group`
- 閾値超過なら `invalid_group`

`valid_group` が空でなければ、`valid_group + latest_start` で 1 つの新規子クラスタを作ります。`invalid_group` は各開始 index ごとに単独子クラスタとして分けます。

`valid_group` が空なら、最新部分列だけを持つ新規子クラスタを作ります。

### 8.4 子クラスタが既にある場合

親クラスタに子がある場合、`process_existing_clusters!` が呼ばれます。

- 既存子クラスタの代表 `as` と最新部分列の距離を測る。
- 最も近い子クラスタを選ぶ。
- `ratio <= merge_threshold_ratio` ならそこへ追加し、代表 `as` を更新する。
- 閾値を超えるなら新規子クラスタを作る。

統合された場合は、その子クラスタをさらに次回伸ばすために `tasks` へ積みます。

## 9. 具体例C: `process_new_clusters!` の分岐

前提:

- 親クラスタ window=2: `si = [0, 2, 4]`
- 今回伸長する window: `new_length = 3`
- 最新開始 index: `latest_start = 4`
- 比較対象 `valid_si = [0, 2]`
- `merge_threshold_ratio = 0.30`

比較結果が次だったとします。

```text
start=0 の長さ3部分列: ratio = 0.22
start=2 の長さ3部分列: ratio = 0.47
```

この場合:

```text
valid_group = [0]
invalid_group = [2]
```

作られる子クラスタは次です。

1. `si = [0, 4]` の子クラスタ
2. `si = [2]` の単独子クラスタ

この設計により、最新部分列に近い過去部分列はまとめられ、近くない過去部分列は別の待ち受けクラスタとして残ります。

## 10. キャッシュ更新フラグ

`PolyphonicClusterManager` は、生成時の高速な試算に使うキャッシュを持っています。

- `cluster_distance_cache`
  - window size ごとのクラスタ代表間距離。
- `cluster_quantity_cache`
  - window size ごとのクラスタ量スコア。
  - 現在の式は `cluster_size * window_size`。
- `cluster_complexity_cache`
  - window size ごとのクラスタ代表系列の複雑度。
  - 現在の式は、代表系列の隣接ステップ距離の平均。

どのクラスタを再計算する必要があるかは、次の更新 ID 集合で管理します。

- `updated_cluster_ids_per_window_for_calculate_distance`
- `updated_cluster_ids_per_window_for_calculate_quantities`

`analyse` 自体は生成候補を選びませんが、クラスタ統合・代表更新時にこれらのフラグは更新されます。

## 11. レスポンス形式

`analyse` の通常レスポンスは次の形です。

```json
{
  "clusteredSubsequences": [
    {
      "window_size": 2,
      "cluster_id": "0",
      "indices": [0, 3, 7]
    }
  ],
  "timeSeries": [60, 62, 64, 65, 67],
  "clusters": {
    "0": {
      "si": [0, 3, 7],
      "as": [[60.0], [62.0]],
      "cc": {}
    }
  },
  "processingTime": 0.01
}
```

実際の `as` は `PolySeq` なので、window=2 の単音代表は次のような形になります。

```json
[[60.0], [62.0]]
```

## 12. 実装上のポイント

- 内部 index は 0-origin です。返却される `indices` も 0-origin の開始 index です。
- 最小 window size は `Config.SUBSEQUENCE_MIN_WINDOW_SIZE`、現在は `2` です。
- 単音系列も `PolyphonicClusterManager` に乗せるため、値は `[value]` として処理されます。
- `analyse` は `scale_mode = :contextual_global_halves` です。
- `generate()` は `scale_mode = :range_fixed` なので、同じ manager を使っていても距離スケールの考え方が違います。
- 現在の `PolyClusterNode` には `last_seen` や `importance_raw` のようなフィールドはありません。
- 現地点から遠いクラスタを prune する処理は `analyse` にはありません。
- 代表系列 `as` は、クラスタ内の部分列から再計算されます。単音では平均値、集合サイズが混在する polyphonic では最新値採用などの分岐があります。
