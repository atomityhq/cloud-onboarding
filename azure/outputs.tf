output "service_principal_object_id" {
  description = "Object ID of Atomity's Service Principal in your tenant. Use it for any role assignments you make by hand."
  value       = azuread_service_principal.atomity.object_id
}

# Nothing has to be pasted into Atomity: the wizard already has these values.
# Compare this output with the Connect step before validating.
output "connection_details" {
  description = "Everything Atomity needs for the connection."
  value = {
    tenant_id                   = var.tenant_id
    application_id              = azuread_service_principal.atomity.client_id
    service_principal_object_id = azuread_service_principal.atomity.object_id
    storage_account             = var.storage_account_name
    container                   = var.container_name
    root_folder_path            = local.root_folder_path
    scope                       = var.scope_mode
    inventory_scope             = local.inventory_scope_label
    export_name                 = var.export_name
    export_scope                = local.billing_scope
    export_id                   = azapi_resource.focus_export.id
    access_level                = "read_only_rbac"
  }
}
