locals {
  # --- Scopes ---------------------------------------------------------------
  management_group_scope = var.management_group_id == null ? null : "/providers/Microsoft.Management/managementGroups/${var.management_group_id}"
  billing_scope          = "/providers/Microsoft.Billing/billingAccounts/${var.billing_account_id}"

  # Where Reader is granted. One entry per scope.
  #   management_group: a single assignment on the root management group.
  #   subscription:     one assignment per listed subscription. An empty list
  #                     assigns nothing (Atomity auto-discovers what it can read).
  subscription_scopes = {
    for s in var.subscription_ids : lower(trimspace(s)) => "/subscriptions/${lower(trimspace(s))}"
  }

  reader_scopes = (
    var.scope_mode == "management_group"
    ? { management_group = local.management_group_scope }
    : local.subscription_scopes
  )

  # What the wizard shows as "Inventory + metrics scope".
  inventory_scope_label = (
    var.scope_mode == "management_group"
    ? local.management_group_scope
    : (length(local.subscription_scopes) == 0 ? "Auto-discover" : join(", ", keys(local.subscription_scopes)))
  )

  # --- Storage account --------------------------------------------------------
  storage_account_id = (
    var.storage_account_id != null
    ? var.storage_account_id
    : data.azurerm_resources.storage[0].resources[0].id
  )

  # Cost Management Exports must be registered on the subscription that hosts
  # the destination storage account (not necessarily the export's own scope).
  storage_subscription_id = split("/", local.storage_account_id)[2]

  # The wizard may write root_folder_path = "". Treat that the same as unset.
  root_folder_path = var.root_folder_path == null ? null : nullif(trimspace(var.root_folder_path), "")
}

# ---------------------------------------------------------------------------
# Step 1: tenant consent
#
# Creating the Service Principal for Atomity's multi-tenant app is what the
# admin consent link does in the portal. It grants no permissions by itself.
# use_existing adopts the Service Principal if the consent link was already used.
# ---------------------------------------------------------------------------

resource "azuread_service_principal" "atomity" {
  client_id    = var.atomity_client_id
  use_existing = true
}

# Cross-variable validation (variable blocks cannot reference each other
# before Terraform 1.9, and this module supports 1.5.7+).
resource "terraform_data" "validate_inputs" {
  lifecycle {
    precondition {
      condition     = var.scope_mode != "management_group" || var.management_group_id != null
      error_message = "management_group_id is required when scope_mode = \"management_group\"."
    }
  }
}

check "subscription_scope_has_targets" {
  assert {
    condition     = var.scope_mode != "subscription" || length(var.subscription_ids) > 0
    error_message = "scope_mode = subscription with an empty subscription_ids list assigns no Reader role. Atomity will only see subscriptions where Reader was already granted."
  }
}

# ---------------------------------------------------------------------------
# Step 2: read-only RBAC
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "reader" {
  for_each = local.reader_scopes

  depends_on = [terraform_data.validate_inputs]

  scope                = each.value
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.atomity.object_id
  principal_type       = "ServicePrincipal"

  # The Service Principal was only just created, so Entra may not have
  # replicated it yet. Skipping the lookup avoids spurious "not found" errors.
  skip_service_principal_aad_check = true
}

data "azurerm_resources" "storage" {
  count = var.storage_account_id == null ? 1 : 0

  name = var.storage_account_name
  type = "Microsoft.Storage/storageAccounts"

  lifecycle {
    postcondition {
      condition     = length(self.resources) == 1
      error_message = "Storage account '${var.storage_account_name}' was not found in the current subscription. Set subscription_id, or pass storage_account_id."
    }
  }
}

resource "azurerm_role_assignment" "storage_blob_reader" {
  scope                = local.storage_account_id
  role_definition_name = "Storage Blob Data Reader"
  principal_id         = azuread_service_principal.atomity.object_id
  principal_type       = "ServicePrincipal"

  skip_service_principal_aad_check = true

  lifecycle {
    precondition {
      condition     = endswith(lower(local.storage_account_id), lower("/storageAccounts/${var.storage_account_name}"))
      error_message = "storage_account_id does not point at storage account '${var.storage_account_name}'."
    }
  }
}

# ---------------------------------------------------------------------------
# Step 3: FOCUS cost export
# ---------------------------------------------------------------------------

# POSTs to .../providers/Microsoft.CostManagementExports/register. Registration
# is idempotent. It is an action rather than azurerm_resource_provider_registration
# on purpose: that resource unregisters the provider on destroy, which could
# break other exports in the customer's subscription.
resource "azapi_resource_action" "register_exports_rp" {
  type        = "Microsoft.Resources/providers@2021-04-01"
  resource_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.CostManagementExports"
  action      = "register"
  method      = "POST"
}

# Registration is asynchronous.
resource "time_sleep" "after_rp_registration" {
  depends_on      = [azapi_resource_action.register_exports_rp]
  create_duration = "30s"
}

# Exports require recurrencePeriod.from to be in the future. time_static pins
# the timestamp at first apply so later plans show no diff.
resource "time_static" "export_start" {}

resource "azapi_resource" "focus_export" {
  type      = "Microsoft.CostManagement/exports@2025-03-01"
  name      = var.export_name
  parent_id = local.billing_scope

  # Provider schema can lag behind the API (FocusCost, Parquet, snappy).
  schema_validation_enabled = false

  body = {
    properties = {
      format                = "Parquet"
      compressionMode       = "snappy"
      partitionData         = true
      dataOverwriteBehavior = var.data_overwrite_behavior

      definition = {
        type      = "FocusCost"
        timeframe = "MonthToDate"
        dataSet = {
          granularity = "Daily"
          configuration = {
            dataVersion = var.focus_dataset_version
          }
        }
      }

      deliveryInfo = {
        destination = {
          type           = "AzureBlob"
          resourceId     = local.storage_account_id
          container      = var.container_name
          rootFolderPath = local.root_folder_path # null is omitted
        }
      }

      schedule = {
        status     = "Active"
        recurrence = "Daily"
        recurrencePeriod = {
          from = timeadd(time_static.export_start.rfc3339, "24h")
          to   = "2099-12-31T00:00:00Z"
        }
      }
    }
  }

  depends_on = [
    time_sleep.after_rp_registration,
    azurerm_role_assignment.storage_blob_reader,
  ]
}

# Optional: run once now so files appear sooner than the first schedule tick.
resource "azapi_resource_action" "run_export_now" {
  count = var.run_export_now ? 1 : 0

  type        = "Microsoft.CostManagement/exports@2025-03-01"
  resource_id = azapi_resource.focus_export.id
  action      = "run"
  method      = "POST"
}
