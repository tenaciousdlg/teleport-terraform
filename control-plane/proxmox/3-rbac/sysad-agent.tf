# sysad-agent.tf — identity for the homelab sysad agent on lgm.
#
# WHAT THIS IS FOR. A local-model agent on lgm investigates firing Grafana
# alerts. Its only window into the estate is `grafana-mcp`, Grafana's own MCP
# server, published as a stdio MCP app by the agent on siem
# (homelab/siem/mcp-grafana.tf). The agent reaches it with
#   tsh mcp connect -i <identity> --proxy teleport.heronwright.com:443 grafana-mcp
# using an identity file this bot's tbot writes, so every tool call lands in
# this cluster's audit log under the bot's name.
#
# DOCS: MCP RBAC https://goteleport.com/docs/enroll-resources/mcp-access/rbac.md
# (`mcp.tools` takes literals, globs and ^regex$, and no tools are allowed if
# it is unset); bots to MCP
# https://goteleport.com/docs/machine-workload-identity/access-guides/mcp.md
# (an `identity` service plus `tsh mcp connect -i`). PATTERN: usage-exporter.tf
# for the role/bot/token shape, data-plane/machine-id-mcp-proxmox for the app
# side.
#
# READ-ONLY THREE TIMES OVER: the role below allows only reading tools, the
# server runs with `--disable-write`, and the Grafana service account behind it
# is a Viewer. Any one of them alone would hold.

# ── The role ──────────────────────────────────────────────────────────────────
resource "teleport_role" "sysad_agent" {
  version = "v7"
  metadata = {
    name        = "sysad-agent"
    description = "IAC: the homelab sysad agent, read-only tools on grafana-mcp only"
    labels = {
      env  = "prod"
      team = "platform"
      role = "telemetry"
    }
  }

  spec = {
    allow = {
      # The one app, matched by name AND by the MCP sub-kind, so a non-MCP app
      # that ever took the same label would still not match.
      app_labels = {
        "teleport.dev/app"               = ["grafana-mcp"]
        "teleport.internal/app-sub-kind" = ["mcp"]
      }
      mcp = {
        # Taken from the server's own tools/list on siem (mcp-grafana 2.0.2
        # with --disable-write, 62 tools), not from its README. The verb
        # prefixes cover 51 of them; the rest are named one by one.
        #
        # LEFT OUT ON PURPOSE: `grafana_api_request`, a generic call to any
        # Grafana API path, and `alerting_manage_routing`, whose name says
        # manage. The Viewer account would refuse a write from either, but an
        # allow-list should not lean on the layer behind it. Also left out are
        # the tools that only matter to someone building config:
        # `suggest_loki_alloy_label_config`, `validate_provisioning_file`,
        # `diff_tempo_traces`.
        tools = [
          "get_*",
          "list_*",
          "query_*",
          "search_*",
          "alerting_rules_read",
          "alerting_silences_read",
          "analyze_loki_labels",
          "check_datasources_health",
          "generate_deeplink",
          "user_info",
        ]
      }
    }

    options = {
      max_session_ttl = "1h"
    }
  }
}

# ── The bot ───────────────────────────────────────────────────────────────────
resource "teleport_bot" "sysad_agent" {
  metadata = {
    name = "sysad-agent"
  }
  spec = {
    roles = [teleport_role.sysad_agent.metadata.name]
  }

  depends_on = [teleport_role.sysad_agent]
}

# ── The join token ────────────────────────────────────────────────────────────
resource "teleport_provision_token" "sysad_agent" {
  version = "v2"
  metadata = {
    name        = "sysad-agent"
    description = "IAC: bound_keypair join for the sysad agent's tbot on lgm"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.sysad_agent.metadata.name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        # Generated on lgm (WSL, as the `sysad` user), never by terraform:
        #   runuser -u sysad -- /usr/local/bin/tbot keypair create \
        #     --proxy-server teleport.heronwright.com:443 \
        #     --storage file:///var/lib/sysad/tbot
        # Re-run it WITHOUT --overwrite to reprint this key.
        initial_public_key = var.sysad_agent_public_key
      }
      recovery = {
        # `standard`: the store holds bkp_key_history.json, so this is a
        # mutable agent-generated key, the same case as usage-exporter.tf.
        mode  = "standard"
        limit = 20
      }
    }
  }

  depends_on = [teleport_bot.sysad_agent]
}
