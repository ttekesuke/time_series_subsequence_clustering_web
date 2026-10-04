# StreamsRoll / ClustersRoll browser benchmark

Issue #33 の完了条件にある実ブラウザの frame time / heap を再現測定するための補助スクリプトです。

## 合成fixtureで測る

1. frontend を Chrome / Edge で開くとき、URL に `?visualizerBenchmark=1` を付ける。
2. MusicAnalyse 画面を開く。
3. DevTools Console で2352-step fixtureをロードする。

```js
await loadMusicAnalyseBenchmarkFixture(2352, 6, 'Complexity')
const { runVisualizerBenchmark } = await import('/benchmark-visualizers.js')
const report2352 = await runVisualizerBenchmark({
  label: '2352-step-complexity',
  iterations: 120,
})
```

Cluster表示も同じfixtureで測れます。

```js
await loadMusicAnalyseBenchmarkFixture(2352, 6, 'Cluster')
const report2352Cluster = await runVisualizerBenchmark({
  label: '2352-step-cluster',
  iterations: 120,
})
```

20,000 step も解析待ちなしで同条件にできます。

```js
await loadMusicAnalyseBenchmarkFixture(20000, 6, 'Complexity')
const report20k = await runVisualizerBenchmark({
  label: '20000-step-complexity',
  iterations: 120,
})
```

```js
await loadMusicAnalyseBenchmarkFixture(20000, 6, 'Cluster')
const report20kCluster = await runVisualizerBenchmark({
  label: '20000-step-cluster',
  iterations: 120,
})
```

fixture loaderは `visualizerBenchmark=1` のときだけ `window` に公開されます。通常利用時にはグローバル関数を追加しません。

## GitHub Actionsで自動計測する

Actions の **Visualizer Manual Browser Benchmark** を `workflow_dispatch` で実行すると、同じ headless Chromium / viewport で次の4条件を連続測定します。

- 2352 step / Complexity
- 2352 step / Cluster
- 20,000 step / Complexity
- 20,000 step / Cluster

既定は6 stream、各roll 120 frameです。結果は `visualizer_browser_benchmark=...` の1行JSONとして Step Summary と artifact に保存されます。共有runnerの性能揺らぎがあるため、性能比較では同じcommitを複数回実行して中央値も確認してください。

## 実データで測る

MusicAnalyseで実際の解析結果を表示した後はfixture loaderを使わず、そのまま計測できます。

```js
const { runVisualizerBenchmark } = await import('/benchmark-visualizers.js')
const report = await runVisualizerBenchmark({ label: 'real-score', iterations: 120 })
```

Console には JavaScript object と1行JSONの両方が出ます。Issueへ結果を貼る場合は1行JSONを保存してください。

## 測るもの

表示中の各 `StreamsRoll` / `ClustersRoll` について次を記録します。

- viewport / scroll領域のサイズ
- programmatic scroll 中の requestAnimationFrame 間隔
  - mean / p50 / p95 / max
  - 16.7ms超・33.3ms超のframe数
- canvasへの mousemove 中の同じframe指標
- 実行前後の JS heap
  - `performance.memory` が使えるChromium系ブラウザのみ
- user agent / viewport / devicePixelRatio

## fixtureの内容

合成fixtureは、長系列表示の描画・スクロール・hit-testを再現するために以下を生成します。

- 指定step数
- 既定6 stream（1〜32で変更可能）
- piano-roll pitch / velocity
- note / area / vol のcomplexity axes
- 各stream/globalのcompressed cluster spans
- stream_count series

MusicAnalyseの計算性能を測るfixtureではありません。可視化コンポーネントだけを一定条件で比較するためのデータです。

## 比較条件

2352 step と20,000 stepで、ブラウザ、viewport、ズーム、表示stream数、roll高さを揃えてください。可能なら同じマシンで3回以上測り、p95と最大値だけでなくmeanも比較します。

実譜の表示確認と合成fixtureの性能測定は分けて扱います。クリック・hover・ハイライトの最終確認は実譜またはfixtureのCluster表示でも行ってください。
