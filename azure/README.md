# Atomity Azure connection

Connects an Azure tenant to Atomity with read-only access.

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
| | Terraform | Cloud Shell | ARM / Deploy to Azure | Bicep Module |
|---|---|---|---|---|
| Best for | Teams that use Terraform for IaC | Teams that want one paste and no installed tools | Teams that prefer the Azure Portal or CLI with no tools | Teams that standardize on Azure Bicep (CDK equivalent) |
| Runs in | Your own terminal or pipeline | Azure Cloud Shell, in the portal | Azure Portal or Azure CLI | Your own Bicep pipeline |
| Management group or per-subscription scope | Yes | Yes | Yes | Yes |
| Preview before changes | `terraform plan` | The `plan` command, and a plan before every apply | Azure Portal Review / `what-if` | `az deployment mg what-if` |
| Removal | `terraform destroy` | The `remove` command | Delete Service Principal in Entra ID | Delete Service Principal in Entra ID |
---
## ARM Template / Deploy to Azure
Our CloudFormation equivalent. One self-contained template (`bicep/atomity.json`) deploys at
management group scope directly from the Azure Portal with the **Deploy to Azure** button.
### 1. Click to Deploy
[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fatomityhq%2Fcloud-onboarding%2Fmain%2Fazure%2Fbicep%2Fatomity.json)
### Before you click
1. Complete **Step 1 (Admin Consent)** in the onboarding wizard. This creates Atomity's Service Principal in your tenant.
2. Obtain the Service Principal's Object ID in your tenant:
   ```bash
   az ad sp show --id c4b84012-e86e-4ea0-9c42-5e015c1c30f4 --query id -o tsv
   ```
3. Have your storage account name, resource group, and subscription ID ready.
### Deploy via Azure CLI
If you prefer the command line over the Azure Portal button:
```bash
az deployment mg create \
  --name "atomity-onboarding" \
  --management-group-id "<root-management-group-id>" \
  --location eastus \
  --template-file azure/bicep/atomity.json \
  --parameters \
    atomityServicePrincipalObjectId="<from Step 1 above>" \
    storageAccountSubscriptionId="<subscription ID>" \
    storageAccountResourceGroupName="<resource group name>" \
    storageAccountName="<storage account name>"
```
### Parameters
| Name | Default | Description |
|---|---|---|
| `atomityServicePrincipalObjectId` | none (required) | Object ID of Atomity's Service Principal in your tenant. |
| `storageAccountSubscriptionId` | none (required) | Subscription ID where your billing export storage account is located. |
| `storageAccountResourceGroupName` | none (required) | Resource group name of the storage account. |
| `storageAccountName` | none (required) | Name of the storage account designated to receive the FOCUS export. |
| `scopeMode` | `management_group` | `management_group` (recommended) or `subscription`. |
| `subscriptionIds` | `[]` | List of subscription IDs if `scopeMode` is set to `subscription`. |
---
## Bicep
Our AWS CDK equivalent, for teams that write Azure Bicep. Reference the module directly from
your own Bicep infrastructure repository:
```bicep
targetScope = 'managementGroup'
module atomityConnection 'bicep/main.bicep' = {
  name: 'atomity-onboarding'
  params: {
    atomityServicePrincipalObjectId: '<SP_OBJECT_ID_FROM_STEP_1>'
    storageAccountSubscriptionId: '<storage-account-subscription-id>'
    storageAccountResourceGroupName: '<storage-account-resource-group>'
    storageAccountName: '<storage-account-name>'
  }
}
```
Preview changes before deploying:
```bash
az deployment mg what-if \
  --management-group-id "<root-management-group-id>" \
  --location eastus \
  --template-file main.bicep \
  --parameters @parameters.json
```
---

## Choose a method

| | Terraform | Cloud Shell |
|---|---|---|
| Best for | Teams that use infrastructure as code | Teams that want one paste and no installed tools |
| Runs in | Your own terminal or pipeline | Azure Cloud Shell, in the portal |
| Management group or per-subscription scope | Yes | Yes |
| Preview before changes | `terraform plan` | The `plan` command, and a plan before every apply |
| Removal | `terraform destroy` | The `remove` command |

The Cloud Shell script runs the same Terraform module, so both create exactly the same things.

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
terraform init -from-module="https://github.com/atomityhq/cloud-onboarding/releases/download/azure-tf-v1.0.0/azure-tf-v1.0.0.zip"

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
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/azure-shell-v1.0.0/atomity-azure.sh
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

**ARM / Bicep.** Deleting an ARM/Bicep deployment record in Azure does not delete role assignments. To revoke access:
1. Remove the role assignments for Atomity's Service Principal (`c4b84012-e86e-4ea0-9c42-5e015c1c30f4`) from the management group and storage account, **OR**
2. Delete Atomity's Service Principal under **Microsoft Entra ID → Enterprise applications**. Access terminates immediately across all scopes.
3. If you set up a Cost Management export, delete it in the Azure Portal under **Cost Management + Billing → Exports**.

Your storage account, the container and the exported files are never managed by Terraform or ARM/Bicep, so
they stay in your subscription and continue to incur storage costs until you delete them.