#!/usr/bin/env bash
set -euo pipefail

: "${PORT:=10000}"

export GENIE_ENV="${GENIE_ENV:-prod}"
export GENIE_HOST="${GENIE_HOST:-127.0.0.1}"
export GENIE_PORT="${GENIE_PORT:-9111}"

# Nginx conf を確定（PORT を埋め込む）
envsubst '${PORT}' < /etc/nginx/templates/app.conf.template > /etc/nginx/conf.d/default.conf

# Genie 起動（バックグラウンド）: scuser がいれば scuser で起動
if id scuser >/dev/null 2>&1; then
  su -s /bin/bash -c "/app/bin/server" scuser &
else
  /app/bin/server &
fi

# Nginx をフォアグラウンドで起動（Render がここに到達する）
exec nginx -g 'daemon off;'
