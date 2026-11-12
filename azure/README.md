# Atomity Azure connection

Connects an Azure tenant to Atomity with read-only access. One Terraform run does what
steps 1 to 3 of the Atomity onboarding wizard otherwise have you click through by hand.
Step 4, **Validate connection**, happens in Atomity.

## What it creates

| Resource | Purpose |
|---|---|
| Service Principal for Atomity's app | Atomity authenticates as this identity in your tenant. Creating it is the equivalent of the admin consent link, and grants no permissions on its own. |
| `Reader` role assignment | On the root management group (every current and future subscription) or on each subscription you list. Used for cost recommendations, resource inventory and metrics. |
| `Storage Blob Data Reader` role assignment | On the storage account that receives your billing export. |
| Cost Management export (FOCUS, Parquet, Snappy) | Daily export on your billing account, delivered to your storage account. Azure does not support FOCUS exports at management group scope, so the export uses billing account scope. |
| `Microsoft.CostManagementExports` registration | On the subscription that holds the storage account. Azure requires it for exports. |

Both roles are read-only. Atomity can't create, resize, stop or delete anything, and can't
purchase commitments. There is no shared secret: trust comes entirely from the roles you
grant inside your own tenant.

Terraform does not create the storage account or the container. You bring the storage account,
and Cost Management creates the container on the first run.

## Choose a method

| | Terraform | Cloud Shell | Bicep / ARM |
|---|---|---|---|
| Best for | Teams that use infrastructure as code | Teams that want one paste and no installed tools | Teams that deploy with ARM or Bicep, or from the Azure CLI |
| Runs in | Your own terminal or pipeline | Azure Cloud Shell, in the portal | The Azure CLI or Cloud Shell |
| Management group or per-subscription scope | Yes | Yes | Yes, with two templates |
| Preview before changes | `terraform plan` | The `plan` command, and a plan before every apply | `az deployment mg what-if` |
| Creates the Service Principal and the export | Yes | Yes | No. Create the Service Principal first. The export is one documented command afterwards. |
| Removal | `terraform destroy` | The `remove` command | Remove the role assignments by hand |

The Cloud Shell script runs the same Terraform module, so those two create exactly the same
things. Bicep / ARM creates the role assignments only.

Use one method per tenant. Two tools managing the same role assignments conflict, so to switch,
remove the first deployment before starting the second.

## Terraform

### Before you start

- Terraform v1.5.7 or newer, and the Azure CLI signed in to your tenant (`az login --tenant <tenant ID>`)
- An existing storage account for the export
- The ID of your billing account (EA: the enrollment number. MCA: `<guid>:<guid>_2019-05-31`)
- A pay-as-you-go (WebDirect) agreement cannot be used: Azure does not offer FOCUS exports for it
- If the storage account is behind a firewall, turn on **Allow trusted Azure services**
- Permissions for the person running Terraform:

  | Where | Needed to |
  |---|---|
  | Entra ID | Create a Service Principal (Cloud Application Administrator or higher) |
  | Root management group, or each subscription you list | Assign `Reader` (Owner or User Access Administrator). A Global Administrator who is not yet Owner of the root management group must first elevate access. |
  | The storage account | Assign `Storage Blob Data Reader` (Owner or User Access Administrator) |
  | The storage account's subscription | Register a resource provider (Contributor) |
  | The billing account | Create exports (EA: Enterprise Administrator. MCA: billing account Owner or Contributor) |

### Deploy

The wizard generates these commands with your values filled in.

```bash
mkdir atomity-azure && cd atomity-azure
terraform init -from-module="https://github.com/atomity/terraform-onboarding/releases/download/azure-tf-v1.0.0/azure-tf-v1.0.0.zip"

cat > terraform.tfvars <<'EOT'
tenant_id            = "<your Entra tenant ID>"
management_group_id  = "<root management group ID>"
storage_account_name = "<existing storage account>"
container_name       = "<container for the export>"
billing_account_id   = "<billing account ID>"
EOT

az login --tenant "<your Entra tenant ID>"
terraform plan    # review what will be created
terraform apply
terraform output connection_details
```

Compare the printed values with the **Connect** step in Atomity, then choose **Validate connection**.

To scan only some subscriptions, replace `management_group_id` with:

```hcl
scope_mode       = "subscription"
subscription_ids = ["<subscription ID>", "<subscription ID>"]
```

### Inputs

| Name | Default | Description |
|---|---|---|
| `tenant_id` | none (required) | Your Entra tenant ID. |
| `storage_account_name` | none (required) | Existing storage account that receives the export. |
| `container_name` | none (required) | Container for the export. Created on the first run if missing. |
| `billing_account_id` | none (required) | Billing account the export is created on. |
| `scope_mode` | `management_group` | `management_group` or `subscription`. |
| `management_group_id` | none | Root management group ID. Required when `scope_mode` is `management_group`. |
| `subscription_ids` | `[]` | Subscriptions to grant `Reader` on, when `scope_mode` is `subscription`. Empty assigns nothing and Atomity auto-discovers what it can already read. |
| `root_folder_path` | `atomity-exports` | Folder inside the container. Azure requires one, so leaving it empty uses the default. |
| `subscription_id` | Azure CLI default | Subscription that holds the storage account. |
| `storage_account_id` | none | Full resource ID, only if the storage account is not in the subscription above. |
| `export_name` | `atomity-focus` | Name of the Cost Management export. |
| `focus_dataset_version` | `1.2-preview` | FOCUS schema version. `1.0` and `1.0r2` are also available. |
| `data_overwrite_behavior` | `OverwritePreviousReport` | `OverwritePreviousReport` keeps one file set per month. `CreateNewReport` keeps every run. |
| `run_export_now` | `true` | Run the export once after creating it. |
| `atomity_client_id` | Atomity's app ID | The same for every customer. Normally left alone. |

### Outputs

`connection_details` has everything Atomity uses, in one object, to compare with the wizard.
`service_principal_object_id` is the value to use if you assign roles by hand.

## Cloud Shell

For teams that don't use Terraform. Azure Cloud Shell is already signed in and includes the Azure CLI
and Terraform, so there is nothing to install. The script is a thin wrapper around the Terraform
module: it downloads a pinned release, verifies its checksum, shows you the plan, and changes nothing
until you type `yes`. It runs the newest Terraform release built into the script. Use
`--module-tag` to run an older one, and `--version` to list them.

### Before you start

- Azure Cloud Shell (Bash), opened from the Azure portal **in the tenant you are connecting**
- The same storage account, billing account and permissions as for [Terraform](#before-you-start)

### Deploy

The wizard generates this command with your values filled in, including the script's checksum.

```bash
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/azure-shell-v1.0.0/atomity-azure.sh
echo "<script checksum from the wizard>  atomity-azure.sh" | sha256sum -c - && bash atomity-azure.sh apply \
  --tenant-id "<your Entra tenant ID>" \
  --storage-account "<existing storage account>" \
  --container "<container for the export>" \
  --billing-account "<billing account ID>" \
  --scope management-group \
  --management-group-id "<root management group ID>"
```

The checksum line stops the paste if the download isn't the script the wizard expects. The script then
checks the Terraform release it downloads against a checksum built into it.

To only see what would be created, use `plan` instead of `apply`. Nothing is created.

To scan only some subscriptions, replace the last two lines with:

```bash
  --scope subscription \
  --subscription-ids "<subscription ID>,<subscription ID>"
```

### Options

| Option | Terraform input | Description |
|---|---|---|
| `--tenant-id` | `tenant_id` | Your Entra tenant ID. Required. |
| `--storage-account` | `storage_account_name` | Existing storage account for the export. Required. |
| `--container` | `container_name` | Container for the export. Required. |
| `--billing-account` | `billing_account_id` | Billing account the export is created on. Required. |
| `--scope` | `scope_mode` | `management-group` (default) or `subscription`. |
| `--management-group-id` | `management_group_id` | Root management group ID. Required for `management-group`. |
| `--subscription-ids` | `subscription_ids` | Comma-separated. Empty means Atomity auto-discovers. |
| `--root-folder` | `root_folder_path` | Folder inside the container. Default `atomity-exports`. |
| `--storage-subscription` | `subscription_id` | Subscription that holds the storage account, if it isn't the Cloud Shell default. |
| `--storage-account-id` | `storage_account_id` | Full resource ID, if the storage account is in another subscription. |
| `--module-tag` | none | Run this Terraform release instead of the newest one the script includes. `--version` lists them. |
| `--yes` | none | Skip the confirmation prompt. |

The script keeps the Terraform state and your settings in `~/atomity-azure`, which Cloud Shell stores
persistently. It refuses to run if you are signed in to a different tenant than `--tenant-id`.

## Bicep / ARM

For teams that deploy with ARM or Bicep, or from the Azure CLI in a pipeline. There are two ARM
templates, compiled from Bicep, because the two scopes are deployed with different commands. Pick
one:

| Template | Grants `Reader` on | Deploy with | Needs |
|---|---|---|---|
| `atomity.json` | The root management group, so every current and future subscription | `az deployment mg create` | Deployment and role assignment rights at the management group |
| `atomity-subscription.json` | Each subscription you list | `az deployment sub create` | Rights only on those subscriptions and the storage account. No management group rights. |

Both also assign `Storage Blob Data Reader` on the storage account that receives your billing
export. They create role assignments only. They do not create Atomity's Service Principal or the
Cost Management export: you create the Service Principal first, and the export with a command
afterwards. The release also has the Bicep source (`azure-bicep-vX.Y.Z-modules.zip`).

### Before you start

- The Azure CLI signed in to your tenant. Azure Cloud Shell has it.
- Atomity's Service Principal in your tenant. Create it with the admin consent link in the
  wizard. Its object ID is a parameter of both templates:

  ```bash
  az ad sp show --id c4b84012-e86e-4ea0-9c42-5e015c1c30f4 --query id -o tsv
  ```

- For the management group template: deployment rights at the management group named in
  `--management-group-id`, and Owner or User Access Administrator on it and on the storage account.
  A Global Administrator who is not yet Owner of the root management group must first elevate
  access, as for Terraform.
- For the subscription template: Contributor or Owner on the subscription you run the command
  against, and Owner or User Access Administrator on each listed subscription and on the storage
  account. It needs no management group rights.

### Deploy at management group scope

The wizard generates this command with your values and the template's checksum. Management group
deployments are made with the Azure CLI, PowerShell or the REST API, so there is no portal button.

```bash
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/azure-bicep-v1.0.0/atomity.json
echo "<template checksum from the wizard>  atomity.json" | sha256sum -c - && az deployment mg create \
  --name atomity \
  --location "<region for the deployment record, for example westeurope>" \
  --management-group-id "<root management group ID>" \
  --template-file atomity.json \
  --parameters \
    atomityServicePrincipalObjectId="$(az ad sp show --id c4b84012-e86e-4ea0-9c42-5e015c1c30f4 --query id -o tsv)" \
    storageAccountSubscriptionId="<subscription of the storage account>" \
    storageAccountResourceGroupName="<its resource group>" \
    storageAccountName="<storage account>"
```

To see what would be created, use `az deployment mg what-if` with the same arguments. Nothing is
created.

### Deploy per subscription

Use this to grant `Reader` on only some subscriptions, or when you have no rights at a management
group. Run it against any one of the subscriptions. Duplicates in the list are ignored, and a
subscription added later is not covered until you deploy again with it listed.

```bash
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/azure-bicep-v1.0.0/atomity-subscription.json
echo "<template checksum from the wizard>  atomity-subscription.json" | sha256sum -c - && az deployment sub create \
  --name atomity \
  --subscription "<any one of the subscriptions below>" \
  --location "<region for the deployment record, for example westeurope>" \
  --template-file atomity-subscription.json \
  --parameters \
    atomityServicePrincipalObjectId="$(az ad sp show --id c4b84012-e86e-4ea0-9c42-5e015c1c30f4 --query id -o tsv)" \
    subscriptionIds='["<subscription ID>","<subscription ID>"]' \
    storageAccountSubscriptionId="<subscription of the storage account>" \
    storageAccountResourceGroupName="<its resource group>" \
    storageAccountName="<storage account>"
```

To see what would be created, use `az deployment sub what-if` with the same arguments.

### Create the export

The template cannot create the Cost Management export, because a management group deployment
cannot reach a billing account. Create it with this command. It sends the same export definition
as the Terraform module: FOCUS 1.2, Parquet, Snappy, daily, written into a folder of your
container. It needs the same billing account role as the Terraform method, in
[Before you start](#before-you-start).

```bash
BILLING_ACCOUNT="<billing account ID>"
STORAGE_SUBSCRIPTION="<subscription of the storage account>"
STORAGE_RG="<its resource group>"
STORAGE_ACCOUNT="<storage account>"
CONTAINER="<container for the export>"
ROOT_FOLDER="atomity-exports"   # Azure requires a folder. Change it if you want another one.

# Cost Management exports must be registered on the storage account's subscription.
az provider register --namespace Microsoft.CostManagementExports --subscription "$STORAGE_SUBSCRIPTION" --wait

STORAGE_ID=$(az storage account show --subscription "$STORAGE_SUBSCRIPTION" \
  --resource-group "$STORAGE_RG" --name "$STORAGE_ACCOUNT" --query id -o tsv)
FROM=$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ)
EXPORT_URL="https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BILLING_ACCOUNT/providers/Microsoft.CostManagement/exports/atomity-focus"

az rest --method put --url "$EXPORT_URL?api-version=2025-03-01" --body "$(cat <<EOF
{
  "properties": {
    "format": "Parquet",
    "compressionMode": "snappy",
    "partitionData": true,
    "dataOverwriteBehavior": "OverwritePreviousReport",
    "definition": {
      "type": "FocusCost",
      "timeframe": "MonthToDate",
      "dataSet": {
        "granularity": "Daily",
        "configuration": { "dataVersion": "1.2-preview" }
      }
    },
    "deliveryInfo": {
      "destination": {
        "type": "AzureBlob",
        "resourceId": "$STORAGE_ID",
        "container": "$CONTAINER",
        "rootFolderPath": "$ROOT_FOLDER"
      }
    },
    "schedule": {
      "status": "Active",
      "recurrence": "Daily",
      "recurrencePeriod": { "from": "$FROM", "to": "2099-12-31T00:00:00Z" }
    }
  }
}
EOF
)"

# Optional: run it once now instead of waiting for the first scheduled run.
az rest --method post --url "$EXPORT_URL/run?api-version=2025-03-01"
```

The container is created on the first run if it does not exist. Azure can take up to 24 hours to
deliver the first files. Running the command again updates the same export. It is safe to repeat.

### Inputs

Both templates take these four:

| Name | Default | Description |
|---|---|---|
| `atomityServicePrincipalObjectId` | none (required) | Object ID of Atomity's Service Principal in your tenant. |
| `storageAccountSubscriptionId` | none (required) | Subscription that holds the storage account. |
| `storageAccountResourceGroupName` | none (required) | Resource group of the storage account. |
| `storageAccountName` | none (required) | Existing storage account that receives the export. |

The subscription template also takes:

| Name | Default | Description |
|---|---|---|
| `subscriptionIds` | none (required, at least one) | Subscriptions to grant `Reader` on. |

Outputs: `readerScope` (management group template) or `readerSubscriptions` (subscription template),
`storageAccount` and `storageRoleAssignmentId`.

### Use it from your own Bicep

Unzip `azure-bicep-vX.Y.Z-modules.zip` into your repository, for example as `atomity/`, and call it
as a module. `what-if` then shows exactly what changes when you update. The values below are
samples. Replace them with yours.

From a management group template:

```bicep
targetScope = 'managementGroup'

module atomity './atomity/main.bicep' = {
  name: 'atomity'
  params: {
    atomityServicePrincipalObjectId: '00000000-0000-0000-0000-000000000000'
    storageAccountSubscriptionId: '11111111-1111-1111-1111-111111111111'
    storageAccountResourceGroupName: 'billing-rg'
    storageAccountName: 'acmebillingexports'
  }
}
```

From a subscription template:

```bicep
targetScope = 'subscription'

module atomity './atomity/subscription.bicep' = {
  name: 'atomity'
  params: {
    atomityServicePrincipalObjectId: '00000000-0000-0000-0000-000000000000'
    subscriptionIds: [
      '22222222-2222-2222-2222-222222222222'
      '33333333-3333-3333-3333-333333333333'
    ]
    storageAccountSubscriptionId: '11111111-1111-1111-1111-111111111111'
    storageAccountResourceGroupName: 'billing-rg'
    storageAccountName: 'acmebillingexports'
  }
}
```

The ARM templates are generated from this source by a pinned Bicep compiler, and CI fails if they
ever differ.

## Troubleshooting

A failed run is safe to repeat. Terraform keeps what it already created and continues from there.
Several resources are created in parallel, so you can see more than one error at once.

### `AuthorizationFailed` on `Microsoft.Authorization/roleAssignments/write`

The account running Terraform cannot assign roles on the scope in the error, usually the root
management group. You need Owner or User Access Administrator there. A Global Administrator
gets this by elevating access: in the Microsoft Entra admin center, open **Properties** and set
**Access management for Azure resources** to **Yes**. Then sign in again (`az logout`, then
`az login --tenant <tenant ID>`) so the new permission is in your token, and re-run. Turn the
setting off again when you are done.

If you only need some subscriptions, use `scope_mode = "subscription"` and an Owner or User
Access Administrator on those subscriptions instead.

### `RoleAssignmentExists` (409)

Atomity's service principal already has that role on that scope, from another setup method or
from an earlier run whose Terraform state is gone. Azure refuses a duplicate even when it would
get a different assignment ID, so Terraform cannot create it. Either let Terraform manage the
existing one, or delete it and re-run.

First see what exists. The service principal's object ID is in `terraform output`, or in
`terraform state show azuread_service_principal.atomity`:

```bash
az role assignment list --assignee <service principal object ID> --all \
  --query "[].{role:roleDefinitionName, scope:scope, id:id, created:createdOn}" -o table
```

To keep it and let Terraform manage it, import it. The error prints the assignment ID without
dashes. Write it as 8-4-4-4-12 characters, and use the resource name from the error (here
`azurerm_role_assignment.storage_blob_reader`; for the management group it is
`azurerm_role_assignment.reader["management_group"]`):

```bash
terraform import azurerm_role_assignment.storage_blob_reader \
  "<scope>/providers/Microsoft.Authorization/roleAssignments/<assignment ID>"
```

Or delete it with `az role assignment delete --ids <id from the list above>` and re-run.

This also means the service principal itself already existed, because the module adopts an
existing one. Run only one setup method per tenant. Note that `terraform destroy` later deletes
that service principal, including the access it had from the earlier setup.

## Remove Atomity's access

**Terraform.** Run this from the folder you deployed from:

```bash
terraform destroy
```

**Cloud Shell.** Download the script as above and run it from the same Cloud Shell, with no other options:

```bash
bash atomity-azure.sh remove
```

It shows what will be removed and asks for confirmation. If the Cloud Shell storage that held the
state is gone, the script says so and lists the manual steps below.

This removes the export, every role assignment and the Service Principal. Atomity loses access
immediately. The resource provider registration is left as it is, because other exports in your
subscription may rely on it.

Your storage account, the container and the exported files are never managed by Terraform, so
they stay in your subscription and continue to incur storage costs until you delete them.

**Bicep / ARM.** Deleting an ARM deployment does not delete what it created. Delete the Service
Principal under **Entra ID → Enterprise applications**, which removes every role assignment at
once. Or remove the assignments one by one:

```bash
az role assignment delete --assignee <service principal object ID> --role Reader \
  --scope /providers/Microsoft.Management/managementGroups/<management group ID>
az role assignment delete --assignee <service principal object ID> --role "Storage Blob Data Reader" \
  --scope <storage account resource ID>
```

In per-subscription mode, delete the `Reader` assignment on each subscription instead:

```bash
az role assignment delete --assignee <service principal object ID> --role Reader \
  --scope /subscriptions/<subscription ID>
```

Then delete the export, which the templates did not create:

```bash
az rest --method delete --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/<billing account ID>/providers/Microsoft.CostManagement/exports/atomity-focus?api-version=2025-03-01"
```

Your storage account, the container and the exported files stay.

Without Terraform, either remove the role assignments for Atomity's application ID
(`c4b84012-e86e-4ea0-9c42-5e015c1c30f4`) from each scope and from the storage account, or
delete the Service Principal under **Entra ID → Enterprise applications**.

## Notes

- Atomity's access has no shared secret, so the Terraform state holds no credentials. It does
  list your resource IDs, so don't commit it, and consider a remote backend if you keep this
  long term.
- First export files can take up to 24 hours to appear. You can finish connecting before then.
- With `scope_mode = "subscription"`, a subscription added later is not covered until you add it
  to `subscription_ids` and apply again.
- Verify a download: compare it with the published `.sha256` file, or run
  `gh attestation verify <file> --repo atomity/terraform-onboarding`.
- Azure is released separately from AWS. Terraform is on `azure-tf-vX.Y.Z` tags, the Cloud Shell script on `azure-shell-vX.Y.Z` tags, and the ARM template and Bicep source on `azure-bicep-vX.Y.Z` tags. Each script release pins one or more Terraform releases and runs the newest by default.
