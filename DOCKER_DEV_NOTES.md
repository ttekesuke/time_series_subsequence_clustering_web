# Docker dev notes (Genie + Vite)

This project runs a **Genie (Julia) API** and a **Vite (Vue) frontend**.

## Why API CPU can jump to 100% on idle

In Docker + bind-mount setups, **Revise / Genie AutoReload** can repeatedly trigger
inference/compilation, resulting in a "no-request" idle CPU burn.

This dev compose disables them by default:

- `JULIA_REVISE=off`
- `GENIE_AUTORELOAD=false`

If you want hot-reload for backend, prefer restarting the API container on file changes.

## Start

```bash
docker compose up -d --build
```

## Logs

```bash
docker compose logs -f api
```

## Restart API after code change

```bash
docker compose restart api
```
