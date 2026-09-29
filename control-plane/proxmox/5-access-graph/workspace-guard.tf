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
# THIS ONE IS ANCHORED DIFFERENTLY, AND IT IS THE STRONGEST OF THE THREE.
# This layer has neither `proxy_address` nor a hostname of its own -- it reads
# everything from 2-teleport's remote state. So rather than comparing a variable
# against a map, it asserts that the REMOTE STATE IT IS ABOUT TO BUILD AGAINST
# belongs to the workspace selected here.
#
# That catches a failure the other two cannot: a workspace mismatch where the
# remote state path resolves to a DIFFERENT cluster's outputs. This layer pins
# that cluster's host CA in `host-ca.pem`, and a mismatch there is what made
# Access Graph return an empty 404 with `JSON.parse: unexpected end of data` --
# a symptom that appears only in the Web UI while both pods read Running.
locals {
  expected_cluster_by_workspace = {
    heronwright = "teleport.heronwright.com"
  }
}

resource "terraform_data" "workspace_guard" {
  input = "${terraform.workspace}:${data.terraform_remote_state.teleport.outputs.cluster_name}"

  lifecycle {
    precondition {
      condition     = data.terraform_remote_state.teleport.outputs.cluster_name == lookup(local.expected_cluster_by_workspace, terraform.workspace, "<unmapped workspace>")
      error_message = <<-EOT
        The teleport remote state belongs to a different cluster than this
        workspace expects.

          workspace        : ${terraform.workspace}
          expected cluster : ${lookup(local.expected_cluster_by_workspace, terraform.workspace, "<unmapped workspace -- add it to local.expected_cluster_by_workspace>")}
          remote state says: ${data.terraform_remote_state.teleport.outputs.cluster_name}

        Applying now would build Access Graph against one cluster while pinning
        another cluster's host CA. Fix the workspace selection first:

          terraform workspace select heronwright
          terraform plan -var-file=heronwright.tfvars
      EOT
    }
  }
}
