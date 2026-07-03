# `generate_polyphonic` アクション詳細

このドキュメントは、サーバサイドの `TimeSeriesController.generate_polyphonic()` が行うポリフォニック生成を、現在の実装に沿って整理したものです。

主な実装は次です。

- `src/controllers/time_series_controller.jl`
- `src/polyphonic/multi_stream_manager.jl`
- `src/polyphonic/polyphonic_cluster_manager.jl`
- `src/polyphonic/dissonance_stm_manager.jl`
- `frontend/src/components/dialog/MusicGenerateDialog.vue`
- `frontend/src/components/features/MusicGenerate.vue`

## 1. エンドポイント

- 直接実行: `POST /api/web/time_series/generate_polyphonic`
- GitHub Actions dispatch: `POST /api/web/time_series/dispatch_generate_polyphonic`
- ルーティング先:
  - `TimeSeriesController.generate_polyphonic()`
  - `TimeSeriesController.dispatch_generate_polyphonic()`

画面の `RUN` は環境変数 `VITE_RUN_GENERATE_POLYPHONIC_ON_GITHUB_ACTIONS` により、直接実行か GitHub Actions dispatch に切り替わります。どちらも生成本体に渡す payload は `generate_polyphonic` キー配下です。

## 2. 入力ペイロード全体

画面の `MusicGenerateDialog.buildParamsPayload()` は概ね次の形を送ります。

```json
{
  "generate_polyphonic": {
    "job_id": "...uuid...",
    "bpm": 480,
    "future_bpm": [480, 480],
    "stream_counts": [1, 2],
    "initial_context": [
      [
        [[60], 1.0, 0.5, 0.2, 0.8, 0.05, 0.2, 0.75]
      ]
    ],
    "initial_context_bpm": [480],
    "dimension_policy": {
      "area": { "accept_params": true, "fixed_value": 0.5, "fixed_value_source": "manual_input" }
    },
    "merge_threshold_ratio": 0.02,
    "stream_strength_target": [0.0, 0.0],
    "stream_strength_spread": [0.0, 0.0],
    "global_dist_weight": [0.2, 0.2],
    "global_qty_weight": [2.0, 2.0],
    "global_comp_weight": [2.0, 2.0],
    "stream_dist_weight": [0.2, 0.2],
    "stream_qty_weight": [2.0, 2.0],
    "stream_comp_weight": [2.0, 2.0],
    "note_register_freedom": [1.0, 1.0],
    "dissonance_target": [0.3, 0.3],
    "area_global": [0.0, 0.0],
    "area_center": [0.0, 0.0],
    "area_spread": [0.0, 0.0],
    "area_conc": [0.0, 0.0],
    "vol_global": [0.0, 0.0],
    "vol_center": [0.0, 0.0],
    "vol_spread": [0.0, 0.0],
    "vol_conc": [0.0, 0.0],
    "vol_target": [0.5, 0.5],
    "vol_target_spread": [1.0, 1.0]
  }
}
```

配列パラメータは future step ごとの値です。サーバは 0-based の `idx0 = step_idx - 1` で `array_param(gp, key, idx0)` を読みます。配列が足りない場合は `array_param` の実装に依存しますが、画面側は `genSteps` 長に正規化してから送るため、通常は全 future step 分があります。

## 3. 画面から送られる主なパラメータ

### 3.1 初期文脈

- `initial_context`
  - 形は `initial_context[step][stream] = stream_record` です。
  - 現在の画面は簡略 strict 形式として `[abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release]` を組み立てます。
  - サーバの厳密内部形式も `[abs_notes, vol, brightness, noise, harmonicity, attack, decay_sustain, release, chord_range, density, sustain]` です。
  - 先頭 8 要素は SuperCollider render が読む `[abs_notes, vol, brightness, noise, harmonicity, attack, decay, sustain_release]` と同じ意味です。`decay_sustain` は SC に渡すときは `decay`、`release` は SC に渡すときは `sustainRelease` です。
  - `chord_range` と `density` は初期文脈から送られても、サーバが `abs_notes` の実観測値から再計算します。
- `initial_context_bpm`
  - 初期文脈各 step の BPM です。
  - dissonance STM の初期 memory に commit する onset 計算に使われます。
- `bpm`, `future_bpm`
  - `future_bpm` は生成対象 step の BPM 配列です。
  - `bpm` は fallback およびレスポンスの代表値です。
  - サーバは BPM から `stepDuration = 60 / bpm` を作り、dissonance STM の future onset に使います。

### 3.2 ストリーム数とストリーム強度

- `stream_counts`
  - 各 future step のストリーム数です。
  - `steps_to_generate = length(stream_counts)` なので、この配列長が生成 step 数です。
  - 各値は最低 1 に丸められます。
- `stream_strength_target`
  - ストリーム増減時に、どの強さのストリームを残す、復活する、複製するかを決める中心値です。
  - `vol` manager がある場合は `vol` の `presence_avg`、なければ `note` 側を使います。
- `stream_strength_spread`
  - `stream_strength_target` を中心にしたターゲット分布の広がりです。
  - `generate_centered_targets(count, target, spread)` で複数の目標値を作ります。

### 3.3 dimension policy

`dimension_policy` は、次元ごとに「画面パラメータで生成するか、固定値を使うか」を決めます。

```json
{
  "vol": {
    "accept_params": true,
    "fixed_value": 1.0,
    "fixed_value_source": "manual_input"
  }
}
```

- `accept_params = true`
  - その次元は `*_global`, `*_center`, `*_spread`, `*_conc`, `*_target`, `*_target_spread` を読んで探索します。
- `accept_params = false`
  - その次元は生成探索せず、固定値を出力します。
- `fixed_value_source = "manual_input"`
  - `fixed_value` を使います。
- `fixed_value_source = "initial_context_last_step"`
  - 初期文脈の最後の step の同じ stream から値を引き継ぎます。
  - `area` は最後の note anchor を 4 semitone band の `band_low` に変換して使います。

サーバ内部のデフォルトは `vol` だけ `accept_params = true`、それ以外は概ね固定です。ただし画面は全 managed dimension を `accept_params = true` で送るデフォルトなので、画面経由では多くの次元が有効になります。

サーバが認識する managed dimension は次です。

- `area`
- `chord_range`
- `density`
- `sustain`
- `vol`
- `brightness`
- `noise`
- `harmonicity`
- `attack`
- `decay_sustain`
- `release`

音色キーは SC の synth パラメータの意味に合わせています。

| キー | SC パラメータ | 意味 |
| --- | --- | --- |
| `brightness` | `brightness` | 部分音量、LPF cutoff、HiShelf に効く明るさ |
| `noise` | `noise` | WhiteNoise 量と歪み混合量 |
| `harmonicity` | `harmonicity` | 部分音比率を整数倍音寄りにする度合い |
| `attack` | `attack` | step duration 内の attack 時間比率 |
| `decay_sustain` | `decay` | step duration 内の decay 時間比率 |
| `release` | `sustainRelease` | sustain/release 区間の時間比率 |

### 3.4 各 dimension の complexity target

対象 dimension ごとに次を送ります。

- `${key}_global`
  - 全ストリームをまとめた global manager の複雑度ターゲットです。
  - 0 は単純寄り、1 は複雑寄りです。
- `${key}_center`
  - stream ごとの複雑度ターゲット分布の中心です。
- `${key}_spread`
  - stream ごとの複雑度ターゲット分布の広がりです。
  - `n` ストリームなら `center ± spread/2` の範囲を `n` 等分した `stream_targets` を作ります。
- `${key}_conc`
  - stream 間の一致・分散の好みです。
  - `conc > 0` は stream 間の値をそろえる方向です。
  - `conc < 0` は stream 間の値を離す方向です。
  - `0` はこのコストを無効にします。

通常 dimension の候補選択では、候補ごとに次を合計して最小化します。

```text
total_cost =
  abs(global_score - global_target)
  + mean(abs(stream_score[i] - stream_target[i]))
  + concordance_cost
```

### 3.5 指標ウェイト

- `global_dist_weight`, `global_qty_weight`, `global_comp_weight`
- `stream_dist_weight`, `stream_qty_weight`, `stream_comp_weight`

`dist`, `quantity`, `complexity` の合成比率です。サーバ内部では `usage` も 4 番目の指標として常に weight 1.0 で足されます。

dimension 固有の `${key}_global_dist_weight` のようなキーもサーバは読めますが、画面は共通キーを送っています。

各指標の意味は単音 `generate()` と同じ方向です。

- `dist`: 候補追加後のクラスタ代表間距離。大きいほど複雑。
- `quantity`: クラスタ内の量。小さいほど複雑。
- `complexity`: 代表系列自体の変化量。大きいほど複雑。
- `usage`: 最新部分列が入ったクラスタの使用密度。小さいほど複雑。

### 3.6 探索窓

`targetWindowDimensionKeys` の次元には、値そのものの探索範囲を狭めるパラメータがあります。

- `${key}_target`
  - 候補値の中心です。
- `${key}_target_spread`
  - 候補値の許容幅です。

例えば `density_target=0.5`, `density_target_spread=0.2` なら、`Config.FLOAT_STEPS = 0.0, 0.1, ..., 1.0` のうち `0.3..0.7` 付近だけを候補にします。候補が空なら target に最も近い値を 1 つ残します。

### 3.7 note / dissonance 系

- `note_register_freedom`
  - 各 stream が直近の register center からどれだけ離れてよいかです。
  - 1.0 ならほぼ制限なしです。
  - 0.0 なら allowance は 0 になり、直近 register に最も近い候補へ強く制限されます。
  - 0..1 の中間では `NOTE_REGISTER_MIN_ALLOWANCE` から `NOTE_REGISTER_MAX_ALLOWANCE` へ線形補間されます。
- `dissonance_target`
  - 最終的な和音候補の roughness を 0..1 正規化した目標値です。
  - 0 は協和寄り、1 は不協和寄りです。

## 4. 処理の全体順

`generate_polyphonic()` の処理順は次です。

1. payload の `generate_polyphonic` を読む。
2. `stream_counts`, `stream_strength_target`, `stream_strength_spread`, BPM 系を正規化する。
3. `initial_context` を 3 階層配列として読み、空ならデフォルト 1 step / 1 stream を作る。
4. stream record をサーバ内部 strict 形式へ正規化する。
5. 初期文脈の `chord_range` と `density` を `abs_notes` から実測再計算する。
6. `dimension_policy` を解決し、固定次元の固定値を決める。
7. 初期文脈から dimension ごとの履歴 matrix を作る。
8. 履歴が `POLYPHONIC_MIN_WINDOW_SIZE + 1` 未満なら padding する。
9. dimension ごとに global manager と stream manager を作る。
10. 初期文脈の実音を `DissonanceStmManager` に commit して短期記憶を seed する。
11. future step ごとに、stream lifecycle を計画して全 manager に適用する。
12. `vol`, `chord_range`, `density`, `sustain`, timbre 系の順に通常 dimension を決める。
13. `area` を `tmp_anchor` として決める。
14. `area`, `chord_range`, `density`, `vol` などから各 stream の実音候補を作る。
15. `dissonance_target` に近い実音の組み合わせを選ぶ。
16. 実音を dissonance STM と note manager に commit する。
17. 出力値を clamp / quantize する。
18. `timeSeries`, `clusters`, `timbreSeries`, BPM 系を返す。

## 5. global / stream / conc の意味

画面で見える `Global`, `Center`, `Spread`, `Conc` は同じ候補を違う観点から評価するためのパラメータです。

### global

`global` は、同時に鳴っている全 stream を 1 つの polyphonic set として扱う複雑度です。

ただし stream 数が増えても同じ manager で扱えるよう、通常 dimension の global 値は stream index ごとに offset encode されます。

```text
encoded_value(stream i) = raw_value + (i - 1) * offset
offset = value_width + 1
```

例えば `vol` の範囲が 0..1 なら `offset = 2` です。2 stream の値 `[0.3, 0.8]` は global manager に `[0.3, 2.8]` として入ります。

この encode により、stream 1 の 0.8 と stream 2 の 0.8 が同じ軸上で衝突せず、global manager は「stream 別の面」を持つ polyphonic series としてクラスタリングできます。`PolyphonicClusterManager` 側では `use_streamwise_surface_average=true` と `stream_axis_offset=offset` が使われ、平均系列を作るときに stream 軸を復元して扱います。

`note` だけは例外で、global manager は全 stream の実音から median anchor を 1 つ取る scalar 系です。`area` は 4 semitone band の `tmp_anchor` を stream offset encode します。

### stream

`stream` は、各声部を独立した時系列として見る複雑度です。

`MultiStreamManager` は stream ごとに `PolyphonicClusterManager.Manager` を持ちます。候補をその stream に仮追加した時の `dist/quantity/complexity/usage` を正規化し、`stream_targets` に近いものを選びます。

`stream_center` と `stream_spread` という名前の payload はありません。各 dimension では `${key}_center` と `${key}_spread` が stream 側ターゲットを作るための値です。

### conc

`conc` は concordance / conformity の重みです。stream 間で同じような値にするか、バラけさせるかを加点します。

通常 dimension では候補内の値の spread を `discordance` として近似します。

- `conc > 0`: `discordance` が小さい候補が有利です。
- `conc < 0`: `discordance` が大きい候補が有利です。

`area` では mean pairwise distance を `BAND_WIDTH` で割った `spread01` を使います。

- `area_conc > 0`: area anchor が近い候補が有利です。
- `area_conc < 0`: area anchor が離れた候補が有利です。

## 6. 通常 dimension の候補選択

通常 dimension の処理対象順は次です。

1. `vol`
2. `chord_range`
3. `density`
4. `sustain`
5. `brightness`
6. `noise`
7. `harmonicity`
8. `attack`
9. `decay_sustain`
10. `release`

各 dimension で行うことは次です。

1. `dimension_policy` が固定なら、stream 数分の固定値を入れて次へ進む。
2. `${key}_global`, `${key}_center`, `${key}_spread`, `${key}_conc` を読む。
3. `${key}_target`, `${key}_target_spread` があれば候補値の探索窓を絞る。
4. stream manager に対して候補ごとの complexity cost を事前計算する。
5. 候補ベクトルを作る。
6. 候補を評価して best を選ぶ。
7. global manager と stream manager に best を commit する。
8. `current_step_values` に値を書き込む。

候補集合は dimension により違います。

- `vol`: `[0.0, 1.0]`
- `density`: `0.0, 0.1, ..., 1.0`
- `chord_range`: `0..12`
- `sustain`: `0.0, 0.25, 0.5, 0.75, 1.0`
- timbre 系: `0.0, 0.1, ..., 1.0`

複数 stream の候補は基本的に cartesian product です。ただし `chord_range` と `density` は「全 stream 同じ値」という global scalar として探索空間を縮小しています。つまり 4 stream でも `[6, 6, 6, 6]` のような候補だけを試します。

`vol` は stream 数が 2 以上のとき `use_global_score=false` になります。これは `preserve_stream_order=true` の volume で global score が探索を支配しすぎるのを避け、stream 側と target window を主に使うためです。

## 7. Hungarian 法による stream 割当

候補ベクトルは「値の集合」として作られるため、その値をどの active stream に割り当てるかを決める必要があります。この割当で Hungarian 法が使われます。

実装は `MultiStreamManager.resolve_mapping_and_score()` です。

### 7.1 コスト行列

active stream 数を `n`、候補値数を `n` として、`n x n` のコスト行列を作ります。

```text
cost(stream i, candidate j) =
  distance_weight * dist01(i, j)
  + complexity_weight * comp01(i, j)
  + tiny_tie_breaker
```

- `dist01`
  - scalar 値なら前回値との差を value range で割ったものです。
  - polyset なら集合距離です。
  - note 系で absolute base がある場合は absolute pitch に戻して距離を取ります。
  - `vol` のような `track_presence` 次元では、stream_costs がある場合 scalar 距離を 0 にして、過去値への張り付きより subsequence fit を優先します。
- `comp01`
  - `precalculate_costs()` で stream ごと、候補値ごとに仮追加して得た raw complexity を、その stream の候補集合内 min/max で 0..1 正規化した値です。
- `tiny_tie_breaker`
  - 完全同点時に小さい candidate index と小さい stream index を優先するための極小値です。

通常は `use_complexity_mapping=true` なので、明示指定がなければ `distance_weight=0`, `complexity_weight=1` です。

ただし `select_best_chord_for_dimension_with_cost()` に `active_total_notes` が渡された場合は、密度に応じて割当の距離/複雑度比率を変える設計があります。現在の通常 dimension 呼び出しではこの引数は使われていません。

### 7.2 Hungarian min assignment

`hungarian_min_assignment(cost_matrix)` は各 stream に候補を 1 つずつ割り当て、総コストを最小化します。

返り値は `assignment[stream_i] = candidate_j` です。これを使って候補値を active stream 順に並べ替えた `ordered` を作ります。

```text
candidate set: [0.0, 1.0]
active streams: [stream 3, stream 5]
assignment: [2, 1]
ordered: stream 3 -> 1.0, stream 5 -> 0.0
```

このため、候補生成時の順序と実際の stream 出力順は一致しない場合があります。

### 7.3 preserve_stream_order

`preserve_stream_order=true` の場合は Hungarian 法を通さず、候補ベクトルの順序をそのまま stream 順に使います。

現在の通常 dimension では、複数 stream のとき `preserve_stream_order = true` になっています。つまり `select_best_chord_for_dimension_with_cost()` 内では Hungarian を通さず、そのまま stream 順に評価します。

ただし `MultiStreamManager.resolve_mapping_and_score()` 自体は生成器の重要な割当 API として残っており、`preserve_stream_order=false` の経路、note/chord 系の拡張、または別呼び出しでは Hungarian 割当が使われます。

## 8. stream lifecycle と「stream 数が増えても固定パラメータで生成できる仕組み」

`stream_counts` が step ごとに変わっても、パラメータ行は「future step ごとに 1 値」です。stream ごとの個別パラメータを画面から送る必要はありません。

これを可能にしている仕組みは 4 つあります。

### 8.1 stream target の自動展開

各 step の `${key}_center` と `${key}_spread` から、現在の stream 数 `n` に合わせて `n` 個の target を生成します。

```text
n = 1: [center]
n = 4: [center-spread/2, ..., center+spread/2] を 4 等分
```

つまり stream 数が 2 でも 16 でも、画面側は `center/spread` だけを指定すれば stream ごとの目標が作られます。

### 8.2 stream manager pool

`MultiStreamManager` は `stream_pool` と `active_ids` / `inactive_ids` を持ちます。

- stream 数が減ると、余った stream id は inactive になります。
- stream 数が増えると、inactive stream を復活するか、active stream を fork します。
- fork は source stream の manager と last value を deep copy するため、新 stream は履歴のない空 stream ではなく、既存 stream の文脈を持って始まります。

### 8.3 lifecycle plan

各 step の最初に `build_stream_lifecycle_plan()` が実行されます。

- 減らす場合:
  - active stream の `presence_avg` を見て、`stream_strength_target/spread` から作った削除 target に近い stream を inactive にします。
- 増やす場合:
  - inactive stream と active stream の両方を候補にします。
  - inactive が target に近ければ revive します。
  - active が target に近ければ、その stream を fork して新 id を作ります。
- 変わらない場合:
  - active ids を維持します。

この同じ plan が全 dimension manager に適用されるため、`vol` だけ stream 3 が増えて `area` は別 stream が増える、というズレを避けています。

### 8.4 global offset encoding

global manager は stream 数が増えても、stream index ごとに offset した値を polyphonic set として追加できます。これにより、1 本の global 時系列 manager で複数 stream 面を同時に扱えます。

## 9. AREA 生成

`area` は実音そのものではなく、4 semitone band の下端 `tmp_anchor = band_low` です。

例えば `AREA_BAND_SIZE = 4` なので、MIDI 60 は `60`, MIDI 62 も `60`, MIDI 64 は `64` の band です。

AREA は通常 dimension とは別ロジックで決まります。

### 9.1 直近 register center

各 stream の note manager から直近 `NOTE_REGISTER_MEMORY_STEPS = 16` step の anchor median を取り、`register_center` にします。

`note_register_freedom` が 1 未満なら、AREA 候補や最終 chord 候補をこの register center 付近に制限します。

### 9.2 AREA 候補

前回の `tmp_anchor` から `Config.AREA_MOVE_BINS` の delta を足し、範囲内の値だけを候補にします。範囲外へ clamp はせず、候補から除外します。

候補はさらに `area_band_low()` で 4 semitone band に量子化されます。

### 9.3 Stage 1: stream 別枝刈り

各 stream で AREA anchor 候補を仮追加し、`dist/quantity/complexity/usage` を合成して 0..1 score を作ります。

その score が `area_stream_targets[s]` に近い候補を残します。

- 1 stream: top 1
- 複数 stream: top 3

target が 0.5 以上なら同点時に大きい jump を好み、0.5 未満なら小さい jump を好みます。

### 9.4 Stage 2: stream 候補の cartesian product

枝刈り後の各 stream 候補を直積し、`area_candidates` を作ります。

### 9.5 Stage 3: global / stream / conc / register cost

各 AREA 候補について次を計算します。

- `g_cost`: global area score と `area_global_target` の差。
- `s_cost`: stream score と `area_stream_targets` の平均差。
- `conc_cost`: area anchor 間の近さまたは遠さ。
- `register_cost`: register 制限を越えた分の罰則。

合計が最小のものを `chosen_area` とし、global area manager と stream area manager に commit します。

`area` が固定 policy の場合は、評価結果ではなく `_fixed_area_band_low_for_stream()` の値を使います。

## 10. chord_range / density と実音候補

AREA が決まったあと、各 stream の実音候補を作ります。

1. `band_low = chosen_area[s]`
2. `band_high = band_low + AREA_BAND_SIZE - 1`
3. `chord_range` で上下に拡張する。
4. `density` から音数を決める。
5. その範囲の全組み合わせを作る。

式は次です。

```text
low  = band_low  - chord_range
high = band_high + chord_range
slot_count = high - low + 1
n_notes = round(density * slot_count)
n_notes = clamp(n_notes, 1, slot_count)
chords = combinations(low..high, n_notes)
```

`density = 0` でも最低 1 音は出ます。`chord_range = 0`, `density = 0` なら、基本的には AREA band 内から 1 音を選ぶ候補になります。

`note_register_freedom` が 1 未満なら、chord の anchor が register window 内にあるものへ絞ります。空になった場合は register center に最も近い chord を 1 つ残します。

## 11. dissonance はどこで使われるか

dissonance は最後の「実音の組み合わせ選択」だけで使われます。`area`, `vol`, `chord_range`, `density` などの complexity manager の候補選択には直接入りません。

実装上の流れは次です。

1. 初期文脈の実音を `DissonanceStmManager.commit!()` し、短期記憶を作る。
2. 各 future step で、AREA と `chord_range/density` から stream ごとの chord 候補を作る。
3. 全 stream chord 候補の直積を列挙する。
4. 各組み合わせを `DissonanceStmManager.evaluate()` で評価する。
5. その step の候補内 min/max で roughness を 0..1 正規化する。
6. `abs(norm - dissonance_target)` が最小の組み合わせを選ぶ。
7. 選んだ実音を `DissonanceStmManager.commit!()` して次 step の短期記憶に入れる。

`evaluate()` は現在の和音 roughness と memory interference を足します。

```text
d_total = dissonance_current(current_notes)
        + memory_interference(current_notes, past_memory)
```

`dissonance_current` は Sethares 1993 系 roughness model です。各 MIDI note から partial を `DISSONANCE_STM_N_PARTIALS = 8` 個作り、振幅を `DISSONANCE_STM_AMP_PROFILE = 0.88` で減衰させます。

memory interference は過去 event との merged roughness から、現在単体と過去単体の roughness を引いた差分です。時間差 `dt` に対して `exp(-dt / memory_span)` で減衰し、`memory_span = 1.5`, `memory_weight = 1.0` が使われます。

重要な注意点として、候補比較時の dissonance は pitch-class normalized note で評価されます。

```text
eval_note = 60 + (midi_note mod 12)
```

これにより、octave 距離そのものが roughness ranking を支配しないようになっています。一方、STM への commit は最後に実際の MIDI note で行われます。

## 12. note manager

実音 chord が決まったあと、note manager には chord 全体ではなく anchor が commit されます。

- global note manager:
  - その step の全 stream 全 note の median anchor を 1 つ commit します。
- stream note manager:
  - 各 stream の chord 内 median anchor を commit します。

note manager は次 step の `note_register_freedom` 制限、cluster timeline 出力、stream lifecycle fallback に使われます。

## 13. 出力

レスポンスは次の形です。

```json
{
  "timeSeries": [
    [
      [[60], 1.0, 0.5, 0.2, 0.8, 0.05, 0.2, 0.75, 0, 1.0, 0, 0.0, 0.5]
    ]
  ],
  "clusters": {
    "note": { "global": [], "streams": {} },
    "area": { "global": [], "streams": {} },
    "vol": { "global": [], "streams": {} }
  },
  "processingTime": 0.12,
  "streamStrengths": null,
  "timbreSeries": {
    "brightness": [],
    "harmonicity": [],
    "noise": [],
    "attack": [],
    "decay_sustain": [],
    "release": []
  },
  "bpm": 480,
  "stepDuration": 0.125,
  "initialContextBpm": [],
  "futureBpm": [],
  "bpmSeries": [],
  "stepDurations": []
}
```

`timeSeries` は初期文脈と生成結果を連結した全 step です。各 stream record はサーバ内部 strict 形式の 11 要素です。

`clusters` は各 dimension の cluster timeline です。

- `global`: global manager の timeline
- `streams`: stream id ごとの stream manager timeline

`timbreSeries` は画面、サーバ、SC と同じ音色キー名で返ります。

## 14. 実装上の注意点
- `dissonance_target` は候補集合内 min/max で step ごとに正規化されます。絶対 roughness 値の 0..1 ではありません。
- stream 数変更時は 1 つの lifecycle plan を全 dimension manager に適用するため、dimension 間で active stream id が揃います。
- `MAX_NOTE_CANDIDATES` は config にありますが、現在の note chord 直積列挙部分では明示的な cap として使われていません。`chord_range`, `density`, stream 数を大きくすると候補爆発に注意が必要です。
