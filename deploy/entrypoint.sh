#!/usr/bin/env bash
set -euo pipefail

# Render は PORT を環境変数で渡す想定。ローカルでも動くようにデフォルトを持つ
: "${PORT:=10000}"

# Genie は内部で固定（Nginx が外側を担当）
export GENIE_ENV="${GENIE_ENV:-prod}"
export GENIE_HOST="${GENIE_HOST:-127.0.0.1}"
export GENIE_PORT="${GENIE_PORT:-9111}"

# Nginx conf を確定（PORT を埋め込む）
envsubst '${PORT}' < /etc/nginx/templates/app.conf.template > /etc/nginx/conf.d/default.conf

# Genie 起動（バックグラウンド）
/app/bin/server &

# Nginx をフォアグラウンドで起動（Render がここに到達する）
exec nginx -g 'daemon off;'
