# MusicXML の解析と DB seed の共通イベント

`src/music/musicxml_events.jl` は MusicXML の part / measure / divisions / backup / forward / note を一度走査し、元の part・staff・voice、音高、開始・終了時刻を四分音符単位の有理数で返す。MusicAnalyse は同じ走査の direction callback から強弱・テンポ等を取得する。seed は元の voice で系列を分け、その後に同時刻の最高音選択とフレーズ分割を行う。解析側の声部 lane 化と厳密グリッドは独立したままにする。

seed の整数 tick は楽譜に現れる全 `<divisions>` の最小公倍数を四分音符あたりの単位として使う。divisions が一定の譜面では従来と同じ tick、途中や part ごとに変わる譜面では修正された時刻になる。以前は生の duration を足していたため、変更後の note が不正な時刻に置かれていた。音高の alter は MusicAnalyse と同じ丸め・MIDI 範囲に揃えた。seed はこれまでと同じ最高音選択を行うので、元の音符数と書き込み点数は異なる場合がある。

`test/musicxml_seed_contract.jl` は二つの part、chord、rest、backup / forward、staff / voice、alter、途中の divisions 変更を含む固定譜面で両経路の元イベントと解析テンポを比較する。`scripts/seed_influx.jl` の読み込み時には DB に接続しないため、テストでは実際の書き込みを行わない。

`julia --project=. scripts/benchmark_musicxml_seed.jl` は 3 part・12小節・144音の有界 fixture で、二つのパーサの時間と割当量、従来の measure_at における毎回の配列生成と事前索引の比較を表示する。パーサ自体の旧版との性能差はこの測定だけでは確定できない。長い MusicAnalyse クラスタリングは実行しない。
