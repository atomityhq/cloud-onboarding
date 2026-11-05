# Atomity Terraform onboarding

Terraform that connects your cloud accounts to Atomity with read-only access.
The Atomity onboarding wizard generates the exact commands for you.

| Cloud | Directory | Status |
|---|---|---|
| AWS | [`aws/`](aws/) | Available |

## For customers

Each cloud is released on its own as a zip with no Git required. Terraform can
fetch and initialize it in one step. For e.g:

```bash
mkdir atomity-aws && cd atomity-aws
terraform init -from-module="https://github.com/atomity/terraform-onboarding/releases/download/aws-v1.0.0/aws-v1.0.0.zip"
```

See the cloud's own README for inputs and the full command list. Prefer to
inspect the code first?

```bash
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/aws-v1.0.0/aws-v1.0.0.zip
curl -fsSLO https://github.com/atomity/terraform-onboarding/releases/download/aws-v1.0.0/aws-v1.0.0.zip.sha256
sha256sum -c aws-v1.0.0.zip.sha256
unzip aws-v1.0.0.zip -d atomity-aws
```

Every release zip also carries a build-provenance attestation:

```bash
gh attestation verify aws-v1.0.0.zip --repo atomity/terraform-onboarding
```

## For maintainers

### Layout

```
aws/                  one standalone Terraform root per cloud
.github/workflows/    ci.yml and release.yml
.tflint.hcl           lint rules
.checkov.yaml         security scan config (every skip has a reason)
```

Each cloud directory is its own root module, with its own state and its own
`versions.tf`, `variables.tf`, `outputs.tf`, `terraform.tfvars.example`, and
`README.md`. CI requires those files.

### CI

`ci.yml` runs on every push to `main`. It finds cloud
directories automatically, so adding `<cloud-provider>/` needs no workflow change.

| Job | Checks |
|---|---|
| hygiene | no state or tfvars committed, required files present |
| fmt | `terraform fmt -check` |
| validate | `terraform validate` on the oldest supported Terraform (1.5.7) and the latest |
| tflint | Terraform and AWS rulesets |
| checkov | security scan, with documented skips in `.checkov.yaml` |
| ci-ok | one aggregate result to use as the required status check |

Run the cheap checks locally before pushing:

```bash
terraform fmt -check -recursive
tflint --init && tflint --chdir=aws --config="$PWD/.tflint.hcl"
checkov --config-file .checkov.yaml
```

### Releasing

```bash
git checkout main && git pull
git tag <cloud-provider>-v1.0.0
git push origin <cloud-provider>-v1.0.0
```

`release.yml` re-runs CI, checks the tag is on `main`, zips only the tracked
files of `aws/` (at the zip root), writes a checksum, attests provenance, and
publishes the release. Tags are `<cloud>-vMAJOR.MINOR.PATCH`, so each cloud
versions independently.

Breaking changes to inputs or outputs are a major version. The wizard pins a
tag, so shipping a new version means bumping the tag in the wizard.

### One-time repository settings

- Branch protection on `main`: require the `ci-ok` check
- Protect `*-v*` tags so only maintainers can create or delete them
- Turn on GitHub secret scanning and push protection
- Commit each cloud's `.terraform.lock.hcl` (CI uses it read-only when present):
  `terraform providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64 -platform=windows_amd64`

### Adding a cloud

1. Create `<cloud>/` with the required files
2. Add the directory to `.github/dependabot.yml` and `.github/CODEOWNERS`
3. Add the cloud to `.github/workflows/release.yml` tag patterns, if it isn't one of `aws`, `azure`, `gcp`
4. Add a tflint ruleset for that provider to `.tflint.hcl`