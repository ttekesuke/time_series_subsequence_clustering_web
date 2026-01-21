using Genie

# In containers, bind to 0.0.0.0 by default (external access) while still allowing override
Genie.config.server_host = get(ENV, "GENIE_HOST", get(ENV, "HOST", "0.0.0.0"))
Genie.config.server_port = parse(Int, get(ENV, "GENIE_PORT", get(ENV, "PORT", "9111")))

Genie.config.run_as_server = true
