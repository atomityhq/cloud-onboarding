variable "tenant_id" {
  type        = string
  description = "Your Entra tenant ID, shown in the Atomity onboarding wizard."

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.tenant_id))
    error_message = "tenant_id must be a GUID, like 8d65815f-a5b6-402f-9298-045155da7d74."
  }
}

variable "scope_mode" {
  type        = string
  default     = "management_group"
  description = "How inventory and metrics access is scoped. management_group: one Reader assignment on the root management group (recommended). subscription: Reader on each subscription in subscription_ids."

  validation {
    condition     = contains(["management_group", "subscription"], var.scope_mode)
    error_message = "scope_mode must be management_group or subscription."
  }
}

variable "management_group_id" {
  type        = string
  default     = null
  description = "Required when scope_mode is management_group. ID of the root management group, often identical to the tenant ID. Reader is granted here, so it covers every current and future subscription."

  validation {
    # A conditional, not ||, because HCL does not short-circuit ||.
    condition     = var.management_group_id == null ? true : (length(trimspace(var.management_group_id)) > 0 && !can(regex("[/\\s]", var.management_group_id)))
    error_message = "management_group_id must be the management group ID only (no slashes, no spaces), not the full resource path."
  }
}

variable "subscription_ids" {
  type        = list(string)
  default     = []
  description = "Used when scope_mode is subscription. Subscriptions that get a Reader assignment. Leave empty to assign nothing: Atomity then auto-discovers every subscription it already has Reader on."

  validation {
    condition     = alltrue([for s in var.subscription_ids : can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", trimspace(s)))])
    error_message = "Every entry in subscription_ids must be a subscription GUID."
  }
}

variable "storage_account_name" {
  type        = string
  description = "Name of the existing storage account that receives the FOCUS export. Terraform does not create or manage it."

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Use a valid storage account name: 3-24 lowercase letters and digits."
  }
}

variable "container_name" {
  type        = string
  description = "Blob container for the export. Cost Management creates it on the first run if it does not exist."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.container_name))
    error_message = "Use a valid container name: 3-63 lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }
}

variable "root_folder_path" {
  type        = string
  default     = null
  description = "Optional folder inside the container where export files are written. Empty means the container root."
}

variable "billing_account_id" {
  type        = string
  description = "Billing account the FOCUS export is created on. Azure does not support FOCUS exports at management group scope, so a billing account export is what gives coverage across all subscriptions. EA: the enrollment number, like 1234567. MCA: like <guid>:<guid>_2019-05-31."

  validation {
    condition     = length(trimspace(var.billing_account_id)) > 0 && !can(regex("/", var.billing_account_id))
    error_message = "billing_account_id must be the ID only, not the full /providers/Microsoft.Billing/... path."
  }
}

variable "subscription_id" {
  type        = string
  default     = null
  description = "Subscription that holds the storage account. Leave unset to use the Azure CLI default or ARM_SUBSCRIPTION_ID."
}

variable "storage_account_id" {
  type        = string
  default     = null
  description = "Full resource ID of the storage account. Only needed when it is not in the subscription above. Otherwise it is looked up by name."
}

variable "atomity_client_id" {
  type        = string
  default     = "c4b84012-e86e-4ea0-9c42-5e015c1c30f4"
  description = "Application (client) ID of Atomity's multi-tenant Entra app registration. Same for every customer."
}

variable "export_name" {
  type        = string
  default     = "atomity-focus"
  description = "Name of the Cost Management export."
}

variable "focus_dataset_version" {
  type        = string
  default     = "1.2-preview"
  description = "FOCUS schema version of the export. 1.2-preview matches the FOCUS 1.2 data Atomity reads from AWS. Older exports use 1.0 or 1.0r2."

  validation {
    condition     = can(regex("^1\\.[0-9]+(r[0-9]+)?(-preview)?$", var.focus_dataset_version))
    error_message = "focus_dataset_version must look like 1.0, 1.0r2, 1.2-preview or 1.2."
  }
}

variable "data_overwrite_behavior" {
  type        = string
  default     = "OverwritePreviousReport"
  description = "OverwritePreviousReport keeps one file set per month and replaces it on every run. CreateNewReport keeps every run."

  validation {
    condition     = contains(["OverwritePreviousReport", "CreateNewReport"], var.data_overwrite_behavior)
    error_message = "data_overwrite_behavior must be OverwritePreviousReport or CreateNewReport."
  }
}

variable "run_export_now" {
  type        = bool
  default     = true
  description = "Run the export once right after it is created, instead of waiting for the first scheduled run."
}
