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

if [[ -f /app/.env ]]; then
  while IFS= read -r rawline || [[ -n "${rawline}" ]]; do
    line="${rawline#"${rawline%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line,,}" == export\ * ]] && line="${line#export }"
    [[ "${line}" == *"="* ]] || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ "${val}" == \"*\" && "${val}" == *\" ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "${val}" == \'*\' && "${val}" == *\' ]]; then
      val="${val:1:${#val}-2}"
    fi
    [[ -z "${key}" ]] && continue
    if [[ -z "${!key+x}" ]]; then
      export "${key}=${val}"
    fi
  done < /app/.env
fi

echo "[entrypoint] PORT=${PORT} (nginx listen)"
echo "[entrypoint] GENIE_HOST=${GENIE_HOST} GENIE_PORT=${GENIE_PORT} (genie listen)"

clustering_query_enabled="${CLUSTERING_QUERY_ENABLED:-false}"
clustering_query_enabled="${clustering_query_enabled//[[:space:]]/}"
clustering_query_enabled="${clustering_query_enabled,,}"
case "${clustering_query_enabled}" in
  1|true|yes|y|on) clustering_query_enabled=true ;;
  *) clustering_query_enabled=false ;;
esac

if [[ "${ENSURE_INFLUX_DBRP_ON_START:-false}" == "true" && "${clustering_query_enabled}" == "true" ]]; then
  echo "[entrypoint] ENSURE_INFLUX_DBRP_ON_START=true and CLUSTERING_QUERY_ENABLED=true; ensuring Influx DBRP mapping"
  julia --project=/app /app/scripts/ensure_influx_dbrp.jl
  echo "[entrypoint] Influx DBRP mapping ensured"
elif [[ "${ENSURE_INFLUX_DBRP_ON_START:-false}" == "true" ]]; then
  echo "[entrypoint] Influx DBRP mapping skipped: CLUSTERING_QUERY_ENABLED is false"
fi

# Optional one-shot seed for hosted environments without shell access.
# Disable after the first successful run to avoid adding more seed points on every restart.
if [[ "${SEED_ON_START:-false}" == "true" && "${clustering_query_enabled}" == "true" ]]; then
  echo "[entrypoint] SEED_ON_START=true and CLUSTERING_QUERY_ENABLED=true; running Influx seed"
  julia --project=/app /app/scripts/seed_influx.jl
  echo "[entrypoint] Influx seed finished"
elif [[ "${SEED_ON_START:-false}" == "true" ]]; then
  echo "[entrypoint] Influx seed skipped: CLUSTERING_QUERY_ENABLED is false"
fi
unset clustering_query_enabled

# Nginx 設定生成（外向き PORT / 内向き GENIE_PORT を埋め込む）
envsubst '${PORT} ${GENIE_PORT}' \
  < /etc/nginx/templates/app.conf.template \
  > /etc/nginx/conf.d/default.conf

# Nginx conf 検証
nginx -t

# ---- Genie 起動（バックグラウンド）----
# Render の環境変数を保持しつつ、書き込み可能な HOME で scuser として起動する。
# build時に作成したportable cacheだけを使い、512MiB環境でのruntime precompileを禁止する。
echo "[entrypoint] CLUSTERING_QUERY_ENABLED=${CLUSTERING_QUERY_ENABLED:-false} STARTUP_WARMUP_ENABLED=${STARTUP_WARMUP_ENABLED:-true}"
echo "[entrypoint] JULIA_CPU_TARGET=${JULIA_CPU_TARGET:-generic}; runtime precompile disabled"
if id scuser >/dev/null 2>&1; then
  su --preserve-environment -s /bin/bash -c \
    'exec env HOME=/home/scuser USER=scuser LOGNAME=scuser PORT="$GENIE_PORT" HOST="$GENIE_HOST" GENIE_ENV="$GENIE_ENV" JULIA_DEPOT_PATH="$JULIA_DEPOT_PATH" julia --startup-file=no --history-file=no --compiled-modules=existing --pkgimages=existing --project=/app /app/scripts/start_server.jl' \
    scuser &
else
  PORT="${GENIE_PORT}" HOST="${GENIE_HOST}" GENIE_ENV="${GENIE_ENV}" JULIA_DEPOT_PATH="${JULIA_DEPOT_PATH}" julia --startup-file=no --history-file=no --compiled-modules=existing --pkgimages=existing --project=/app /app/scripts/start_server.jl &
fi
GENIE_PID=$!

# Genie がlistenする前にNginxを公開すると、Renderがlive判定した後に/apiが502になる。
# Genie readinessを同期的に待ち、成功後にだけ公開ポートを開く。
GENIE_STARTUP_TIMEOUT_SECONDS="${GENIE_STARTUP_TIMEOUT_SECONDS:-300}"
if ! [[ "${GENIE_STARTUP_TIMEOUT_SECONDS}" =~ ^[0-9]+$ ]] || (( GENIE_STARTUP_TIMEOUT_SECONDS <= 0 )); then
  echo "[entrypoint] Invalid GENIE_STARTUP_TIMEOUT_SECONDS; using 300"
  GENIE_STARTUP_TIMEOUT_SECONDS=300
fi

echo "[entrypoint] Waiting up to ${GENIE_STARTUP_TIMEOUT_SECONDS}s for Genie on 127.0.0.1:${GENIE_PORT}"
genie_ready=false
for ((attempt = 0; attempt < GENIE_STARTUP_TIMEOUT_SECONDS * 2; attempt++)); do
  if ! kill -0 "${GENIE_PID}" >/dev/null 2>&1; then
    if wait "${GENIE_PID}"; then
      EXIT_CODE=0
    else
      EXIT_CODE=$?
    fi
    (( EXIT_CODE == 0 )) && EXIT_CODE=1
    echo "[entrypoint] Genie exited before becoming ready (code=${EXIT_CODE})"
    exit "${EXIT_CODE}"
  fi

  if (echo > "/dev/tcp/127.0.0.1/${GENIE_PORT}") >/dev/null 2>&1; then
    genie_ready=true
    break
  fi
  sleep 0.5
done

if [[ "${genie_ready}" != "true" ]]; then
  echo "[entrypoint] Genie did not become ready within ${GENIE_STARTUP_TIMEOUT_SECONDS}s"
  kill "${GENIE_PID}" >/dev/null 2>&1 || true
  wait "${GENIE_PID}" >/dev/null 2>&1 || true
  exit 1
fi

echo "[entrypoint] Genie is ready on 127.0.0.1:${GENIE_PORT}; starting Nginx on port ${PORT}"
nginx -g 'daemon off;' &
NGINX_PID=$!

# どちらかが落ちたらコンテナも落としてRenderに再起動させる。
if wait -n "${GENIE_PID}" "${NGINX_PID}"; then
  EXIT_CODE=0
else
  EXIT_CODE=$?
fi

echo "[entrypoint] A process exited (code=${EXIT_CODE}). Shutting down..."
kill "${GENIE_PID}" "${NGINX_PID}" >/dev/null 2>&1 || true
wait "${GENIE_PID}" "${NGINX_PID}" >/dev/null 2>&1 || true
exit "${EXIT_CODE}"
