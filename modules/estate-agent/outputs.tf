output "rendered_config" {
  description = "The rendered /etc/teleport.yaml. Diff this against the live file BEFORE the first apply — that is the whole point of adopting a running agent rather than building a new one."
  value       = local.rendered
}

output "config_sha256" {
  description = "Hash of the rendered config. Matches null_resource.config's `config` trigger, so a changed hash is what causes a re-delivery."
  value       = sha256(local.rendered)
}

output "backup_path" {
  description = "Where this render's pre-write backup lands on the host."
  value       = "/etc/teleport.yaml.bak-${local.backup_suffix}"
}
