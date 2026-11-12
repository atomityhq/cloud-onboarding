# Atomity cloud onboarding

Automated setups that connect your cloud accounts to
Atomity with read-only access. The Atomity onboarding wizard generates the exact commands for you.

| Cloud | Directory | Setup methods | Status |
|---|---|---|---|
| AWS | [`aws/`](aws/) | Terraform, CloudFormation | Available |
| Azure | [`azure/`](azure/) | Terraform, Cloud Shell, Bicep / ARM | In progress |

## For customers

Choose one setup method per account (AWS) or tenant (Azure). Each method is released on its
own, with no Git required.

### Terraform

Terraform can fetch and initialize the module in one step. For example:

```bash
mkdir atomity-aws && cd atomity-aws
terraform init -from-module="https://github.com/atomityhq/cloud-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip"
```

For Azure, use the `azure-tf` release in the same way:

```bash
mkdir atomity-azure && cd atomity-azure
terraform init -from-module="https://github.com/atomityhq/cloud-onboarding/releases/download/azure-tf-v1.0.0/azure-tf-v1.0.0.zip"
```

See the cloud's own README for inputs and the full command list. Prefer to
inspect the code first?

```bash
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip.sha256
sha256sum -c aws-tf-v1.0.0.zip.sha256
unzip aws-tf-v1.0.0.zip -d atomity-aws
```

Every release zip also carries a build-provenance attestation:

```bash
gh attestation verify aws-tf-v1.0.0.zip --repo atomityhq/cloud-onboarding
```

### CloudFormation

The release is a single template, `atomity.yaml`:

```bash
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/aws-cfn-v1.0.0/atomity.yaml
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/aws-cfn-v1.0.0/atomity.yaml.sha256
sha256sum -c atomity.yaml.sha256
gh attestation verify atomity.yaml --repo atomityhq/cloud-onboarding
```

The cloud's own README has the deploy commands and parameters.

### AWS CDK

CDK teams use the CloudFormation release: they import `atomity.yaml` into their app with
`CfnInclude`. There is no separate CDK package. See the cloud's own README for the code.

### Azure Bicep / ARM

The release has two ARM templates, compiled from Bicep, and the Bicep source as a zip:
`atomity.json` for management group scope and `atomity-subscription.json` for subscription scope.
The wizard generates a command that downloads the right template, checks its checksum and deploys
it with `az deployment mg create` or `az deployment sub create`. To inspect the files first:

```bash
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/azure-bicep-v1.0.0/atomity.json
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/azure-bicep-v1.0.0/atomity.json.sha256
sha256sum -c atomity.json.sha256
gh attestation verify atomity.json --repo atomityhq/cloud-onboarding
```

`atomity-subscription.json` and `azure-bicep-v1.0.0-modules.zip` (the Bicep source) each have their
own `.sha256` file and attestation. The cloud's own README has the parameters and how to use the module from your own
Bicep.

### Azure Cloud Shell

For Azure customers who don't use Terraform. The release is a single script, `atomity-azure.sh`,
that runs in Azure Cloud Shell, where nothing needs to be installed. It downloads a pinned
Terraform release, shows the plan, and changes nothing until you confirm.

The wizard generates one command that downloads the script, checks its checksum, and runs it.
To inspect the script first:

```bash
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/azure-shell-v1.0.0/atomity-azure.sh
curl -fsSLO https://github.com/atomityhq/cloud-onboarding/releases/download/azure-shell-v1.0.0/atomity-azure.sh.sha256
sha256sum -c atomity-azure.sh.sha256
gh attestation verify atomity-azure.sh --repo atomityhq/cloud-onboarding
```

The script verifies the Terraform release it uses against a checksum built into it. The cloud's
own README has the options.

## For maintainers

### Layout

```
aws/                      one cloud, with both setup methods
  *.tf                    the Terraform root module
  policies/               role trust and permission policies, used by both methods
  member_role.yaml        member-account role (Organizations), used by both methods
  focus_query.sql         billing export query, used by both methods
  cloudformation/         the CloudFormation template (generated) and its build script
    cdk-test/             test that the template imports into a CDK app (not released)
azure/                    one cloud, with both setup methods
  *.tf                    the Terraform root module
  bicep/                  the ARM templates and their Bicep source (not part of the Terraform release)
    main.bicep            the management group template source. modules/ holds the child modules
    subscription.bicep    the subscription template source, using the same modules
    atomity.json          the management group ARM template, generated by build.py. Never edit it by hand
    atomity-subscription.json  the subscription ARM template, generated by build.py. Never edit it by hand
    build.py              compiles both Bicep files, then rewrites or checks both ARM templates
    BICEP_VERSION         the Bicep compiler version the ARM templates are built with
    BICEP_SHA256          checksums of that compiler's downloads
    install-bicep.sh      installs the pinned compiler, checksum verified
    test_build.py         tests for build.py, run with the real compiler
    test_export_parity.py checks that the export command in the module README sends the same
                          definition as the Terraform module
  cloud-shell/            the Cloud Shell script (not part of the Terraform release)
    atomity-azure.sh      the script, with placeholders for the release stamp
    build.py              stamps the pinned Terraform releases into the script
    TERRAFORM_TAGS        the Terraform releases the script pins, one tag per line
    test.sh               behaviour tests against a mock az and terraform
docs/                     design documents, one per cloud
.github/workflows/        ci.yml and release.yml
.tflint.hcl               lint rules
.checkov.yaml             security scan config (every skip has a reason)
```

Each cloud directory is its own root module, with its own state and its own
`versions.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars.example`, and
`README.md`. CI requires those files.

### Keeping the setup methods in sync

**AWS.** Both methods must give the customer the same role, permissions and export, so
they read the same files: `policies/trust.json`, `policies/permission.json`,
`member_role.yaml` and `focus_query.sql`. Terraform reads them directly. A
CloudFormation template has to be one self-contained file, so
`cloudformation/atomity.yaml` is generated from `atomity.src.yaml` and those files.

After changing a shared file or `atomity.src.yaml`, regenerate and commit:

```bash
python3 aws/cloudformation/build.py
```

The build also checks that `member_role.yaml` (a narrower copy of the role) still
matches the shared policies, and fails if it has drifted. Never edit
`atomity.yaml` by hand.

**Azure.** There is no copy to keep in sync. The Cloud Shell script holds no access
definitions of its own: it runs a pinned release of the Terraform module, so both methods
give the same result by construction. `TERRAFORM_TAGS` lists the pinned releases, one per
line. `build.py` stamps each release's checksum into the script and fails if a release does
not exist. The script runs the newest pin by version number, and any pin with `--module-tag`.

**Azure Bicep / ARM.** The two ARM templates are the Bicep compiler's output, not copies to keep in
step. `build.py` compiles `main.bicep` and `subscription.bicep` with the compiler pinned in
`BICEP_VERSION` and `BICEP_SHA256`, and rewrites `atomity.json` and `atomity-subscription.json`
with the result. After changing any `.bicep` file, regenerate and commit:

```bash
bash azure/bicep/install-bicep.sh      # once, then keep ~/.local/bin on your PATH
python3 azure/bicep/build.py
```

The compiler download is about 80 MB. The script shows progress, and gives up with a message if the
speed stays below 10 KB/s for 30 seconds. If the download is slow or blocked, download the asset for
your system from the [Bicep releases](https://github.com/Azure/bicep/releases) page and install that
file instead. It is still checked against the pinned checksum:
`BICEP_FILE=~/Downloads/bicep-linux-x64 bash azure/bicep/install-bicep.sh`. If the compiler
downloads but will not start, it needs the ICU library (Arch and CachyOS: `sudo pacman -S icu`).

CI recompiles and fails if a committed template differs in any way from the compiler's output, if
the compiler reports a warning, or if a template could assign any role other than `Reader` and
`Storage Blob Data Reader`. It also fails if the two templates take the storage account parameters
differently. Never edit the ARM templates by hand. To change the compiler, update `BICEP_VERSION`
and `BICEP_SHA256` together, then regenerate.

The templates cannot create the Cost Management export, so the Bicep / ARM method documents it as
a command in the module README. That command is a second writing of the export definition in
`main.tf`. If you change the export in either place, change both: `test_export_parity.py` fails CI
when they differ.

To ship a Terraform change to Cloud Shell users, release Terraform first. That opens a pull
request adding the new tag to `TERRAFORM_TAGS`. Merge it, then release the script. Older pins
stay in the file, so they remain selectable and serve as fallbacks: if the newest release is
ever deleted, the script falls back to the next one. It falls back only when a release is
gone (404 or 410). A checksum mismatch or any other download error stops it, so a replaced
release is never hidden by an older one. Delete a line to stop shipping a pin.

### CI

`ci.yml` runs on every pull request and on every push to `main`. It finds cloud
directories automatically, so adding `<cloud-provider>/` needs no workflow change.

| Job | Checks |
|---|---|
| hygiene | no state or tfvars committed, required files present |
| fmt | `terraform fmt -check` |
| validate | `terraform validate` on the oldest supported Terraform (1.5.7) and the latest |
| tflint | Terraform, AWS and Azure rulesets |
| cfn-lint | `atomity.yaml` is up to date, `member_role.yaml` matches the shared policies, and every CloudFormation template passes `cfn-lint` |
| cdk-compat | the released `atomity.yaml` imports and synthesizes through CDK's `CfnInclude` |
| bicep-check | installs the pinned Bicep compiler, recompiles both Bicep files, fails if an ARM template is not exactly the compiler's output or breaks its contract, runs `test_build.py`, and checks that the README's export command matches the Terraform module (`test_export_parity.py`) |
| shell | `shellcheck` on `azure/cloud-shell`, and `test.sh` against a mock `az` and `terraform` |
| checkov | security scan, with documented skips in `.checkov.yaml` |
| ci-ok | one aggregate result to use as the required status check |

Run the cheap checks locally before pushing:

```bash
terraform fmt -check -recursive
tflint --init && tflint --chdir=aws --config="$PWD/.tflint.hcl"
tflint --chdir=azure --config="$PWD/.tflint.hcl"
checkov --config-file .checkov.yaml
pip install cfn-lint pyyaml
python3 aws/cloudformation/build.py --check
cfn-lint aws/cloudformation/atomity.yaml aws/member_role.yaml
(cd aws/cloudformation/cdk-test && npm ci && npm test)
shellcheck azure/cloud-shell/*.sh && bash azure/cloud-shell/test.sh
bash azure/bicep/install-bicep.sh && python3 azure/bicep/build.py --check && python3 azure/bicep/test_build.py
pip install python-hcl2==8.2.0 && python3 azure/bicep/test_export_parity.py
```

### Releasing

Each setup method is released on its own tag, because a customer uses only one:

```bash
git checkout main && git pull
git tag <cloud-provider>-tf-v1.0.0      # Terraform
git push origin <cloud-provider>-tf-v1.0.0
git tag aws-cfn-v1.0.0                  # CloudFormation
git push origin aws-cfn-v1.0.0
git tag azure-shell-v1.0.0              # Azure Cloud Shell
git push origin azure-shell-v1.0.0
git tag azure-bicep-v1.0.0              # Azure Bicep / ARM
git push origin azure-bicep-v1.0.0
```

`release.yml` re-runs CI and checks the tag is on `main`. Then, depending on the tag:

- **`-tf-` (Terraform):** zips the tracked files of the cloud directory at the zip root,
  without `cloudformation/`, `cloud-shell/` and `bicep/`, and checks that the extracted zip alone passes
  `terraform validate`. It writes a checksum, attests provenance, and publishes the release.
- **`-cfn-` (CloudFormation):** publishes `atomity.yaml` with a checksum and a
  provenance attestation.
- **`-shell-` (Azure Cloud Shell):** verifies every Terraform release listed in
  `TERRAFORM_TAGS` (its published checksum and its provenance attestation), then runs
  `build.py` to stamp those releases into the script and publishes `atomity-azure.sh` with a
  checksum and a provenance attestation. The wizard embeds that checksum in the command it
  generates. Every pinned Terraform release must already be published.

- **`-bicep-` (Azure Bicep / ARM):** installs the pinned compiler, recompiles both Bicep files from
  the tagged commit and fails if either ARM template differs, zips only `main.bicep`,
  `subscription.bicep` and `modules/`, compiles that zip on its own and compares the result with
  the templates, then publishes the two templates and the zip with checksums and provenance
  attestations.

Tags are `<cloud>-<method>-vMAJOR.MINOR.PATCH`, so each cloud and method versions
independently.

When an AWS shared file changes (see above), release both methods, or one keeps the
old policies. Each release warns if the shared files changed since the other
method's latest release. On Azure, release the Terraform module first. The release opens a
pull request that pins it in the Cloud Shell script, and merging that and tagging
`azure-shell-v...` ships it.

Breaking changes to inputs, parameters or outputs are a major version. The wizard
pins one tag per method, so shipping a new version means bumping that tag in the
wizard.

### One-time repository settings

- Branch protection on `main`: require the `ci-ok` check
- Protect `*-v*` tags so only maintainers can create or delete them
- Turn on GitHub secret scanning and push protection
- Add a `PIN_BUMP_TOKEN` secret: a fine-grained token or GitHub App token with contents and
  pull-requests write. The pull request that pins a new Terraform release is opened with it,
  so CI runs on that pull request. Without the secret the workflow still opens the pull
  request, but CI does not start on it until you close and reopen it, and the repository
  setting "Allow GitHub Actions to create and approve pull requests" must be on
- Commit each cloud's `.terraform.lock.hcl` (CI uses it read-only when present):
  `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64`

### Adding a cloud

1. Create `<cloud>/` with the required files
2. Add the cloud's tag pattern, for example `<cloud>-tf-v[0-9]+.[0-9]+.[0-9]+`, to the tag filter in `.github/workflows/release.yml`
3. Add a tflint ruleset for that provider to `.tflint.hcl`
4. Only if the cloud also has a CloudFormation-style template: add `<cloud>/cloudformation/` with a `build.py`, and a `<cloud>-cfn-v…` tag pattern
5. Only if the cloud also has an ARM/Bicep method: add `<cloud>/bicep/` with a `build.py` that
   compiles with a pinned compiler and fails on any difference, exclude it from the Terraform
   release zip, and add a `<cloud>-bicep-v…` tag pattern
6. Only if the cloud also has a script method: add `<cloud>/<method-dir>/`, exclude it from the Terraform release zip, and add a `<cloud>-shell-v…` tag pattern. The script must run the released Terraform module rather than carry its own copy of the access definitions.
