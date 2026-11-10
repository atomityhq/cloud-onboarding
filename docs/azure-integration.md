# Azure integration design

This document describes how Atomity connects to a customer's Azure environment: the
architecture, the security model, the approaches for setting it up, and the decisions behind
them. It follows the structure of the [AWS integration design](aws-integration.md). For setup
instructions, see the [module guide](../azure/README.md).

## Goals

- **Read-only.** Atomity can observe cost and usage data. It can never change anything.
- **Customer-controlled.** Everything is created in the customer's own tenant. It can be
  reviewed before it is created and removed at any time.
- **No shared secret.** The customer holds no password, key or secret for Atomity. Access
  exists only as role assignments inside the customer's own tenant.
- **Standard data.** Billing data arrives in an open format, in the customer's own storage.
- **Consistent.** However it is set up, the result in the customer's tenant is the same.

## Architecture

Setting up creates four things in the customer's Azure tenant: a Service Principal for Atomity's
application, a read-only `Reader` role assignment for inventory and metrics, a read-only blob
role on one storage account, and a Cost Management export that delivers billing data to that
storage account.

```
Atomity (multi-tenant Entra application)
   │   authenticates in your tenant as its Service Principal
   ▼
┌────────────────────── Your Azure tenant ───────────────────────┐
│                                                                │
│ Service Principal "Atomity"  (created by consent)              │
│    │                                                           │
│    ├── Reader ───────────────▶ root management group           │
│    │                           (or each subscription you list) │
│    │                                                           │
│    └── Storage Blob Data Reader ──▶ Storage account            │
│                                          ▲                     │
│                                          │ writes              │
│                       Cost Management export (FOCUS, Parquet)  │
│                       created on your billing account          │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

Atomity gets access in four steps:

1. The customer creates the Service Principal for Atomity's multi-tenant application in their
   tenant (the consent step). This grants no permissions.
2. The customer assigns read-only roles to that Service Principal.
3. Atomity authenticates against the customer's tenant as its application. Azure issues a
   short-lived token that allows only what the assigned roles allow.
4. Atomity reads the billing files and a limited set of resource information with that token.

## Scopes

Three things are scoped independently.

| Scope | What it covers | What is created |
|---|---|---|
| Management group (recommended) | Resource details, metrics and recommendations for every subscription under the root management group, including subscriptions added later | One `Reader` assignment on the root management group |
| Per subscription | The same, for the subscriptions the customer lists | One `Reader` assignment per listed subscription. With an empty list nothing is assigned, and Atomity discovers the subscriptions it already has `Reader` on |
| Billing account | Billing data for every subscription under that billing account, from one connection | One FOCUS export on the billing account |
| Storage account | The export files | One `Storage Blob Data Reader` assignment on the storage account that receives them |

The export follows the billing account, not the `Reader` scope. In per-subscription mode the
billing data can therefore include subscriptions that Atomity cannot inspect. Those show up in
cost data but have no resource details or metrics.

## Access and security

### What Atomity can read

| Area | What it covers |
|---|---|
| Billing and cost | The FOCUS export files in the storage account |
| Recommendations | Azure Advisor recommendations, including cost recommendations |
| Resource details | Configuration of the resources in scope |
| Metrics | Azure Monitor metrics |
| Tags | Resource tags |
| Account structure | The subscriptions in scope, listed through the management group |
| Storage | File contents of the one storage account that receives the export |

Both roles are Azure built-in roles: `Reader` (`acdd72a7-3385-48ef-bd42-f606fba81ae7`) and
`Storage Blob Data Reader` (`2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`). Neither allows creating,
changing, deleting or purchasing anything. `Reader` shows the configuration of resources, but
not the data inside them, such as blob contents, Key Vault secrets or database contents.

`Reader` covers more resource types than the hand-written AWS policy does, because it is a
built-in role rather than a list of selected actions.

### How access is protected

- **No credential for the customer to hold.** The only credential belongs to Atomity's own
  application. It grants nothing in a tenant until the customer assigns roles.
- **Consent grants nothing.** Creating the Service Principal gives Atomity no permission. Every
  permission is an explicit role assignment that the customer makes, scopes and can see.
- **Standard role assignments.** They appear in Access control (IAM) and in the Activity log,
  where the customer's usual tooling already looks.
- **One storage account.** Blob access applies to the whole storage account, not to one
  container. Customers are advised to use a storage account dedicated to the export.
- **Revocable.** Removing the role assignments, or deleting the Service Principal under
  Enterprise applications, ends Atomity's access. Azure can take a few minutes to apply the
  change.
- **Pinned to the right tenant.** The Terraform module pins its providers to the customer's
  tenant, so a wrong sign-in context fails instead of creating resources elsewhere.

## Approaches

The same result can be created in several ways. Each approach follows the same contract: the
application, the roles and their scopes, and the export definition. The onboarding wizard
generates the exact commands or links for each approach.

| Approach | Best for | Status |
|---|---|---|
| Terraform | Teams that use infrastructure as code, or want a preview and a clean removal | Implemented |
| Cloud Shell script | Customers who want one paste and no installed tools | Implemented |
| ARM template with a Deploy to Azure button | Customers who prefer the portal and no extra tools. The counterpart of CloudFormation. | Planned |
| Bicep module | Teams that standardize on Bicep. The counterpart of CDK. | Planned |
| Manual setup | Customers who cannot use any of the above | Implemented (the wizard walkthrough) |
| Custom scripts (SDK, CLI or REST) | None | Not offered |

What each approach does for the three parts of the contract:

| Part | Terraform and Cloud Shell | ARM template and Bicep | Manual |
|---|---|---|---|
| Service Principal (consent) | Created by the run | Already exists. Created in the wizard's consent step. Its object ID is a parameter. | Consent link |
| Role assignments | Created by the run | Created by the deployment | Portal, Access control (IAM) |
| FOCUS export | Created by the run | Created by the deployment (see open question 1) | Portal, Cost Management exports |

### Terraform

A Terraform module creates the Service Principal, the role assignments, the resource provider
registration and the export in a single run. It is the primary approach for the same reasons as
on AWS: it shows a preview before changing anything, tracks what it created, detects manual
changes, and has a defined way to remove everything. The code is public, so a customer's
security team can read it first.

Identity and RBAC use the `azuread` and `azurerm` providers. The export uses `azapi`, because
`azurerm` cannot create FOCUS exports. The module reads no files, so a release archive cannot
be missing one.

The module is published as a versioned release archive (tag `azure-tf-vX.Y.Z`) with a checksum
and a build attestation. The customer supplies an existing storage account.

### Cloud Shell script

For customers who do not use infrastructure as code and do not want to install anything. Azure
Cloud Shell runs in the portal, is already signed in, and includes the Azure CLI and Terraform.
The customer pastes one command that the wizard generates with their values.

The script is a thin wrapper over the released Terraform module. It downloads a pinned release,
verifies its checksum, shows the plan, asks for confirmation, and then applies. A `plan` command
stops after the plan, and a `remove` command runs the destroy.

Two checksums protect the paste. The wizard's command includes the script's own checksum and
verifies it before the script runs. The script, once verified, carries the checksum of every
Terraform release it pins, and verifies the download of the one it runs. The checksum comes from the wizard rather
than from the same release page as the script, so one compromised download location cannot
supply both.
The script accepts only plain characters in the values it writes into the Terraform
settings, so a pasted value cannot add configuration of its own. It holds no definition of the access of its own, so it cannot drift from
Terraform. That is what separates it from the custom scripts described below.

The Terraform state stays in Cloud Shell's persistent storage. The script is released on its own
tag (`azure-shell-vX.Y.Z`) and pins one or more Terraform releases. It runs the newest by
default, so customers get a new Terraform release when the wizard points them at a script
release that includes it. A `--module-tag` option runs an older pinned release, for rollback
or testing. If the newest release has been deleted, the script falls back to the next pin.
It falls back only when a release is gone (HTTP 404 or 410). A checksum mismatch, any other
HTTP error, or a network error stops it without trying another version, so a replaced release
is never hidden behind an older one. Removal uses the release that created the connection,
because a newer module may expect inputs the saved settings do not have.

Publishing a Terraform release opens a pull request that adds it to the script's pins.
Merging it and tagging a script release ships it.

### ARM template with a Deploy to Azure button

The counterpart of CloudFormation. One self-contained template deploys at management group
scope. The customer opens it from a button in the wizard, fills in the parameters in the portal,
and reviews the result before creating it. `az deployment mg what-if` gives the same preview
from the command line.

ARM templates manage Azure resources, not Entra ID objects. The Microsoft Graph extension lets
Bicep create a Service Principal, but its Service Principal type is still in beta and cannot be
compiled into the ARM template that the button uses. This approach therefore starts after the
consent step, and takes the Service Principal's object ID as a parameter.

Unlike a CloudFormation stack, deleting an ARM deployment does not delete what it created.
Removal is a separate step: see [Data and removal](#data-and-removal).

The template is generated from the Bicep source (`bicep build`), not written by hand. See
[Keeping the approaches consistent](#keeping-the-approaches-consistent).

### Bicep module

The counterpart of CDK, for teams that already write Bicep. The customer references the module
from their own Bicep files and passes the same parameters as the template, and `what-if` shows
exactly what changes when they update.

The dependency runs the other way round than on AWS. On AWS the CloudFormation template is the
source and CDK imports it. On Azure the Bicep module is the source and the ARM template is
compiled from it. The role assignments and export are therefore identical in both by
construction.

Both are released on one tag (`azure-bicep-vX.Y.Z`), because a customer uses only one of them.

### Manual setup

The step-by-step walkthrough in the wizard: the admin consent link, role assignments in the
portal, and a Cost Management export created by hand. It exists for customers who cannot use
infrastructure as code or a template. Because it is the easiest approach to get wrong, it must
follow the same contract as the others.

### Custom scripts

Not offered. A script that calls the Azure CLI, REST or SDK directly with its own copy of the
access definitions cannot preview changes, track what it created, or remove things cleanly, and
customers would have to read and trust custom code that assigns roles. The Cloud Shell script
avoids this by running the Terraform module instead of reimplementing it.

### Choosing and switching

Use one approach per tenant. Two tools managing the same role assignments conflict, and the
second one fails because the assignments already exist. Terraform and the Cloud Shell script
keep separate state, so they count as two tools. To move from one approach to another, remove
the first deployment before starting the second. The storage account, the container and the
exported files are never removed, so the new deployment can reuse them.

## Keeping the approaches consistent

The goal that every approach gives the same result is enforced by sharing definitions, not by
hoping separate copies stay equal. On Azure the shared definitions are small, because the roles
are built in and need no policy files.

| Shared definition | Used by |
|---|---|
| The application ID `c4b84012-e86e-4ea0-9c42-5e015c1c30f4` | Every approach |
| The two built-in role IDs, and where each is assigned | Every approach |
| The export definition: `FocusCost`, Parquet, Snappy, daily, partitioned, overwrite, dataset version | Terraform, and the Bicep source that the ARM template is built from |
| The Terraform releases that the Cloud Shell script pins, newest used by default | Cloud Shell script |

A template must be one self-contained file, so the ARM template is generated from the Bicep
source by a build step. CI enforces the rest:

- The committed ARM template must match what `bicep build` produces.
- The role IDs, scopes and export settings in the Terraform module must match those in the
  Bicep source.
- The Terraform module must validate on the oldest supported version and the latest.
- A release archive must validate on its own.
- The Cloud Shell script must point at a Terraform release that exists, and verify its checksum.

## Releases

Each approach is released on its own tag, because a customer uses only one of them:
`azure-tf-vX.Y.Z` for Terraform, `azure-shell-vX.Y.Z` for the Cloud Shell script, and
`azure-bicep-vX.Y.Z` for the ARM template and the Bicep module. CI runs before every release.
When a shared definition has changed since another approach's latest release, the release prints
a warning, so one approach does not silently keep old settings. A change to a shared definition
should be released for every approach that uses it.

## Data and removal

Removing Atomity's access and deleting billing data are separate actions.

Removing a Terraform or Cloud Shell deployment deletes the export, every role assignment and the
Service Principal, so Atomity can no longer read anything. The resource provider registration is
left in place, because other exports in the subscription may rely on it.

The storage account, the container and the exported files are never managed by Terraform, so
removal never touches them. The billing history belongs to the customer. Unlike AWS, there is no
opt-in to delete them: the storage account is the customer's own, and the customer deletes the
files, or the account, when they choose. Files left behind continue to incur storage costs.

Removing an ARM or Bicep deployment, or a manual setup, takes two steps. Deleting the Service
Principal under Enterprise applications removes every role assignment at once. The Cost
Management export is then deleted in the portal, or it keeps writing files.

## Design decisions

| Decision | Why | Alternatives considered |
|---|---|---|
| Access through the Service Principal of a multi-tenant application, created by consent | The customer holds no credential, access exists only in their tenant, and deleting the Service Principal revokes it | A customer-created app registration with a client secret, which has to be shared, rotated and protected |
| No external ID | Azure has no assume-role step. Atomity authenticates against the customer's own tenant, and the Service Principal there has only the roles that customer assigned | None |
| Consent grants nothing, and roles are assigned in a separate step | The customer sees every permission as an explicit assignment they control | Granting API permissions at consent |
| Built-in `Reader` and `Storage Blob Data Reader` roles | Security reviewers know them, there is no role definition to create or keep current, and both are read-only | A custom role limited to the actions Atomity uses. Narrower, but one more definition to maintain in every customer tenant |
| `Reader` on the root management group is recommended, with per-subscription as an alternative | One assignment covers current and future subscriptions. Per-subscription suits customers who cannot or will not grant at the root | Per-subscription only |
| With per-subscription and no IDs listed, Terraform assigns nothing and Atomity discovers what it can read | Matches the wizard, and lets customers grant `Reader` through their own process | Requiring at least one subscription |
| Blob access on one storage account, always | Billing files are the only blob data Atomity needs | Blob access on a whole subscription |
| Billing data as a FOCUS Parquet export in the customer's own storage | An open standard, the data stays in the customer's tenant, and no extra analytics services are needed | CSV exports, the legacy usage details exports |
| FOCUS 1.2 (`1.2-preview`) by default | The same schema as the AWS export, so one reader handles both clouds. Azure's FOCUS 1.2 is still a preview | FOCUS 1.0 or 1.0r2, which are generally available but a different schema |
| The export is created at billing account scope | Azure does not support FOCUS exports at management group scope, and a billing account export covers every subscription under it | One export per subscription |
| The customer supplies the storage account | The wizard asks for it, and the module never owns the customer's data store, so removal cannot delete billing data | The module creates the storage account, as it does the bucket on AWS. May be offered later |
| The module never unregisters `Microsoft.CostManagementExports` | Other exports in the subscription may rely on it | `azurerm_resource_provider_registration`, which unregisters on destroy |
| The export uses `azapi`, not `azurerm` | `azurerm` cannot create FOCUS exports | Waiting for `azurerm` support |
| ARM and Bicep approaches take the Service Principal's object ID as a parameter | ARM cannot create Entra objects, and the Bicep Service Principal type is in beta | Creating it with the Graph Bicep extension once it is generally available |
| Terraform as the primary approach | Preview, state tracking, drift detection, a defined removal, and reviewable code | Custom scripts |
| The Cloud Shell script wraps the Terraform module | One paste for customers without Terraform, with the same preview and removal, and no second definition to keep identical | A standalone Azure CLI script |
| The Cloud Shell script pins several Terraform releases, runs the newest, and falls back only when a release is gone | Customers get a new release through a script release, a bad release can be bypassed with `--module-tag`, and a deleted release does not strand customers. Every pin has a known checksum, so verification still works. A replaced release is never hidden: a checksum mismatch stops the run | One pin, where every Terraform change and every rollback needs a new script. Resolving "latest" at run time, which needs the rate-limited GitHub API and leaves nothing to verify the download against. Falling back on any error, which would hide a replaced release |
| One ARM template, generated from the Bicep source | One definition to review and release. The ARM template and the Bicep module cannot differ | A hand-written template next to a separate Bicep module |
| Separate release tags per approach | A customer uses only one, so each sees only its own artifact and version history | One release containing everything |
| One approach per tenant | Two tools managing the same role assignments would conflict | Mixing approaches |

## Limitations

- The first billing files can take up to 24 hours to appear after setup.
- The billing account roles that create exports (for EA, Enterprise Administrator, and for MCA, a
  billing account owner or contributor) are often held by finance rather than by the cloud
  administrators. The person completing the wizard may need a second person.
- FOCUS exports need an Enterprise Agreement or Microsoft Customer Agreement billing account.
  Pay-as-you-go (WebDirect) agreements are not supported.
- Assigning `Reader` on the root management group needs Owner or User Access Administrator
  there. A Global Administrator who is not yet Owner must first elevate access.
- A storage account behind a firewall must allow trusted Azure services for exports to reach it.
- Azure Policy and deny assignments can block role assignments or exports. When they do, the
  customer's Azure administrator must allow them.
- Azure can take a few minutes to apply a new or removed role assignment.
- Azure's FOCUS 1.2 export is a preview, so its schema can still change.
- Deleting an ARM or Bicep deployment never removes what it created. Customers remove access
  by deleting the Service Principal and the export.
- The Cloud Shell script keeps its state in Cloud Shell's persistent storage. A customer who
  has never used Cloud Shell is first asked to create a small storage account for it. If that
  state is lost, removal falls back to deleting the Service Principal and the export.
- The Terraform module and the Cloud Shell script create the Service Principal themselves, which
  needs an Entra role that can create one. The consent link in the other approaches needs a
  Global Administrator or Privileged Role Administrator.

## Terms

| Term | Meaning |
|---|---|
| Tenant | A customer's Microsoft Entra directory, the boundary for identities and access |
| Service Principal | The identity an application has inside one tenant. Roles are assigned to it |
| Multi-tenant application | An app registration that any tenant can consent to, which creates its own Service Principal there |
| Consent | The step that creates Atomity's Service Principal in the customer's tenant |
| RBAC | Azure role-based access control, the role assignments on a scope |
| Management group | A container above subscriptions. The root management group holds everything in the tenant |
| Billing account | The commercial agreement (EA or MCA) that subscriptions are billed under |
| FOCUS | An open standard format for cloud billing data |
| Cost Management export | An Azure feature that delivers billing data to a storage account on a schedule |
| ARM template | Azure's JSON deployment format |
| Bicep | A language that compiles to ARM templates |
| Deploy to Azure button | A link that opens a template in the portal with a form for its parameters |
| Cloud Shell | A browser-based shell in the Azure portal with the Azure CLI and Terraform installed |
| What-if | A preview of what a deployment would create or change |
| Azure Policy | Rules that can allow or block actions across subscriptions |

## Open questions

These need an answer from whoever owns the approach before this document is final.

1. **ARM and Bicep scopes.** A deployment targets one scope, but this setup spans three: `Reader`
   on a management group, the blob role on a storage account, and the export on a billing
   account. Can one template do all three with nested deployments, or does the export stay a
   separate step?
2. **Deploy to Azure at management group scope.** Confirm how the portal handles a template whose
   schema is management group scope, and which permission the customer needs to run it.
3. **Cloud Shell state.** Is persistent Cloud Shell storage acceptable for the Terraform state,
   or should the script use another backend?
4. **Tag names.** `azure-shell` and `azure-bicep` are proposals.
5. **Dataset version.** Switch the default from `1.2-preview` once Azure releases FOCUS 1.2 as
   generally available.