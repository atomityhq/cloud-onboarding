variable "enable_azure_events" {
  description = "Create BlobCreated notifications for the registered Atomity webhook."
  type        = bool
  default     = false
}

variable "azure_events_webhook_endpoint" {
  type    = string
  default = ""
}

variable "azure_events_webhook_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "azure_events_subscription_name" {
  type    = string
  default = "atomity-cost-blob-created"

  validation {
    condition = can(regex(
      "^[A-Za-z0-9][A-Za-z0-9-]{2,63}$",
      var.azure_events_subscription_name
    ))
    error_message = "Use a 3–64 character name containing letters, numbers, and hyphens."
  }
}

resource "terraform_data" "azure_events_inputs" {
  count = var.enable_azure_events ? 1 : 0

  lifecycle {
    precondition {
      condition = can(regex(
        "^https://[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?/api/v1/webhooks/azure/[0-9a-fA-F-]{36}$",
        var.azure_events_webhook_endpoint
      ))
      error_message = "Provide the HTTPS webhook endpoint returned by Atomity registration."
    }

    precondition {
      condition = can(regex(
        "^[A-Za-z0-9_-]{43}$",
        var.azure_events_webhook_secret
      ))
      error_message = "Provide the 43-character secret returned by Atomity registration."
    }
  }
}

resource "terraform_data" "azure_events_secret_version" {
  count = var.enable_azure_events ? 1 : 0
  input = sha256(var.azure_events_webhook_secret)
}

resource "azapi_resource_action" "register_eventgrid_rp" {
  count       = var.enable_azure_events ? 1 : 0
  type        = "Microsoft.Resources/providers@2021-04-01"
  resource_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.EventGrid"
  action      = "register"
  method      = "POST"

  depends_on = [terraform_data.azure_events_inputs]
}

resource "time_sleep" "after_eventgrid_registration" {
  count           = var.enable_azure_events ? 1 : 0
  create_duration = "30s"

  depends_on = [azapi_resource_action.register_eventgrid_rp]
}

resource "azapi_resource" "azure_events" {
  count     = var.enable_azure_events ? 1 : 0
  type      = "Microsoft.EventGrid/eventSubscriptions@2022-06-15"
  name      = var.azure_events_subscription_name
  parent_id = local.storage_account_id

  body = {
    properties = {
      eventDeliverySchema = "EventGridSchema"

      destination = {
        endpointType = "WebHook"

        properties = {
          endpointUrl = var.azure_events_webhook_endpoint

          deliveryAttributeMappings = [{
            name = "X-Atomity-Webhook-Token"
            type = "Static"

            properties = {
              value    = var.azure_events_webhook_secret
              isSecret = true
            }
          }]
        }
      }

      filter = {
        includedEventTypes = [
          "Microsoft.Storage.BlobCreated"
        ]

        subjectBeginsWith = "/blobServices/default/containers/${var.container_name}/blobs/${local.root_folder_path}/"

        isSubjectCaseSensitive = true
      }

      retryPolicy = {
        maxDeliveryAttempts      = 30
        eventTimeToLiveInMinutes = 1440
      }
    }
  }

  lifecycle {
    # Azure redacts secret delivery attributes when reading the resource.
    ignore_changes = [
      body.properties.destination.properties.deliveryAttributeMappings
    ]

    # Changing the secret recreates the subscription so the new value
    # is delivered despite the ignore_changes rule above.
    replace_triggered_by = [
      terraform_data.azure_events_secret_version[count.index]
    ]
  }

  depends_on = [time_sleep.after_eventgrid_registration]
}

output "azure_events_subscription_id" {
  value = var.enable_azure_events ? azapi_resource.azure_events[0].id : null
}