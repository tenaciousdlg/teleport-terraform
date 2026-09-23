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
  count = var.chrisdlg_saml_entity_descriptor != "" ? 1 : 0

  # A BARE `terraform apply` HERE USED TO DESTROY OKTA SSO. Verified 2026-09-21:
  # with TF_VAR_chrisdlg_saml_entity_descriptor unset, count collapses to 0 and
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
  #   export TF_VAR_chrisdlg_saml_entity_descriptor="$(terraform \
  #     -chdir=$HOME/github/okta output -raw chrisdlg_teleport_saml_metadata)"
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
    spec = {
      display = "Okta"
      acs     = "https://${var.proxy_address}:443/v1/webapi/saml/acs/okta"
      attributes_to_roles = [
        { name = "groups", value = "homelab", roles = ["base-user"] },
        { name = "groups", value = "engineers", roles = ["base-user"] },
        { name = "groups", value = "devs", roles = ["base-user"] },
        { name = "groups", value = "senior-devs", roles = ["base-user"] },
      ]
      entity_descriptor = var.chrisdlg_saml_entity_descriptor
    }
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
        db_labels = {
          env  = ["dev"]
          team = ["*"]
        }
        db_names       = ["{{external.db_names}}", "*"]
        db_users       = ["{{external.db_users}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}", "reader", "writer"]
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
        logins      = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}", "ubuntu", "ec2-user"]
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
        db_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        db_names       = ["{{external.db_names}}", "*"]
        db_users       = ["{{external.db_users}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}", "reader", "writer"]
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
        logins      = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}", "ubuntu", "ec2-user"]
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
        create_db_user                 = true
        create_db_user_mode            = "keep"
        create_desktop_user            = false
        create_host_user_mode          = "keep"
        create_host_user_default_shell = "/bin/bash"
        desktop_clipboard              = true
        desktop_directory_sharing      = true
        max_session_ttl                = "2h0m0s"
        pin_source_ip                  = false
        enhanced_recording             = ["command", "network"]
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
        logins      = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}", "ubuntu", "ec2-user"]
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
        logins      = ["{{external.logins}}", "{{email.local(external.username)}}", "{{email.local(external.email)}}", "ubuntu", "ec2-user"]
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
        db_labels = {
          env  = ["prod"]
          team = [var.prod_team]
        }
        db_names = ["*"]
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
          "db_names" = var.db_names_by_access_list["devs"]
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
          "team-name" = ["platform"]
          "db_names"  = var.db_names_by_access_list["senior-devs"]
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
          "team-name" = ["dev"]
          "db_names"  = var.db_names_by_access_list["engineers"]
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
      grants = {
        roles = ["platform-dev-access", "dev-auto-access", "prod-readonly-access", "dev-reviewer", "prod-requester", "prod-reviewer", "auditor", "team-access", "config-reader", "admin-requester"]
        traits = {
          "team-name" = ["platform", "dev"]
          # Same bundle as engineers, so the same database scope. Without
          # this line phase 2 would silently strip every visiting SE's
          # database access, and the failure mode is an empty dropdown that
          # looks like the UI bug this change set exists to fix.
          "db_names" = var.db_names_by_access_list["engineers"]
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
        app_labels = {
          env  = ["home"]
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
      description = "IAC: SSH to the env=home estate machines for the personal identity"
    }
    spec = {
      allow = {
        # Literals, not trait templates -- that is the whole lesson of
        # role_homelab_kube and of the data-plane breakage this repairs.
        logins = ["dlg", "chris"]
        node_labels = {
          env  = ["home"]
          team = ["platform"]
        }
      }
      options = {
        create_host_user_mode = "keep"
        # Safe to set broadly: both evaluate as the MOST RESTRICTIVE across a
        # user's roles, so this cannot widen anything granted elsewhere.
        client_idle_timeout     = "1h"
        disconnect_expired_cert = true
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
          "db_names" = var.db_names_by_access_list["engineers"]
        }
      }
    }
  })
}
