output "identity_resource_id" {
  description = "Managed identity resource ID users assume (wire into role azure_identities)"
  value       = azurerm_user_assigned_identity.teleport_azure.id
}
