# Time Series Subsequence Clustering (Julia / Genie + Vue)

時系列データの **部分列クラスタリング（subsequence clustering）** を用いて複雑度（complexity）を推定し、
ユーザが指定した複雑度遷移近い時系列（音楽生成用途を含む）を生成する Web アプリです。

- **Live Demo (Render)**: https://time-series-subsequence-clustering-web.onrender.com/
- Backend: **Julia + Genie**
- Frontend: **Vue 3 + Vite + Vuetify**
- Production: **Nginx (static + reverse proxy) + Genie**

---

## Production InfluxDB Cloud

Render ではローカル Docker の `influxdb:1.8` ではなく、InfluxDB Cloud Serverless を使います。
ローカルと本番で InfluxQL の見え方をそろえるため、v1 database 名、bucket 名、measurement 名はすべて `timeseries` にそろえます。

Render の Environment Variables に次を設定してください。

- `INFLUX_URL`: InfluxDB Cloud の API endpoint URL。例: `https://us-east-1-1.aws.cloud2.influxdata.com`
- `INFLUX_TOKEN`: bucket の read 権限を持つ API token
- `INFLUX_BUCKET`: `timeseries`
- `INFLUX_DB`: `timeseries`
- `INFLUX_ORG_ID`: organization ID
- `INFLUX_BUCKET_ID`: bucket ID。設定しておくと bucket lookup を省略できます
- `INFLUX_MEASUREMENT`: `timeseries`
- `INFLUX_FIELD`: `value`
- `INFLUX_RP`: `autogen`
- `INFLUX_AUTO_CREATE_DBRP`: 通常は未設定または `false`
- `ENSURE_INFLUX_DBRP_ON_START`: `true` にすると起動時に `scripts/ensure_influx_dbrp.jl` を実行。成功後は外してください
- `SEED_ON_START`: `true` にするとコンテナ起動時に `scripts/seed_influx.jl` を実行。初回 seed 後は外してください
- `STARTUP_WARMUP_ENABLED`: 起動後 JIT warmup を行うか。未設定時は `true`
- `STARTUP_WARMUP_DELAY_SECONDS`: warmup 開始までの待機秒数。未設定時は `3`
- `STARTUP_WARMUP_READY_TIMEOUT_SECONDS`: `/api/health` が返るまで待つ最大秒数。未設定時は `180`
- `STARTUP_WARMUP_CONFIG`: warmup payload 設定。未設定時は `config/warmup_actions.json`

ローカル開発では従来通り `INFLUX_TOKEN` / `INFLUX_BUCKET` を設定しなければ InfluxDB 1.8 の `/query` API を使います。
InfluxDB Cloud Serverless では Flux ではなく v1 互換の InfluxQL `/query` API を使います。

Cloud Serverless で v1 互換 `/query?db=timeseries&rp=autogen` を使うには、事前に DBRP mapping が必要です。
これは `db=timeseries, rp=autogen` を bucket `timeseries` に対応させる一度きりの設定です。
管理権限を持つ token を使える環境で次を実行してください。

```bash
julia --project=. scripts/ensure_influx_dbrp.jl
```

成功後、アプリ本体の token は bucket の read/write に必要な権限へ絞れます。
アプリ起動中に DBRP mapping を自動作成したい場合だけ、強い権限を持つ token と `INFLUX_AUTO_CREATE_DBRP=true` を設定してください。
Render Shell が使えない場合は、管理権限を持つ token を一時的に設定し、`ENSURE_INFLUX_DBRP_ON_START=true` で一度だけデプロイしてください。
ログに `Influx DBRP mapping ensured` が出たら、`ENSURE_INFLUX_DBRP_ON_START` を削除し、token も通常の read/write 用に戻してください。

Render Shell が使えない場合は、初回だけ `SEED_ON_START=true` を設定してデプロイすると起動時に seed できます。
成功後は restart のたびに追加 seed されないよう、`SEED_ON_START` を削除してください。

Data Explorer の SQL query で seed データを確認する例:

```sql
SHOW TABLES
```

`timeseries` が出ていれば seed データの measurement が存在します。中身を見る例:

```sql
SELECT *
FROM "timeseries"
LIMIT 20
```

直近24時間の series 数を確認する例:

```sql
SELECT series_id, COUNT(*) AS count
FROM "timeseries"
WHERE time >= now() - INTERVAL '24 hours'
GROUP BY series_id
LIMIT 20
```
