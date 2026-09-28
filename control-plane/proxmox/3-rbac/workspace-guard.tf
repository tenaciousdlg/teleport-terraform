##################################################################################
# WORKSPACE GUARD
##################################################################################
#
# WHY THIS EXISTS, AND IT IS A NEAR MISS RATHER THAN A THEORY. `terraform.tfvars`
# is AUTO-LOADED by terraform, and in this layer it still carries the DESTROYED
# `teleport.chrisdlg.com` values while the active workspace is `heronwright`. So
# running `terraform plan` WITHOUT `-var-file=heronwright.tfvars` produced a
# clean-looking plan -- "0 to add, 4 to change, 0 to destroy" -- that would have:
#
#   * pointed the Okta SAML connector's ACS URL back at teleport.chrisdlg.com,
#     which breaks SSO login for everyone, and
#   * replaced the terraform bot's live `initial_public_key` with the dead
#     chrisdlg-era key, which locks terraform out of Teleport entirely.
#
# Caught on 2026-09-28 only by reading the diffs of two resources the change in
# hand did not author. NOTHING IN THE PLAN SAID "WRONG CLUSTER": there were no
# destroys, no replacements, and no warnings. `proxy_address` has no default, so
# the omission could not surface as a missing-variable error either -- the
# auto-loaded file answered for it.
#
# `terraform.tfvars` is GITIGNORED and untracked, so it is deliberately NOT
# renamed or deleted here; the estate rule is to never delete untracked state.
# The guard is the fix instead. A `lifecycle precondition` FAILS the run, where
# a `check` block would only emit a warning that is easy to scroll past.
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
