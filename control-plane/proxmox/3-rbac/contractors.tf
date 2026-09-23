# contractors.tf — the external-contractor tier.
#
# WHY A SEPARATE TIER AND NOT "put them in devs".
# devs grants dev-access, which carries db_users = [..., "reader", "writer"].
# A contractor inheriting `writer` on demo databases is the kind of thing that
# is obvious in hindsight and invisible in a group membership screen. The
# tier exists so that "who is external" is answerable from the access list
# alone rather than by reading four role definitions.
#
# WHAT IS DIFFERENT ABOUT IT, deliberately:
#   - read-only database access (contractor-db-readonly below), never writer
#   - no requester roles, so no path to prod even via approval
#   - a MONTHLY access review, against 3-monthly for visiting-ses
#   - one database, from var.db_names_by_access_list["contractors"]
#
# MEMBERSHIP IS NOT SET HERE. type = "scim" means Okta owns it: add the user
# to the `contractors` group in ~/github/okta (groups.tf) and SCIM pushes it.
# Nothing in this file needs to change to add or remove a contractor.

# ── The read-only database role ───────────────────────────────────────────────
#
# ON THE PROVIDER, NOT A CR, per the repo default that Teleport-native
# resources go on the Teleport provider and only bootstrap stays on the
# operator. There is precedent in this exact layer: agents.tf already manages
# teleport_provision_token this way, and providers.tf already declares
# provider "teleport" {}. It is a NEW resource, so none of the
# delete-to-convert risk applies.
#
# Pre-flight for any plan touching this file:
#   source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv teleport
resource "teleport_role" "contractor_db_readonly" {
  version = "v7"
  metadata = {
    name = "contractor-db-readonly"
    # IAC: prefix so the web UI and `tctl get roles` show at a glance that
    # this is terraform-managed. Only expressible on the provider -- a CR
    # silently drops metadata.description.
    description = "IAC: External contractors — read-only database access, no writer, no prod path"
    labels = {
      env  = "dev"
      team = "contractor"
      role = "database"
    }
  }

  spec = {
    allow = {
      # Dev databases only. Explicitly NOT env: prod.
      db_labels = {
        "env" = ["dev"]
      }

      # Scope comes from the access list's db_names trait grant. No "*"
      # here even in phase 1: this role is new, so there is no existing
      # access to preserve and nothing to migrate.
      db_names = ["{{external.db_names}}"]

      # `reader` only. dev-access grants reader AND writer; that is the
      # single most important difference in this file.
      db_users = ["reader"]
    }

    options = {
      # Contractors are the population most worth re-verifying mid-session.
      max_session_ttl = "8h"
    }
  }
}

# ── The access list ───────────────────────────────────────────────────────────
#
# A CR rather than teleport_access_list, and this is the one place the repo
# default is deliberately NOT followed. Reason: its four siblings (everyone,
# devs, senior-devs, engineers) are CRs, and an access list carries runtime
# membership that SCIM populates. Splitting one member of a governed set onto
# a second management path buys nothing and makes "show me every tier" a
# two-command question. The role above is new and standalone, so it takes the
# provider; this joins an existing set, so it matches the set.
resource "kubectl_manifest" "access_list_contractors" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessList"
    metadata = {
      name      = "contractors"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      title       = "contractors"
      description = "External contractors — read-only dev database access, monthly review"
      type        = "scim"
      owners = [
        { name = var.access_list_owner, description = "Platform lead" }
      ]
      audit = {
        next_audit_date = "2026-10-22T00:00:00Z"
        # Monthly, against 3months for visiting-ses. External access is the
        # kind that outlives the engagement precisely because nobody is
        # reminded to look at it.
        recurrence = {
          frequency = "1month"
        }
      }
      grants = {
        # team-access gives SSH to their team's dev nodes, scoped by the
        # team-name trait below. No dev-requester, no prod-requester: there
        # is no approval path out of this tier on purpose.
        roles = ["contractor-db-readonly", "team-access"]
        traits = {
          # The Okta side asserts no team for contractors (scim.tf maps them
          # to "dev" so team-access resolves); granting it here too is
          # harmless, the two UNION and dedupe.
          "team-name" = ["dev"]
          "db_names"  = var.db_names_by_access_list["contractors"]
        }
      }
    }
  })

  depends_on = [teleport_role.contractor_db_readonly]
}
