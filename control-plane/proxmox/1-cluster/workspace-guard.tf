##################################################################################
# WORKSPACE GUARD
##################################################################################
#
# ADDED 2026-09-29, and the reason is a task about to be run rather than a
# theory. The `.terraform/` sweep deletes `.terraform/environment`, which is
# where the SELECTED WORKSPACE lives. Five layers here hold
# `workspace=heronwright`; lose that and the next plan runs against `default`,
# which auto-loads the gitignored `terraform.tfvars` still describing the
# DESTROYED chrisdlg cluster. On 2026-09-28 that combination produced a plan
# reporting "0 to destroy" while intending to point the SAML ACS URL at the dead
# host and overwrite the terraform bot's live public key.
#
# 2-teleport and 3-rbac already had this. This layer did not, so the sweep was
# only safe if whoever ran it remembered to re-select afterwards. A
# `lifecycle precondition` FAILS the run; a `check` block would only warn.
#
# ANCHORED ON container_hostname, not proxy_address. This layer builds the
# container and has no idea what the Teleport address is, so the hostname is the
# only cluster-identifying value it holds.
locals {
  expected_hostname_by_workspace = {
    heronwright = "heronwright-k3s"
  }
}

resource "terraform_data" "workspace_guard" {
  input = "${terraform.workspace}:${var.container_hostname}"

  lifecycle {
    precondition {
      condition     = var.container_hostname == lookup(local.expected_hostname_by_workspace, terraform.workspace, "<unmapped workspace>")
      error_message = <<-EOT
        container_hostname does not match the active terraform workspace.

          workspace    : ${terraform.workspace}
          expected     : ${lookup(local.expected_hostname_by_workspace, terraform.workspace, "<unmapped workspace -- add it to local.expected_hostname_by_workspace>")}
          actually got : ${var.container_hostname}

        The usual causes are a MISSING -var-file, or a workspace selection lost
        to the .terraform sweep. Either way:

          terraform workspace select heronwright
          terraform plan -var-file=heronwright.tfvars
      EOT
    }
  }
}
