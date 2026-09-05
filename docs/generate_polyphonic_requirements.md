# `generate_polyphonic()` 要件定義・実装監査

## 0. 文書情報

| 項目 | 内容 |
|---|---|
| 文書の目的 | `generate_polyphonic()` の現行実装を要件として再構成し、設計・実装上の不整合と是正要件を明確にする |
| 対象 | polyphonic生成API、stream lifecycle、dimension/AREA/note選択、dissonance STM、BPM、tie、レスポンス、UIからの呼び出し |
| 要件区分 | **AS-IS**: 現行コードが実際に行うこと、**TO-BE**: 問題を是正するために満たすべきこと |
| 調査方法 | コントローラ、manager群、設定、UI、既存Markdown、関連テストの静的調査およびDockerコンテナ内での動的検証 |
| 実行検証 | Julia 1.11.6コンテナで既存36 assertions、stable ID tie、stable-ID global encode/decode、CR/DEN共通schema、`stream_counts: [3,1,2]`のHTTP response/identity/tie経路を確認済み |
| 重大度集計 | Critical: 0、High: 2、Medium: 5、Low: 3 |

> **重要:** AS-ISは現行挙動の記録であり、正しい仕様として承認するものではない。監査で問題と判定した挙動は、TO-BEの `FIX-*` を優先する。

### 0.1 調査対象

- [`src/controllers/time_series_controller.jl`](../src/controllers/time_series_controller.jl)
- [`src/polyphonic/polyphonic_cluster_manager.jl`](../src/polyphonic/polyphonic_cluster_manager.jl)
- [`src/polyphonic/multi_stream_manager.jl`](../src/polyphonic/multi_stream_manager.jl)
- [`src/polyphonic/dissonance_stm_manager.jl`](../src/polyphonic/dissonance_stm_manager.jl)
- [`src/config.jl`](../src/config.jl)
- [`frontend/src/components/dialog/MusicGenerateDialog.vue`](../frontend/src/components/dialog/MusicGenerateDialog.vue)
- [`docs/generate_polyphonic.md`](generate_polyphonic.md)
- [`test/metric_calibration_and_chord_greedy.jl`](../test/metric_calibration_and_chord_greedy.jl)
- [`test/occurrence_interval_complexity.jl`](../test/occurrence_interval_complexity.jl)
- [`test/tie_rendering.jl`](../test/tie_rendering.jl)

関数名は調査時点の識別子を記載する。行番号は変更で陳腐化するため、根拠はファイル名と関数・変数名で示す。

---

## 1. システムの目的と非目的

### 1.1 目的

`generate_polyphonic()` は、過去のpolyphonic時系列を初期コンテキストとして受け取り、クラスタリング由来の複雑度、stream間の整合性、音響dimension、音程上の不協和度を逐次評価しながら、複数streamからなる将来時系列を生成する。

生成対象は次を含む。

1. 各streamの絶対MIDI note集合
2. volume
3. brightness、noise、harmonicity、attack、decay/sustain、release
4. chord range、density
5. tie指示
6. stepごとのBPMとduration
7. クラスタ状態およびtimbre系列

### 1.2 非目的・保証しないこと

- 全候補の組合せを探索するglobal optimumは保証しない。
- 音楽理論上の和声進行、調性、声部進行の最適性は保証しない。
- greedy探索の候補順序に対する不変性は保証しない。
- 生成後の音声合成・MIDIレンダリングそのものは本関数の責務外とする。
- clustered tie modeではtieもnote確定後の二値候補評価対象とし、後段rendererが確定値を接続として解釈する。legacy modeでは従来どおり決定論的に展開する。

---

## 2. 用語とデータモデル

### 2.1 用語

| 用語 | 定義 |
|---|---|
| step | 同時刻に存在する全streamのrecord集合 |
| stream | 時系列上の一つの声部・音響系列。lifecycle上はstable IDを持つことが意図されている |
| active stream | 現stepで生成対象となっているstream |
| pool index | `stream_pool` 配列内の物理位置。stable stream IDとは別概念 |
| dimension | note集合以外の生成属性。volume、CR、DEN、各timbre属性を含む |
| AREA | 4 semitone幅のregister bandの基準位置 |
| CR | chord range生成control。AREAからnote候補範囲を左右に拡張する量。初期値はnote集合から推定する |
| DEN | density生成control。note候補slotのうち何音を選ぶかを決める量。初期値はnote集合から推定する |
| STM | short-term memory。不協和度評価の履歴manager |
| calibrator | 生のmetricを0〜1付近のscoreへ写像する固定変換 |
| fixed dimension | 探索せず指定sourceの値を採用するdimension |

### 2.2 strict stream record

**DR-001:** 各stream recordは、次の順序を持つ**11要素**の配列として扱う。

| index（1-origin） | 名前 | 意味 |
|---:|---|---|
| 1 | `abs_notes` | 絶対MIDI noteの配列 |
| 2 | `vol` | volume |
| 3 | `brightness` | brightness |
| 4 | `noise` | noise |
| 5 | `harmonicity` | harmonicity |
| 6 | `attack` | attack |
| 7 | `decay_sustain` | decay/sustain |
| 8 | `release` | release |
| 9 | `chord_range` | CR |
| 10 | `density` | DEN |
| 11 | `tie` | 後段レンダリング用tie指示 |

**DR-002:** index、意味、要素数はcontroller、manager、UI、renderer間で一致していなければならない。ただし現行backendの入力検証は11要素、型、有限値、範囲を完全には強制していない。

**DR-003:** 一つのstepはstream recordの配列である。現行コードは空step、ragged record、step間で異なるstream数に対する完全な構造検証を行わない。

---

## 3. 外部インターフェース（AS-IS）

### 3.1 Endpoint

**FR-001:** 同期生成endpointは `POST /api/web/time_series/generate_polyphonic` とする。

**FR-002:** dispatch endpointは `POST /api/web/time_series/dispatch_generate_polyphonic` とし、生成処理をdispatchする入口を提供する。

**FR-003:** frontendは `MusicGenerateDialog.buildParamsPayload()` でpayloadを構築し、`handleGeneratePolyphonic()` から生成を要求する。

### 3.2 入力契約

**DR-004:** 初期コンテキストは、step → stream → 11要素recordの階層で受け取る。

**DR-005:** 将来の生成step数は `length(stream_counts)` で決定する。

**DR-006:** `stream_counts[t]` はstep `t` の目標active stream数としてlifecycleへ渡される。

**DR-007:** backendの基準MIDI範囲は36〜120である。AREAおよびCRで作るnote候補は、この有効範囲に制限される。

**DR-008:** frontendはstream数を1〜16に制限するUIを持つが、現行backendは同等の強制上限を持たない。したがって「最大16」はAPI契約ではなくUI制約に留まる。

**DR-009:** dimension候補は現行実装上、概ね次を使用する。

| dimension | 候補 |
|---|---|
| volume | `0`, `1` |
| chord range | 整数 `0:12` |
| density | `0:0.1:1` |
| brightness | `0:0.1:1` |
| noise | `0:0.1:1` |
| harmonicity | `0:0.1:1` |
| attack | `0:0.1:1` |
| decay/sustain | `0:0.1:1` |
| release | `0:0.1:1` |

**DR-010:** lifecycle merge閾値のdefaultは `0.02` である。

**DR-011:** clusteringに必要な最小windowは `POLYPHONIC_MIN_WINDOW_SIZE = 2` を基準とし、初期履歴が不足する場合は少なくとも `POLYPHONIC_MIN_WINDOW_SIZE + 1` stepになるまで補う。

**DR-012:** BPM未指定時のbackend defaultは `Config.POLYPHONIC_BPM = 240` である。一方、調査時点のfrontend defaultは480であり、同一のdefault契約になっていない。

### 3.3 出力契約

**FR-004:** 正常応答は少なくとも次のfieldを返す。

| field | 内容 |
|---|---|
| `timeSeries` | 初期コンテキストと生成結果を含むpolyphonic時系列 |
| `streamIds` | `timeSeries`と同じstep/slot構造で対応するstable stream IDを保持する |
| `clusters` | managerが保持するクラスタ情報（clustered tie modeでは`tie`を含む） |
| `processingTime` | 処理時間 |
| `streamStrengths` | 現行値は `nothing` |
| `timbreSeries` | timbre dimension系列 |
| `bpm` | 代表BPM |
| `stepDuration` | 代表step duration |
| `initialContextBpm` | 初期コンテキストBPM |
| `futureBpm` | 将来BPM |
| `bpmSeries` | step別BPM系列 |
| `stepDurations` | step別duration系列 |

**FR-005:** 応答は各stepのslotに対応するstable stream IDを `streamIds` として返す。初期コンテキストはslot由来のID、生成stepはlifecycleの `active_ids` を保持する。

### 3.4 canonical clustering parameterと互換性（TO-BE実装済み）

**FR-005A:** AREAは今回のcanonical化対象外とし、既存の `area_global`、`area_center`、`area_spread`、`area_conc` を維持する。

**FR-005B:** AREA以外のmanaged dimension（`vol`、`chord_range`、`density`、`brightness`、`noise`、`harmonicity`、`attack`、`decay_sustain`、`release`）は次のcanonical parameterを使用する。

| 意味 | canonical key | legacy alias |
|---|---|---|
| global complexity目標 | `{dim}_global_complexity_target` | `{dim}_global` |
| stream complexity目標中心 | `{dim}_stream_complexity_center` | `{dim}_center` |
| stream complexity目標の全体幅 | `{dim}_stream_complexity_span` | `{dim}_spread` |
| stream間concordance | `{dim}_concordance` | `{dim}_conc` |
| 候補値の中心 | `{dim}_value_target` | `{dim}_target` |
| 候補値中心からの半径 | `{dim}_value_radius` | `{dim}_target_spread` |

- `span` はstream群へ配置する目標の全体幅であり、`center ± span / 2` を意味する。
- `radius` は値候補filterの半径であり、`value_target ± value_radius` を意味する。
- backendはcanonical keyを優先し、欠落時だけlegacy aliasへfallbackする。
- frontendはcanonical keyを保存・送信し、旧params JSONのimportおよび可視化ではlegacy aliasを受理する。

**FR-005C:** volume探索候補は `Config.VOL_STEPS = [0, 1]` とし、厳密な二値候補だけを評価する。`vol_value_target/value_radius` はこの二候補をfilterする。

### 3.5 clustered three-level tie契約（TO-BE実装済み）

clustered tie modeは次の6 parameterのいずれかがrequestに存在すると有効になる。

| parameter | 範囲 | 意味 |
|---|---:|---|
| `tie_global_complexity_target` | 0..1 | eligible stream群のtie値平均系列に対するglobal complexity目標 |
| `tie_stream_complexity_center` | 0..1 | stable stream別3値tie系列のcomplexity目標中心 |
| `tie_stream_complexity_span` | 0..1 | stream complexity目標の全体幅（`center ± span / 2`） |
| `tie_concordance` | -1..1 | 正値は同時tie段階の一致、負値は3段階の分散を優先 |
| `tie_value_target` | 0, 0.5, 1 | tieの音響段階の中心。再発音／軽い再アタック付き継続／完全継続 |
| `tie_value_radius` | 0, 0.5, 1 | targetを中心に許可するtie候補の半径 |

- 候補は `Config.TIE_STEPS = [0, 0.5, 1]` で、note/chord確定後にgreedy評価する。
- 境界がeligibleとなるのは、同じstable IDが直前stepにも存在し、MIDI note集合が同一で、前後volumeが可聴であり、rendererがtie中に更新できない `vol`、`brightness`、`noise`、`harmonicity`、`attack`、`decay_sustain` が一致する場合だけである。`release` はrun末尾値へ更新できるため相違を許容する。
- ineligible境界の出力tieは0とし、tie managerへcommitしない。
- concordanceの不一致度は、eligible stream間のtie値の平均pairwise absolute distanceで正規化する。
- 新6 keyが一つもなく、旧 `tie_center/tie_spread` だけのrequestは、center/spread展開後に最も近い3段階へ量子化する。

### 3.6 stable stream ID render契約（TO-BE実装済み）

- frontendは生成responseの `streamIds` を `timeSeries` と同じslot対応で保持し、render APIへsnake_caseの `stream_ids` sidecarとして送る。
- frontendとrender endpointが無効・無音voiceを除外するときは、対応IDも同時に除外してslot対応を維持する。
- `build_score_events_scd(...; stream_ids=nothing)` はstable IDをoptional keywordで受け取る。省略時は既存互換としてstep内slot indexを使用する。
- SuperCollider event builderの `active_runs`、present判定、tie継続判定はstable `stream_id` をkeyとする。同じstable ID・同一note集合で、tie=0は再発音、0.5はrun継続と軽いattack transient、1は完全継続にする。
- lifecycleによるslot順変更、deactivate/revive、新規stream追加があっても、異なるstable IDのrunを誤接続してはならない。

### 3.7 stable stream ID global encodingとCR/DEN契約（TO-BE実装済み）

- global managerのstreamwise rowはrun-localで不変のstable ID→axis slot mapを使う。step内のactive配列位置をidentityとして使用しない。
- identity axis capacityは、初期stream数に`stream_counts`の正の増分を加えたrequest単位上界で初期化する。1 stepの最大要素数を表す`max_set_size`とは分離する。
- initial history、candidate simulation、commit、AREAは同じstable-ID encoderを使用する。row内でinactiveなIDは要素省略で表現する。
- CR/DENはper-stream生成controlとして扱う。初期controlは`abs_notes`から推定し、initial/futureとも他dimensionと同じstreamwise global schemaへ投入する。
- capacity外ID、重複ID、ID/value長不一致は別slotへclampせず明示エラーにする。

---

## 4. 生成処理フロー（AS-IS）

### 4.1 初期化

**FR-006:** controllerはpayload、BPM、初期コンテキストを内部表現へ正規化する。

**FR-007:** CRとDENはper-stream生成controlとする。初期コンテキストでは実際のnote集合からcontrol初期値を推定し、他dimensionと同じstable-ID streamwise global履歴を構築する。

**FR-008:** 初期履歴が短い場合、最後のstepを複製して `POLYPHONIC_MIN_WINDOW_SIZE + 1` 以上になるまで末尾paddingする。

**FR-009:** 各dimensionについてglobal managerとstream managerを構築し、note用managerおよびdissonance STMを構築する。

**FR-010:** calibratorはmanager構築・commit済みsnapshotを基に生成開始時に固定し、候補ごとには再学習しない。

### 4.2 step単位処理

**FR-011:** 各future stepでは、概ね次の順序で処理する。

1. stream lifecycleの更新
2. active streamのrecency/position情報更新
3. 通常dimensionのgreedy選択
4. AREAの2-stage greedy選択
5. AREA、CR、DENからnote poolと音数を決定
6. stream間およびstream内のnoteをsingle-addition greedyで選択
7. dimension manager、note manager、dissonance STMへ確定値をcommit
8. step結果をレスポンス用系列へ追加

**FR-012:** 通常dimensionの処理順は次のとおりであり、後続dimensionは先行dimensionの確定値に依存し得る。

1. `vol`
2. `chord_range`
3. `density`
4. `brightness`
5. `noise`
6. `harmonicity`
7. `attack`
8. `decay_sustain`
9. `release`

**FR-013:** dimensionごとに候補を一つずつsimulateし、costが最小の候補を選択する。全dimensionの直積探索は行わない。

**FR-014:** fixed dimensionは候補探索を省略し、指定sourceから値を取得する。`initial_context_last_step` sourceの現行実装は不変snapshotではなく、更新される結果系列の末尾を参照し得る。

### 4.3 stream lifecycle

**FR-015:** `stream_counts` に従いactive stream数を増減させ、deactivateされたstreamをpoolに保持し、条件によりreviveまたは新規作成する。

**FR-016:** streamの評価・commitは `active_stream_containers()` が返すactive stream集合を基準に行う箇所を持つ。

**FR-017:** recency、strength、register center等は、lifecycleの選択・候補評価に利用される。

### 4.4 AREA選択

**FR-018:** AREAは4 semitone幅のbandの下端 `band_low` として扱う。

**FR-019:** AREA候補は、現在位置からのmove bin、MIDI register制限、stream別候補評価、global評価の順で絞る。

**FR-020:** stream別に上位候補（状況によりtop 1またはtop 3）を残し、その集合からglobal greedyで各streamのAREAを決定する。

### 4.5 note poolと音数

**FR-021:** streamのnote候補範囲は次で決定する。

```text
low  = band_low  - chord_range
high = band_high + chord_range
```

ここでAREA band幅は4 semitoneであり、最終候補はMIDI有効範囲に制限される。

**FR-022:** note候補slot数を `slot_count` としたとき、選択音数は次で決定する。

```text
n_notes = clamp(round(density * slot_count), 1, slot_count)
```

したがってdensityが0でも、候補slotが存在する限り最低1音を生成する。

**FR-023:** noteは `select_notes_by_single_addition_greedy` により1音ずつ追加する。各追加時に候補noteのdissonanceとnote complexityを評価し、最小cost候補を採用する。

**FR-024:** stream間の組合せも全直積ではなく、stream順・note追加順に依存するgreedy探索とする。

### 4.6 commitと後処理

**FR-025:** step内の候補が確定した後、dimension manager、note manager、dissonance STMを更新する。

**FR-026:** 生成されたdimension値とnote集合からstrict stream recordを組み立て、`timeSeries` と `timbreSeries` へ追加する。

**FR-027:** tieはnote候補の探索とは分離し、note確定後に二値候補を評価する。確定tie値は生成後のrender処理でstable stream ID単位の接続として解釈される。legacy requestでは旧center/spreadの決定論的展開を維持する。

---

## 5. 評価・クラスタリング要件（AS-IS）

### 5.1 dimension cost

**SR-001:** 通常dimensionの基本costは、次の構成を持つ。

```text
abs(global_score - global_target)
+ abs(stream_score - stream_target)
+ concordance_cost
```

**SR-002:** multi-stream volume評価では `use_global_score = false` とし、global scoreを基本costへ加えない。

**SR-003:** targetとspreadはdimension別parameterから取得する。ただしscalar指定されたstrength parameterではtarget/spreadが十分反映されない経路がある。

### 5.2 calibrator

**SR-004:** 生metric `raw` は、固定した `center`、`scale`、metric方向 `direction` を使って次のscoreへ変換する。

```text
score = 0.5 + atan(direction * (raw - center) / scale) / pi
```

**SR-005:** distanceおよびcomplexityは値が大きい方向を正方向として扱い、quantityは逆方向として扱う。

**SR-006:** calibratorはcandidate simulationごとに変化させず、同一step内・生成run内で比較可能な尺度を維持する。

### 5.3 occurrence interval

**SR-007:** cluster評価にはdistance、complexity、quantityに加え、occurrence interval complexityを含める。最終評価軸はprediction、diversity、shape、occurrence、massの5軸とする。

**SR-008:** occurrence interval metricがreadyでない間は、利用可能なmetricで評価する。ready時は正規化後の総合scoreに概ね20%相当の寄与を持つ。

**SR-009:** candidate previewはmanager状態を恒久変更せず、採用候補のみcommitすることが設計意図である。

### 5.4 dissonance

**SR-010:** note候補のdissonanceは、同一stream内の既選択noteおよび他streamの選択noteとの関係を評価する。

**SR-011:** candidate評価ではpitch-class正規化値を利用する経路がある一方、STMの初期seedとcommitではabsolute MIDIを保存する経路がある。

### 5.5 greedy方針

**NFR-001:** dimension、AREA、noteは計算量を抑えるためgreedyに選択する。

**NFR-002:** greedyは候補順、stream順、dimension順に依存する。この順序依存は現時点では性能上の意図的trade-offであり、それ自体を不具合とはみなさない。

**NFR-003:** `Config.MAX_NOTE_CANDIDATES = 8000` は設定されているが、調査した生成経路では実効的な評価budgetとして強制されていない。

---

## 6. AS-IS受入シナリオ

以下は「現行挙動を再現できること」の確認項目であり、TO-BEの品質承認ではない。

| ID | シナリオ | 期待される現行挙動 |
|---|---|---|
| AC-ASIS-001 | 有効な初期履歴と `stream_counts` を送信 | `length(stream_counts)` 個のfuture stepを生成する |
| AC-ASIS-002 | 初期履歴が2 step以下 | 最終stepを複製してmanager構築に必要な履歴長へ補う |
| AC-ASIS-003 | densityを0に固定 | note poolが空でなければ最低1音を生成する |
| AC-ASIS-004 | volumeを生成 | 二値候補 `0`, `1` から選択し、multi-stream global scoreは使わない |
| AC-ASIS-005 | CRを生成 | 整数0〜12から選択する |
| AC-ASIS-006 | timbre/DENを生成 | 0.1刻みの0〜1候補から選択する |
| AC-ASIS-007 | future BPMを指定 | `bpmSeries` と `stepDurations` にstep別値を返す |
| AC-ASIS-008 | canonical tie parameterを指定 | eligible境界で0/1をcluster評価し、rendererがstable stream ID単位で接続する |
| AC-ASIS-009 | lifecycleでstream数を変更 | poolからdeactivate/revive/newを選択し、目標active数へ近づける |
| AC-ASIS-010 | 正常生成 | 3.3節のresponse fieldを返し、`streamIds` が `timeSeries` とstep/slot対応する。`streamStrengths` は `nothing` |

---

## 7. 実装監査結果

### 7.1 判定基準

| 重大度 | 基準 |
|---|---|
| Critical | 通常条件で全体停止、重大なデータ破壊、または安全性問題を直ちに生む |
| High | 正常に見える誤結果、stream identity破壊、広範囲な状態破損、容易な資源枯渇を生み得る |
| Medium | 特定条件で意味不一致、予測困難な出力、検証不足、保守性低下を生む |
| Low | 観測性、再現性、dead/no-op、限定的な一貫性の問題 |

### 7.2 指摘一覧

| ID | 重大度 | 確信度 | 問題 | 主な根拠 | 影響 | 推奨 | 受入条件 |
|---|---|---|---|---|---|---|---|
| AUD-005 | High | 高 | 例外をzero metric化し、commit失敗時に状態を二重更新し得る | `_safe_simulate_add_and_calculate_all_extended()`、`MultiStreamManager.build_stream_manager`、`safe_simulate_add_and_calculate`、`update_caches_permanently!` のcatch。`safe_add_data_point!()` のfallback `push!` | 壊れた候補を「cost 0」として優先、部分commit、`mgr.data`二重push、履歴とcacheの不整合を起こし得る | typed error、ログ、transactional simulate/commit、rollbackを導入する | fault injection時にzero scoreへ化けず、履歴長/cache/clusterが変更前へ戻る |
| AUD-006 | High | 高 | API側にstep、stream、note、候補評価総数の強制上限がない | `stream_counts` 長・値、total notes、evaluation budgetのbackend検証なし。`MAX_NOTE_CANDIDATES` 未使用。UI上限16は迂回可能 | direct APIでCPU・memoryを枯渇させ、サービス不能を起こせる | backend hard limit、request budget、早期拒否、timeout/cancellationを導入する | 上限超過requestが生成前に4xxとなり、設定budgetを超える候補評価を行わない |
| AUD-007 | Medium | 高 | `initial_context_last_step` が初期snapshotではなく可変系列末尾を参照する | fixed value source処理が更新される `results[end]` を参照。後処理も最終生成stepを基準にし得る | 「初期値固定」のはずがstepごとにdriftし、過去stepを最終値で上書きし得る | 正規化直後にimmutable initial snapshotを保存する | future生成中・後処理後も固定値が初期最終stepと完全一致する |
| AUD-008 | Medium | 高 | 入力構造、空配列、有限値、範囲の検証が不足する | `array_param()` が空vectorで `val[end]`。ragged/empty step許容。NaN/Inf・範囲検証不足。scalar strength target/spread無視 | BoundsError、NaN伝播、黙ったparameter無視、500応答を生む | schema validationとfield別errorをendpoint境界に置く | empty/ragged/NaN/Inf/範囲外/不正長を決定的な4xxで拒否する |
| AUD-010 | Medium | 中〜高 | dissonance STMでpitch classとabsolute MIDI表現が混在する | candidateはpitch-class normalized、STM seed/commitはabsolute MIDI | 同音名のoctave違いと絶対音程がmetric/calibrator内で一貫しない | STM境界でcanonical representationを一つに統一する | seed、preview、commitが同じ表現を使い、octave方針がテストで明示される |
| AUD-011 | Medium | 中〜高 | volume固定時のlifecycle fallbackがnote managerを使う | volume managerが利用できない経路でnote manager由来の値をstrengthとして使用 | volume strengthのはずがpitch正規化値になり、deactivate/revive判断が変質する | strength sourceをdimension型付きで定義し、volume不在時の明示fallbackを設ける | volume固定時もstrengthが契約した0〜1 volume指標から算出される |
| AUD-012 | Medium | 高 | backendとfrontendのBPM defaultが不一致 | `Config.POLYPHONIC_BPM = 240`、`MusicGenerateDialog.vue` default 480 | 呼出経路により同じ未指定操作のテンポとdurationが変わる | 単一のdefault sourceまたはAPI明示必須化 | UI経由・direct APIで未指定時のBPMが一致する |
| AUD-013 | Low | 高 | request/step全体のatomic rollbackがない | managerごとのsafe処理はあるが、複数manager/STM commitを束ねるtransactionがない | step途中の失敗でmanager間の履歴長がずれる | step単位commit transactionまたはcopy-on-writeを導入する | 任意のcommit箇所で失敗させても全managerがstep開始状態へ戻る |
| AUD-014 | Low | 高 | no-op/dead parameterと観測不能な出力が残る | `streamStrengths => nothing`、`debug_score*`、`use_recent_position_weight`、`debug_poly`、`strength_params`、`_apply_fixed_dimension_values!`、未使用 `max_streams` | 利用者が有効機能と誤認し、デバッグ不能・保守コスト増になる | 削除、実装、deprecated明記のいずれかを選ぶ | 公開parameter/outputが動作テストを持ち、未実装fieldはAPI契約から除外または明記される |
| AUD-015 | Low | 中 | byte-for-byte再現性が保証されない | Dict走査、serialization順、同点候補の順序規則が契約化されていない | 同一入力でも環境差で順序やserialized bytesが変わり得る | stable sort、tie-break、seed、canonical serializationを定義する | 同一version・seed・inputで意味上同一かつ規定範囲の再現性を満たす |

### 7.4 総評

`AUD-005` と `AUD-006` は運用上の障害リスクが高い。例外をzero scoreへ変換する実装はfail-safeではなく、失敗候補を最良候補として選ぶ可能性がある。またUI制限はAPI防御にならない。

---

## 8. 意図的trade-offと不具合を分ける

次は現時点で意図的な設計選択と判断し、単独では監査不具合に数えない。

| 項目 | 判断 | 条件・注意 |
|---|---|---|
| pure greedy探索 | 維持可能 | global optimumを保証しないこと、順序依存、budgetを明記する |
| 固定calibrator | 維持可能 | candidate間比較の尺度を安定させる意図がある |
| 短履歴の末尾padding | 維持可能 | padding済み履歴であることを観測可能にするのが望ましい |
| density=0でも最低1音 | 製品要件次第で維持可能 | 「無音」をdensity 0に期待するUIとは意味が衝突し得る |
| tieをnote探索と分離し、接続はrenderで解釈 | 維持可能 | clustered modeはnote確定後に二値評価し、legacy modeは決定論的値を使う。いずれもstable stream IDで接続する |
| fixed AREAもmanagerへcommit | 維持可能 | 固定値も時系列状態の一部として学習させる方針なら整合する |

一方、例外のzero score化は性能trade-offではなく、是正対象である。

---

## 9. 是正必須要件（TO-BE）

### 9.1 P0: 正しさと状態保全

**FIX-004: simulation/commitの例外安全性**

- simulation失敗を有効なzero metricとして返してはならない。
- 失敗候補は選択対象外とし、原因、dimension、step、stream IDを構造化ログへ記録しなければならない。
- candidate previewは必ず状態をrollbackし、commitはstep単位でatomicでなければならない。
- fallback `push!` は先行処理が変更済みか判定せず実行してはならない。
- **受入条件:** managerの各更新点へfault injectionしても、失敗候補が採用されず、全履歴・cache・cluster・STMが変更前状態を維持する。

### 9.2 P1: API防御と意味の一貫性

**FIX-005: server-side validationとresource budget**

- 11要素record、配列階層、非空条件、数値型、有限値、許容範囲をendpoint境界で検証しなければならない。
- 最大future step数、step当たりstream数、note数、候補数、総評価回数、処理時間をbackend設定で制限しなければならない。
- `MAX_NOTE_CANDIDATES` を実効budgetとして使用するか、実態に合う設定へ置換しなければならない。
- 不正requestとbudget超過は生成開始前または安全な中断点で4xxとして返さなければならない。
- **受入条件:** empty、ragged、11要素未満/超過、NaN、Inf、範囲外、過大step/stream/note requestが500や部分commitを起こさない。

**FIX-006: fixed sourceのsnapshot semantics**

- `initial_context_last_step` は正規化完了時点の初期コンテキスト最終stepをimmutable snapshotとして参照しなければならない。
- future `results[end]` や後処理後の末尾を参照してはならない。
- **受入条件:** 複数future step生成後も固定dimension全stepが初期snapshot値と一致する。

**FIX-007: dissonance表現の統一**

- candidate、STM seed、preview、commit、calibratorはabsolute MIDIまたはpitch classのどちらか一つのcanonical表現を使わなければならない。
- octave差を無視するか評価するかを要件として明記しなければならない。
- **受入条件:** 同じchordをseed・candidate・commitの各経路へ与えたmetricが同一定義で計算される。

**FIX-008: lifecycle strengthの型付きsource**

- lifecycle strengthはdimension名と値の意味を保持しなければならない。
- volume固定時にnote/pitch値をvolume strengthとして代用してはならない。
- **受入条件:** volume固定・生成の両modeでstrengthが同じ0〜1意味尺度を持ち、lifecycle判断を説明できる。

**FIX-009: BPM defaultの単一化**

- backendとfrontendは同じBPM defaultを共有するか、APIでBPMを必須にしなければならない。
- **受入条件:** UI経由とdirect APIで未指定相当の操作が同じ `bpmSeries` / `stepDurations` を返す。

### 9.3 P2: 観測性と再現性

**FIX-010: responseとdebug情報の契約化**

- `streamStrengths` を実装して返すか、responseから削除しなければならない。
- step別stable stream ID、padding有無、採用候補score、fallback/失敗情報をdebug modeで観測可能にすべきである。
- no-op parameterは削除またはdeprecated化しなければならない。
- **受入条件:** 公開field/parameterごとに利用箇所とcontract testが存在する。

**FIX-011: 再現性規則**

- 同点候補のtie-break、Dict由来集合のsort、乱数seed、serialization順を定義しなければならない。
- **受入条件:** 同一version、設定、seed、入力でstable stream ID付きの意味上同一な出力を再現する。

---

## 10. テスト要求とtraceability

### 10.1 既存テストで確認されている範囲

| 対象 | 既存テスト | 主な確認内容 |
|---|---|---|
| metric calibration / chord greedy | `test/metric_calibration_and_chord_greedy.jl` | 固定calibrator、simulation rollback、single-addition greedyの計算量特性 |
| occurrence interval | `test/occurrence_interval_complexity.jl` | readiness、preview rollback、metric追加 |
| tie rendering | `test/tie_rendering.jl` | tie target分布、render時の接続 |

### 10.2 未検証で追加が必要な範囲

| テストID | 対応要件・指摘 | 必須シナリオ |
|---|---|---|
| T-004 | FIX-004 / AUD-005,013 | preview/各commit箇所のfault injectionと完全rollback |
| T-005 | FIX-005 / AUD-006,008 | empty/ragged/NaN/Inf/過大request、budget上限、4xx |
| T-006 | FIX-006 / AUD-007 | fixed sourceが複数stepでdriftしない |
| T-007 | FIX-007 / AUD-010 | seed/preview/commitでPC・absolute表現を統一 |
| T-008 | FIX-008 / AUD-011 | volume固定時のlifecycle strength |
| T-009 | FIX-009 / AUD-012 | UI/direct APIのBPM default一致 |
| T-010 | FR-018〜024 | AREA境界、CR拡張、DEN=0/1、MIDI 36/120、greedy候補 |
| T-011 | FR-001〜005 | 同期endpoint、dispatch、response schema、step別ID |
| T-012 | FIX-011 / AUD-015 | 同点候補、順序、seed、serializationの再現性 |
| T-013 | SR-001〜009 | metric方向、target/spread、occurrence寄与、固定calibrator |
| T-014 | NFR-001〜003 / FIX-005 | 候補数と処理時間のbudget/performance回帰 |

### 10.3 静的traceability

| 要件群 | 主な実装箇所 |
|---|---|
| API、正規化、生成loop、AREA、note、response | `src/controllers/time_series_controller.jl` |
| cluster metric、calibrator、simulation/commit | `src/polyphonic/polyphonic_cluster_manager.jl` |
| stream pool、active container、lifecycle、global/stream評価 | `src/polyphonic/multi_stream_manager.jl` |
| dissonance STM | `src/polyphonic/dissonance_stm_manager.jl` |
| default・閾値・候補制約 | `src/config.jl` |
| UI payload、UI上限、BPM default | `frontend/src/components/dialog/MusicGenerateDialog.vue` |
| 既存の実装解説 | `docs/generate_polyphonic.md` |

---

## 11. 未決事項

実装修正前に、少なくとも次を製品要件として決める必要がある。

1. density 0は「最低1音」か「無音」か。
3. dissonanceはoctaveを区別するか、pitch classだけを見るか。
5. deactivateしたstreamが復帰した際、tieと音響dimensionの継続性を維持するか。
6. backendの最大future step数、最大stream数、最大note数、総候補評価budgetをいくつにするか。
7. BPM defaultを240、480、その他のどれに統一するか。
8. fixed dimensionのsourceを初期最終step以外にも許可するか。その場合のsnapshot時点はいつか。
9. global scoreを使わないvolume評価を維持するか。
10. 再現性を意味上の同一性まで求めるか、byte-for-byteまで求めるか。

---

## 12. 推奨実施順

4. **FIX-004**: simulation/commitの例外安全性とatomicityを確保する。
5. **FIX-005**: endpoint validationとresource budgetを導入する。
6. FIX-006〜009でfixed source、dissonance、strength、BPMの意味を統一する。
7. FIX-010〜011で観測性と再現性を整える。

この順序は、音楽的なscore調整より先に、失敗時に状態が壊れないこととAPI入力が安全な範囲に収まることを保証するためである。
