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
| Member accounts | Resource details, metrics, recommendations and tags in each account of the Organization | A narrower read-only role in every member account, including accounts added later |

The management account's billing export already includes all member accounts. Member
accounts receive only the narrower role, which has no access to billing data or S3.

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
databases or secrets. The exact policy is in [`aws/main.tf`](../aws/main.tf).

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
contract: the role name, the trust rules, and the data format.

| Approach | Best for | Status |
|---|---|---|
| Terraform | Teams that use infrastructure as code, or want a preview and a clean removal | Implemented |
| CloudFormation | AWS-only teams that prefer the console and no extra tools | Implemented |
| Manual setup | Customers who cannot use infrastructure as code | Step-by-step guide |
| AWS CDK | Teams that standardize on CDK | Not planned for now |
| Custom scripts (SDK or CLI) | None | Not offered |

### Terraform

A Terraform module creates the role, its permissions, the bucket and the export in a
single run. It is the primary approach because it shows a preview before changing
anything, tracks what it created, detects manual changes, and has a defined way to
remove everything. The code is public, so a customer's security team can read it first.

The module is published as a versioned release archive with a checksum and a build
attestation, so customers can verify what they download without needing Git.

### CloudFormation

A template for customers who prefer the AWS console and do not want to install tools. A
quick-create link would open the console with the stack ready to review, and change sets
provide the preview. A stack lives in one region, but the Data Export must be created in
`us-east-1`, so the design uses two stacks when the customer wants the bucket elsewhere:
one for the bucket and one for the role and export. Deleting the stacks keeps the
billing bucket, as in the Terraform approach. Permissions will come from the same
definitions as the Terraform module, so the two cannot drift apart.

### Manual setup

A step-by-step guide for creating the same role, policy and export by hand in the
console. It exists for customers who cannot use infrastructure as code. Because it is the
easiest approach to get wrong, it must follow the same contract as the others.

### AWS CDK

Not planned for now. CDK needs a programming toolchain on the customer's machine, and its
bootstrap step creates extra roles and a storage bucket in the customer's account, which
means more permissions to grant and review. It would also be a third copy of the access
definitions. Teams that use CDK can deploy the CloudFormation template instead. This will
be revisited if there is demand.

### Custom scripts

Not offered. A script that calls the AWS APIs directly cannot preview changes, track what
it created, or remove things cleanly, and customers would have to read and trust custom
code that creates IAM roles. Declarative templates are easier to review and safer to run.

### Choosing and switching

Use one approach per AWS account. Two tools managing the same role conflict, so to move
from one approach to another, remove the first deployment before starting the second. The
billing bucket is kept on removal, so it can be reused or replaced.

## Data and removal

Removing Atomity's access and deleting billing data are separate actions.

Removing a deployment deletes the role, its permissions and the export, so Atomity can no
longer read anything. In Organizations mode it also removes the roles in member accounts.
The billing bucket is kept if it still contains files, because the billing history belongs
to the customer. Deleting the bucket and its files is an explicit, opt-in step and cannot
be undone. Files left in the bucket stay in the customer's account and continue to incur
storage costs until the customer deletes them.

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
| Organizations: one export, plus a narrower role per member account through a StackSet | The management account's export already covers every account. Terraform cannot loop over accounts, so AWS's StackSet service handles the fan-out and new accounts. | Per-account setup, separate exports for each account |
| Terraform as the primary approach | Preview, state tracking, drift detection, a defined removal, and reviewable code | Custom scripts |
| CloudFormation as the second approach | A console-friendly option without extra tools | AWS CDK |
| A versioned release archive | No Git needed, verifiable with a checksum and attestation | Cloning the repository, the Terraform Registry (possible later) |
| One approach per account | Two tools managing the same role would conflict | Mixing approaches |

## Limitations

- The first billing files can take up to 24 hours to appear after setup.
- Organization policies, such as service control policies, can block creating roles or
  buckets. When they do, the customer's AWS administrator must allow it. This applies to
  any account that belongs to an AWS Organization, whether or not Atomity's Organizations
  mode is used.
- AWS creates Data Exports only in `us-east-1`, so that part of the setup cannot move.

## Terms

| Term | Meaning |
|---|---|
| IAM role | An AWS identity that others can assume to get temporary access |
| External ID | A unique value the caller must present to assume a role |
| FOCUS | An open standard format for cloud billing data |
| Data Export | An AWS feature that delivers billing data to an S3 bucket |
| StackSet | A CloudFormation feature that deploys the same resources to many accounts |
| Service control policy | An organization-wide rule that can block actions in member accounts |
| Management account | The account that owns an AWS Organization |