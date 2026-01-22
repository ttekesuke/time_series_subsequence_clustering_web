#!/usr/bin/env bash
set -euo pipefail

# Render が外向きに使うポート（Nginx が listen）
: "${PORT:=10000}"

# コンテナ内部で Genie が listen するポート（固定）
: "${GENIE_PORT:=9111}"
: "${GENIE_HOST:=127.0.0.1}"

# Genie / Julia 環境
: "${GENIE_ENV:=prod}"
: "${JULIA_DEPOT_PATH:=/app/.julia}"

# envsubst は export された環境変数だけ置換するので必ず export
export PORT GENIE_PORT GENIE_HOST GENIE_ENV JULIA_DEPOT_PATH

echo "[entrypoint] PORT=${PORT} (nginx listen)"
echo "[entrypoint] GENIE_HOST=${GENIE_HOST} GENIE_PORT=${GENIE_PORT} (genie listen)"

# Nginx conf を生成（PORT と GENIE_PORT を埋め込む）
envsubst '${PORT} ${GENIE_PORT}' \
  < /etc/nginx/templates/app.conf.template \
  > /etc/nginx/conf.d/default.conf

# conf 検証（失敗したらコンテナを落とす）
nginx -t

# ---- Genie 起動（バックグラウンド）----
# Genie が PORT 環境変数を参照する挙動があるので、ここで PORT=9111 を明示する
if id scuser >/dev/null 2>&1; then
  su -s /bin/bash -c "PORT=${GENIE_PORT} HOST=${GENIE_HOST} JULIA_DEPOT_PATH=${JULIA_DEPOT_PATH} GENIE_ENV=${GENIE_ENV} /app/bin/server" scuser &
else
  PORT="${GENIE_PORT}" HOST="${GENIE_HOST}" JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH}" GENIE_ENV="${GENIE_ENV}" /app/bin/server &
fi

GENIE_PID=$!

# Genie が 127.0.0.1:9111 を listen するまで待つ（最大30秒）
for i in $(seq 1 60); do
  if (echo > /dev/tcp/127.0.0.1/${GENIE_PORT}) >/dev/null 2>&1; then
    echo "[entrypoint] Genie is up on 127.0.0.1:${GENIE_PORT}"
    break
  fi

  # 途中で Genie が落ちたら即終了（502を出し続けない）
  if ! kill -0 "$GENIE_PID" >/dev/null 2>&1; then
    echo "[entrypoint] Genie exited unexpectedly"
    wait "$GENIE_PID" || true
    exit 1
  fi

  sleep 0.5
done

# 最終確認：ポートが開いていなければ失敗
if ! (echo > /dev/tcp/127.0.0.1/${GENIE_PORT}) >/dev/null 2>&1; then
  echo "[entrypoint] Genie did not open port ${GENIE_PORT}"
  kill "$GENIE_PID" || true
  exit 1
fi

# ---- Nginx 起動（フォアグラウンド）----
echo "[entrypoint] Starting nginx..."
exec nginx -g 'daemon off;'
