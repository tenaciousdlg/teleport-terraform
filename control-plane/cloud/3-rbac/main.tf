##################################################################################
# dlgdemo.teleport.sh RBAC: roles and Access Lists.
# Moved here 2026-10-13 from a root in ~/Documents (in no repo, local state
# only). Planned against the live tenant before the move: every role, list and
# member matched. The SAML connector and auth preference live in 2-teleport.
##################################################################################
terraform {
  # State in S3 in the SE AWS account (bucket made 2026-10-13: versioned,
  # SSE-S3, public access blocked). Credentials come from the shell's
  # AWS_PROFILE (the SSO profile); no profile is named here because its name
  # carries the account ID and this repo is public.
  backend "s3" {
    bucket       = "dlg-dlgdemo-teleport-terraform-state"
    key          = "control-plane/cloud/3-rbac/terraform.tfstate"
    region       = "us-east-2"
    encrypt      = true
    use_lockfile = true
  }
  required_providers {
    teleport = {
      source  = "terraform.releases.teleport.dev/gravitational/teleport"
      version = "~> 18.0"
    }
  }
}

provider "teleport" {
  addr = "${var.proxy_address}:443"
}

##################################################################################
# BASE ROLES
##################################################################################

# Base role with minimal permissions - used as a foundation for Access Lists
resource "teleport_role" "base_user" {
  version = "v7"

  metadata = {
    name        = "base-user"
    description = "Base authenticated user with minimal permissions"
  }

  spec = {
    options = {
      max_session_ttl    = "8h0m0s"
      enhanced_recording = ["command", "network"]
    }

    allow = {
      rules = [
        {
          resources = ["event"]
          verbs     = ["list", "read"]
        },
        {
          resources = ["session"]
          verbs     = ["read", "list"]
        }
      ]
    }
  }
}

##################################################################################
# GRANULAR PERMISSION ROLES
##################################################################################

# Development Environment Access
resource "teleport_role" "dev_environment_access" {
  version = "v7"
  metadata = {
    name        = "dev-environment-access"
    description = "Access to development tier resources"
  }

  spec = {
    allow = {
      # Application access
      app_labels = {
        tier = ["dev"]
        team = ["engineering"]
      }

      aws_role_arns = ["{{external.aws_dev_roles}}"]

      # Database access - mapped users
      db_labels = {
        tier = ["dev"]
        team = ["engineering"]
      }
      db_names = ["*"]
      db_users = ["{{external.db_users}}", "reader", "dev_user"]

      # Kubernetes access
      kubernetes_labels = {
        tier = ["dev"]
        team = ["engineering"]
      }
      kubernetes_groups = ["dev-users"]
      kubernetes_resources = [
        {
          kind      = "*"
          name      = "*"
          namespace = "dev"
          verbs     = ["get", "list", "watch", "create", "update", "patch", "delete"]
        }
      ]

      # Server access
      node_labels = {
        tier = ["dev"]
        team = ["engineering"]
      }
      logins = ["{{external.logins}}", "{{email.local(external.username)}}", "developer"]

      # Windows desktop access
      windows_desktop_labels = {
        tier = ["dev"]
        team = ["engineering"]
      }
      windows_desktop_logins = ["{{external.windows_logins}}", "DevUser"]
    }

    options = {
      max_session_ttl                = "8h0m0s"
      create_host_user_mode          = 3 # 3 = keep
      create_host_user_default_shell = "/bin/bash"

      # Disable DB auto-provisioning for this role
      create_db_user      = false
      create_db_user_mode = 1 # 1 = off

      desktop_clipboard         = true
      desktop_directory_sharing = true
      enhanced_recording        = ["command", "network"]
      pin_source_ip             = false
    }
  }
}

# Production Read-Only Access
resource "teleport_role" "prod_readonly_access" {
  version = "v7"
  metadata = {
    name        = "prod-readonly-access"
    description = "Read-only access to production resources"
  }

  spec = {
    allow = {
      app_labels = {
        tier = ["prod"]
        team = ["engineering"]
      }

      db_labels = {
        tier = ["prod"]
        team = ["engineering"]
      }
      db_names = ["*"]
      db_users = ["reader", "reporting", "{{external.readonly_db_user}}"]

      kubernetes_labels = {
        tier = ["prod"]
        team = ["engineering"]
      }
      kubernetes_groups = ["prod-viewers"]
      kubernetes_resources = [
        {
          kind      = "*"
          name      = "*"
          namespace = "prod"
          verbs     = ["get", "list", "watch"]
        }
      ]

      node_labels = {
        tier = ["prod"]
        team = ["engineering"]
      }
      logins = ["readonly", "{{external.readonly_login}}"]
    }

    options = {
      max_session_ttl       = "4h0m0s"
      create_host_user_mode = 1 # off

      # Explicitly disable DB auto-provisioning
      create_db_user      = false
      create_db_user_mode = 1 # off

      enhanced_recording = ["command", "network"]
    }
  }
}

# Production Full Access
resource "teleport_role" "prod_full_access" {
  version = "v7"
  metadata = {
    name        = "prod-full-access"
    description = "Full access to production resources"
  }

  spec = {
    allow = {
      # Application access
      app_labels = {
        tier = ["prod"]
      }

      # Database access - all users
      db_labels = {
        tier = ["prod"]
      }
      db_names = ["*"]
      db_users = ["{{external.db_users}}", "admin", "writer", "reader"]

      # Kubernetes access - full
      kubernetes_labels = {
        tier = ["prod"]
      }
      kubernetes_groups = ["system:masters", "prod-admins"]
      kubernetes_resources = [
        {
          kind      = "*"
          name      = "*"
          namespace = "*"
          verbs     = ["*"]
        }
      ]

      # Server access
      node_labels = {
        tier = ["prod"]
      }
      logins = ["{{external.logins}}", "root", "admin", "ec2-user", "ubuntu"]

      # Windows desktop access
      windows_desktop_labels = {
        tier = ["prod"]
      }
      windows_desktop_logins = ["{{external.windows_logins}}", "Administrator"]
    }

    options = {
      max_session_ttl       = "2h0m0s" # shorter for prod
      create_host_user_mode = 3        # keep

      # Explicitly disable DB auto-provisioning for prod
      create_db_user      = false
      create_db_user_mode = 1 # off

      desktop_clipboard         = true
      desktop_directory_sharing = true
      enhanced_recording        = ["command", "network"]

      # Require MFA for prod sessions
      require_session_mfa = 1 # 1 = SESSION
    }
  }
}

# Engineering Tools Access
resource "teleport_role" "engineering_tools_access" {
  version = "v7"

  metadata = {
    name        = "engineering-tools-access"
    description = "Access to engineering team tools"
  }

  spec = {
    allow = {
      app_labels = {
        team = ["engineering"]
      }
      db_labels = {
        team = ["engineering"]
      }
      db_names = ["*"]
      db_users = ["{{external.db_users}}", "engineer"]
    }

    options = {
      max_session_ttl = "8h0m0s"
    }
  }
}

##################################################################################
# ACCESS LISTS - TEAM STRUCTURE
##################################################################################

resource "teleport_access_list" "engineering_team" {
  header = {
    version = "v1"
    metadata = {
      name = "engineering-team"
    }
  }

  spec = {
    title       = "Engineering Team"
    description = "All members of the engineering organization"

    owners = [
      {
        name        = "admin"
        description = "Platform team admin"
      }
    ]

    # Very lightweight guardrail:
    # - Must at least be a Teleport user (base-user)
    # You *can* add a groups trait check here if you want to keep it aligned
    # with an IdP group, but we're intentionally not hard-tying it to Okta.
    membership_requires = {
      roles = [teleport_role.base_user.metadata.name]
    }

    # Team membership grants:
    # - base-user (if not already)
    # - engineering tools access
    grants = {
      roles = [
        teleport_role.base_user.metadata.name,
        teleport_role.engineering_tools_access.metadata.name
      ]
    }

    audit = {
      recurrence = {
        frequency    = 3 # every 3 months
        day_of_month = 1
      }
    }
  }
}

##################################################################################
# ACCESS LISTS - ENVIRONMENT ACCESS
##################################################################################

# Development Access List (static/terraform-managed membership)
# Dev environment access (Terraform-managed)
resource "teleport_access_list" "dev_environment" {
  header = {
    version = "v1"
    metadata = {
      name = "dev-environment-access"
    }
  }

  spec = {
    title       = "Development Environment Access"
    description = "Access to development tier resources for daily work"
    type        = "static" # Terraform manages membership

    owners = [
      {
        name        = "admin"
        description = "Platform team admin"
      }
    ]

    grants = {
      roles = [
        teleport_role.dev_environment_access.metadata.name
      ]
    }
  }
}

# Add engineering team list as a member of dev access
resource "teleport_access_list_member" "dev_access_engineering" {
  header = {
    version = "v1"
    metadata = {
      # upstream list (the "member")
      name = teleport_access_list.engineering_team.id
    }
  }

  spec = {
    # target list (the container)
    access_list     = teleport_access_list.dev_environment.id
    membership_kind = 2 # LIST membership
  }
}

# Production Read-Only Access List
resource "teleport_access_list" "prod_readonly" {
  header = {
    version = "v1"
    metadata = {
      name = "prod-readonly-access"
    }
  }

  spec = {
    title       = "Production Read-Only Access"
    description = "Read-only access to production for troubleshooting"
    # type omitted => default (UI/SCIM/tctl manage membership)

    owners = [
      {
        name        = "admin"
        description = "Platform team admin"
      },
      {
        # Engineering managers (represented by the team list)
        name            = teleport_access_list.engineering_team.id
        membership_kind = 2
        description     = "Engineering team managers"
      }
    ]

    # Light guardrail if you want one:
    membership_requires = {
      roles = [teleport_role.base_user.metadata.name]
    }

    grants = {
      roles = [
        teleport_role.prod_readonly_access.metadata.name
      ]
      traits = [
        {
          key    = "readonly_db_user"
          values = ["reporting"]
        },
        {
          key    = "readonly_login"
          values = ["viewer"]
        }
      ]
    }

    audit = {
      recurrence = {
        frequency    = 1 # monthly
        day_of_month = 1
      }
    }
  }
}

# Production Full Access List (On-call)
resource "teleport_access_list" "prod_oncall" {
  header = {
    version = "v1"
    metadata = {
      name = "prod-oncall-access"
    }
  }

  spec = {
    title       = "Production On-Call Access"
    description = "Full production access for on-call engineers. Auto-reviewed on a schedule."

    # type omitted => default; on-call rotation managed in UI/tctl/SCIM

    owners = [
      {
        name        = "admin"
        description = "Platform team admin"
      }
    ]

    membership_requires = {
      roles = [teleport_role.base_user.metadata.name]
    }

    grants = {
      roles = [
        teleport_role.prod_full_access.metadata.name
      ]
    }

    audit = {
      recurrence = {
        frequency    = 1 # monthly review
        day_of_month = 1
      }
      notifications = {
        start = "72h"
      }
    }
  }
}

# Break-Glass Emergency Access
resource "teleport_access_list" "break_glass" {
  header = {
    version = "v1"
    metadata = {
      name = "break-glass-emergency"
    }
  }

  spec = {
    title       = "Break-Glass Emergency Access"
    description = "Emergency access for critical incidents. All usage is audited."

    owners = [
      {
        name        = "admin"
        description = "Security team"
      }
    ]

    membership_requires = {
      roles = [teleport_role.base_user.metadata.name]
    }

    grants = {
      roles = [
        "access",
        "editor",
        teleport_role.prod_full_access.metadata.name
      ]
    }

    audit = {
      recurrence = {
        frequency    = 1 # review monthly
        day_of_month = 15
      }
    }
  }
}

##################################################################################
# ACCESS REQUEST ROLES
##################################################################################

# Requester for temporary production access
resource "teleport_role" "prod_access_requester" {
  version = "v7"
  metadata = {
    name        = "prod-access-requester"
    description = "Can request temporary production read-only access"
  }

  spec = {
    allow = {
      request = {
        roles           = [teleport_role.prod_readonly_access.metadata.name]
        search_as_roles = [teleport_role.prod_readonly_access.metadata.name]
        max_duration    = "8h"

        claims_to_roles = [
          {
            claim = "reason"
            value = "*"
            roles = [teleport_role.prod_readonly_access.metadata.name]
          }
        ]

        # Simple policy: one approval is enough when they request prod readonly
        thresholds = [
          {
            approve = 1
            deny    = 1
            filter  = "contains(request.roles, \"prod-readonly-access\")"
          }
        ]
      }
    }
  }
}

# Reviewer role for access requests
resource "teleport_role" "access_reviewer" {
  version = "v7"
  metadata = {
    name        = "access-reviewer"
    description = "Can review and approve access requests"
  }

  spec = {
    allow = {
      review_requests = {
        roles = [
          teleport_role.prod_readonly_access.metadata.name,
          teleport_role.prod_full_access.metadata.name
        ]

        preview_as_roles = [
          teleport_role.prod_readonly_access.metadata.name,
          teleport_role.prod_full_access.metadata.name
        ]

        # No 'where' expression here for now; earlier attempts used unsupported fields.
        # If you want to gate reviewers later, we can add a predicate only referencing
        # reviewer.roles / reviewer.traits / request.roles / request.reason / annotations.
      }
    }
  }
}
