(pwd() != @__DIR__) && cd(joinpath(@__DIR__, ".."))

using Genie
Genie.loadapp(pwd())

host = get(ENV, "GENIE_HOST", "127.0.0.1")
port = try
  parse(Int, get(ENV, "GENIE_PORT", get(ENV, "PORT", "9111")))
catch
  9111
end

Genie.config.run_as_server = true
Genie.config.server_host = host
Genie.config.server_port = port

println("[start_server] env GENIE_ENV=", get(ENV, "GENIE_ENV", "(none)"),
        " host=", host, " port=", port)

Genie.up(port, host; async=false)
