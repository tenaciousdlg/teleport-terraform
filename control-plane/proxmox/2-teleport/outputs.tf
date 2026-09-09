##################################################################################
# OUTPUTS
##################################################################################
# Adapted from eks/2-teleport/outputs.tf — dropped the DynamoDB/S3/EKS outputs
# (standalone mode). Added the klipper LoadBalancer IP so you can confirm the
# cloudflared origin (teleport.chrisdlg.com -> this IP:443).

# The Teleport proxy Service. With klipper (servicelb) its EXTERNAL-IP is the
# VM's own IP — that is what cloudflared points at.
data "kubernetes_service" "teleport_cluster" {
  depends_on = [helm_release.teleport_cluster]
  metadata {
    name      = helm_release.teleport_cluster.name
    namespace = helm_release.teleport_cluster.namespace
  }
}

output "teleport_url" {
  description = "Teleport public URL (served via Cloudflare edge)"
  value       = "https://${var.proxy_address}"
}

output "teleport_version" {
  description = "Deployed Teleport version"
  value       = var.teleport_version
}

output "cluster_name" {
  description = "Teleport cluster name"
  value       = var.proxy_address
}

output "loadbalancer_service_ip" {
  description = "klipper-assigned Service IP (the cloudflared origin target on :443)"
  value       = try(data.kubernetes_service.teleport_cluster.status[0].load_balancer[0].ingress[0].ip, "pending")
}

output "certificate_status" {
  description = "Commands to check certificate status"
  value = {
    check_certificate   = "kubectl describe certificate teleport-tls -n teleport-cluster"
    check_secret        = "kubectl describe secret teleport-tls -n teleport-cluster"
    cert_manager_logs   = "kubectl logs -n cert-manager deployment/cert-manager"
    certificate_details = "kubectl get certificate -n teleport-cluster teleport-tls -o yaml"
  }
}
