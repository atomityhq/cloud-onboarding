# Azure event onboarding and replacement

The connection workflow remains create → configure → consent → deploy → validate.
Register the event binding after saving configuration and before Deploy, while the
connection is PENDING. Registration is tenant-wide and requires credentials:write.
Keep the one-time secret only long enough to deploy Event Grid; never place it in
localStorage, logs, analytics, URLs, or status responses.

## Permission contract

- Connection listing/details and binding status: credentials:read.
- Create, validate, onboarding configuration, event registration and retry: credentials:write.
- Connection deletion and disabling events: credentials:delete.
- These checks require a tenant-wide grant. A sub-tenant-only grant is insufficient.
- Public webhook delivery uses the binding secret, not a user's session or role.

## Status

GET /api/v1/connections/{id}/azure-events returns the enabled binding, or the most
recent disabled binding if none is enabled. Existing status fields remain.
New fields are ingestion_ready, readiness_checked_at, disabled_reason, disabled_at,
and replacement_required. A connection with no binding still returns {"enabled":false}.

Display these disabled reasons:

- configuration_changed: "Automatic updates stopped because the billing destination changed.
  Register a replacement and redeploy Event Grid with the new endpoint and secret."
- disabled_by_user: "Automatic updates are disabled."
- connection_invalid: "The connection is no longer eligible. Restore an automated Azure
  connection, then register and deploy a replacement if automatic updates are wanted."
- legacy_disabled: "This binding was disabled before reason tracking was introduced."

A transient IAM request failure does not permanently disable a binding. Readiness
is checked again. disabled_at is null for historical disabled bindings whose
original disable time is unknown. replacement_required is true for configuration_changed.

## Destination changes

Before submitting a change to storage account, container or normalized root prefix,
show this warning and an explicit confirmation:

"Changing this destination requires replacing automatic updates. You'll need to
redeploy the Azure Event Grid subscription with a new endpoint and secret."

For a confirmed change:

1. DELETE /api/v1/connections/{id}/azure-events to disable the old binding.
2. Save the destination through the existing connection configuration/validation
   API. The azure-onboarding draft endpoint remains PENDING-only; do not use it
   to edit an ACTIVE connection. Handle 409 by reloading, not blindly resubmitting.
3. POST /api/v1/connections/{id}/azure-events with the full storage_resource_id.
   Keep the new endpoint and one-time secret for the deployment step.
4. Redeploy the same managed Azure Event Grid subscription with the new endpoint,
   X-Atomity-Webhook-Token value and container/root subject filter. Update every
   onboarding method: Terraform, Cloud Shell, Bicep/ARM and manual Azure portal.
5. Complete Validate connection if still pending and poll binding status. A
   validation challenge proves subscription delivery, not successful cost ingestion.

If deployment fails, leave the replacement binding in place and offer deployment
retry while the secret is still available. If it was lost, disable/register again
and redeploy. GET status and ingestion retry cannot reveal or regenerate the old
secret. Do not automatically register on status polling or on a 409 response.

The worker also detects mismatches when changes bypass this UI; it disables the
binding and exposes configuration_changed. A readiness check may take about 30s.
Existing manual and scheduled sync continue to work. Disabling a connector binding
revokes delivery authentication; it does not delete the customer's Event Grid
subscription. The frontend must not imply that Azure resources were removed.
