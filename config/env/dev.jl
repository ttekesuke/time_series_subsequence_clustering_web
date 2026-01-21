using Genie

# dev は既存互換で HOST/PORT も読むが、優先は GENIE_* にする
Genie.config.server_host = get(ENV, "GENIE_HOST", get(ENV, "HOST", "0.0.0.0"))
Genie.config.server_port = parse(Int, get(ENV, "GENIE_PORT", get(ENV, "PORT", "9111")))

Genie.config.run_as_server = true
