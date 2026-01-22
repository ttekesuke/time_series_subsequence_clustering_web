#!/usr/bin/env bash
set -euo pipefail

# Render が外向きに使うポート（Nginx が listen）
: "${PORT:=10000}"

# コンテナ内部で Genie が listen するポート（固定）
: "${GENIE_PORT:=9111}"
: "${GENIE_HOST:=127.0.0.1}"

# Genie / Julia
: "${GENIE_ENV:=prod}"
: "${JULIA_DEPOT_PATH:=/app/.julia}"

# envsubst は export された環境変数だけ置換するので必ず export
export PORT GENIE_PORT GENIE_HOST GENIE_ENV JULIA_DEPOT_PATH

echo "[entrypoint] PORT=${PORT} (nginx listen)"
echo "[entrypoint] GENIE_HOST=${GENIE_HOST} GENIE_PORT=${GENIE_PORT} (genie listen)"

# Nginx 設定生成（外向き PORT / 内向き GENIE_PORT を埋め込む）
envsubst '${PORT} ${GENIE_PORT}' \
  < /etc/nginx/templates/app.conf.template \
  > /etc/nginx/conf.d/default.conf

# Nginx conf 検証
nginx -t

# ---- Genie 起動（バックグラウンド）----
# Genie は PORT 環境変数を見るので、ここで PORT=9111 を明示して固定
if id scuser >/dev/null 2>&1; then
  su -s /bin/bash -c "PORT=${GENIE_PORT} HOST=${GENIE_HOST} GENIE_ENV=${GENIE_ENV} JULIA_DEPOT_PATH=${JULIA_DEPOT_PATH} /app/bin/server" scuser &
else
  PORT="${GENIE_PORT}" HOST="${GENIE_HOST}" GENIE_ENV="${GENIE_ENV}" JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH}" /app/bin/server &
fi
GENIE_PID=$!

# ---- Nginx 起動（フォアグラウンドじゃなくバックグラウンド）----
# Render に「ポートが開いた」と認識させるため、Nginx はすぐ起動する
nginx -g 'daemon off;' &
NGINX_PID=$!

# ---- Genie の起動をログ出ししながら待つ（失敗しても即終了はしない）----
(
  for i in $(seq 1 360); do   # 最大180秒待つ（0.5秒 × 360）
    if (echo > /dev/tcp/127.0.0.1/${GENIE_PORT}) >/dev/null 2>&1; then
      echo "[entrypoint] Genie is up on 127.0.0.1:${GENIE_PORT}"
      exit 0
    fi
    sleep 0.5
  done
  echo "[entrypoint] Genie is still not listening on ${GENIE_PORT} after 180s (nginx will keep running)"
  exit 0
) &

# ---- どちらかが落ちたらコンテナも落として Render に再起動させる ----
wait -n "$GENIE_PID" "$NGINX_PID"
EXIT_CODE=$?

echo "[entrypoint] A process exited (code=${EXIT_CODE}). Shutting down..."
kill "$GENIE_PID" "$NGINX_PID" >/dev/null 2>&1 || true
exit "$EXIT_CODE"
