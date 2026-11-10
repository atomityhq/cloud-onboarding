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