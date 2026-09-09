# 1-cluster/outputs.tf
#
# The downstream layers (2-teleport, 3-rbac, 4-plugins) read these via
# terraform_remote_state (local backend) and wire the kubernetes/helm/kubectl
# providers with explicit client-cert auth — NO exec plugin (k3s issues the
# admin client cert; there is no cloud IdP token to fetch).
#
# CONTRACT: kube_host / cluster_ca_certificate / client_certificate / client_key
# are consumed verbatim by 2/3/4-*. They are IDENTICAL to the VM version — the
# rework only changed the compute substrate (VM -> privileged LXC), not these.

locals {
  # yamldecode of k3s.yaml. try() keeps `terraform plan` working before the
  # kubeconfig has been fetched (data.local_file would otherwise be empty).
  _kubeconfig = try(yamldecode(data.local_file.kubeconfig.content), null)
}

output "container_ip" {
  description = "Static IPv4 of the k3s LXC container (also the klipper LoadBalancer IP and the cloudflared origin)"
  value       = var.container_ip
}

output "kube_host" {
  description = "Kubernetes API server URL"
  value       = local.kube_host
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA (base64decode before handing to a provider)"
  value       = try(local._kubeconfig["clusters"][0]["cluster"]["certificate-authority-data"], null)
}

output "client_certificate" {
  description = "Base64-encoded admin client certificate"
  value       = try(local._kubeconfig["users"][0]["user"]["client-certificate-data"], null)
}

output "client_key" {
  description = "Base64-encoded admin client key"
  value       = try(local._kubeconfig["users"][0]["user"]["client-key-data"], null)
  sensitive   = true
}

output "kubeconfig_path" {
  description = "Local path to the fetched, server-rewritten kubeconfig"
  value       = local.kubeconfig_local
}

output "fetch_kubeconfig_command" {
  description = "Manual fallback if the automatic fetch can't run — produces ./kubeconfig via the Proxmox node, then re-apply this layer"
  value       = "ssh ${local.node_ssh} 'pct exec ${proxmox_virtual_environment_container.k3s.vm_id} -- cat /etc/rancher/k3s/k3s.yaml' | sed 's#https://127.0.0.1:6443#${local.kube_host}#g' > ${local.kubeconfig_local}"
}
