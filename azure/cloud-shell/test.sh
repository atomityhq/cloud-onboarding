#!/usr/bin/env bash
#
# Behaviour tests for atomity-azure.sh, using a mock `az` and `terraform`.
#
# Runs everything the script does except talk to Azure: argument validation,
# environment checks, the download and checksum, the generated tfvars, the
# plan / confirm / apply flow, and remove. It cannot show that the Terraform
# module itself works against Azure. That needs a real tenant.
#
#   bash test.sh                       # module folder defaults to ..
#   MODULE_DIR=/path/to/azure bash test.sh
#
# Needs: bash, python3, shellcheck (optional, skipped if missing).

# shellcheck disable=SC2016  # assertions are single-quoted on purpose: they are eval-ed later
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MODULE_DIR=${MODULE_DIR:-$HERE/..}
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

[[ -f "$MODULE_DIR/main.tf" ]] || { echo "No module found in $MODULE_DIR"; exit 2; }

# ---------------------------------------------------------------- environment
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/rel/azure-tf-v9.9.9"
export PATH="$ROOT/bin:$PATH"
export HOME="$ROOT/home" MOCK_LOG="$ROOT/log"
export ATOMITY_RELEASES_BASE="file://$ROOT/rel" ATOMITY_WORKDIR="$ROOT/work"
: > "$MOCK_LOG"

cat > "$ROOT/bin/az" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_NOLOGIN:-0}" == 1 ]] && exit 1
if [[ "$*" == *"--query tenantId"* ]]; then echo "${MOCK_TENANT:-8d65815f-a5b6-402f-9298-045155da7d74}"; exit 0; fi
if [[ "$*" == *"--query id"* ]]; then echo "99999999-9999-9999-9999-999999999999"; exit 0; fi
exit 0
MOCK

# Prints a long `version` on purpose: a short one hides SIGPIPE bugs under pipefail.
cat > "$ROOT/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
echo "terraform $* (ARM_SUB=${ARM_SUBSCRIPTION_ID:-unset})" >> "$MOCK_LOG"
case "$1" in
  version)
    echo "Terraform v${MOCK_TF_VERSION:-1.9.5}"; echo "on linux_amd64"
    for i in $(seq 1 3000); do echo "+ provider registry.terraform.io/hashicorp/azurerm v4.$i.0"; done ;;
  init)
    if [[ "${MOCK_INIT_FAIL_ONCE:-0}" == 1 && ! -f .init_failed ]]; then touch .init_failed; exit 1; fi ;;
  plan)
    echo "Plan: 5 to add, 0 to change, 0 to destroy."
    mode=create
    for a in "$@"; do [[ "$a" == -destroy ]] && mode=destroy; done
    for a in "$@"; do [[ "$a" == -out=* ]] && echo "$mode" > "${a#-out=}"; done ;;
  apply)
    if [[ "${MOCK_APPLY_FAIL:-0}" == 1 ]]; then echo "Error: boom" >&2; exit 1; fi
    if [[ "$(cat tfplan)" == destroy ]]; then rm -f terraform.tfstate; echo "Destroy complete."
    else echo '{}' > terraform.tfstate; echo "Apply complete."; fi ;;
  output) echo 'connection_details = { tenant_id = "mock" }' ;;
esac
MOCK
chmod +x "$ROOT/bin/az" "$ROOT/bin/terraform"

# A fake Terraform release made from the real module, then the script built against it.
python3 - "$MODULE_DIR" "$ROOT/rel/azure-tf-v9.9.9/azure-tf-v9.9.9.zip" <<'PY'
import sys, zipfile, glob, os
src, dst = sys.argv[1:3]
with zipfile.ZipFile(dst, "w") as z:
    for f in sorted(glob.glob(os.path.join(src, "*.tf"))):
        z.write(f, os.path.basename(f))
PY
python3 "$HERE/build.py" --tf-tag azure-tf-v9.9.9 --version 1.2.3 \
  --zip "$ROOT/rel/azure-tf-v9.9.9/azure-tf-v9.9.9.zip" --out "$ROOT/dist" >/dev/null || { echo "build.py failed"; exit 2; }
S="$ROOT/dist/atomity-azure.sh"
SRC="$HERE/atomity-azure.sh"
ZIP="$ROOT/rel/azure-tf-v9.9.9/azure-tf-v9.9.9.zip"

T=8d65815f-a5b6-402f-9298-045155da7d74
BASE=(--tenant-id "$T" --storage-account acmebilling --container atomity-focus --billing-account 1234567)
reset() { rm -rf "$ROOT/work"; : > "$MOCK_LOG"; }
calls() { sed -E 's/ \(ARM_SUB.*//' "$MOCK_LOG" | tr '\n' ';'; }
out=""; rc=0
# shellcheck disable=SC2034  # rc is read inside the eval strings passed to check()
run() { out=$("$@" 2>&1); rc=$?; }
has() { grep -qF -- "$1" <<<"$out"; }
logged() { grep -qE -- "$1" "$MOCK_LOG"; }

# Run a command under a pseudo-terminal and type $1 at the confirmation prompt.
pty() {
  python3 - "$@" <<'PY'
import os, pty, sys, select
answer, cmd = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
buf = b""; sent = False
while True:
    r, _, _ = select.select([fd], [], [], 10)
    if not r: break
    try: d = os.read(fd, 4096)
    except OSError: break
    if not d: break
    buf += d
    if b"Type 'yes'" in buf and not sent:
        os.write(fd, (answer + "\n").encode()); sent = True
os.waitpid(pid, 0)
sys.stdout.write(buf.decode(errors="replace"))
PY
}

# ---------------------------------------------------------------- static checks
echo "## static"
check "bash syntax" 'bash -n "$SRC"'
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" 'shellcheck -s bash "$SRC"'
else
  echo "SKIP  shellcheck not installed"
fi
check "source has the three placeholders" \
  'grep -q "@@SCRIPT_VERSION@@" "$SRC" && grep -q "@@TF_TAG@@" "$SRC" && grep -q "@@TF_SHA256@@" "$SRC"'
check "built script has none left" \
  '! grep -qE "@@(SCRIPT_VERSION|TF_TAG|TF_SHA256)@@" "$S"'
check "built script checksum file verifies" '(cd "$ROOT/dist" && sha256sum -c atomity-azure.sh.sha256 >/dev/null 2>&1)'
run python3 "$HERE/build.py" --tf-tag v1 --version 1.0.0 --zip "$ZIP" --out "$ROOT/x"
check "build.py rejects a bad --tf-tag" '[[ $rc -ne 0 ]] && has "azure-tf-vX.Y.Z"'
run python3 "$HERE/build.py" --tf-tag azure-tf-v1.0.0 --version 1.0 --zip "$ZIP" --out "$ROOT/x"
check "build.py rejects a bad --version" '[[ $rc -ne 0 ]] && has "X.Y.Z"'

run python3 "$HERE/build.py" --version 1.0.0 --zip "$ZIP" --out "$ROOT/x"
check "build.py reads the pinned tag from TERRAFORM_TAG" 'has "Terraform pin  : $(tr -d "\n" < "$HERE/TERRAFORM_TAG")"'

# ---------------------------------------------------------------- arguments
echo "## arguments and validation"
reset
run bash "$S" --version;                                         check "--version" 'has "atomity-azure.sh 1.2.3 (Terraform module azure-tf-v9.9.9)"'
run bash "$S" frobnicate;                                        check "unknown command" 'has "Unknown command: frobnicate"'
run bash "$S" plan --bogus;                                      check "unknown option" 'has "Unknown option: --bogus"'
run bash "$S" plan --storage-account a --container c --billing-account 1
check "tenant required" 'has "--tenant-id is required"'
run bash "$S" plan --tenant-id nope --storage-account acme --container abc --billing-account 1 --management-group-id x
check "tenant must be a GUID" 'has "--tenant-id must be a GUID"'
run bash "$S" plan "${BASE[@]}";                                 check "management group id required" 'has "--management-group-id is required"'
run bash "$S" plan "${BASE[@]}" --management-group-id 'x"; rm -rf /; "'
check "quotes rejected (tfvars injection)" 'has "characters that are not allowed"'
run bash "$S" plan --tenant-id "$T" --storage-account acme --container 'a${b}c' --billing-account 1 --management-group-id x
check "interpolation rejected" 'has "characters that are not allowed"'
run bash "$S" plan "${BASE[@]}" --scope subscription --subscription-ids abc
check "bad subscription GUID rejected" 'has "Not a subscription GUID: abc"'
run bash "$S" plan "${BASE[@]}" --scope galaxy;                  check "bad scope rejected" 'has "--scope must be"'
run bash "$S" plan --tenant-id "$T" --container --billing-account 1
check "missing value is not swallowed by the next flag" 'has "Option --container needs a value"'
check "no terraform call for any rejected input" '[[ ! -s "$MOCK_LOG" ]]' "$(cat "$MOCK_LOG")"

reset
run bash "$S" plan "${BASE[@]}" --management-group-id 'my-mg_(prod).1'
check "management group ID with ( ) . _ - accepted" 'has "Plan: 5 to add"'
run bash "$S" plan "${BASE[@]}" --management-group-id 'a:b'
check "management group ID with a colon rejected" 'has "characters that are not allowed"'

# ---------------------------------------------------------------- environment
echo "## environment checks"
reset
MOCK_NOLOGIN=1 run bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "not signed in" 'has "Not signed in to Azure"'
MOCK_TENANT=11111111-1111-1111-1111-111111111111 run bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "wrong tenant" 'has "but this connection is for $T"'
MOCK_TENANT=8D65815F-A5B6-402F-9298-045155DA7D74 run bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "tenant comparison ignores case" 'has "Plan: 5 to add"'
MOCK_TF_VERSION=1.4.0 run bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "Terraform below 1.5.7 rejected" 'has "Terraform 1.5.7 or newer is required. Found 1.4.0"'
MOCK_TF_VERSION=1.5.7 run bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "Terraform 1.5.7 accepted" 'has "Plan: 5 to add"'
fails=0
for _ in $(seq 1 20); do reset; bash "$S" plan "${BASE[@]}" --management-group-id "$T" >/dev/null 2>&1 || fails=$((fails + 1)); done
check "20 repeated runs, long 'terraform version' output (SIGPIPE guard)" '[[ $fails -eq 0 ]]' "$fails failures"

# ---------------------------------------------------------------- plan and apply
echo "## plan, apply, confirmation"
reset
run bash "$S" plan "${BASE[@]}" --management-group-id "$T" --root-folder atomity/focus
check "plan stops after the plan" 'has "This was only a plan. Nothing was created"'
check "plan runs version, init, plan only" '[[ "$(calls)" == "terraform version;terraform init -input=false -no-color;terraform plan -input=false -out=tfplan;" ]]' "$(calls)"
check "tfvars content" \
  'grep -q "management_group_id  = \"$T\"" "$ROOT/work/terraform.tfvars" && grep -q "root_folder_path     = \"atomity/focus\"" "$ROOT/work/terraform.tfvars" && grep -q "scope_mode           = \"management_group\"" "$ROOT/work/terraform.tfvars"'
check "tfvars is 0600, workdir 0700" '[[ "$(stat -c %a "$ROOT/work/terraform.tfvars")" == 600 && "$(stat -c %a "$ROOT/work")" == 700 ]]'
check "ARM_SUBSCRIPTION_ID defaults to the CLI subscription" 'logged "ARM_SUB=99999999-9999-9999-9999-999999999999"'

reset
run bash "$S" plan "${BASE[@]}" --management-group-id "$T" --storage-subscription 22222222-2222-2222-2222-222222222222
check "--storage-subscription written and exported" \
  'grep -q "subscription_id      = \"22222222-2222-2222-2222-222222222222\"" "$ROOT/work/terraform.tfvars" && logged "ARM_SUB=22222222-2222-2222-2222-222222222222"'

reset
run bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes
check "apply --yes runs plan then apply of that plan" \
  '[[ "$(calls)" == "terraform version;terraform init -input=false -no-color;terraform plan -input=false -out=tfplan;terraform apply -input=false tfplan;terraform output connection_details;" ]]' "$(calls)"
check "apply prints next steps" 'has "Back in Atomity, choose Validate connection"'
check "state kept in the workdir" '[[ -f "$ROOT/work/terraform.tfstate" ]]'

reset
out=$(pty yes bash "$S" apply "${BASE[@]}" --management-group-id "$T"); check "typing yes applies" 'has "Apply complete"'
reset
out=$(pty no bash "$S" apply "${BASE[@]}" --management-group-id "$T")
check "typing no cancels and never applies" 'has "Cancelled. Nothing was changed." && ! logged "terraform apply"'
reset
out=$(pty y bash "$S" apply "${BASE[@]}" --management-group-id "$T"); check "only the whole word yes is accepted" 'has "Cancelled"'
reset
run setsid bash "$S" apply "${BASE[@]}" --management-group-id "$T" </dev/null
check "no terminal and no --yes: refuses, applies nothing" 'has "Rerun with --yes" && ! logged "terraform apply"'

reset; bash "$S" plan "${BASE[@]}" --scope subscription --subscription-ids "11111111-1111-1111-1111-111111111111, AAAAAAAA-bbbb-cccc-dddd-222222222222" >/dev/null 2>&1
check "subscription scope: list written" \
  'grep -q "subscription_ids     = \[\"11111111-1111-1111-1111-111111111111\", \"AAAAAAAA-bbbb-cccc-dddd-222222222222\"\]" "$ROOT/work/terraform.tfvars" && ! grep -q management_group_id "$ROOT/work/terraform.tfvars"'
reset; bash "$S" plan "${BASE[@]}" --scope subscription --subscription-ids "" >/dev/null 2>&1
check "subscription scope: blank list means auto-discover" 'grep -q "subscription_ids     = \[\]" "$ROOT/work/terraform.tfvars"'
reset; bash "$S" plan "${BASE[@]}" --scope subscription --subscription-ids --root-folder "" >/dev/null 2>&1
check "omitted --subscription-ids value does not eat the next flag" 'grep -q "subscription_ids     = \[\]" "$ROOT/work/terraform.tfvars"'

# ---------------------------------------------------------------- integrity
echo "## download and integrity"
reset; cp "$ZIP" "$ZIP.orig"; printf 'tampered' >> "$ZIP"
run bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes
check "tampered archive rejected" 'has "Checksum mismatch for azure-tf-v9.9.9"'
check "nothing but the version check ran" '[[ "$(calls)" == "terraform version;" ]]' "$(calls)"
check "no module files installed" '[[ -z "$(ls "$ROOT"/work/*.tf 2>/dev/null)" ]]'
mv "$ZIP.orig" "$ZIP"
reset; ATOMITY_RELEASES_BASE=file:///nonexistent run bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes
check "failed download reported" 'has "Could not download"'
reset; run bash "$SRC" apply "${BASE[@]}" --management-group-id "$T" --yes
check "unstamped development copy refuses to download" 'has "This is a development copy of the script"'
reset; run bash "$SRC" plan "${BASE[@]}" --management-group-id "$T" --module-dir "$MODULE_DIR"
check "--module-dir works for a development copy" 'has "Development mode" && has "Plan: 5 to add"'
run bash "$SRC" plan "${BASE[@]}" --management-group-id "$T" --module-dir /tmp
check "--module-dir without main.tf rejected" 'has "No main.tf in /tmp"'

mkdir -p "$ROOT/nested/azure" "$ROOT/rel2/azure-tf-v9.9.9"
cp "$MODULE_DIR"/*.tf "$ROOT/nested/azure/"
python3 - "$ROOT/nested" "$ROOT/rel2/azure-tf-v9.9.9/azure-tf-v9.9.9.zip" <<'PY'
import sys, zipfile, glob, os
base, dst = sys.argv[1:3]
with zipfile.ZipFile(dst, "w") as z:
    for f in sorted(glob.glob(os.path.join(base, "azure", "*.tf"))):
        z.write(f, os.path.join("azure", os.path.basename(f)))
PY
python3 "$HERE/build.py" --tf-tag azure-tf-v9.9.9 --version 1.2.3 --zip "$ROOT/rel2/azure-tf-v9.9.9/azure-tf-v9.9.9.zip" --out "$ROOT/dist2" >/dev/null
reset; ATOMITY_RELEASES_BASE="file://$ROOT/rel2" run bash "$ROOT/dist2/atomity-azure.sh" plan "${BASE[@]}" --management-group-id "$T"
check "module inside a top-level folder of the archive" 'has "Plan: 5 to add"'

# ---------------------------------------------------------------- re-run, safety
echo "## re-run and safety"
reset; bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes >/dev/null 2>&1
echo stale > "$ROOT/work/removed_in_newer_release.tf"
bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes >/dev/null 2>&1
check "re-run keeps the state" '[[ -f "$ROOT/work/terraform.tfstate" ]]'
check "re-run removes .tf files an older release had" '[[ ! -f "$ROOT/work/removed_in_newer_release.tf" && -f "$ROOT/work/main.tf" ]]'
reset; MOCK_INIT_FAIL_ONCE=1 bash "$S" plan "${BASE[@]}" --management-group-id "$T" >/dev/null 2>&1
check "failed init is retried with -upgrade" 'logged "init -input=false -upgrade"'
run env ATOMITY_WORKDIR="$HOME" bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "refuses \$HOME as the working directory" 'has "Refusing to use"'
run env ATOMITY_WORKDIR=/ bash "$S" plan "${BASE[@]}" --management-group-id "$T"
check "refuses / as the working directory" 'has "Refusing to use"'

# ---------------------------------------------------------------- remove
echo "## remove"
reset
run bash "$S" remove
check "no state: manual steps, exit 1" '[[ $rc -eq 1 ]] && has "c4b84012-e86e-4ea0-9c42-5e015c1c30f4" && has "Cost Management, Exports"'
check "no state: nothing run" '! logged "destroy|apply"'

reset; bash "$S" apply "${BASE[@]}" --management-group-id "$T" --storage-subscription 22222222-2222-2222-2222-222222222222 --yes >/dev/null 2>&1
echo keep > "$HOME/sentinel.tf"; : > "$MOCK_LOG"
out=$(pty no bash "$S" remove)
check "remove, answer no: cancelled, state kept" 'has "Cancelled. Nothing was changed." && [[ -f "$ROOT/work/terraform.tfstate" ]] && ! logged "terraform apply"'
check "remove shows a destroy plan first" 'logged "plan -destroy"'
: > "$MOCK_LOG"
out=$(pty yes bash "$S" remove)
check "remove, answer yes: removes" 'has "are removed."'
check "remove says the storage was not touched" 'has "were not touched"'
check "remove reuses the storage subscription from tfvars" 'logged "ARM_SUB=22222222-2222-2222-2222-222222222222"'
check "workdir deleted after success" '[[ ! -e "$ROOT/work" ]]'
check "files outside the workdir untouched" '[[ -f "$HOME/sentinel.tf" ]]'

reset; bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes >/dev/null 2>&1
MOCK_TENANT=11111111-1111-1111-1111-111111111111 run bash "$S" remove --yes
check "remove in the wrong tenant: refused, state kept" 'has "but this connection is for $T" && [[ -f "$ROOT/work/terraform.tfstate" ]]'
MOCK_APPLY_FAIL=1 run bash "$S" remove --yes
check "failed destroy keeps workdir and state for a retry" '[[ $rc -ne 0 && -f "$ROOT/work/terraform.tfstate" ]]'
run bash "$S" remove --yes
check "retry succeeds and then deletes the workdir" 'has "are removed." && [[ ! -e "$ROOT/work" ]]'
reset
MOCK_APPLY_FAIL=1 run bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes
check "failed apply: non-zero exit, no success message" '[[ $rc -ne 0 ]] && ! has "Back in Atomity"'

# ---------------------------------------------------------------- one paste
echo "## the wizard's one-paste command"
SHA=$(cut -d' ' -f1 "$ROOT/dist/atomity-azure.sh.sha256")
mkdir -p "$ROOT/rel/azure-shell-v1.2.3"; cp "$ROOT/dist/atomity-azure.sh" "$ROOT/rel/azure-shell-v1.2.3/"
paste_cmd() {
  cat <<CMD
rm -rf "$ROOT/shellhome" && mkdir -p "$ROOT/shellhome" && cd "$ROOT/shellhome"
curl -fsSLO file://$ROOT/rel/azure-shell-v1.2.3/atomity-azure.sh
echo "$1  atomity-azure.sh" | sha256sum -c - && bash atomity-azure.sh apply \\
  --tenant-id $T --storage-account acmebilling --container atomity-focus \\
  --billing-account 1234567 --scope management-group --management-group-id $T
CMD
}
reset; paste_cmd "$SHA" > "$ROOT/paste_ok.sh"
out=$(pty yes bash "$ROOT/paste_ok.sh")
check "correct checksum: script verified, runs, applies" 'has "atomity-azure.sh: OK" && has "Checksum verified." && has "Apply complete"'
reset; paste_cmd "$(printf '0%.0s' $(seq 1 64))" > "$ROOT/paste_bad.sh"
run bash "$ROOT/paste_bad.sh"
check "wrong checksum: script never runs" 'has "FAILED" && [[ ! -s "$MOCK_LOG" ]]'

# ---------------------------------------------------------------- summary
echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]