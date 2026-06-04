# Time Series Subsequence Clustering (Julia / Genie + Vue)

時系列データの **部分列クラスタリング（subsequence clustering）** を用いて複雑度（complexity）を推定し、
ユーザが指定した複雑度遷移近い時系列（音楽生成用途を含む）を生成する Web アプリです。

- **Live Demo (Render)**: https://time-series-subsequence-clustering-web.onrender.com/
- Backend: **Julia + Genie**
- Frontend: **Vue 3 + Vite + Vuetify**
- Production: **Nginx (static + reverse proxy) + Genie**

---

## Production InfluxDB Cloud

Render ではローカル Docker の `influxdb:1.8` ではなく、InfluxDB Cloud の v2 API を使います。
Render の Environment Variables に次を設定してください。

- `INFLUX_URL`: InfluxDB Cloud の API endpoint URL。例: `https://us-east-1-1.aws.cloud2.influxdata.com`
- `INFLUX_TOKEN`: bucket の read 権限を持つ API token
- `INFLUX_BUCKET`: 作成した bucket 名
- `INFLUX_ORG_ID`: organization ID。Cloud では token に紐づくため必須ではありませんが、設定しておくと OSS v2 互換にも使えます
- `INFLUX_MEASUREMENT`: measurement 名。未設定時は `timeseries`
- `INFLUX_FIELD`: field 名。未設定時は `value`

ローカル開発では従来通り `INFLUX_TOKEN` / `INFLUX_BUCKET` を設定しなければ InfluxDB 1.8 の `/query` API を使います。
