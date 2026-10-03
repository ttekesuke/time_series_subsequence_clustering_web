# MusicAnalyse の quantity / complexity 差分集計

確定追加で変更された cluster ID の cache 値だけを更新し、旧値との差を window ごとの合計と全体の合計に反映する。MusicAnalyse が渡す集計状態は manager の外にあるため、生成の候補評価・rollback 経路には影響しない。距離計算とクラスタの代表系列の更新も従来どおり行う。

初回は全 cache の値を一度集計する。新しい window が生じたときは既存 cache を初期値として取り込み、単独出現から複数出現への遷移と代表変更のどちらも `new - old` で更新する。浮動小数の加算順差を制限するため、256回の確定追加ごとに全 cache から再基準化する。各 step の元データや window を省略しない。

`test/observed_quantity_totals.jl` は旧全件集計経路と毎 step の raw distance / quantity / complexity、表示軸、window ごとの cache 合計、最終圧縮クラスタを比較する。単一 stream の繰り返しと複数 stream の値を含み、再基準化も実行する。許容誤差は `1e-8`。`scripts/benchmark_observed_quantity_totals.jl` は32/64 step の有界 fixture で集計単体と確定追加全体の時間・割当量を両経路で記録する。長い入力のテストは行わない。
