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

The subscription ARM template requires at least one subscription. An empty list, which Terraform
and Cloud Shell allow so that Atomity can discover what it already reads, would deploy nothing.

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
| ARM templates | Teams and pipelines that deploy with the Azure CLI or PowerShell. Two templates, one per scope. The counterpart of CloudFormation. | Built, not yet deployed in a tenant |
| Bicep module | Teams that standardize on Bicep. The counterpart of CDK. | Built, not yet deployed in a tenant |
| Manual setup | Customers who cannot use any of the above | Implemented (the wizard walkthrough) |
| Custom scripts (SDK, CLI or REST) | None | Not offered |

What each approach does for the three parts of the contract:

| Part | Terraform and Cloud Shell | ARM template and Bicep | Manual |
|---|---|---|---|
| Service Principal (consent) | Created by the run | Already exists. Created in the wizard's consent step. Its object ID is a parameter. | Consent link |
| Role assignments | Created by the run | Created by the deployment | Portal, Access control (IAM) |
| FOCUS export | Created by the run | Not created by the template. Created afterwards by a documented `az rest` command that sends the same definition as Terraform. | Portal, Cost Management exports |

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

### ARM templates

The counterpart of CloudFormation. There are two self-contained templates, because the two scopes
are deployed with different commands and need different rights. Each does one thing:

| Template | `Reader` on | Deployed with | Rights needed |
|---|---|---|---|
| `atomity.json` | The management group, so every current and future subscription | `az deployment mg create` | Deployment and role assignment rights at the management group |
| `atomity-subscription.json` | Each listed subscription | `az deployment sub create` | Rights only on those subscriptions and on the storage account |

Both also assign `Storage Blob Data Reader` on the storage account. Those are the only two roles
either template can assign, and the build checks that on the compiled templates.

Management group deployments are made with the Azure CLI, PowerShell or the REST API, so there is
no portal button. The customer pastes one command into Cloud Shell. It downloads the template,
checks it against a checksum that the wizard embeds, the same way as the Cloud Shell script, and
runs `az deployment mg create` or `az deployment sub create`. The matching `what-if` gives the
preview.

The subscription template exists because per-subscription mode is usually chosen by customers who
cannot act at a management group, and a management group deployment would still need rights there.
It can be run against any one of the listed subscriptions. A subscription deployment can target the
other subscriptions and the storage account's resource group, so one run covers them all.

ARM templates manage Azure resources, not Entra ID objects. The Microsoft Graph extension lets
Bicep create a Service Principal, but its Service Principal type is still in beta and cannot be
compiled into an ARM template. This approach therefore starts after the consent step, and takes
the Service Principal's object ID as a parameter.

It does not create the Cost Management export. A single deployment targets one scope, and the
export belongs to the billing account, which neither template can reach. The customer creates the
export afterwards with a documented `az rest` command. It sends the same export definition as the
Terraform module, and a CI test compares the two field by field.

Unlike a CloudFormation stack, deleting an ARM deployment does not delete what it created.
Removal is a separate step: see [Data and removal](#data-and-removal).

The templates are generated from the Bicep source, never edited by hand. See
[Keeping the approaches consistent](#keeping-the-approaches-consistent).

### Bicep module

The counterpart of CDK, for teams that already write Bicep. The customer unzips the release's
`<tag>-modules.zip` into their repository and calls `main.bicep` (management group) or
`subscription.bicep` (subscription) as a module from a template at the same scope, with the same
parameters as the matching ARM template. `what-if` then shows exactly what changes when they
update.

The dependency runs the other way round than on AWS. On AWS the CloudFormation template is the
source and CDK imports it. On Azure the Bicep module is the source and the ARM templates are
compiled from it, so the role assignments are identical in both by construction.

All of it is released on one tag (`azure-bicep-vX.Y.Z`): the two ARM templates and the modules
zip, because a customer uses only one of the two ways.

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
| The two built-in role IDs, and where each is assigned | Every approach. The Bicep build fails if the compiled template references any other role. |
| The Bicep compiler version, pinned with its checksum | The ARM templates, and every place that builds or checks them |
| The export definition: `FocusCost`, Parquet, Snappy, daily, partitioned, overwrite, dataset version | Terraform, and the `az rest` command in the module README that the ARM and Bicep approach uses. CI compares them. |
| The Terraform releases that the Cloud Shell script pins, newest used by default | Cloud Shell script |

A template must be one self-contained file, so the ARM templates are generated from the Bicep
source by a build step. CI enforces the rest:

- Each committed ARM template must be exactly what the pinned Bicep compiler produces from its
  Bicep file. Any difference fails, not only a change to the parameters, and the compiler must
  report no errors and no warnings.
- Each compiled template must use the scope its schema names, may contain only role assignments
  and nested deployments, may assign only the built-in `Reader` and `Storage Blob Data Reader`
  roles (the same two the Terraform module assigns by name), must be for a Service Principal in
  every assignment, and must take exactly the parameters the docs rely on. The two templates must
  take the storage account parameters in exactly the same way.
- The export command in the module README must send the same definition as the Terraform module:
  the same fields, constants, defaults, API version, export name, scope and resource provider. A
  change on one side without the other fails CI.
- The release recompiles the template from the tagged commit, then compiles the released Bicep
  zip on its own and compares the result with the released templates, so the assets agree and the
  zip is complete.
- The Terraform module must validate on the oldest supported version and the latest.
- A release archive must validate on its own.
- The Cloud Shell script must point at a Terraform release that exists, and verify its checksum.

## Releases

Each approach is released on its own tag, because a customer uses only one of them:
`azure-tf-vX.Y.Z` for Terraform, `azure-shell-vX.Y.Z` for the Cloud Shell script, and
`azure-bicep-vX.Y.Z` for the two ARM templates and the Bicep source. CI runs before every release.
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
Principal under Enterprise applications removes every role assignment at once, or each assignment
is deleted with `az role assignment delete`. The Cost Management export, which these approaches do
not create, is then deleted with `az rest --method delete` or in the portal, or it keeps writing
files.

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
| The export always writes into a folder, `atomity-exports` unless the customer chooses one | Azure rejects an export with no root folder, and the AWS export has the same default prefix | Writing at the container root, which the Cost Management API does not accept |
| The customer supplies the storage account | The wizard asks for it, and the module never owns the customer's data store, so removal cannot delete billing data | The module creates the storage account, as it does the bucket on AWS. May be offered later |
| The module never unregisters `Microsoft.CostManagementExports` | Other exports in the subscription may rely on it | `azurerm_resource_provider_registration`, which unregisters on destroy |
| The export uses `azapi`, not `azurerm` | `azurerm` cannot create FOCUS exports | Waiting for `azurerm` support |
| ARM and Bicep approaches take the Service Principal's object ID as a parameter | ARM cannot create Entra objects, and the Bicep Service Principal type is in beta | Creating it with the Graph Bicep extension once it is generally available |
| Terraform as the primary approach | Preview, state tracking, drift detection, a defined removal, and reviewable code | Custom scripts |
| The Cloud Shell script wraps the Terraform module | One paste for customers without Terraform, with the same preview and removal, and no second definition to keep identical | A standalone Azure CLI script |
| The Cloud Shell script pins several Terraform releases, runs the newest, and falls back only when a release is gone | Customers get a new release through a script release, a bad release can be bypassed with `--module-tag`, and a deleted release does not strand customers. Every pin has a known checksum, so verification still works. A replaced release is never hidden: a checksum mismatch stops the run | One pin, where every Terraform change and every rollback needs a new script. Resolving "latest" at run time, which needs the rate-limited GitHub API and leaves nothing to verify the download against. Falling back on any error, which would hide a replaced release |
| Two ARM templates, one per scope, generated from the Bicep source by a pinned compiler, and recompiled in CI and at release | One definition to review and release. The templates and the Bicep module cannot differ, and a hand edit fails the build | Hand-written templates next to a separate Bicep module. A check that compares only parameter names, which cannot see a changed resource |
| Per-subscription mode is its own subscription scope template, not a mode of the management group template | A subscription deployment needs no management group rights, which is the usual reason for choosing per-subscription mode. Each template does one thing, with fewer parameters and a simpler contract | One template with a `scopeMode` switch, which would keep the management group rights requirement for per-subscription customers |
| The Bicep compiler is pinned by version and by checksum | The template is the compiler's output and another version produces a different template. A swapped compiler could also make the drift check pass on a tampered template | A floating compiler version |
| The ARM and Bicep approach has no portal button. It is deployed with `az deployment mg create` after a checksum check | Management group deployments are made with the CLI, PowerShell or REST, and the same checksum chain as the Cloud Shell script applies | A portal button. The subscription template could work with one, but the customer could not check a checksum, and it is not planned |
| The ARM and Bicep approach creates role assignments only. The export is one documented `az rest` command, kept equal to the Terraform module by a CI test | One deployment targets one scope, and the export belongs to the billing account, which a management group template cannot reach. The command reuses a definition that has already worked against Azure through Terraform | Creating the export by hand in the portal, which is error-prone. A tenant scope deployment that also creates the export, which needs tenant level deployment rights, cannot register the resource provider, and has not been tried |
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
  by deleting the Service Principal, or the role assignments, and the export.
- The ARM and Bicep approach does not create the export. The customer creates it afterwards with a
  documented command, and nothing tracks it, so removal is a separate step.
- Deploying the management group template needs permission to deploy at the management group, and
  to assign roles there and on the storage account. A Global Administrator who is not yet Owner of
  the root management group must first elevate access. The subscription template needs rights only
  on the listed subscriptions and the storage account.
- A subscription added later is not covered by the subscription template until it is deployed again
  with that subscription listed.
- The two templates are separate. Moving from one to the other means removing the first one's
  `Reader` assignments.
- The template takes the storage account's subscription and resource group, not only its name,
  because a role assignment needs the account's resource ID.
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
| Cloud Shell | A browser-based shell in the Azure portal with the Azure CLI and Terraform installed |
| What-if | A preview of what a deployment would create or change |
| Azure Policy | Rules that can allow or block actions across subscriptions |

## Open questions

These need an answer before this document is final.

1. **Cloud Shell state.** Is persistent Cloud Shell storage acceptable for the Terraform state,
   or should the script use another backend?
2. **Dataset version.** Switch the default from `1.2-preview` once Azure releases FOCUS 1.2 as
   generally available.
