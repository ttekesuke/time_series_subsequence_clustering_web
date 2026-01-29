# scripts/start_server.jl
cd(joinpath(@__DIR__, ".."))  # repo root

# Genie は ENV を見るので、なるべく先に確定
ENV["GENIE_ENV"] = get(ENV, "GENIE_ENV", "prod")

using Genie

# ブロッキングで動かす（=スクリプトが終わってもサーバが死なない）
Genie.config.run_as_server = true
Genie.config.server_host = get(ENV, "GENIE_HOST", "127.0.0.1")
Genie.config.server_port = parse(Int, get(ENV, "GENIE_PORT", get(ENV, "PORT", "9111")))

# ここが本命：routes を登録
include(joinpath(pwd(), "routes.jl"))

# ちゃんと /api/health が登録できたかログに出す（CIで超重要）
using Genie.Router
has_health = any(r -> getfield(r, :path) == "/api/health", Genie.Router.routes())
println("[start_server] routes loaded: ", length(Genie.Router.routes()))
println("[start_server] health route present: ", has_health)
println("[start_server] starting on http://$(Genie.config.server_host):$(Genie.config.server_port)")
flush(stdout)

Genie.up(Genie.config.server_port, Genie.config.server_host; async=false)
