output "viewer_service_account" {
  description = "Target service account users assume (wire into role gcp_service_accounts)"
  value       = google_service_account.viewer.email
}

output "agent_service_account" {
  description = "Controlling service account attached to the agent VM"
  value       = google_service_account.agent.email
}
