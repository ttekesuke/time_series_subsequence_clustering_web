# `analyse` アクション詳細

このドキュメントは、サーバサイドの `TimeSeriesController.analyse` が行っている**部分列クラスタリング処理**を、コード実装に沿って整理したものです。

## 1. エンドポイント

- ルート: `POST /api/web/time_series/analyse`
- ルーティング先: `TimeSeriesController.analyse()`

## 2. 入力ペイロード

`analyse` は JSON かフォームパラメータを受け取り、以下を参照します。

```json
{
  "analyse": {
    "time_series": [60, 62, 64, 65, 67],
    "merge_threshold_ratio": 0.3
  }
}
```

- `analyse.time_series`
  - 数値列を想定。
  - 各要素は `_parse_int` で `Int` に変換され、変換失敗は無視されます。
- `analyse.merge_threshold_ratio`
  - クラスタへ統合する閾値（デフォルト `0.3`）。

## 3. `analyse` 本体の流れ

`TimeSeriesController.analyse` は、次の順で処理します。

1. リクエストボディを `_payload` で取得。
2. `analyse` キー配下を取り出す。
3. `time_series` を `Int[]` として構築（不正値はスキップ）。
4. `TimeSeriesClusterManager` を以下設定で生成。
   - `min_window_size = 2`
   - `calculate_distance_when_added_subsequence_to_cluster = true`
   - `scale_mode = :global_halves`（analyse専用スケール）
5. `process_data!(manager)` を実行して、系列全体を逐次クラスタリング。
6. 結果を
   - `clusters_to_timeline`
   - `clusters_to_dict`
   で整形。
7. `processingTime` を含めて JSON 返却。

---

## 4. まず押さえるべきデータ構造

`TimeSeriesClusterManager` では、クラスタを木構造で持ちます。

- `ClusterNode`
  - `si`: そのクラスタに属する部分列の開始インデックス群（0-origin）
  - `as`: 代表系列（average sequence）
  - `cc`: 子クラスタ（次の window size）

`clusters` のルートは「長さ2（`min_window_size`）」のクラスタ群です。

### 4.1 具体イメージ（例）

たとえば次のような状態は、

- ルート（window=2）クラスタ `10`
  - `si = [1, 4, 7]`
  - `as = [62.0, 64.3]`
- その子（window=3）クラスタ `18`
  - `si = [1, 4]`
  - `as = [62.0, 64.5, 65.5]`

という意味です。

- `si=[1,4,7]` は「長さ2の部分列が index 1/4/7 から始まる3本が同じクラスタ」に属する。
- 子クラスタは「親に属する部分列をさらに1音伸ばしたとき（長さ3）にどう分かれるか」を持つ。

---

## 5. 逐次クラスタリング (`process_data!`)

`process_data!` は入力系列を先頭から走査し、インデックス `data_index` ごとに
`clustering_subsequences_incremental!` を呼びます。

- 0-based で `data_index <= min_window_size - 1` の間はスキップ。
- それ以降は、新しく確定した末尾要素を使ってクラスタを更新。

---

## 6. 距離判定ルール（「入る/入らない」を決める式）

`analyse` では `scale_mode = :global_halves` のため、部分列長 `len` ごとに次を使います。

- 入力全体の平均 `data_mean` を計算
- `<= data_mean` 群の平均を `lower_half_average`
- `>= data_mean` 群の平均を `upper_half_average`
- `delta = |upper_half_average - lower_half_average|`
- `max_distance = delta * sqrt(len)`

実際の判定は次です。

- `distance = euclidean_distance(candidate, cluster.as)`
- `ratio = distance / max_distance`（`max_distance=0` の時は `0` 扱い）
- `ratio <= merge_threshold_ratio` なら**そのクラスタに統合**
- 超えたら**統合しない**（新規クラスタ作成）

---

## 7. 具体例A: 「どこにクラスタリングされるか/されないか」

ここでは計算しやすいように、

- `merge_threshold_ratio = 0.30`
- 現在の window=2 の root クラスタが2つある

とします。

- クラスタ `0`: `as = [60, 62]`
- クラスタ `1`: `as = [72, 74]`

新しく来た最新部分列（長さ2）が `latest_seq = [61, 63]` だとします。

1. 距離を計算
   - `dist([61,63],[60,62]) = sqrt(1^2 + 1^2) = 1.414`
   - `dist([61,63],[72,74]) = sqrt(11^2 + 11^2) = 15.556`
2. 最小距離クラスタは `0`
3. たとえばこの時点の `max_distance(2)=8.0` なら
   - `ratio = 1.414 / 8.0 = 0.17675 <= 0.30`
4. よって**クラスタ0に統合される**

逆に `latest_seq = [68, 70]` なら、

- `dist` がどちらに対しても大きく、
- 最小距離でも `ratio > 0.30`

となり、**既存クラスタには入らず新規ルートクラスタ**が作られます。

---

## 8. 具体例B: 「クラスタリングされた後、次回さらに窓が伸びるとどうなるか」

ここが `tasks` の役割です。

### 8.1 前提

- 直前ステップで、window=2 のクラスタ `0` に `latest_start=5` が統合された。
- このとき `tasks` に `([0], 2)` が積まれる。
  - 意味: 「次回はクラスタ0を長さ3に伸ばして判定せよ」。

### 8.2 次のデータ点が来たとき

`clustering_subsequences_incremental!` は `tasks` を読み、

- `keys_to_parent = [0]`
- `length0 = 2`
- `new_length = 3`

として window=3 の判定に進みます。

親クラスタ（window=2）の `si` が仮に `[1, 3, 5]` なら、

- `latest_start = data_index - 3 + 1`（今回新しくできた長さ3部分列の開始）
- `valid_si` は「長さ3が切り出せる開始位置」だけ残す

となります。

### 8.3 子クラスタがまだ無い場合（`process_new_clusters!`）

`valid_si` の各部分列を `latest_seq(len=3)` と比較して、

- 閾値以内 -> `valid_group`
- 閾値超過 -> `invalid_group`

に分けます。

- `valid_group` があれば `valid_group + latest_start` で**1つの新規子クラスタ**を作成
- `invalid_group` は各開始位置ごとに**単独子クラスタ**として作成

つまり「似ているものはまとめ、似ていないものは待ち受けクラスタとして分離」します。

### 8.4 次回以降

一度できた子クラスタが次回は `process_existing_clusters!` の対象となり、

- 既存子クラスタ代表 `as` に近ければそこへ追加
- 遠ければ新規子クラスタ

という流れを、window=4,5,... と再帰的に繰り返します。

---

## 9. 具体例C: `process_new_clusters!` の分岐を数値で見る

前提:

- 親クラスタ（window=2）: `si=[0,2,4]`
- 今回伸長で `new_length=3`
- `latest_start=4`（よって `latest_seq` は index 4 からの長さ3）
- `valid_si` 候補は `[0,2]`（`4` は latest 自身なので除外）

比較結果が次だったとします。

- start=0 の長さ3部分列: `ratio=0.22`（閾値0.30以内）
- start=2 の長さ3部分列: `ratio=0.47`（閾値超過）

このとき:

- `valid_group=[0]`
- `invalid_group=[2]`

なので生成される子は

1. クラスタA: `si=[0,4]`（`valid_group + latest_start`）
2. クラスタB: `si=[2]`（invalid単独）

になります。

---

## 10. キャッシュ更新フラグ

`analyse` 実行中にも、将来の `generate` で使うための更新ID集合は維持されます。

- `updated_cluster_ids_per_window_for_calculate_distance`
- `updated_cluster_ids_per_window_for_calculate_quantities`

クラスタへ系列を追加して代表系列が変わった時などに、対象クラスタIDが登録されます。

---

## 11. レスポンス形式

`analyse` は次のキーを返します。

- `clusteredSubsequences`
  - 各クラスタの `window_size`, `cluster_id`, `indices` を持つ配列
- `timeSeries`
  - サニタイズ済み入力系列（`Int[]`）
- `clusters`
  - 木構造の完全表現（`si`, `as`, `cc`）
- `processingTime`
  - 秒（小数2桁）

---

## 12. 実装上のポイント

- インデックス管理は**内部0-origin**（JSON返却時の `indices` も開始位置ベース）。
- `min_window_size` は固定で `2`。
- 距離はユークリッド距離、代表系列は要素ごとの平均。
- 正規化スケールを部分列長ごとに `sqrt(len)` で伸縮させる設計のため、
  長い部分列でも閾値の解釈が崩れにくくなっています。
