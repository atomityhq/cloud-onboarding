# Atomity cloud onboarding

Terraform and CloudFormation that connect your cloud accounts to Atomity with
read-only access. The Atomity onboarding wizard generates the exact commands for you.

| Cloud | Directory | Setup methods | Status |
|---|---|---|---|
| AWS | [`aws/`](aws/) | Terraform, CloudFormation | Available |
| Azure | [`azure/`](azure/) | Terraform, ARM ("Deploy to Azure"), Bicep | Available |

## For customers

Choose one setup method per account. Each method is released on its own, with no
Git required.

### Terraform

Terraform can fetch and initialize the module in one step. For example:

```bash
mkdir atomity-aws && cd atomity-aws
terraform init -from-module="https://github.com/atomity/terraform-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip"
```

See the cloud's own README for inputs and the full command list. Prefer to
inspect the code first?

```bash
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/aws-tf-v1.0.0/aws-tf-v1.0.0.zip.sha256
sha256sum -c aws-tf-v1.0.0.zip.sha256
unzip aws-tf-v1.0.0.zip -d atomity-aws
```

Every release zip also carries a build-provenance attestation:

```bash
gh attestation verify aws-tf-v1.0.0.zip --repo atomity/terraform-onboarding
```

### CloudFormation

The release is a single template, `atomity.yaml`:

```bash
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/aws-cfn-v1.0.0/atomity.yaml
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/aws-cfn-v1.0.0/atomity.yaml.sha256
sha256sum -c atomity.yaml.sha256
gh attestation verify atomity.yaml --repo atomity/terraform-onboarding
```

The cloud's own README has the deploy commands and parameters.

### AWS CDK

CDK teams use the CloudFormation release: they import `atomity.yaml` into their app with
`CfnInclude`. There is no separate CDK package. See the cloud's own README for the code.

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
.github/workflows/        ci.yml and release.yml
.tflint.hcl               lint rules
.checkov.yaml             security scan config (every skip has a reason)
```

Each cloud directory is its own root module, with its own state and its own
`versions.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars.example`, and
`README.md`. CI requires those files.

### Keeping the two methods in sync

Both methods must give the customer the same role, permissions and export, so
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

### CI

`ci.yml` runs on every push to `main`. It finds cloud
directories automatically, so adding `<cloud-provider>/` needs no workflow change.

| Job | Checks |
|---|---|
| hygiene | no state or tfvars committed, required files present |
| fmt | `terraform fmt -check` |
| validate | `terraform validate` on the oldest supported Terraform (1.5.7) and the latest |
| tflint | Terraform and AWS rulesets |
| cfn-lint | `atomity.yaml` is up to date, `member_role.yaml` matches the shared policies, and every CloudFormation template passes `cfn-lint` |
| cdk-compat | the released `atomity.yaml` imports and synthesizes through CDK's `CfnInclude` |
| checkov | security scan, with documented skips in `.checkov.yaml` |
| ci-ok | one aggregate result to use as the required status check |

Run the cheap checks locally before pushing:

```bash
terraform fmt -check -recursive
tflint --init && tflint --chdir=aws --config="$PWD/.tflint.hcl"
checkov --config-file .checkov.yaml
pip install cfn-lint pyyaml
python3 aws/cloudformation/build.py --check
cfn-lint aws/cloudformation/atomity.yaml aws/member_role.yaml
(cd aws/cloudformation/cdk-test && npm ci && npm test)
```

### Releasing

Each setup method is released on its own tag, because a customer uses only one:

```bash
git checkout main && git pull
git tag <cloud-provider>-tf-v1.0.0      # Terraform
git push origin <cloud-provider>-tf-v1.0.0
git tag <cloud-provider>-cfn-v1.0.0     # CloudFormation
git push origin <cloud-provider>-cfn-v1.0.0
```

`release.yml` re-runs CI and checks the tag is on `main`. Then, depending on the tag:

- **`-tf-` (Terraform):** zips the tracked files of `aws/` at the zip root, without
  `cloudformation/`, and checks that the extracted zip alone passes `terraform
  validate`. It writes a checksum, attests provenance, and publishes the release.
- **`-cfn-` (CloudFormation):** publishes `atomity.yaml` with a checksum and a
  provenance attestation.

Tags are `<cloud>-<method>-vMAJOR.MINOR.PATCH`, so each cloud and method versions
independently.

When a shared file changes (see above), release both methods, or one keeps the
old policies. Each release warns if the shared files changed since the other
method's latest release.

Breaking changes to inputs, parameters or outputs are a major version. The wizard
pins one tag per method, so shipping a new version means bumping that tag in the
wizard.

### One-time repository settings

- Branch protection on `main`: require the `ci-ok` check
- Protect `*-v*` tags so only maintainers can create or delete them
- Turn on GitHub secret scanning and push protection
- Commit each cloud's `.terraform.lock.hcl` (CI uses it read-only when present):
  `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64`

### Adding a cloud

1. Create `<cloud>/` with the required files
2. Add the directory to `.github/dependabot.yml` and `.github/CODEOWNERS`
3. Add the cloud's tag pattern, for example `<cloud>-tf-v[0-9]+.[0-9]+.[0-9]+`, to the tag filter in `.github/workflows/release.yml`
4. Add a tflint ruleset for that provider to `.tflint.hcl`
5. Only if the cloud also has a CloudFormation-style template: add `<cloud>/cloudformation/` with a `build.py`, and a `<cloud>-cfn-v…` tag pattern