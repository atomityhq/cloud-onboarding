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
| | Terraform | ARM / Deploy to Azure | Bicep Module |
|---|---|---|---|
| Best for | Teams that use Terraform for IaC | Teams that prefer the Azure Portal or CLI with no tools | Teams that standardize on Azure Bicep (CDK equivalent) |
| Setup scope | Management group or Subscriptions | Management group (or Subscriptions) | Management group (or Subscriptions) |
| Entra ID consent | Automated in run | Pre-step in wizard (provides SP Object ID) | Pre-step in wizard (provides SP Object ID) |
| FOCUS export creation | Automated in run | Automated via Portal guide or companion template | Automated via Portal guide or companion module |
| Preview before changes | `terraform plan` | Azure Portal Review / `what-if` | `az deployment mg what-if` |
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
| `root_folder_path` | none | Folder inside the container. Empty means the container root. |
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

## Remove Atomity's access

### Terraform

Run this from the folder you deployed from:

```bash
terraform destroy
```

This removes the export, every role assignment and the Service Principal. Atomity loses access
immediately. The resource provider registration is left as it is, because other exports in your
subscription may rely on it.

Your storage account, the container and the exported files are never managed by Terraform, so
they stay in your subscription and continue to incur storage costs until you delete them.

Without Terraform, either remove the role assignments for Atomity's application ID
(`c4b84012-e86e-4ea0-9c42-5e015c1c30f4`) from each scope and from the storage account, or
delete the Service Principal under **Entra ID → Enterprise applications**.

### ARM / Bicep
Deleting an ARM/Bicep deployment record does not delete role assignments. To revoke access:
1. Remove the role assignments for Atomity's Service Principal from the management group and storage account, **OR**
2. Delete Atomity's Service Principal under **Microsoft Entra ID → Enterprise applications**. Access terminates immediately across all scopes.
3. If you set up a Cost Management export, delete it in the Azure Portal under **Cost Management + Billing → Exports**.

## Notes

- Atomity's access has no shared secret, so the Terraform state holds no credentials. It does
  list your resource IDs, so don't commit it, and consider a remote backend if you keep this
  long term.
- First export files can take up to 24 hours to appear. You can finish connecting before then.
- With `scope_mode = "subscription"`, a subscription added later is not covered until you add it
  to `subscription_ids` and apply again.
- Verify a download: compare it with the published `.sha256` file, or run
  `gh attestation verify <file> --repo atomity/terraform-onboarding`.
- Azure is released separately from AWS, on `azure-tf-vX.Y.Z` tags.