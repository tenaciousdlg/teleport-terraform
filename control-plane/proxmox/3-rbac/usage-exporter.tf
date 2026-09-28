# usage-exporter.tf — read-only identity for the teleport-usage exporter.
#
# WHAT THIS IS FOR. `tools/teleport-dashboards/exporter` from rev-tech PR #59
# (jturner) polls Teleport for Protected Resources and Machine & Workload
# Identity counts and, with `-postgres-dsn`, writes each snapshot to
# `public.tpr_history` / `public.mwi_history`. Grafana reads Postgres natively,
# so this gives us usage dashboards WITHOUT standing up Prometheus.
#
# THE DATABASE SIDE NEEDS NOTHING NEW. The `demo-traffic` tbot already running
# on CT104 exposes a `database-tunnel` on 127.0.0.1:15432 to `postgres-dev` as
# `writer` (see /etc/demo-traffic/tbot.yaml). The exporter writes through that.
#
# WHY NOT REUSE `config-reader`. Measured 2026-09-26: it covers 5 of the 8
# reads the exporter makes (node, windows_desktop, bot, bot_instance,
# cluster_auth_preference) and is missing `app_server`, `db_server` and
# `kube_server`. It holds `app`, `db` and `kube_cluster`, which are the CONFIG
# kinds rather than the server heartbeat kinds the exporter counts. Widening a
# role that humans hold, to suit a bot, is also the wrong direction.
#
# ON THE PROVIDER, NOT A CR, per the repo default that Teleport-native
# resources go on the Teleport provider. All three are new, so none of the
# delete-to-convert risk applies. Precedent in this layer: agents.tf
# (teleport_provision_token) and contractors.tf (teleport_role).
#
# Pre-flight for any plan touching this file:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv teleport

# ── The role ──────────────────────────────────────────────────────────────────
resource "teleport_role" "usage_exporter" {
  version = "v7"
  metadata = {
    name        = "usage-exporter"
    description = "IAC: read-only resource and identity counts for the usage exporter"
    labels = {
      env  = "dev"
      team = "platform"
      role = "telemetry"
    }
  }

  spec = {
    allow = {
      # Exactly the API calls the exporter makes, taken from the source on the
      # PR branch rather than from its README:
      #   resources.go  GetNodes, GetApplicationServers, GetDatabaseServers,
      #                 GetKubernetesServers, GetWindowsDesktops
      #   mwi.go        GetBots/ListBots, GetBotInstances/ListBotInstances
      #   authpref.go   GetAuthPreference
      rules = [
        {
          resources = ["node", "app_server", "db_server", "kube_server", "windows_desktop"]
          verbs     = ["read", "list"]
        },
        {
          resources = ["bot", "bot_instance"]
          verbs     = ["read", "list"]
        },
        {
          resources = ["cluster_auth_preference"]
          verbs     = ["read"]
        },
        {
          # ADDED after the first live run, which is why it is worth recording.
          # My source scan covered resources.go, mwi.go and authpref.go and
          # MISSED the `SearchEvents` call in tpr.go and mau.go, so the first
          # apply produced:
          #   [ERROR] Failed to fetch events: access denied to perform action
          #   "list" on "event"
          # Everything else still worked (TPR 9, Bots 6, rows written to
          # Postgres); the only casualty was "SPIFFE IDs Issued", which reads
          # audit events and reported 0. A partial-permission failure that
          # still returns a plausible number is exactly the shape that gets
          # shipped unnoticed.
          resources = ["event"]
          verbs     = ["read", "list"]
        },
      ]

      # The heartbeat kinds are ALSO gated by label matchers, separately from
      # the rules above, so counting everything needs both. If the counts come
      # back zero after this applies, these are the first thing to check --
      # `config-reader` has all of these unset, which is part of why it could
      # not be reused.
      node_labels            = { "*" = ["*"] }
      app_labels             = { "*" = ["*"] }
      db_labels              = { "*" = ["*"] }
      kubernetes_labels      = { "*" = ["*"] }
      windows_desktop_labels = { "*" = ["*"] }
    }

    options = {
      # NO LOGINS, and that is load-bearing. This role matches every node via
      # node_labels, and the working rules record that a role matching a node
      # with create_host_user_mode off or unset cancels another role's `keep`
      # cluster-wide. That bit us once already, via the `access` preset in the
      # `homelab` access list.
      #
      # It is safe HERE because role evaluation is per identity: this role is
      # held only by the bot below, never by a human, so it cannot appear
      # alongside `homelab`'s roles in anyone's certificate. Deliberately left
      # unset rather than set to a semantically wrong value to look defensive.
      #
      # DO NOT GRANT THIS ROLE TO A PERSON OR AN ACCESS LIST. If it ever needs
      # to be, set create_host_user_mode = 3 (keep) in the same change, and
      # re-verify `tsh ssh chris@<node>` afterwards.
      max_session_ttl = "1h"
    }
  }
}

# ── The bot ───────────────────────────────────────────────────────────────────
resource "teleport_bot" "usage_exporter" {
  # metadata/spec, NOT the flat `name`/`roles` attributes. Those still work and
  # `terraform validate` accepts them, but it warns: "Deprecated resource
  # attribute \"name\" used." The nested form needs provider v18.4.0+, which
  # this layer already pins.
  metadata = {
    name = "usage-exporter"
  }
  spec = {
    roles = [teleport_role.usage_exporter.metadata.name]
  }

  depends_on = [teleport_role.usage_exporter]
}

# ── The join token ────────────────────────────────────────────────────────────
resource "teleport_provision_token" "usage_exporter" {
  version = "v2"
  metadata = {
    name        = "usage-exporter"
    description = "IAC: bound_keypair join for the teleport-usage exporter on CT104"
  }
  spec = {
    roles       = ["Bot"]
    bot_name    = teleport_bot.usage_exporter.metadata.name
    join_method = "bound_keypair"
    bound_keypair = {
      onboarding = {
        # A PUBLIC key, so it belongs in the repo. Generated on CT104 per the
        # standing default that pre-registered keypairs are made on the host,
        # never with `tls_private_key`, because these layers use a local
        # backend and a generated private key would sit in plaintext state:
        #   /usr/local/bin/tbot keypair create \
        #     --proxy-server teleport.chrisdlg.com:443 \
        #     --storage file:///var/lib/teleport-usage
        # Re-run it WITHOUT --overwrite to reprint this key rather than mint a
        # new one.
        initial_public_key = var.usage_exporter_public_key
      }
      recovery = {
        # `standard`, NOT `insecure`. The store on CT104 contains
        # bkp_key_history.json, so this is an agent-generated key with mutable
        # join state, not a `--static` one. `insecure` is for static keys,
        # which keep no join state and fail verification on every rejoin.
        mode = "standard"
        # BASELINE 20, set 2026-09-27. A recovery is consumed whenever the
        # client loses its join state, which in practice means the cluster
        # or this host was rebuilt. The estate rebuilt its cluster TWICE in
        # nine days during the heronwright migration, and each rebuild costs
        # every bot one. The previous value of 5 was about two years of
        # ordinary operation and about two migration-heavy weeks, which is
        # the wrong shape of number for the thing that carries the audit
        # trail: it ran down to 4 remaining without anything reporting it.
        #
        # Be honest about what this control is. With `initial_public_key`,
        # an attacker holding the PRIVATE half needs exactly ONE re-bind to
        # obtain a bot identity, so the limit does not meaningfully bound
        # key theft. It bounds RUNAWAY re-binding and acts as a tripwire.
        # That argues for generous-but-finite rather than as-tight-as-
        # possible. Key custody is the real control.
        limit = 20
      }
    }
  }

  depends_on = [teleport_bot.usage_exporter]
}
