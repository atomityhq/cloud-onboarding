# Atomity AWS connection

Connects an AWS account (or an AWS Organization) to Atomity with read-only access.
One deployment creates everything the Atomity onboarding wizard otherwise has you
click through by hand. Choose the method that fits your team: [Terraform](#terraform)
or [CloudFormation](#cloudformation).

## What it creates

| Resource | Purpose |
|---|---|
| IAM role `AtomityReadOnly` | Atomity assumes it with temporary STS credentials. It can only be assumed with your external ID. |
| Inline permission policy | Read-only access to billing data, cost recommendations, resource inventory, and metrics. |
| S3 bucket | Private bucket that receives your billing export. Only AWS billing exports can write to it. |
| Data Export (FOCUS 1.2, Parquet) | Created in `us-east-1`, as AWS requires. Files are delivered to the bucket. |
| CloudFormation StackSet `AtomityMemberRoles` | Organizations only. Deploys a narrower read-only role to every member account. |

Everything is read-only. Atomity can't create, change, delete, or purchase anything in your account.
Both methods create the same role, permissions, bucket and export. The permission and trust
policies come from the same files in [`policies/`](policies/).

## Choose a method

| | Terraform | CloudFormation |
|---|---|---|
| Best for | Teams that use infrastructure as code | Teams that prefer the AWS console or CLI and no extra tools |
| Single account | Yes | Yes |
| Organization billing data (management account) | Yes | Yes |
| Member-account roles (StackSet) | Yes | Yes |
| Preview before changes | `terraform plan` | Change set |
| Delete the bucket on removal | Optional, built in | Manual |

AWS CDK teams use the CloudFormation template: see [AWS CDK](#aws-cdk).

Use one method per AWS account. Two tools managing the same role conflict, so to switch,
remove the first deployment before starting the second. The billing bucket is kept on
removal, so the new deployment can reuse it.

## Terraform

### Before you start

- Terraform v1.5.7 or newer
- AWS credentials for the account you're connecting (for Organizations: the management account or a delegated admin account)
- Permission to create IAM roles, S3 buckets, and Data Exports (and CloudFormation StackSets for Organizations)
- Organizations only, once per organization, from the management account:

  ```bash
  aws organizations enable-aws-service-access \
    --service-principal member.org.stacksets.cloudformation.amazonaws.com
  ```

### Deploy

The wizard generates these commands with your values filled in.

```bash
mkdir atomity-aws && cd atomity-aws
terraform init -from-module="https://github.com/atomityhq/cloud-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip"

cat > terraform.tfvars <<'EOT'
external_id = "<from the Atomity wizard>"
s3_bucket   = "<a globally unique bucket name>"
EOT

terraform plan    # review what will be created
terraform apply
terraform output -raw role_arn
```

Paste the printed role ARN into the **Connect** step in Atomity.

### Inputs

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

### Outputs

`role_arn` is the value to paste into Atomity. `connection_details` has everything else in one object.

## CloudFormation

One template, `atomity.yaml`, covers a single account and, with `EnableOrganizations`, a whole
AWS Organization.

### Before you start

- The AWS CLI, or access to the CloudFormation console
- Permission to create IAM roles, S3 buckets, and Data Exports
- The external ID from the Atomity wizard
- `atomity.yaml` from the latest CloudFormation release (tags named `aws-cfn-vX.Y.Z`)
- Organizations only, once per organization, from the management account:

  ```bash
  aws organizations enable-aws-service-access \
    --service-principal member.org.stacksets.cloudformation.amazonaws.com
  ```

  You also need the ID of the organization root, for example `r-ab12`:

  ```bash
  aws organizations list-roots --query "Roots[0].Id" --output text
  ```

### Deploy

AWS creates Data Exports only in `us-east-1`, and a stack lives in one region. The
`Deploy` parameter handles this:

| `Deploy` | Creates | Region to deploy in |
|---|---|---|
| `Everything` (default) | Bucket, role, and export | `us-east-1`. The bucket is also in `us-east-1`. |
| `BucketOnly` | Bucket only | The region where you want your billing data |
| `AccessOnly` | Role and export, for a bucket made with `BucketOnly` | `us-east-1` |

**Option 1: bucket in `us-east-1`.** One stack:

```bash
aws cloudformation deploy \
  --region us-east-1 \
  --stack-name atomity \
  --template-file atomity.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    ExternalId="<from the Atomity wizard>" \
    BucketName="<a globally unique bucket name>"
```

**Option 2: bucket in another region**, for example `eu-central-1`.
Two stacks, bucket first:

```bash
aws cloudformation deploy \
  --region eu-central-1 \
  --stack-name atomity-bucket \
  --template-file atomity.yaml \
  --parameter-overrides Deploy=BucketOnly BucketName="<a globally unique bucket name>"

aws cloudformation deploy \
  --region us-east-1 \
  --stack-name atomity \
  --template-file atomity.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    Deploy=AccessOnly \
    BucketRegion=eu-central-1 \
    ExternalId="<from the Atomity wizard>" \
    BucketName="<the same bucket name>"
```

**Organizations.** Deploy from the management account and add the organization parameters to
either option above:

```bash
  ... EnableOrganizations=true OrganizationRootId="<r-ab12>"
```

Add `StackSetCallAs=DELEGATED_ADMIN` when you deploy from a StackSets delegated admin account.

To review before anything is created, add `--no-execute-changeset` to a command. Then
inspect the change set in the console and execute it there.

In the console, choose **Create stack**, upload `atomity.yaml`, and fill in the same
parameters. Acknowledge that the stack creates an IAM role with a custom name.

Then get the role ARN and paste it into the **Connect** step in Atomity:

```bash
aws cloudformation describe-stacks --region us-east-1 --stack-name atomity \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text
```

### Parameters

| Name | Default | Description |
|---|---|---|
| `ExternalId` | none (required, except `BucketOnly`) | Per-connection external ID from the wizard. Hidden in the console. |
| `BucketName` | none (required) | Name of the bucket for the export. |
| `Deploy` | `Everything` | `Everything`, `BucketOnly`, or `AccessOnly`. |
| `BucketRegion` | empty | Region of the bucket. Required only for `AccessOnly`. |
| `S3Prefix` | `atomity-exports` | Folder inside the bucket. |
| `ExportName` | `atomity-exports` | Name of the Data Export. |
| `TimeGranularity` | `HOURLY` | `HOURLY`, `DAILY`, or `MONTHLY`. |
| `EnableOrganizations` | `false` | Set to `true` in a management account to cover every member account. |
| `OrganizationRootId` | empty | Organization root ID. Required when `EnableOrganizations` is `true`. |
| `StackSetCallAs` | `SELF` | `DELEGATED_ADMIN` when deploying from a StackSets delegated admin account. |
| `AtomityRoleArn` | Atomity's collector role | The same for every customer. Normally left alone. |

### Outputs

`RoleArn` is the value to paste into Atomity. `S3Bucket`, `S3Prefix`, `ExportName`, `Region`,
`Scope` and, for Organizations, `MemberStackSet` carry the rest of the connection details.

## AWS CDK

There is no separate CDK package. CDK teams import the CloudFormation template into
their own app, so the role, permissions and export are identical to the other methods,
and `cdk diff` shows exactly what changes when you update.

### Before you start

- A CDK v2 app whose target account and region are bootstrapped (the normal setup for CDK users)
- `atomity.yaml` from the latest CloudFormation release. Check its checksum, then commit it
  to your repository, for example as `atomity/atomity.yaml`.
- The external ID from the Atomity wizard

### Deploy

TypeScript:

```ts
import * as cdk from 'aws-cdk-lib';
import { CfnInclude } from 'aws-cdk-lib/cloudformation-include';

const app = new cdk.App();

// AWS creates Data Exports only in us-east-1, so this stack must be there.
const stack = new cdk.Stack(app, 'Atomity', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'us-east-1' },
});

new CfnInclude(stack, 'Atomity', {
  templateFile: 'atomity/atomity.yaml',
  parameters: {
    ExternalId: '<from the Atomity wizard>',
    BucketName: '<a globally unique bucket name>',
  },
});
```

Python (same API):

```python
import os
import aws_cdk as cdk
from aws_cdk.cloudformation_include import CfnInclude

app = cdk.App()
stack = cdk.Stack(
    app, "Atomity",
    env=cdk.Environment(account=os.environ["CDK_DEFAULT_ACCOUNT"], region="us-east-1"),
)
CfnInclude(
    stack, "Atomity",
    template_file="atomity/atomity.yaml",
    parameters={"ExternalId": "<from the Atomity wizard>", "BucketName": "<a globally unique bucket name>"},
)

app.synth()
```

Then deploy. CDK shows the IAM changes and asks you to approve them, and prints the stack
outputs when it finishes. Paste the `RoleArn` output into the **Connect** step in Atomity.

```bash
cdk deploy Atomity
```

The parameters are the same as for [CloudFormation](#parameters). Values such as the bucket
name go in `parameters`, as above. To change a setting that switches parts of the template on
or off, set its default instead. For Organizations, e.g:

```ts
const atomity = new CfnInclude(stack, 'Atomity', { /* as above */ });
atomity.getParameter('EnableOrganizations').default = 'true';
atomity.getParameter('OrganizationRootId').default = 'r-ab12';
```

**Bucket outside `us-east-1`.** Add a second stack in the bucket's region that deploys only
the bucket, and make the access stack depend on it:

```ts
const bucketStack = new cdk.Stack(app, 'AtomityBucket', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: 'eu-central-1' },
});
const bucketTemplate = new CfnInclude(bucketStack, 'Atomity', {
  templateFile: 'atomity/atomity.yaml',
  parameters: { BucketName: '<the same bucket name>' },
});
bucketTemplate.getParameter('Deploy').default = 'BucketOnly';

// the access stack from above, with two more settings
const accessTemplate = new CfnInclude(stack, 'Atomity', {
  templateFile: 'atomity/atomity.yaml',
  parameters: {
    ExternalId: '<from the Atomity wizard>',
    BucketName: '<the same bucket name>',
  },
});
accessTemplate.getParameter('Deploy').default = 'AccessOnly';
accessTemplate.getParameter('BucketRegion').default = 'eu-central-1';
stack.addStackDependency(bucketStack);
```

**Why defaults, not `parameters`.** If you fix `Deploy` or `EnableOrganizations` in
`parameters`, CDK replaces them with constants and prints about a dozen "condition will always
return True/False" warnings. They are harmless but noisy. Setting the default leaves the
template's conditions open. The single-stack setup prints no warnings. The two-stack layout
still prints two, about outputs that the bucket stack does not create. Those are harmless too.

**Keeping the external ID out of the template.** Values you give in `parameters` are written
into the synthesized template in plain text, including the external ID. It then shows in
`cdk.out` and in the CloudFormation console, and the template's `NoEcho` no longer applies.
To keep it hidden, leave `ExternalId` out of `parameters` and pass it when you deploy:

```bash
cdk deploy Atomity --parameters Atomity:ExternalId="<from the Atomity wizard>"
```

To update, download the new release's `atomity.yaml`, replace your copy, and review `cdk diff`.

## Remove Atomity's access

### Terraform

Run this from the folder you deployed from:

```bash
terraform destroy
```

This removes the IAM role `AtomityReadOnly`, its permission policy and the Data Export. Atomity loses access immediately.

Your billing bucket is kept if it still holds files. Terraform reports an error for the bucket. That's expected: the access is already removed, and the bucket and its files stay in your account. If the bucket is empty, `terraform destroy` deletes it.

For Organizations, also delete the `AtomityMemberRoles` StackSet. Otherwise the role stays in your member accounts.

### CloudFormation

Delete the stack that contains the role (`atomity` in the examples above). If you deployed
through CDK, `cdk destroy Atomity` does the same:

```bash
aws cloudformation delete-stack --region us-east-1 --stack-name atomity
```

This removes the IAM role `AtomityReadOnly`, its permission policy and the Data Export. Atomity loses access immediately.

For Organizations, deleting the stack also deletes the `AtomityMemberRoles` StackSet and the
roles it deployed to member accounts.

The billing bucket is always kept, even if it is empty. It stays in your account and its
files continue to incur storage costs until you delete it. If you used two stacks, deleting
the bucket stack also leaves the bucket in place.

### Delete the bucket and its files too (optional, cannot be undone)

**Terraform.** Terraform only empties a bucket when the configuration says so, so set that first:

```bash
terraform apply -var="delete_bucket_contents_on_destroy=true"
terraform destroy
```

The first command changes only the bucket's setting, and deletes nothing. The second deletes the export, the role and its policy, every file in the bucket (including old versions, if versioning was on), and then the bucket.

**CloudFormation.** After deleting the stack, delete the bucket yourself. This removes every file in it:

```bash
aws s3 rb s3://<bucket name> --force
```

If versioning was turned on for the bucket, remove the old versions first, or `rb` will fail.

## Notes

- The Terraform state file contains your external ID. Don't commit it, and consider a remote backend if you keep this long term.
- First export files can take up to 24 hours to appear. You can finish connecting before then.
- Verify a download: compare it with the published `.sha256` file, or run `gh attestation verify <file> --repo atomity/cloud-onboarding`. This works for the Terraform zip and for `atomity.yaml`.
- Terraform and CloudFormation are released separately, on `aws-tf-vX.Y.Z` and `aws-cfn-vX.Y.Z` tags. You only need the one for the method you chose.