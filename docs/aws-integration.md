# AWS integration design

This document describes how Atomity connects to a customer's AWS environment: the
architecture, the security model, the approaches for setting it up, and the
decisions behind them. For setup instructions, see the
[module guide](../aws/README.md).

## Goals

- **Read-only.** Atomity can observe cost and usage data. It can never change anything.
- **Customer-controlled.** Everything is created in the customer's own account. It can
  be reviewed before it is created and removed at any time.
- **No stored credentials.** Access uses short-lived credentials, not passwords or keys.
- **Standard data.** Billing data arrives in an open format, in the customer's own storage.
- **Consistent.** However it is set up, the result in the customer's account is the same.

## Architecture

Setting up creates three things in the customer's AWS account: a read-only IAM role,
a private S3 bucket, and an AWS Data Export that delivers billing data to that bucket.

```
Atomity
   │   assumes the role (needs the customer's external ID)
   ▼
┌─────────────────────── Your AWS account ───────────────────────┐
│                                                                │
│ IAM role "AtomityReadOnly" ──── reads ────▶ S3 bucket          │
│ (read-only permissions)                         ▲              │
│                                                 │ writes       │
│                                  AWS Data Export (FOCUS 1.2)   │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Atomity gets access in three steps:

1. Atomity asks AWS for temporary credentials for the role and presents the customer's
   external ID.
2. AWS checks that the caller is the trusted Atomity role and that the external ID matches.
3. Atomity reads the billing files and a limited set of account information with those
   credentials, which expire after a short time.

## Scopes

| Scope | What it covers | What is created |
|---|---|---|
| Single account | One AWS account. It may still belong to an AWS Organization. | The role, its permissions, the bucket and the export |
| Organization | Billing data for every account in an AWS Organization, from one connection | The same, in the management account |
| Member accounts | Resource details, metrics, recommendations and tags in each account of the Organization | A narrower read-only role in every member account, including accounts added later, deployed through a StackSet |

The management account's billing export already includes all member accounts. Member
accounts receive only the narrower role, which has no access to billing data or S3.
Terraform and CloudFormation (and so CDK) deploy the same member role template.

## Access and security

### What Atomity can read

| Area | What it covers |
|---|---|
| Billing and cost | Cost and usage, forecasts, anomalies, and the billing export files in the bucket |
| Recommendations | AWS Cost Optimization Hub and Compute Optimizer recommendations |
| Resource details | Details of EC2 instances and volumes, RDS database instances and load balancers |
| Metrics | CloudWatch metrics |
| Tags | Resource tags |
| Account structure | The list of accounts in the AWS Organization, if there is one |
| S3 | Bucket names and locations. File contents are readable only in the billing bucket. |

The policy contains only read actions. It does not allow creating, changing, deleting or
purchasing anything, and it does not grant access to the contents of other S3 buckets,
databases or secrets. The exact policies are in
[`aws/policies/permission.json`](../aws/policies/permission.json) (management account) and
[`aws/member_role.yaml`](../aws/member_role.yaml) (member accounts).

### How access is protected

- **An assumable role, not keys.** Atomity holds no password or access key for the account.
- **An external ID.** The role can only be assumed when the caller presents a unique value
  generated for that customer. This stops anyone else from tricking Atomity into using the
  customer's role.
- **One trusted identity.** The role trusts a single, specific Atomity role, not the whole
  Atomity AWS account.
- **A private bucket.** Public access is blocked, and only AWS billing exports from the
  customer's own account can write to it.
- **Revocable.** Deleting the role ends Atomity's access immediately.

## Approaches

The same result can be created in several ways. Each approach follows the same
contract: the role name, the trust rules, and the data format. The onboarding wizard
generates the exact commands for each approach.

| Approach | Best for | Status |
|---|---|---|
| Terraform | Teams that use infrastructure as code, or want a preview and a clean removal | Implemented |
| CloudFormation | AWS-only teams that prefer the console or CLI and no extra tools | Implemented |
| AWS CDK | Teams that standardize on CDK | Supported by importing the CloudFormation template |
| Manual setup | Customers who cannot use infrastructure as code | Step-by-step guide |
| Custom scripts (SDK or CLI) | None | Not offered |

### Terraform

A Terraform module creates the role, its permissions, the bucket and the export in a
single run. It is the primary approach because it shows a preview before changing
anything, tracks what it created, detects manual changes, and has a defined way to
remove everything. The code is public, so a customer's security team can read it first.

The module is published as a versioned release archive (tag `aws-tf-vX.Y.Z`) with a
checksum and a build attestation, so customers can verify what they download without
needing Git. The archive contains only the module. Before a release is published, CI
validates the extracted archive on its own, so a file the module reads cannot be missing
from it.

### CloudFormation

A single template, `atomity.yaml`, for customers who prefer the AWS console or CLI and do
not want to install tools. Change sets provide the preview, and a customer can also upload
the template in the console.

A stack lives in one region, but the Data Export must be created in `us-east-1`. One
`Deploy` parameter selects what a stack creates:

| `Deploy` | Creates | Deployed in |
|---|---|---|
| `Everything` (default) | Bucket, role and export | `us-east-1`. The bucket is also there. |
| `BucketOnly` | The bucket | The region where the customer wants the data |
| `AccessOnly` | Role and export, for a bucket made with `BucketOnly` | `us-east-1` |

A customer who wants the bucket elsewhere deploys two stacks, bucket first. Template rules
reject a deployment in the wrong region. The template also deploys the member-account roles
through a StackSet when `EnableOrganizations` is true.

Deleting the stack keeps the billing bucket. Unlike Terraform, which deletes an empty
bucket, CloudFormation always keeps it, because a retain policy cannot depend on a
parameter. Deleting the bucket is a manual step.

The template is published as a versioned release asset (tag `aws-cfn-vX.Y.Z`) with a
checksum and a build attestation. It is generated, not written by hand. See
[Keeping the approaches consistent](#keeping-the-approaches-consistent).

### AWS CDK

There is no separate CDK package. CDK teams download the released CloudFormation template
and import it into their own app with CDK's `CfnInclude`. The role, permissions and export
are therefore identical to the other approaches, and `cdk diff` shows exactly what changes
when they update. Their CDK environment must already be bootstrapped, which is normal for
CDK users. That removes the original objection to CDK, which was asking customers to
install a toolchain and bootstrap an account only to connect to Atomity.

A construct library (`new AtomityConnection(...)`) was considered and is not planned. It
would be a third implementation of the access definitions to keep identical, a published
package for customers to trust, and one more release line to maintain. It will be revisited
if several customers ask for typed configuration.

A test in CI imports the released template through `CfnInclude` and synthesizes it on every
change, so the promise that the template works in a CDK app stays true. It checks the role,
the retained bucket, the export, the permissions and the two-stack layout. It also checks
that the single-stack and Organizations setups print no CDK warnings. It only synthesizes
and never deploys.

Notes for CDK users:

- Values passed in `parameters` are written into the synthesized template in plain text,
  including the external ID. The wizard passes the external ID at deploy time instead
  (`--parameters`), which keeps it out of the repository and the template.
- A deployment mode should be set through a parameter's default, not its value. Replacing
  `Deploy` with a constant makes CDK print about a dozen "condition always true or false"
  warnings. With defaults, the single-stack setup prints none and the two-stack setup
  prints two harmless ones.

### Manual setup

A step-by-step guide for creating the same role, policy and export by hand in the
console. It exists for customers who cannot use infrastructure as code. Because it is the
easiest approach to get wrong, it must follow the same contract as the others.

### Custom scripts

Not offered. A script that calls the AWS APIs directly cannot preview changes, track what
it created, or remove things cleanly, and customers would have to read and trust custom
code that creates IAM roles. Declarative templates are easier to review and safer to run.

### Choosing and switching

Use one approach per AWS account. Two tools managing the same role conflict, so to move
from one approach to another, remove the first deployment before starting the second. The
billing bucket is kept on removal if it still has files, so it can be reused or replaced.

## Keeping the approaches consistent

The goal that every approach gives the same result is enforced by sharing definitions,
not by hoping separate copies stay equal.

| Shared file | Used by |
|---|---|
| `aws/policies/trust.json` | Terraform (read directly) and CloudFormation (inlined at build time) |
| `aws/policies/permission.json` | Terraform (read directly) and CloudFormation (inlined at build time) |
| `aws/member_role.yaml` | Terraform and CloudFormation, as the StackSet template for member accounts |
| `aws/focus_query.sql` | Terraform (read directly) and CloudFormation (inlined at build time) |

A CloudFormation template must be one self-contained file, so
`aws/cloudformation/atomity.yaml` is generated by a build script from a hand-written
source template and the shared files. CDK uses that same generated template. CI enforces
the rest:

- The committed template must match what the build script produces.
- The member role template must match the shared policies, statement by statement.
  Its trust policy and role name must match too.
- The template must pass `cfn-lint`, and must import and synthesize through CDK.
- The Terraform module must validate on the oldest supported version and the latest.
- A release archive must validate on its own.

## Releases

Each approach is released on its own tag, because a customer uses only one of them:
`aws-tf-vX.Y.Z` for Terraform and `aws-cfn-vX.Y.Z` for CloudFormation (and CDK). CI runs
before every release. When a shared file has changed since the other approach's latest
release, the release prints a warning, so one approach does not silently keep old
policies. A change to a shared file should be released for both approaches.

## Data and removal

Removing Atomity's access and deleting billing data are separate actions.

Removing a deployment deletes the role, its permissions and the export, so Atomity can no
longer read anything. In Organizations mode it also removes the roles in member accounts.
The billing bucket is kept if it still contains files, because the billing history belongs
to the customer. Terraform deletes an empty bucket. CloudFormation and CDK always keep it.
Deleting the bucket and its files is an explicit, opt-in step and cannot be undone. Files
left in the bucket stay in the customer's account and continue to incur storage costs
until the customer deletes them.

## Design decisions

| Decision | Why | Alternatives considered |
|---|---|---|
| Access through an assumable IAM role | No credentials to store or rotate, short-lived access, and the customer can revoke it by deleting the role | An IAM user with access keys |
| A required, per-customer external ID with no default | Prevents another party from tricking Atomity into using a customer's role | No external ID, or one shared by all customers |
| Trust one specific Atomity role | Limits who can use the customer's role to a single, known identity | Trusting the whole Atomity AWS account |
| A fixed role name | Keeps the permissions Atomity needs on its own side narrow and predictable | Customer-chosen names |
| Read-only permissions only | Atomity needs to observe, never to change | None |
| Billing data as a FOCUS 1.2 Parquet export in the customer's own bucket | An open standard, the data stays in the customer's account, and no extra analytics services are needed | The legacy Cost and Usage Report, CSV files |
| The module creates the bucket | One less thing for the customer to prepare, and its access rules are managed together with the rest | A customer-supplied bucket, which may be offered later |
| A private bucket that only the customer's own billing exports can write to | Keeps exposure of billing data to a minimum | None |
| Bucket in the customer's region, export in `us-east-1` | AWS creates Data Exports only in `us-east-1`, and customers keep storage where they want it | One region for everything |
| Keep the bucket on removal by default | Billing history belongs to the customer, and deleting it should be deliberate | Deleting everything on removal |
| Organizations: one export, plus a narrower role per member account through a StackSet | The management account's export already covers every account. Terraform cannot loop over accounts, so AWS's StackSet service handles the fan-out and new accounts. Both approaches deploy the same member template. | Per-account setup, separate exports for each account |
| Terraform as the primary approach | Preview, state tracking, drift detection, a defined removal, and reviewable code | Custom scripts |
| CloudFormation as the second approach | A console-friendly option without extra tools | AWS CDK as a separate implementation |
| One CloudFormation template with a `Deploy` mode, not several templates | One file to review and release. The two-stack case for a bucket outside `us-east-1` needs only a parameter. | Separate bucket and access templates |
| Shared policy, query and member role files, with the CloudFormation template generated from them | Terraform reads them directly. CloudFormation needs one file, so a build step inlines them, and CI checks it. This keeps the approaches from drifting apart. | Hand-maintained copies in each approach |
| CDK through the released CloudFormation template, not a construct library | No new implementation or package to keep identical and trust. CDK teams already have a bootstrapped environment. | A construct library, a starter CDK app |
| Separate release tags for Terraform and CloudFormation | A customer uses only one, so each sees only its own artifact and version history | One release containing both |
| A versioned release archive | No Git needed, verifiable with a checksum and attestation | Cloning the repository, the Terraform Registry (possible later) |
| One approach per account | Two tools managing the same role would conflict | Mixing approaches |

## Limitations

- The first billing files can take up to 24 hours to appear after setup.
- Organization policies, such as service control policies, can block creating roles or
  buckets. When they do, the customer's AWS administrator must allow it. This applies to
  any account that belongs to an AWS Organization, whether or not Atomity's Organizations
  mode is used.
- AWS creates Data Exports only in `us-east-1`, so that part of the setup cannot move. With
  CloudFormation or CDK, a bucket in another region therefore needs two stacks.
- Removing a CloudFormation or CDK deployment never deletes the billing bucket. The customer
  deletes it separately if they want it gone.
- CDK deployments need a bootstrapped CDK environment, and the CDK test checks that the
  template synthesizes but does not deploy it.

## Terms

| Term | Meaning |
|---|---|
| IAM role | An AWS identity that others can assume to get temporary access |
| External ID | A unique value the caller must present to assume a role |
| FOCUS | An open standard format for cloud billing data |
| Data Export | An AWS feature that delivers billing data to an S3 bucket |
| StackSet | A CloudFormation feature that deploys the same resources to many accounts |
| Change set | A CloudFormation preview of what a deployment would create or change |
| AWS CDK | A framework that defines AWS resources in code and deploys them through CloudFormation |
| CfnInclude | A CDK feature that imports an existing CloudFormation template into a CDK app |
| Bootstrap | The one-time CDK setup of an account and region, which creates its own roles and a storage bucket |
| Service control policy | An organization-wide rule that can block actions in member accounts |
| Management account | The account that owns an AWS Organization |