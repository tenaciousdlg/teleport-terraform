##################################################################################
# WORKSPACE GUARD
##################################################################################
#
# ADDED 2026-09-29 alongside the ones in 1-cluster and 5-access-graph, for the
# `.terraform/` sweep: deleting `.terraform/environment` loses the selected
# workspace, and five layers here hold `workspace=heronwright`.
#
# BUT THIS LAYER WAS NEVER EXPOSED TO THE VAR-FILE HALF OF THAT HAZARD, and
# saying so matters more than having the guard. Measured 2026-09-29: this
# layer's `proxy_address` has NO DEFAULT and is NOT in its auto-loaded
# `terraform.tfvars`, so running without `-var-file` fails loudly with
#
#   Error: No value for required variable
#
# rather than planning silently against the dead cluster. That is exactly what
# 2-teleport, 3-rbac and 1-cluster could not do -- their values ARE in the
# auto-loaded file, which answers for the missing flag. 1-cluster's guard fired
# on first test and showed `container_hostname = teleport-k3s`, the destroyed
# cluster's container.
#
# So what this guard actually buys here is narrower: it catches a WRONG
# workspace with a var-file present, and an unmapped workspace. Worth one
# resource, and not the same protection it provides elsewhere.
#
# A `lifecycle precondition` FAILS the run; a `check` block would only warn.
locals {
  expected_proxy_by_workspace = {
    heronwright = "teleport.heronwright.com"
    # Destroyed 2026-09-27. Kept so the map describes reality rather than only
    # the workspace that still matters.
    default = "teleport.chrisdlg.com"
  }
}

resource "terraform_data" "workspace_guard" {
  input = "${terraform.workspace}:${var.proxy_address}"

  lifecycle {
    precondition {
      condition     = var.proxy_address == lookup(local.expected_proxy_by_workspace, terraform.workspace, "<unmapped workspace>")
      error_message = <<-EOT
        proxy_address does not match the active terraform workspace.

          workspace     : ${terraform.workspace}
          expected      : ${lookup(local.expected_proxy_by_workspace, terraform.workspace, "<unmapped workspace -- add it to local.expected_proxy_by_workspace>")}
          actually got  : ${var.proxy_address}

        The usual cause is a MISSING -var-file. terraform.tfvars is auto-loaded
        and still describes the destroyed chrisdlg cluster, so run:

          source ~/github/teleport-zsh/lib/tfenv.zsh && tfenv heronwright
          . ./idp-env.sh
          terraform plan -var-file=heronwright.tfvars

        Note tfenv takes `heronwright`, NOT `teleport`: it derives its tbot
        config name from the cluster's FIRST DNS LABEL, and both clusters are
        `teleport.*`, so `tfenv teleport` selects the DEAD cluster's config.
      EOT
    }
  }
}
