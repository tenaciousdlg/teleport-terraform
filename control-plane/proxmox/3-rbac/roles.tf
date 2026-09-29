##################################################################################
# TELEPORT CLUSTER RESOURCES (CRDs)
##################################################################################

# SAML Connectors
#
# ⚠ PHASE-1 FLAG (Proxmox replica): these connectors carry the PRESALES Okta app
# bindings. `acs` / `service_provider_issuer` already retarget to
# teleport.chrisdlg.com via var.proxy_address, but `entity_descriptor_url` still
# points at the presales Okta app. Before the SSO phase, create NEW Okta apps for
# teleport.chrisdlg.com and set TF_VAR_okta_metadata_url (and, for preview,
# TF_VAR_okta_preview_metadata_url + enable_okta_preview=true). Phase 1 is local
# auth, so both connectors default OFF: the primary is gated on a non-empty
# okta_metadata_url, the preview on enable_okta_preview.
resource "kubectl_manifest" "saml_connector_okta" {
  count = var.okta_metadata_url != "" ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v2"
    kind       = "TeleportSAMLConnector"
    metadata = {
      name      = "okta-integrator"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      acs = "https://${var.proxy_address}:443/v1/webapi/saml/acs/okta"
      attributes_to_roles = [
        { name = "groups", value = "Everyone", roles = ["base-user"] }
      ]
      display                 = "okta integrator"
      entity_descriptor_url   = var.okta_metadata_url
      service_provider_issuer = "https://${var.proxy_address}/sso/saml/metadata"
    }
  })
}

# The connector for THIS cluster's own Okta app, distinct from the presales
# one above. Named `okta` because the connector name is the last path segment
# of the ACS URL, and cluster_auth_preference.connector_name points at it.
#
# Unified pattern, fully: maps only to base-user. Real grants come from the
# access lists -- `homelab` for the personal identity, `engineers` and the rest
# for the demo personas -- where they are owner-reviewed and auditable.
resource "kubectl_manifest" "saml_connector_chrisdlg" {
  count = var.saml_entity_descriptor != "" ? 1 : 0

  # A BARE `terraform apply` HERE USED TO DESTROY OKTA SSO. Verified 2026-09-21:
  # with TF_VAR_saml_entity_descriptor unset, count collapses to 0 and
  # the plan reads
  #   kubectl_manifest.saml_connector_chrisdlg[0] will be destroyed
  #   (because index [0] is out of range for count)
  # which is a one-line, easily-skimmed way to take down every SSO login on
  # this cluster. The variable is deliberately not in the repo, so forgetting
  # to export it is the DEFAULT state, not an unusual mistake.
  #
  # prevent_destroy turns that into a loud refusal at plan time. It is not a
  # substitute for exporting the variable -- it just means the failure mode is
  # an error instead of an outage. Source it with:
  #   . ./idp-env.sh
  # which reads the right okta outputs for the current WORKSPACE and exports
  # BOTH this variable and `saml_mfa_entity_descriptor`. Exporting only the
  # first has its own quiet failure: the connector survives, and the plan
  # proposes removing its `mfa` block, which turns off SSO MFA without ever
  # tripping prevent_destroy.
  #
  # To retire the connector on purpose, delete this lifecycle block in the same
  # commit that removes the resource, so the intent is reviewable.
  lifecycle {
    prevent_destroy = true
  }
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v2"
    kind       = "TeleportSAMLConnector"
    metadata = {
      name      = "okta"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = merge({
      display = "Okta"
      acs     = "https://${var.proxy_address}:443/v1/webapi/saml/acs/okta"

      # EVERY GROUP THAT CAN REACH THE APP NEEDS A LINE HERE. A user whose
      # groups match nothing in this list logs in with NO roles and Teleport
      # rejects them -- it reads like an access-list problem and is not.
      #
      # `contractors` was MISSING until 2026-09-27. The group and its access
      # list were built on 2026-09-22 but never added here, so
      # sam@chrisdlg.com (its only member) could not have logged in at all.
      # Real grants come from the access lists; this only decides who gets
      # through the door with `base-user`.
      attributes_to_roles = [
        { name = "groups", value = "homelab", roles = ["base-user"] },
        { name = "groups", value = "engineers", roles = ["base-user"] },
        { name = "groups", value = "devs", roles = ["base-user"] },
        { name = "groups", value = "senior-devs", roles = ["base-user"] },
        { name = "groups", value = "contractors", roles = ["base-user"] },
      ]
      entity_descriptor = var.saml_entity_descriptor
      },
      # ── SSO MFA ───────────────────────────────────────────────────────────
      #
      # Delegates Teleport's PER-SESSION MFA checks to Okta, so an SSO-only
      # identity can satisfy them without registering a WebAuthn device
      # directly in Teleport. Without this, `require_session_mfa` on a SAML
      # user demands a device Teleport holds and an SSO user usually has none,
      # so the option reads as a lockout rather than a prompt.
      #
      # POINTS AT A SECOND, SEPARATE OKTA APP. The login app cannot serve
      # both: this needs an app whose sign-on policy always challenges, where
      # the login app's deliberately never re-prompts. Built in
      # okta/heronwright-teleport.tf.
      #
      # `force_authn` is DELIBERATELY OMITTED. The CRD types it as
      # int-or-string tri-state and documents "UNSPECIFIED is treated as YES",
      # so leaving it out gives the safe default -- always re-authenticate --
      # without guessing whether this version wants `true`, `"yes"` or `1`.
      #
      # Empty variable omits the block entirely, which is what keeps the
      # chrisdlg workspace unchanged.
      var.saml_mfa_entity_descriptor != "" ? {
        mfa = {
          enabled = true
          # INLINE XML, NOT A URL. Teleport FETCHES entity_descriptor_url, and
          # Okta's app metadata URL is an ADMIN API path needing an SSWS
          # token, so the fetch 401s and the operator reports "failed to fetch
          # or parse entity descriptor" -- which reads like bad XML and is an
          # auth failure. The login half above already passes XML inline; this
          # matches it.
          entity_descriptor = var.saml_mfa_entity_descriptor
        }
    } : {})
  })
}

resource "kubectl_manifest" "saml_connector_okta_preview" {
  count = var.enable_okta_preview ? 1 : 0
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v2"
    kind       = "TeleportSAMLConnector"
    metadata = {
      name      = "okta-preview"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      acs = "https://${var.proxy_address}/v1/webapi/saml/acs/okta-preview"
      # Unified pattern, fully: EVERY IdP maps only to base-user — real
      # grants come from access lists. This IdP has no SCIM, so membership
      # of the visiting-ses list below is explicit and owner-reviewed
      # (the JML story: a visiting SE gets base-user until the owner adds
      # them to the list).
      attributes_to_roles = [
        { name = "groups", value = "Solutions-Engineering", roles = ["base-user"] }
      ]
      display                 = "okta preview"
      entity_descriptor_url   = var.okta_preview_metadata_url
      service_provider_issuer = "https://${var.proxy_address}/sso/saml/metadata"
    }
  })
}

# Login Rules
#
# PERMANENTLY RETIRED 2026-08-20 (Chris): short logins (email local part)
# and raw SSO attributes were always the intent. This rule's traits_map
# REPLACED the trait set with logins+groups only, silently starving every
# role template that expects raw assertion attributes —
# {{email.local(external.username)}} expanded to nothing (so logins were the
# FULL email via strings.lower(external.username), never "dlg") and
# {{external.aws_role_arns}} had no trait to read. With no login rule, all
# assertion attributes land as traits untouched and the templates work as
# designed. The rule arrived wholesale in the 2026-03-12 rev-tech sync
# (b2ce624); rev-tech itself doesn't carry it. Kept for history only —
# do NOT re-enable as-was. Gotcha if ever recreating one: exactly ONE of
# traits_map / traits_expression is allowed — both set = operator
# crash-loop (2026-07-29 destroy → fixed 2026-08-05).
#
# resource "kubectl_manifest" "login_rule_okta" {
#   yaml_body = yamlencode({
#     apiVersion = "resources.teleport.dev/v1"
#     kind       = "TeleportLoginRule"
#     metadata = {
#       name      = "okta-preferred-login-rule"
#       namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
#     }
#     spec = {
#       priority = 0
#       traits_map = {
#         logins = ["external.logins", "strings.lower(external.username)"]
#         groups = ["external.groups"]
#         # Trait-collision demo: pass-through required because traits_map
#         # REPLACES the trait set — unmapped assertion attributes are dropped.
#         "team-name" = ["external.team-name"]
#       }
#     }
#   })
# }

# Audit-export bot role — held by the event-handler bot that ships events
# to fluentd. ADOPTED INTO IaC 2026-08-20 (was tctl-created, un-owned; it is
# LOAD-BEARING for the audit export). Same one-time adoption dance as the
# AMRs if recreating: tctl rm roles/event-handler, operator recreates.
resource "kubectl_manifest" "role_event_handler" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "event-handler"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Read audit events — impersonated by the event-handler bot (audit export pipeline)"
    }
    spec = {
      allow = {
        rules = [
          { resources = ["event"], verbs = ["list", "read"] }
        ]
      }
    }
  })
}

# Base user role
resource "kubectl_manifest" "role_base_user" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "base-user"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] }
        ]
      }
      options = {
        max_session_ttl    = "8h0m0s"
        enhanced_recording = ["command", "network"]
      }
    }
  })
}

# ABAC showcase: ONE role for the whole org (granted by the Everyone access
# list); WHAT it reaches is decided per-user by the IdP-asserted team-name
# trait (Okta derives it from group membership — okta repo scim.tf) plus any
# team-name values granted by access lists (engineers get "dev" on top of
# their asserted "platform" — Teleport unions the two at login). A user with
# no team gets team-name="" which matches nothing. env=dev only: prod SSH
# stays JIT-only via prod-access, on purpose.
resource "kubectl_manifest" "role_team_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "team-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "SSH to your team's dev nodes — scope comes from the IdP-asserted team-name trait, not per-team roles"
    }
    spec = {
      allow = {
        # Personal login ONLY — no shared ubuntu/ec2-user accounts. Paired
        # with create_host_user_mode=keep below, every session is a named
        # user auto-provisioned on the host: full attribution in the audit
        # log (least privilege: shared accounts break accountability).
        logins = ["{{email.local(external.username)}}"]
        node_labels = {
          env = ["dev"]
          # Bracket-index form is REQUIRED: the trait key contains a hyphen,
          # and {{external.team-name}} parses "-" as subtraction — the
          # operator rejects the role ("- is not supported").
          team = ["{{external[\"team-name\"]}}"]
        }
      }
      options = {
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        max_session_ttl                = "8h0m0s"
        enhanced_recording             = ["command", "network"]
      }
    }
  })
}

# Zero standing privilege: engineers hold NO standing editor. Reads come
# from config-reader (below) + auditor; writes are JIT via admin-requester →
# editor (4h, reason required, auto-approved for the owner by the
# demo-admin-jit AMR in amr.tf). Break-glass: kubectl exec into the auth pod
# gives local tctl with full admin (see RESTORE-NOTES).
resource "kubectl_manifest" "role_config_reader" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "config-reader"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Read-only cluster configuration access — preflight tooling (demo-doctor) and inspection without standing editor"
    }
    spec = {
      allow = {
        rules = [
          {
            resources = [
              "role", "user", "access_list", "access_monitoring_rule",
              "access_request", "node", "app", "db", "kube_cluster",
              "windows_desktop", "auth_connector", "login_rule", "lock",
              "cluster_auth_preference", "cluster_networking_config",
              "session_recording_config", "trusted_cluster",
              # MWI read-only (2026-08-26): without these the Bots/Workload
              # Identity UI pages are hidden entirely. Deliberately NOT
              # "token" — join tokens carry secrets; writes stay editor-JIT.
              "bot", "bot_instance", "workload_identity",
              # Managed-updates visibility (2026-08-28): watch client/agent
              # rollouts without JIT-ing editor.
              "autoupdate_config", "autoupdate_version", "autoupdate_agent_rollout"
            ]
            verbs = ["list", "read"]
          }
        ]
      }
      options = {
        max_session_ttl    = "8h0m0s"
        enhanced_recording = ["command", "network"]
      }
    }
  })
}

resource "kubectl_manifest" "role_admin_requester" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "admin-requester"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "JIT path to editor: 4h max, reason required"
    }
    spec = {
      allow = {
        request = {
          roles        = ["editor"]
          max_duration = "4h0m0s"
          reason = {
            mode = "required"
          }
        }
      }
    }
  })
}

# Dev/Prod Access Roles, Reviewers, Requesters, Access Lists

##################################################################################
# DEV/PROD ACCESS ROLES (TeleportRoleV7)
##################################################################################

resource "kubectl_manifest" "role_dev_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "dev-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Development access for mapped user databases and infrastructure"
    }
    spec = {
      allow = {
        # team matchers are lists: profiles deploy their data plane with
        # team=platform (TF_VAR_team default), so dev roles must match both.
        app_labels = {
          env  = ["dev"]
          team = [var.dev_team, "platform"]
        }
        aws_role_arns = ["{{external.aws_role_arns}}"]
        db_labels = {
          env                      = ["dev"]
          team                     = [var.dev_team, "platform"]
          "teleport.dev/db-access" = ["mapped"]
        }
        db_names       = ["{{external.db_names}}", "*"]
        db_users       = ["{{external.db_users}}", "reader", "writer"]
        desktop_groups = ["Administrators"]
        impersonate = {
          roles = ["Db"]
          users = ["Db"]
        }
        join_sessions = [
          {
            kinds = ["k8s", "ssh"]
            modes = ["moderator", "observer"]
            name  = "Join dev sessions"
            roles = ["dev-access", "platform-dev-access"]
          }
        ]
        # Scoped k8s group (was system:masters, which bypasses ALL k8s RBAC):
        # namespace-bound RoleBinding in kube-rbac.tf. kubernetes_resources
        # below still pins the namespace as the second enforcement layer.
        kubernetes_groups = ["{{external.kubernetes_groups}}", "teleport-dev-editors"]
        # Scoped like every other matcher in this role (was "*":"*" — the
        # only wildcard cluster matcher in the dev tier; least privilege).
        kubernetes_labels = {
          env  = "dev"
          team = var.dev_team
        }
        kubernetes_resources = [
          { kind = "*", name = "*", namespace = "dev", verbs = ["*"] }
        ]
        host_groups = ["wheel"]
        logins      = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        mcp = {
          tools = ["*"]
        }
        node_labels = {
          env  = ["dev"]
          team = [var.dev_team, "platform"]
        }
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] }
        ]
        windows_desktop_labels = {
          env  = ["dev"]
          team = [var.dev_team, "platform"]
        }
        windows_desktop_logins = ["{{external.windows_logins}}", "{{email.local(external.username)}}"]
      }
      options = {
        # false since 2026-08-26 — same mapped-DB reasoning as
        # platform-dev-access; without it bob's --db-user=writer is rejected.
        create_db_user                 = false
        create_db_user_mode            = "off"
        create_desktop_user            = true
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        desktop_clipboard              = true
        desktop_directory_sharing      = true
        max_session_ttl                = "8h0m0s"
        pin_source_ip                  = false
        enhanced_recording             = ["command", "network"]
      }
    }
  })
}

resource "kubectl_manifest" "role_dev_auto_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "dev-auto-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Development access with auto user provisioning for RDS databases"
    }
    spec = {
      allow = {
        db_labels = {
          env                      = ["dev"]
          team                     = [var.dev_team, "platform"]
          "teleport.dev/db-access" = ["auto"]
        }
        db_names = ["{{external.db_names}}", "*"]
        db_roles = ["{{external.db_roles}}", "reader", "writer", "dbadmin"]
        db_users = ["{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        node_labels = {
          env  = ["dev"]
          team = [var.dev_team, "platform"]
        }
        host_groups = ["wheel"]
        logins      = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] }
        ]
      }
      options = {
        create_db_user                 = true
        create_db_user_mode            = "keep"
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        max_session_ttl                = "8h0m0s"
        enhanced_recording             = ["command", "network"]
      }
    }
  })
}

resource "kubectl_manifest" "role_platform_dev_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "platform-dev-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Standing access to all dev resources for platform"
    }
    spec = {
      allow = {
        app_labels = {
          env  = ["dev"]
          team = ["*"]
        }
        aws_role_arns = ["{{external.aws_role_arns}}"]
        # DATABASE ACCESS MOVED OUT OF THIS ROLE, 2026-09-27.
        #
        # It used to carry db_labels {env: dev, team: *} with
        # db_names = ["{{external.db_names}}", "*"]. Two problems with that,
        # and the wildcard was the smaller one:
        #
        #   1. The `*` meant every database name was allowed, so the grant said
        #      nothing about what actually exists. Removing it was recorded in
        #      this repo as "phase 2", gated on the db_names TRAIT landing
        #      first so the estate owner would not be locked out of every
        #      database. That trait is confirmed in the issued certificate
        #      (db_names: [postgres, demo]), so phase 2 is unblocked.
        #   2. The trait is PER USER, not per database, so both engines were
        #      offered both names. Postgres has `postgres` and no `demo`, which
        #      is why `--db-name=demo` against postgres-dev returned
        #      `FATAL: database "demo" does not exist` — the same defect as the
        #      phantom `dlg` db_user: an option offered that cannot work.
        #
        # Both are fixed by scoping the grant to the ENGINE label the databases
        # already carry, in role_db_dev_postgres and role_db_dev_mysql below.
        # Those roles hold db_users AND db_names together, deliberately: the
        # database RBAC reference does not state whether db_users and db_names
        # combine ACROSS roles or must both come from one matching role, so
        # keeping them together is correct under either reading. Verified by
        # connecting afterwards rather than by inference.
        #
        # THE COST, stated plainly: a dev database of some OTHER engine (mongo,
        # cassandra) now matches no role and gets no access until an
        # engine-scoped role is added for it. That fails closed, which is the
        # right direction, but it is a real step someone has to remember.
        # NO PER-USER TEMPLATES HERE. Removed 2026-09-27 after Chris reported
        # "neither of the dbs work to login", and this was the cause.
        #
        # This role used to offer `{{email.local(external.username)}}` as a
        # database user, which renders `dlg`. But THIS ROLE SETS
        # create_db_user_mode = "off" (see options below), so Teleport never
        # creates that account and both engines reject it outright:
        #     postgres-dev -> FATAL: role "dlg" does not exist
        #     mysql-dev    -> ERROR 1045 Access denied for user 'dlg'@'localhost'
        # Worse, `dlg` sorts FIRST in the allowed-users list, so it is the
        # obvious pick in the Web UI connect dialog. The role advertised an
        # option that could never authenticate, and the refusal comes from the
        # ENGINE rather than from Teleport, so it reads as "the database is
        # broken" rather than "this user was never going to work".
        #
        # PER-USER DATABASE ACCESS IS NOT LOST. `dev-auto-access` carries the
        # same two templates WITH create_db_user_mode = "keep", gated on the
        # label `teleport.dev/db-access: auto`. Both estate databases are
        # labelled `mapped`, so they are deliberately in the named-role model
        # the demo playbook describes ("reader and writer are certificate
        # subjects"). A database that should auto-provision gets the `auto`
        # label; the template does not come back here.
        #
        # The general rule: only offer a db_user that something will actually
        # create. A template plus `create_db_user_mode = off` is a promise
        # nothing keeps.
        desktop_groups = ["Administrators"]
        impersonate = {
          roles = ["Db"]
          users = ["Db"]
        }
        join_sessions = [
          {
            kinds = ["k8s", "ssh"]
            modes = ["moderator", "observer"]
            name  = "Join dev sessions"
            roles = ["dev-access", "platform-dev-access"]
          }
        ]
        kubernetes_groups = ["{{external.kubernetes_groups}}", "teleport-dev-editors"]
        kubernetes_labels = {
          env  = "dev"
          team = "*"
        }
        kubernetes_resources = [
          { kind = "*", name = "*", namespace = "dev", verbs = ["*"] }
        ]
        host_groups = ["wheel"]
        # NO SHARED ubuntu / ec2-user. Removed from all four roles that had
        # them on 2026-09-27, at Chris's request: "drop ubuntu and ec2-user
        # from standing access roles too and just leave the dynamic SSH
        # created user."
        #
        # Same reasoning as the homelab-ssh literals fixed earlier the same
        # day. A shared OS account means every host-side record -- file
        # ownership, shell history, process owners, sudo entries -- names an
        # account rather than a person, so the Teleport audit log becomes the
        # only place the real identity survives.
        #
        # NOTHING IS LOST, because these are exactly the roles that set
        # create_host_user_mode = "keep" and carry
        # {{email.local(external.username)}}, which resolves on this cluster.
        # Teleport creates the per-user account at session start, the
        # behaviour Chris confirmed working: a fresh `chris` on pts/2 with no
        # shell config yet.
        #
        # REMOVED FROM THE REQUEST-ONLY ROLES TOO (prod-access,
        # prod-access-mfa, prod-auto-access), not only the standing one.
        # Leaving them there would mean any approved access request handed the
        # shared accounts straight back, which defeats removing them from
        # standing access.
        #
        # `{{email.local(external.email)}}` stays but is DEAD on this cluster:
        # no user carries an `email` trait, so it renders empty. Kept because
        # it costs nothing and becomes correct if such a trait is ever
        # asserted. Do not mistake it for a working grant.
        logins = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        mcp = {
          tools = ["*"]
        }
        node_labels = {
          env  = ["dev"]
          team = ["*"]
        }
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] },
          { resources = ["access_graph"], verbs = ["list", "read"] }
        ]
        windows_desktop_labels = {
          env  = ["dev"]
          team = ["*"]
        }
        windows_desktop_logins = ["{{external.windows_logins}}", "{{email.local(external.username)}}"]
      }
      options = {
        # false since 2026-08-26: the self-hosted (mapped) DBs have no
        # admin_user, so provisioning enforcement blocked reader/writer for
        # ANYONE holding this role. dev-auto-access remains the auto role.
        create_db_user                 = false
        create_db_user_mode            = "off"
        create_desktop_user            = false
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        desktop_clipboard              = true
        desktop_directory_sharing      = true
        max_session_ttl                = "8h0m0s"
        pin_source_ip                  = false
        enhanced_recording             = ["command", "network"]
      }
    }
  })
}


resource "kubectl_manifest" "role_prod_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "prod-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Full access to production resources"
    }
    spec = {
      allow = {
        app_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        aws_role_arns = ["{{external.aws_role_arns}}"]
        # GATED ON `mapped`, ADDED 2026-09-28. This was the only role offering
        # per-user database access whose db_labels carried NO
        # `teleport.dev/db-access` gate, which made it the prod twin of the
        # `platform-dev-access` fault Chris hit on 2026-09-27 -- offering a
        # db_user that nothing creates, where the refusal comes from the ENGINE
        # (`FATAL: role "dlg" does not exist`) and so reads as "the database is
        # broken" rather than "this user was never going to work".
        #
        # IT WAS LATENT, NOT HARMLESS, AND THAT IS THE WHOLE POINT. Every
        # database in the estate is `env: dev`, so this role's db_labels match
        # NOTHING today and the fault could not fire. The estate is being
        # retagged toward `env: prod`; the first prod database registered would
        # have armed it. Fixing the instance on platform-dev-access and leaving
        # the same shape here is exactly the "a gotcha is not a fix" pattern
        # from the working rules, so the class is closed instead.
        #
        # Verified before writing this, not assumed: all three databases carry
        # `teleport.dev/db-access: mapped` and NONE has an `admin_user`, so
        # auto user provisioning is impossible estate-wide. `keep` could not
        # have worked on any of them. Auto-provisioning is covered by
        # `prod-auto-access`, which is already gated on `db-access: auto`.
        #
        # This role is now the prod mirror of `dev-access`: mapped databases,
        # named certificate subjects, no creation.
        db_labels = {
          env                      = ["prod"]
          team                     = [var.prod_team]
          "teleport.dev/db-access" = ["mapped"]
        }
        db_names = ["{{external.db_names}}", "*"]
        # Per-user templates REMOVED. `{{email.local(external.username)}}`
        # renders `dlg` and would be offered with nothing able to create it;
        # `{{email.local(external.email)}}` renders empty because no user on
        # this cluster carries an `email` trait (re-verified against
        # `tctl get users` on 2026-09-28, not recalled from the note).
        db_users       = ["{{external.db_users}}", "reader", "writer"]
        desktop_groups = ["Administrators"]
        impersonate = {
          roles = ["Db"]
          users = ["Db"]
        }
        join_sessions = [
          {
            kinds = ["k8s", "ssh"]
            modes = ["moderator", "observer"]
            name  = "Join prod sessions"
            # Scoped (was ["*"]): joinable sessions are those started under
            # these roles — wildcards in a prod role are the anti-pattern.
            roles = ["prod-access", "prod-access-mfa", "platform-dev-access", "dev-access"]
          }
        ]
        kubernetes_groups = ["{{external.kubernetes_groups}}", "teleport-prod-editors"]
        kubernetes_labels = {
          env  = "prod"
          team = var.prod_team
        }
        kubernetes_resources = [
          { kind = "*", name = "*", namespace = "prod", verbs = ["*"] }
        ]
        host_groups = ["wheel"]
        # No shared ubuntu/ec2-user -- see the note on platform-dev-access.
        logins = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        mcp = {
          tools = ["*"]
        }
        node_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] }
        ]
        windows_desktop_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        windows_desktop_logins = ["{{external.windows_logins}}", "{{email.local(external.username)}}", "Administrator"]
      }
      options = {
        # OFF, changed from `keep` 2026-09-28, together with gating db_labels
        # on `mapped` above. Read the schema, not this comment, for the enum:
        # `create_db_user_mode` keep is **2** and off is **1**, and it does NOT
        # share numbering with `create_host_user_mode` (where keep is 3).
        create_db_user                 = false
        create_db_user_mode            = "off"
        create_desktop_user            = false
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        desktop_clipboard              = true
        desktop_directory_sharing      = true
        max_session_ttl                = "2h0m0s"
        pin_source_ip                  = false
        enhanced_recording             = ["command", "network"]

        # lock: strict — see role_prod_readonly_access for the full reasoning.
        # Aggregates across the user's whole role set ("strict wins in case of
        # conflict"), so it is not scoped to prod-labelled resources alone.
        lock = "strict"
      }
    }
  })
}

# Per-session MFA variant: same prod nodes, but every connection re-verifies
# with WebAuthn (the touch-your-key-at-ssh-time demo beat). Requestable via
# prod-requester like the rest of the prod ladder.
resource "kubectl_manifest" "role_prod_access_mfa" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "prod-access-mfa"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Production SSH with per-session MFA re-verification"
    }
    spec = {
      allow = {
        node_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        host_groups = ["wheel"]
        # No shared ubuntu/ec2-user -- see the note on platform-dev-access.
        logins = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] }
        ]
      }
      options = {
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        max_session_ttl                = "1h0m0s"
        # Proto enum, not bool (CRD rejects booleans): 1 = per-session webauthn
        require_session_mfa = 1
        enhanced_recording  = ["command", "network"]

        # lock: strict — see role_prod_readonly_access for the full reasoning.
        # Aggregates across the user's whole role set ("strict wins in case of
        # conflict"), so it is not scoped to prod-labelled resources alone.
        lock = "strict"
      }
    }
  })
}

resource "kubectl_manifest" "role_prod_auto_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "prod-auto-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Production access with auto user provisioning for RDS databases (requires approval)"
    }
    spec = {
      allow = {
        db_labels = {
          env                      = ["prod"]
          team                     = [var.prod_team]
          "teleport.dev/db-access" = ["auto"]
        }
        db_names = ["{{external.db_names}}", "*"]
        db_roles = ["{{external.db_roles}}", "reader", "writer", "dbadmin"]
        db_users = ["{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        node_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        host_groups = ["wheel"]
        # No shared ubuntu/ec2-user -- see the note on platform-dev-access.
        logins = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        rules = [
          { resources = ["event"], verbs = ["list", "read"] },
          { resources = ["session"], verbs = ["read", "list"] }
        ]
      }
      options = {
        create_db_user                 = true
        create_db_user_mode            = "keep"
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        max_session_ttl                = "2h0m0s"
        enhanced_recording             = ["command", "network"]

        # lock: strict — see role_prod_readonly_access for the full reasoning.
        # Aggregates across the user's whole role set ("strict wins in case of
        # conflict"), so it is not scoped to prod-labelled resources alone.
        lock = "strict"
      }
    }
  })
}

resource "kubectl_manifest" "role_prod_readonly_access" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "prod-readonly-access"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "Read-only access to production resources"
    }
    spec = {
      allow = {
        app_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        # Gated on `mapped` for the same reason as prod-access above: this
        # role's db grants were ungated too, and fixing one twin while leaving
        # the other is how the platform-dev-access fault survived in the first
        # place.
        db_labels = {
          env                      = ["prod"]
          team                     = [var.prod_team]
          "teleport.dev/db-access" = ["mapped"]
        }
        # `*` ALONE MAKES THE WEB UI DROPDOWN LOOK EMPTY. `prepareOptions`
        # filters `*` out of the options and only sets `hasWildcard`, so the
        # user sees "Select..." with nothing in it and reads that as broken
        # access when the field is actually typeable. There is no concrete name
        # to add here yet because no prod database exists; when one is
        # registered, grant its real database names as a `db_names` trait.
        db_names = ["*"]
        # UNVERIFIABLE TODAY, AND SAID SO RATHER THAN QUIETLY KEPT OR QUIETLY
        # DROPPED. `create_db_user_mode` is off on this role, so every name
        # here must ALREADY EXIST in the target engine. `reader` does exist in
        # the dev databases; `reporting` has never been checked against
        # anything, because there is no prod database to check it against, and
        # `{{external.readonly_db_user}}` is granted by no access list so it
        # renders empty. **Confirm `reporting` exists in the engine before the
        # first prod database is registered**, or it becomes the same phantom:
        # an offered user the ENGINE refuses, which reads as a broken database.
        db_users = ["reader", "reporting", "{{external.readonly_db_user}}"]
        # Without logins this role matched the prod node but granted no SSH
        # principal — an approved request still ended in access denied.
        logins = ["{{email.local(external.username)}}", "{{email.local(external.email)}}"]
        # Cloud CLI tie-in (2026-08-27): elevation to this role unlocks the
        # Azure demo identity (Reader on rg-dlg-teleport-demo). CLI-only —
        # Teleport has no Azure Portal federation.
        azure_identities = [
          # camelCase resourceGroups — must match the azurerm-emitted resource
          # ID from profiles/cloud-cli (az CLI emits lowercase; forms differ).
          "/subscriptions/060a97ea-3a57-4218-9be5-dba3f19ff2b5/resourceGroups/rg-dlg-teleport-demo/providers/Microsoft.ManagedIdentity/userAssignedIdentities/teleport-azure"
        ]
        # GCP CLI tie-in (2026-08-27): project Viewer via impersonated SA.
        # NOTE: identities/SAs are baked into the user cert at login — role
        # changes here need a tsh logout/login to take effect.
        gcp_service_accounts = [
          "teleport-vm-viewer@weighty-planet-305123.iam.gserviceaccount.com"
        ]
        mcp = {
          tools = ["*"]
        }
        # Was missing entirely — without a kube group the role's kube access
        # was inert. view-only group, namespace-pinned below.
        kubernetes_groups = ["teleport-prod-viewers"]
        kubernetes_labels = {
          env  = "prod"
          team = var.prod_team
        }
        kubernetes_resources = [
          { kind = "*", name = "*", namespace = "prod", verbs = ["get", "list", "watch"] }
        ]
        node_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        windows_desktop_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        windows_desktop_logins = ["{{external.windows_logins}}", "Administrator"]
      }
      options = {
        max_session_ttl = "4h0m0s"
        # "keep" since 2026-08-20 (was "off"): this is the ONLY standing role
        # matching the env=prod node, and a matched role without keep blocks
        # auto host-user creation for the whole session — Chris's rule is
        # every system has host user creation enabled.
        create_host_user_mode = "keep"
        create_db_user        = false
        create_db_user_mode   = "off"
        enhanced_recording    = ["command", "network"]

        # LOCK: STRICT — 2026-09-27, on every role that selects env=prod.
        # Chris: "I only really need homelab to be treated as production."
        # Schema-checked rather than guessed: `terraform providers schema
        # -json` gives teleport_role options.lock as type STRING
        # ("strict|best_effort"), not one of the integer proto enums that
        # require_session_mfa and the host/db user modes use.
        #
        # READ THIS BEFORE ASSUMING IT IS SCOPED TO PROD. The roles reference
        # says "'strict' wins in case of conflict", so this is resolved across
        # the user's WHOLE role set. Chris holds prod and dev roles at once,
        # so setting it here makes his dev sessions strict too. The
        # open-items note said lock "belongs on prod and nowhere else in this
        # estate" — that intent is not expressible through a role option,
        # because options aggregate per user, not per target resource.
        #
        # Accepted anyway, and the reason is specific to this estate: strict
        # denies when the lock view cannot be refreshed from auth. Auth and
        # the proxy both run on CT103, so if auth is unreachable there is no
        # Teleport path to anything regardless of this setting. The window it
        # actually changes is narrow, and the non-Teleport break-glass paths
        # (ssh lgm-win, pct exec from hollowtree) are unaffected by it.
        lock = "strict"
      }
    }
  })
}


resource "kubectl_manifest" "role_prod_requester" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "prod-requester"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        request = {
          roles           = ["prod-readonly-access", "prod-access", "prod-auto-access", "prod-access-mfa"]
          search_as_roles = ["prod-readonly-access", "prod-access", "prod-auto-access", "prod-access-mfa"]
          # JIT bounds: elevation expires in ≤4h (zero standing privilege —
          # no more multi-day approved requests), and prod requests must
          # carry a reason (audit trail; the demo-prodaccess AMR keys off it).
          max_duration = "4h0m0s"
          reason = {
            mode = "required"
          }
        }
      }
    }
  })
}

resource "kubectl_manifest" "role_dev_requester" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "dev-requester"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        request = {
          roles           = ["prod-readonly-access"]
          search_as_roles = ["prod-readonly-access"]
          # Reason stays optional at the dev tier (demo friction); the
          # duration bound still applies — no long-lived elevations.
          max_duration = "4h0m0s"
        }
      }
    }
  })
}

resource "kubectl_manifest" "role_senior_dev_requester" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "senior-dev-requester"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        request = {
          roles           = ["prod-readonly-access", "prod-access", "prod-auto-access"]
          search_as_roles = ["prod-readonly-access", "prod-access", "prod-auto-access"]
          max_duration    = "4h0m0s"
          reason = {
            mode = "required"
          }
        }
      }
    }
  })
}

resource "kubectl_manifest" "role_dev_reviewer" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "dev-reviewer"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        review_requests = {
          roles            = ["dev-access", "platform-dev-access"]
          preview_as_roles = ["dev-access", "platform-dev-access"]
        }
      }
    }
  })
}

resource "kubectl_manifest" "role_prod_reviewer" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "prod-reviewer"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      allow = {
        review_requests = {
          roles            = ["prod-readonly-access", "prod-access", "prod-auto-access", "prod-access-mfa"]
          preview_as_roles = ["prod-readonly-access", "prod-access", "prod-auto-access", "prod-access-mfa"]
        }
      }
    }
  })
}

# Access Lists
resource "kubectl_manifest" "access_list_everyone" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "everyone"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "Everyone"
      description = "All users in the organization"
      type        = "scim"
      owners = [
        # Owners must be REAL users — they run membership reviews and the
        # ownership shows in audit ("admin" was a phantom placeholder). The
        # actual identity stays out of this public repo, same as the IdP
        # URLs: set TF_VAR_access_list_owner locally.
        { name = var.access_list_owner, description = "Platform lead" }
      ]
      grants = {
        # GOTCHA: this list is MEMBERLESS — Okta cannot group-push its
        # built-in "Everyone" group, so SCIM never populates it and these
        # grants reach nobody. base-user actually comes from the SAML
        # connector's attributes_to_roles mapping. Kept for parity with the
        # Okta group; grant real roles via devs/senior-devs/engineers below.
        roles = ["base-user"]
      }
    }
  })
}

resource "kubectl_manifest" "access_list_devs" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "devs"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "devs"
      description = "Standing dev access for the dev team"
      type        = "scim"
      owners = [
        # Owners must be REAL users — they run membership reviews and the
        # ownership shows in audit ("admin" was a phantom placeholder). The
        # actual identity stays out of this public repo, same as the IdP
        # URLs: set TF_VAR_access_list_owner locally.
        { name = var.access_list_owner, description = "Platform lead" }
      ]
      grants = {
        # team-access = the ABAC role: shared by all tiers, per-user scope
        # via the team-name trait (see role_team_access).
        roles = ["dev-access", "dev-auto-access", "dev-requester", "team-access"]
        # Database scope by the same ABAC mechanism as team-name. The db roles
        # already read {{external.db_names}}; this is what makes that expand
        # to something. Until the "*" is removed from those roles (phase 2,
        # see variables.tf) this changes NO access, only what the Web UI
        # connect dialog can offer.
        traits = {
          "db_names"      = var.db_names_by_access_list["devs"]
          "aws_role_arns" = var.aws_role_arns_by_access_list["devs"]
        }
      }
    }
  })
}

resource "kubectl_manifest" "access_list_senior_devs" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "senior-devs"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "senior-devs"
      description = "Senior devs: cross-team dev access + prod request capability"
      type        = "scim"
      owners = [
        # Owners must be REAL users — they run membership reviews and the
        # ownership shows in audit ("admin" was a phantom placeholder). The
        # actual identity stays out of this public repo, same as the IdP
        # URLs: set TF_VAR_access_list_owner locally.
        { name = var.access_list_owner, description = "Platform lead" }
      ]
      grants = {
        roles = ["platform-dev-access", "dev-auto-access", "senior-dev-requester", "team-access"]
        # Cross-team dev breadth expressed through ABAC too: the IdP asserts
        # senior-devs' home team ("dev"); this grant adds "platform" so
        # team-access reaches both teams' dev nodes — mirroring
        # platform-dev-access's team=* intent, but visible/governable here.
        traits = {
          "team-name"     = ["platform"]
          "db_names"      = var.db_names_by_access_list["senior-devs"]
          "aws_role_arns" = var.aws_role_arns_by_access_list["senior-devs"]
        }
      }
    }
  })
}

resource "kubectl_manifest" "access_list_engineers" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "engineers"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "engineers"
      description = "Platform team: standing dev access, dev approvals, prod requests"
      type        = "scim"
      owners = [
        # Owners must be REAL users — they run membership reviews and the
        # ownership shows in audit ("admin" was a phantom placeholder). The
        # actual identity stays out of this public repo, same as the IdP
        # URLs: set TF_VAR_access_list_owner locally.
        { name = var.access_list_owner, description = "Platform lead" }
      ]
      grants = {
        # No standing editor (ZSP): reads via config-reader + auditor,
        # writes JIT via admin-requester → editor.
        roles = ["platform-dev-access", "dev-auto-access", "prod-readonly-access", "dev-reviewer", "prod-requester", "prod-reviewer", "auditor", "team-access", "config-reader", "admin-requester"]
        # Engineers hold standing dev-team roles (dev-auto-access,
        # platform-dev-access above), so the list also asserts the dev team
        # affiliation as a trait. Okta separately asserts the HOME team from
        # group membership (engineers=platform — okta repo scim.tf); Teleport
        # UNIONS the two at login: engineers get team-name=[platform, dev].
        # Identical values from both sides dedupe to one. Grant values are
        # literals, not expressions; applied at next login, never live.
        traits = {
          "team-name"     = ["dev"]
          "db_names"      = var.db_names_by_access_list["engineers"]
          "aws_role_arns" = var.aws_role_arns_by_access_list["engineers"]
        }
      }
    }
  })
}

# Non-SCIM identity sources get the SAME governance surface: a regular
# (owner-reviewed) access list with explicit membership and a recurring
# audit. Grants the engineers-equivalent bundle + both team affiliations
# (this IdP asserts no team-name trait). Membership is a runtime action:
#   tctl acl users add visiting-ses <user>
resource "kubectl_manifest" "access_list_visiting_ses" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "visiting-ses"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "visiting-ses"
      description = "SEs from the secondary IdP (no SCIM) — explicit membership, owner-reviewed quarterly"
      owners = [
        { name = var.access_list_owner, description = "Platform lead" }
      ]
      audit = {
        next_audit_date = "2026-11-20T00:00:00Z"
        recurrence = {
          frequency = "3months"
        }
      }
      # THE PROD BUNDLE WAS REMOVED 2026-09-27 — `prod-readonly-access`,
      # `prod-requester` and `prod-reviewer`. It was inherited from mirroring
      # presales' `engineers` list, where `prod` means demo prod resources.
      #
      # THIS CLUSTER HAS NO DEMO PROD RESOURCES. Since the `env: prod` retag
      # earlier today, the only things carrying that label are lgm and siem,
      # which are Chris's actual inference box and the SIEM holding the
      # estate's entire audit trail. So every prod grant here pointed at
      # personal infrastructure and at nothing else.
      #
      # REMOVING ONLY THE STANDING GRANT WOULD HAVE BEEN COSMETIC, which is
      # the part worth writing down. `prod-requester` can request `prod-access`
      # (full access, 4h, reason required) and `prod-reviewer` can approve that
      # same set. This cluster has NO access_monitoring_rules, so approval is
      # a human decision — and with both roles on one list, two visiting SEs
      # approve each other. Teleport blocks reviewing your own request, not
      # reviewing your colleague's. That two-person path to root-equivalent
      # access on the SIEM was strictly worse than the read-only grant that
      # was actually reported.
      #
      # Safe to do outright: the list has no members and there is no backing
      # Okta group for it, so nothing is being taken away from anyone today.
      # Everything else it grants is env=dev and unaffected.
      #
      # `engineers` still carries the same three roles. Left alone
      # deliberately: its only member is the estate owner's SSO identity.
      # The structural fix for both is to separate the personal machines on
      # `team` rather than on `env` — all four prod roles select
      # `team: var.prod_team` ("platform"), so retagging lgm and siem to a
      # different team value makes them unmatchable by the demo bundle while
      # keeping `env: prod`. That is a decision about the demo model, not a
      # cleanup, so it is in open-items rather than done here.
      grants = {
        roles = ["platform-dev-access", "dev-auto-access", "dev-reviewer", "auditor", "team-access", "config-reader", "admin-requester"]
        traits = {
          "team-name" = ["platform", "dev"]
          # Same bundle as engineers, so the same database scope. Without
          # this line phase 2 would silently strip every visiting SE's
          # database access, and the failure mode is an empty dropdown that
          # looks like the UI bug this change set exists to fix.
          "db_names"      = var.db_names_by_access_list["engineers"]
          "aws_role_arns" = var.aws_role_arns_by_access_list["visiting-ses"]
        }
      }
    }
  })
}

##################################################################################
# AGENT MANAGED UPDATES
##################################################################################
resource "kubectl_manifest" "autoupdate_config" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAutoupdateConfigV1"
    metadata = {
      name      = "autoupdate-config"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      tools = {
        mode = var.autoupdate_mode
      }
      agents = {
        mode     = var.autoupdate_mode
        strategy = "halt-on-error"
        schedules = {
          regular = [
            {
              name = "default"
              days = ["Mon", "Tue", "Wed", "Thu", "Fri"]
              # start_hour is UTC. 13:00 UTC = 08:00 CT: after the 07:45
              # cost-scheduler wake, before demo hours. The original 02:00 UTC
              # (21:00 CT) sat inside the nightly scale-down, so no agent —
              # cluster included — was ever awake for a scheduled rollout.
              start_hour = 13
            }
          ]
        }
      }
    }
  })
}

resource "kubectl_manifest" "autoupdate_version" {
  count = var.autoupdate_target_version != "" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAutoupdateVersionV1"
    metadata = {
      name      = "autoupdate-version"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      agents = {
        start_version  = var.autoupdate_start_version != "" ? var.autoupdate_start_version : var.autoupdate_target_version
        target_version = var.autoupdate_target_version
        schedule       = "regular"
        mode           = var.autoupdate_mode
      }
      tools = {
        target_version = var.autoupdate_target_version
      }
    }
  })
}

# The personal identity's grants, as an access list rather than roles hung off
# the SAML connector.
#
# The unified pattern above is that EVERY IdP maps only to base-user and real
# grants come from access lists. The Okta connector for this cluster was first
# written mapping `homelab` straight to roles, which works but puts the grant
# somewhere no review process looks. This is the same bundle expressed the way
# the rest of the cluster expresses grants: owner-reviewed, auditable, and
# visible in Identity Security alongside the others.
#
# Zero standing privilege, same as engineers: reads via config-reader +
# auditor, writes JIT through admin-requester -> editor (4h, reason required,
# auto-approved by demo-admin-jit in amr.tf).
#
# type = scim: membership arrives by Okta group push, so the `homelab` group
# must be added to Push Groups on the Okta app. Until it is, this list has no
# members and grants nobody anything.
# Kubernetes access for the personal identity.
#
# WHY A CR AND NOT THE PROVIDER (per ~/github/CLAUDE.md): the grant lives on
# access_list_homelab in this same file, which is operator-managed. Splitting
# the role into provider state and the grant into CR state would make the
# apply order across two backends fragile for no benefit.
#
# WHY THIS EXISTS AT ALL: the `access` preset grants
# kubernetes_groups: ['{{internal.kubernetes_groups}}'] -- a TEMPLATE. SCIM
# users carry no static traits, so it renders EMPTY (role templates reference:
# a missing variable renders empty rather than erroring). The result is the
# worst kind of half-working: kubernetes_labels '*':'*' means the cluster is
# visible and `tsh kube ls` succeeds, but with no group the Kubernetes API has
# no identity to authorise and discovery fails with NotFound -- which reads
# like a broken cluster, not a missing permission.
#
# Standing access is VIEWER only, matching zero-standing-privilege elsewhere
# here: editor-level kube comes through the existing JIT path, not by default.
resource "kubectl_manifest" "role_homelab_kube" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "homelab-kube"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "IAC: standing read-only Kubernetes access for the personal identity"
    }
    spec = {
      allow = {
        # A literal group, not a trait template -- that is the entire point.
        kubernetes_groups = ["teleport-prod-viewers"]
        kubernetes_labels = {
          env  = ["prod"]
          team = ["platform"]
        }
        kubernetes_resources = [
          { kind = "*", namespace = "*", name = "*", verbs = ["get", "list", "watch"] }
        ]
      }
    }
  })
}

# App access for the personal identity, replacing the `access` PRESET.
#
# WHY DROP `access`: it broke host user creation on EVERY node, cluster-wide.
# Measured 2026-09-21 -- `tsh ssh chris@siem` and `tsh ssh chris@dev-postgres`
# both failed with "Failed to launch: user: unknown user chris" even though
# homelab-ssh and platform-dev-access BOTH set create_host_user_mode: keep.
# Enumerating every node-matching role I held found exactly one without the
# option set:
#
#   access                 <unset>   node_labels {'*': '*'}   <-- poisons
#   dev-auto-access        keep      {env: dev, team: [dev, platform]}
#   homelab-ssh            keep      {env: home, team: platform}
#   platform-dev-access    keep      {env: dev, team: '*'}
#   prod-readonly-access   keep      {env: prod, team: platform}
#   team-access            keep      {env: dev, team: '{{external.team-name}}'}
#
# So the note in ~/github/CLAUDE.md is right: a matching role that leaves the
# mode UNSET cancels `keep` elsewhere, and `node_labels '*':'*'` means it
# matches everything. The roles reference documents how explicit values
# combine but is silent on unset, so this is empirical, not doc-backed.
#
# AND `access` WAS GIVING US ALMOST NOTHING. Every one of its grants is an
# `{{internal.*}}` template -- logins, db_users, db_names, kubernetes_groups,
# desktop logins -- and a SCIM user here carries no static traits, so they all
# render EMPTY. The only thing it actually provided was app visibility via
# app_labels '*':'*'. That is what this role replaces, scoped to the estate's
# own labels instead of a wildcard.
#
# BLAST RADIUS: `access` is granted by the `homelab` access list ONLY --
# engineers, devs, senior-devs and visiting-ses do not grant it (checked
# against every list on the cluster). So dropping it affects the personal
# identity and nobody else. Audit reads it also carried (event/session) are
# already covered by `auditor` and `config-reader` in the same grant.
#
# DELIBERATELY NO node_labels. This role must never be able to poison host
# user creation the way `access` did; app access needs no node match.
resource "kubectl_manifest" "role_homelab_apps" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "homelab-apps"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "IAC: app access for the personal identity (replaces the access preset)"
    }
    spec = {
      allow = {
        # grafana and ollama both carry env=home, team=platform.
        #
        # RETAGGED home -> prod, 2026-09-27. grafana and ollama now carry
        # env=prod, team=platform.
        #
        # Done as widen/flip/narrow rather than in one step: this selector
        # briefly read ["home", "prod"] (a label selector with several values
        # is an OR), the agents' own teleport.yaml files were flipped, and
        # only then was it narrowed back to one value. Doing it in the other
        # order leaves a window where the app carries `prod`, the role still
        # demands `home`, and the Grafana and Ollama apps disappear until the
        # apply lands. The intermediate apply costs nothing and removes the
        # window entirely.
        app_labels = {
          env  = ["prod"]
          team = ["platform"]
        }
      }
    }
  })
}

# SSH to the env=home machines for the personal identity.
#
# WHY A SEPARATE ROLE: no presales role matches env=home, because presales has
# no such nodes -- mirroring the `engineers` bundle onto access_list_homelab
# (below) fixes env=dev only. lgm and siem both carry env=home and were
# unreachable: "Failed to launch: user: unknown user dlg".
#
# Same CR-not-provider reasoning as role_homelab_kube above: the grant lives on
# an operator-managed access list in this file.
#
# TWO LOGINS ON PURPOSE, and the pair is deliberate:
#   dlg   -- already exists on lgm (uid 1000, zsh). Granting it means SSH to
#            lgm works whether or not host user creation does.
#   chris -- siem has NO login users at all, only root, so reaching it depends
#            on create_host_user_mode below actually creating one. Granting
#            root instead would be the easy answer and the wrong one.
#
# create_host_user_mode = keep, per the standing default. Note the residual
# uncertainty: the `access` preset also matches these nodes (node_labels
# '*':'*') and leaves the mode UNSET. The roles reference documents how
# explicit values combine ("logical AND ... if some roles specify both
# insecure-drop or keep it will evaluate to keep") but does NOT say what an
# unset value does among them. My own note here claimed "off or unset" both
# disable it; that is not doc-backed and should not be trusted. The `dlg`
# login is the hedge -- if unset does poison the node, lgm still works and
# only siem needs revisiting.
resource "kubectl_manifest" "role_homelab_ssh" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "homelab-ssh"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "IAC: SSH to the env=prod estate machines (lgm, siem) for the personal identity"
    }
    spec = {
      allow = {
        # Literals, not trait templates -- that is the whole lesson of
        # role_homelab_kube and of the data-plane breakage this repairs.
        # PER-USER, NOT A SHARED LIST. Fixed 2026-09-27 after Chris caught it:
        # this read `logins = ["dlg", "chris"]`, a LITERAL pair granted to
        # every member of the `homelab` access list, so either of the two
        # human identities on this cluster could open a session as the OTHER
        # one, on every env=prod/team=platform host. Two consequences,
        # and the second is the worse one:
        #
        #   1. It is mutual impersonation between the estate's two humans.
        #   2. It destroys attribution at the OS layer. The Teleport audit log
        #      still records who authenticated, but file ownership, ~/.bash_history,
        #      process owners, sudo entries and anything else the HOST records
        #      name an OS user who is not the person. A cluster built around
        #      zero standing privilege was handing out a shared account.
        #
        # `{{email.local(external.username)}}` takes the LOCAL PART of each
        # user's own username trait, so `sam@example.com` gets the login `sam`
        # and `bob@example.com` gets `bob`. Each identity gets exactly its own
        # login and nobody else's.
        #
        # WHY username AND NOT email, which is the trap the old comment was
        # right to fear. A missing trait renders EMPTY rather than erroring, so
        # the wrong template silently grants nothing. These SSO users carry
        # ONLY `username`:
        #     sam@example.com -> traits {username: [sam@example.com]}
        #     bob@example.com -> traits {username: [bob@example.com]}
        # (illustrative form; the real values are the two SSO identities)
        # There is no `email` trait at all, so
        # `{{email.local(external.email)}}` renders empty here. Verified
        # against `tctl get users` before this edit, not assumed.
        logins = ["{{email.local(external.username)}}"]

        # RETAGGED home -> prod, 2026-09-27. Same widen/flip/narrow sequence
        # as homelab-apps above. lgm and siem now carry env=prod.
        #
        # WHY THIS ROLE STILL EXISTS AFTER THE RETAG. Once lgm and siem carry
        # env=prod they are also matched by `prod-readonly-access`, which the
        # `homelab` list already grants, so this role looks redundant. It is
        # kept for two reasons: it is the SSH-specific grant that says what
        # these hosts are for, and it sets create_host_user_mode explicitly
        # rather than depending on another role to do it.
        #
        # The old note claimed the literal logins were the GUARANTEE against
        # trait templates rendering empty. Half right. The risk is real, and
        # the answer is to use a template that actually resolves and to check
        # that it does, not to hand every user a fixed list of everyone's
        # accounts. Failing closed on SSH is correct; failing open into someone
        # else's account is not.
        #
        # Checked before making this change: prod-readonly-access matches the
        # same node_labels, already grants
        # {{email.local(external.username)}}, and also sets
        # create_host_user_mode = keep, so nothing here depends on the literals
        # for either login or host-user creation.
        #
        # Checked before making this change: every role whose node_labels can
        # match env=prod/team=platform (prod-access, prod-access-mfa,
        # prod-auto-access, prod-readonly-access) sets
        # create_host_user_mode = keep, so the retag cannot reintroduce the
        # "one bad role poisons a host" failure that the `access` preset did.
        node_labels = {
          env  = ["prod"]
          team = ["platform"]
        }
      }
      options = {
        create_host_user_mode = "keep"
        # Safe to set broadly: both evaluate as the MOST RESTRICTIVE across a
        # user's roles, so this cannot widen anything granted elsewhere.
        client_idle_timeout     = "1h"
        disconnect_expired_cert = true

        # lock: strict — see role_prod_readonly_access for the full reasoning.
        # Aggregates across the user's whole role set ("strict wins in case of
        # conflict"), so it is not scoped to prod-labelled resources alone.
        lock = "strict"
      }
    }
  })
}

resource "kubectl_manifest" "access_list_homelab" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "homelab"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "homelab"
      description = "Personal identity — estate administration on this cluster"
      type        = "scim"
      owners = [
        { name = var.access_list_owner, description = "Estate owner" }
      ]
      audit = {
        next_audit_date = "2026-12-20T00:00:00Z"
        recurrence = {
          frequency = "6months"
        }
      }
      # DATA-PLANE ROLES ADDED 2026-09-21, mirroring presales' `engineers`
      # list (control-plane/eks/3-rbac/roles.tf). Before this the list granted
      # only control-plane roles, and SSH and database access were both
      # non-functional for the personal identity:
      #
      #   tsh ssh -> "Failed to launch: user: unknown user dlg"
      #   mysql   -> "Access denied for user 'dlg'@'localhost'"
      #   pg      -> 'role "dlg" does not exist', and NO database list at all
      #
      # Root cause is the same defect `homelab-kube` above was created to fix,
      # in three more dimensions. The `access` preset grants
      # logins/db_users/db_names as '{{internal.*}}' TEMPLATES; this user has
      # no such traits, so all three render EMPTY (a missing variable renders
      # empty, it does not error). node_labels '*':'*' still matches, so nodes
      # and databases are LISTED while being unusable -- the same
      # "half-working, reads like a broken cluster" failure documented above.
      #
      # platform-dev-access is what actually fixes it: env=dev / team=* covers
      # dev-postgres and dev-mysql, it carries create_host_user_mode=keep, and
      # its db_users include the LITERAL reader/writer that those databases
      # actually have (they are cert-authenticated; there is no 'dlg' user in
      # either engine, which is why connecting as dlg failed rather than being
      # a permissions problem).
      #
      # STILL NOT COVERED: env=home. lgm and siem carry env=home, and no
      # presales role matches that label because presales has no such nodes.
      # Mirroring alone therefore cannot fix SSH to those two; that needs a
      # homelab-scoped role in the shape of homelab-kube above.
      grants = {
        roles = [
          # control-plane grants. `access` was REMOVED 2026-09-21: it matched
          # every node with create_host_user_mode unset, which disabled host
          # user creation cluster-wide and made SSH fail with "unknown user"
          # despite two other roles setting keep. homelab-apps replaces the
          # only thing it actually provided (app visibility). See the role
          # definition above for the measurements.
          "auditor", "config-reader", "admin-requester",
          "homelab-kube", "homelab-apps",
          # env=home SSH (lgm, siem) -- not covered by any presales role
          "homelab-ssh",
          # data plane, mirroring presales `engineers`
          "platform-dev-access", "dev-auto-access", "prod-readonly-access",
          "team-access",
          # ENGINE-SCOPED DATABASE ACCESS, added 2026-09-27. These replace the
          # database half of platform-dev-access, which granted
          # db_names = ["{{external.db_names}}", "*"] against every env=dev
          # database. Two things that could not fix:
          #   * the `*` allowed any name, so the grant described nothing real;
          #   * db_names came from a PER-USER trait, so Postgres was offered
          #     `demo` (which does not exist there) and MySQL `postgres`.
          # Scoping by the `engine` label the databases already carry is the
          # only way the allowed NAME can depend on the DATABASE. Adding a dev
          # database of another engine needs a matching role, which fails
          # closed.
          "db-dev-postgres", "db-dev-mysql", "db-dev-mongodb",
          # PER-SESSION MFA GATE, added 2026-09-28. Grants nothing on its own
          # today: it matches only resources labelled
          # `teleport.dev/mfa: required`, and nothing carries that label yet, so
          # this line changes no access at all. `require_session_mfa` is a
          # LOGICAL OR across roles, so labelling one resource arms the prompt
          # for that resource and leaves everything else untouched. Defined in
          # mfa.tf with the reasoning.
          teleport_role.mfa_required.metadata.name,
          # access-request paths, same bundle
          "prod-requester", "prod-reviewer", "dev-reviewer",
        ]
        # REQUIRED, not decoration: team-access scopes node_labels to
        # team: '{{external["team-name"]}}'. Without the trait it renders
        # empty and the role grants nothing. presales sets this on the list
        # too ('dev' for engineers, 'platform' for senior-devs); the homelab
        # nodes are all team=platform, so platform is the value that matches.
        traits = {
          "team-name" = ["platform"]
          # SAME REASONING, for databases. The comment above records that pg
          # showed "NO database list at all" because db_names rendered empty
          # from an {{internal.*}} template. platform-dev-access fixed the
          # db_users half by carrying literal reader/writer, but db_names is
          # still `["{{external.db_names}}", "*"]`, so the wildcard is the
          # only thing granting access and the Web UI drops it from the
          # dropdown -- which is why the connect dialog is still empty.
          #
          # This is also the entry that stops phase 2 (removing "*") from
          # locking the estate owner out of every database. Adding it here
          # was not optional: this list is 13 roles and the personal
          # identity, and it is easy to miss when editing the four SCIM
          # tiers next to each other.
          "db_names"      = var.db_names_by_access_list["engineers"]
          "aws_role_arns" = var.aws_role_arns_by_access_list["homelab"]
        }
      }
    }
  })
}

##################################################################################
# ENGINE-SCOPED DATABASE ACCESS (replaces the wildcard + flat trait)
##################################################################################
#
# Added 2026-09-27, doing two things the previous arrangement could not:
#
#   * removes `*` from db_names ("phase 2"), so the grant names real databases
#     instead of asserting that anything is fine;
#   * makes the allowed NAME depend on the DATABASE rather than on the user,
#     which a trait fundamentally cannot do. `db_names` was granted as a flat
#     per-user trait [postgres, demo], so Postgres offered `demo` (which does
#     not exist there) and MySQL offered `postgres`. Offering a name that
#     cannot work is the same defect as the phantom `dlg` db_user fixed
#     earlier the same day, and it fails at the ENGINE, which reads as the
#     database being broken.
#
# The `engine` label is already on both databases (engine=postgres /
# engine=mysql), set by the self-database-lxc module, so this needs no
# relabelling.
#
# db_users and db_names are kept TOGETHER in each role on purpose. The database
# RBAC reference does not say whether the two combine across a user's roles or
# must both come from a single matching role. Rather than guess, each role is
# self-sufficient, which is correct under either reading.
#
# NOTE db_names is NOT enforced for MySQL by Teleport at all, so on mysql-dev
# the value below is what populates the Web UI dropdown rather than a control.
# On Postgres it is enforced and required.

locals {
  # Shared by both roles. `{{external.db_users}}` is kept so an access list can
  # still grant an extra user by trait; `reader` and `writer` are the
  # certificate subjects that actually exist in both engines.
  db_engine_users = ["{{external.db_users}}", "reader", "writer"]

  db_engine_labels = {
    env  = ["dev"]
    team = ["*"]
  }
}

resource "kubectl_manifest" "role_db_dev_postgres" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name      = "db-dev-postgres"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      # NOTE: description is silently DROPPED through an operator CR (it is not
      # a field on Kubernetes ObjectMeta). Kept for the yaml reader only; the
      # live role will report `description: None`. See ~/github/CLAUDE.md.
      description = "IAC: dev Postgres, real database names only"
    }
    spec = {
      allow = {
        db_labels = merge(local.db_engine_labels, { engine = ["postgres"] })
        db_users  = local.db_engine_users
        # The ONLY database on postgres-dev. `demo` is MySQL's and does not
        # exist here, which is exactly what this role stops offering.
        db_names = ["postgres"]
      }
      options = {
        # Matches the other database roles. `off` is correct: these engines use
        # named certificate subjects, nothing auto-provisions a user, and
        # offering one that nothing creates is the defect being fixed.
        create_db_user_mode     = "off"
        client_idle_timeout     = "1h"
        disconnect_expired_cert = true
        lock                    = "strict"
      }
    }
  })
}

# MONGODB, added 2026-09-28. This role is THE COST OF ENGINE SCOPING ARRIVING,
# exactly as recorded when db_names was scoped by engine: "a dev database of
# another engine now matches no role and gets no access until an engine-scoped
# role is added for it. That fails closed."
#
# It did fail closed. mongodb-dev registered correctly, the agent was healthy,
# and `tsh db ls` simply did not show it — which reads as a broken registration
# rather than a missing grant. That is the right direction to fail, and this is
# the step someone has to remember.
resource "kubectl_manifest" "role_db_dev_mongodb" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "db-dev-mongodb"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "IAC: dev MongoDB, real database names only"
    }
    spec = {
      allow = {
        db_labels = merge(local.db_engine_labels, { engine = ["mongodb"] })
        db_users  = local.db_engine_users
        # `demo` is the application database seeded by the provision script.
        # MongoDB enforces db_names, unlike MySQL, so this is a real control
        # here rather than only populating the Web UI dropdown.
        db_names = ["demo"]
      }
      options = {
        create_db_user_mode     = "off"
        client_idle_timeout     = "1h"
        disconnect_expired_cert = true
        lock                    = "strict"
      }
    }
  })
}

resource "kubectl_manifest" "role_db_dev_mysql" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportRoleV7"
    metadata = {
      name        = "db-dev-mysql"
      namespace   = data.kubernetes_namespace.teleport_cluster.metadata[0].name
      description = "IAC: dev MariaDB, real database names only"
    }
    spec = {
      allow = {
        db_labels = merge(local.db_engine_labels, { engine = ["mysql"] })
        db_users  = local.db_engine_users
        # `demo` is the application database on mysql-dev. Teleport does not
        # enforce db_names for MySQL, so this populates the Web UI dropdown
        # rather than restricting anything.
        db_names = ["demo"]
      }
      options = {
        create_db_user_mode     = "off"
        client_idle_timeout     = "1h"
        disconnect_expired_cert = true
        lock                    = "strict"
      }
    }
  })
}
