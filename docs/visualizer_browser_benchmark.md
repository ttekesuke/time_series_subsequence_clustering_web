# StreamsRoll / ClustersRoll browser benchmark

Issue #33 の完了条件にある実ブラウザの frame time / heap を、現在表示している実データで再現測定するための補助スクリプトです。

## 実行方法

1. frontend を通常どおり開き、MusicAnalyse 等で測りたいデータを表示する。
2. Chrome / Edge の DevTools Console で次を実行する。

```js
const { runVisualizerBenchmark } = await import('/benchmark-visualizers.js')
const report = await runVisualizerBenchmark({ label: '2352-step', iterations: 120 })
```

20,000 step のデータでも同じ条件で実行します。

```js
const report20k = await runVisualizerBenchmark({ label: '20000-step', iterations: 120 })
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

## 比較条件

2352 step と20,000 stepで、ブラウザ、viewport、ズーム、表示stream数、roll高さを揃えてください。可能なら同じマシンで3回以上測り、p95と最大値だけでなくmeanも比較します。

このベンチは実データを生成しません。対象の長さの解析結果を画面へ表示してから実行します。CIでは長いMusicAnalyseを起動しないため、実ブラウザ計測は手動です。
