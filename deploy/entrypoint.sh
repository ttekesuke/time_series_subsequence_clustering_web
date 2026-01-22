#!/usr/bin/env bash
set -euo pipefail

# Render が外向きに使うポート（Nginx が listen）
: "${PORT:=10000}"

# コンテナ内部で Genie が listen するポート（固定）
: "${GENIE_PORT:=9111}"
: "${GENIE_HOST:=127.0.0.1}"

export GENIE_ENV="${GENIE_ENV:-prod}"
export JULIA_DEPOT_PATH="/app/.julia"

# Nginx 設定を生成（外向き PORT と 内向き GENIE_PORT を埋め込む）
envsubst '${PORT} ${GENIE_PORT}' \
  < /etc/nginx/templates/app.conf.template \
  > /etc/nginx/conf.d/default.conf

# Nginx 設定の検証（失敗したら落ちるので安全）
nginx -t

# ---- Genie 起動（バックグラウンド）----
# 重要: Genie 側が PORT を参照する挙動があるので、PORT=9111 を明示して固定する
if idHook id scuser >/dev/null 2>&1; then
  su -s /bin/bash -c "PORT=${GENIE_PORT} HOST=${GENIE_HOST} JULIA_DEPOT_PATH=${JULIA_DEPOT_PATH} /app/bin/server" scuser &
else
  PORT="${GENIE_PORT}" HOST="${GENIE_HOST}" JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH}" /app/bin/server &
fi

GENIE_PID=$!

# Genie が起動して 9111 を listen するまで待つ（最大30秒）
for i in $(seq 1 60); do
  if (echo > /dev/tcp/127.0.0.1/${GENIE_PORT}) >/dev/null 2>&1; then
    break
  fi

  # 途中で落ちたら即終了（502を出し続けない）
  if ! kill -0 "$GENIE_PID" >/dev/null 2>&1; then
    echo "Genie exited unexpectedly"
    wait "$GENIE_PID" || true
    exit 1
  fi

  sleep 0.5
done

# 最終確認
if ! (echo > /dev/tcp/127.0.0.1/${GENIE_PORT}) >/dev/null 2>&1; then
  echo "Genie did not open port ${GENIE_PORT}"
  kill "$GENIE_PID" || true
  exit 1
fi

# ---- Nginx 起動（フォアグラウンド）----
exec nginx -g 'daemon off;'
