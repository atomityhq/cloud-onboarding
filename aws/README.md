# Atomity AWS connection

Terraform that connects an AWS account (or an AWS Organization) to Atomity with
read-only access. One run creates everything the Atomity onboarding wizard
otherwise has you click through by hand.

## What it creates

| Resource | Purpose |
|---|---|
| IAM role `AtomityReadOnly` | Atomity assumes it with temporary STS credentials. It can only be assumed with your external ID. |
| Inline permission policy | Read-only access to billing data, cost recommendations, resource inventory, and metrics. |
| S3 bucket | Private bucket that receives your billing export. Only AWS billing exports can write to it. |
| Data Export (FOCUS 1.2, Parquet) | Created in `us-east-1`, as AWS requires. Files are delivered to the bucket. |
| CloudFormation StackSet `AtomityMemberRoles` | Organizations only. Deploys a narrower read-only role to every member account. |

Everything is read-only. Atomity can't create, change, delete, or purchase anything in your account.

## Before you start

- Terraform v1.5.7 or newer 
- AWS credentials for the account you're connecting (for Organizations: the management account or a delegated admin account)
- Permission to create IAM roles, S3 buckets, and Data Exports (and CloudFormation StackSets for Organizations)
- Organizations only, once per organization, from the management account:

  ```bash
  aws organizations enable-aws-service-access \
    --service-principal member.org.stacksets.cloudformation.amazonaws.com
  ```

## Deploy

The wizard generates these commands with your values filled in.

```bash
mkdir atomity-aws && cd atomity-aws
terraform init -from-module="https://github.com/atomity/terraform-onboarding/releases/download/aws-v1.0.0/aws-v1.0.0.zip"

cat > terraform.tfvars <<'EOT'
external_id = "<from the Atomity wizard>"
s3_bucket   = "<a globally unique bucket name>"
EOT

terraform plan    # review what will be created
terraform apply
terraform output -raw role_arn
```

Paste the printed role ARN into the **Connect** step in Atomity.

## Inputs

| Name | Default | Description |
|---|---|---|
| `external_id` | none (required) | Per-connection external ID from the wizard. Marked sensitive. |
| `s3_bucket` | none (required) | Name of the bucket Terraform creates for the export. |
| `aws_region` | `eu-central-1` | Region of that bucket. |
| `s3_prefix` | `atomity-exports` | Folder inside the bucket. |
| `export_name` | `atomity-exports` | Name of the Data Export. |
| `time_granularity` | `HOURLY` | `HOURLY`, `DAILY`, or `MONTHLY`. |
| `enable_organizations` | `false` | Set to `true` in a management account to cover every member account. |
| `stackset_call_as` | `SELF` | `DELEGATED_ADMIN` when running from a StackSets delegated admin account. |
| `atomity_role_arn` | Atomity's collector role | The same for every customer. Normally left alone. |

## Outputs

`role_arn` is the value to paste into Atomity. `connection_details` has everything else in one object.

## Remove Atomity's access

Run `terraform destroy` from the same folder, or delete the `AtomityReadOnly` role in IAM to stop access immediately. For Organizations, deleting the `AtomityMemberRoles` StackSet also removes the role from every member account.

Terraform stops at the billing bucket while it still holds files. That's deliberate, so delete the role first if you want access gone right away.

## Notes

- The state file contains your external ID. Don't commit it, and consider a remote backend if you keep this long term.
- First export files can take up to 24 hours to appear. You can finish connecting before then.
- Verify a download: compare it with the published `.sha256` file, or run `gh attestation verify <zip> --repo atomity/terraform-onboarding`.