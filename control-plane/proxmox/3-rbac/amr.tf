# Access Monitoring Rules — auto-approval for the demo JIT flows.
#
# ADOPTED INTO IaC 2026-08-20: demo-prodaccess previously existed only as an
# ad-hoc tctl-created resource. The operator refuses to adopt resources it
# doesn't own — on first apply, if the CR status reports an ownership
# conflict, delete the live rule once and let the operator recreate it:
#   tctl rm access_monitoring_rule/demo-prodaccess
#
# Condition-language gotchas (verified on 18.10.x):
# - contains()/contains_all()/contains_any() take SETS; request_reason is a
#   string — only exact equality works on it, and regexp over set() wraps
#   validate but silently never match.
# - The owner identity is parameterized (TF_VAR_access_list_owner) — org
#   emails stay out of this public repo (gitleaks-enforced).

resource "kubectl_manifest" "amr_demo_prodaccess" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessMonitoringRuleV1"
    metadata = {
      name      = "demo-prodaccess"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      subjects      = ["access_request"]
      desired_state = "reviewed"
      # Requested roles must be a subset of the prod ladder (note:
      # prod-access-mfa is deliberately absent — requesting it stays pending
      # for the human-approval demo beat), and the requester must be the
      # owner. Reason is enforced by prod-requester, not matched here.
      condition = "contains_all(set(\"prod-access\", \"prod-auto-access\", \"prod-readonly-access\"), access_request.spec.roles) && contains_any(user.traits[\"username\"], set(\"${var.access_list_owner}\"))"
      automatic_review = {
        integration = "builtin"
        decision    = "APPROVED"
      }
    }
  })
}

# JIT editor: the ZSP counterpart to dropping standing editor from the
# engineers list. Editor-only requests from the owner auto-approve; anyone
# else's editor request waits for a human reviewer.
resource "kubectl_manifest" "amr_demo_admin_jit" {
  yaml_body = yamlencode({
    apiVersion = "resources.teleport.dev/v1"
    kind       = "TeleportAccessMonitoringRuleV1"
    metadata = {
      name      = "demo-admin-jit"
      namespace = data.kubernetes_namespace.teleport_cluster.metadata[0].name
    }
    spec = {
      subjects      = ["access_request"]
      desired_state = "reviewed"
      condition     = "contains_all(set(\"editor\"), access_request.spec.roles) && contains_any(user.traits[\"username\"], set(\"${var.access_list_owner}\"))"
      automatic_review = {
        integration = "builtin"
        decision    = "APPROVED"
      }
    }
  })
}
