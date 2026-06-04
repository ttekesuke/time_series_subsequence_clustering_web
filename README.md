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
Render の Environment Variables に次を設定してください。

- `INFLUX_URL`: InfluxDB Cloud の API endpoint URL。例: `https://us-east-1-1.aws.cloud2.influxdata.com`
- `INFLUX_TOKEN`: bucket の read 権限を持つ API token
- `INFLUX_BUCKET`: 作成した bucket 名
- `INFLUX_ORG_ID`: organization ID。Cloud では token に紐づくため必須ではありませんが、設定しておくと OSS v2 互換にも使えます
- `INFLUX_MEASUREMENT`: measurement 名。未設定時は `timeseries`
- `INFLUX_FIELD`: field 名。未設定時は `value`
- `INFLUX_RP`: retention policy 名。必要な場合のみ設定
- `SEED_ON_START`: `true` にするとコンテナ起動時に `scripts/seed_influx.jl` を実行。初回 seed 後は外してください

ローカル開発では従来通り `INFLUX_TOKEN` / `INFLUX_BUCKET` を設定しなければ InfluxDB 1.8 の `/query` API を使います。
InfluxDB Cloud Serverless では Flux ではなく v1 互換の InfluxQL `/query` API を使います。

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
