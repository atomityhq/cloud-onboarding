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
SRV_PID=""
trap 'rm -rf "$ROOT"; if [[ -n "$SRV_PID" ]]; then kill "$SRV_PID" 2>/dev/null; fi' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '      %s\n' "$2"; }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

[[ -f "$MODULE_DIR/main.tf" ]] || { echo "No module found in $MODULE_DIR"; exit 2; }

# ---------------------------------------------------------------- environment
mkdir -p "$ROOT/bin" "$ROOT/home" "$ROOT/rel"
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

# Three fake Terraform releases made from the real module. Each carries a marker file, so a test
# can tell which one was installed. 9.10.0 is newest by version but sorts before 9.9.x as text.
mkrel() {
  mkdir -p "$ROOT/rel/$1"
  python3 - "$MODULE_DIR" "$ROOT/rel/$1/$1.zip" "$1" <<'PY'
import sys, zipfile, glob, os
src, dst, tag = sys.argv[1:4]
with zipfile.ZipFile(dst, "w") as z:
    for f in sorted(glob.glob(os.path.join(src, "*.tf"))):
        z.write(f, os.path.basename(f))
    z.writestr("marker.tf", f"# {tag}\n")
PY
}
TAG_LO=azure-tf-v9.9.8; TAG_MID=azure-tf-v9.9.9; TAG_HI=azure-tf-v9.10.0
for t in $TAG_LO $TAG_MID $TAG_HI; do mkrel "$t"; done
zipof() { echo "$ROOT/rel/$1/$1.zip"; }
# pinned out of order on purpose: the script must still treat 9.10.0 as the newest
python3 "$HERE/build.py" --version 1.2.3 --tf-tags "$TAG_MID,$TAG_HI,$TAG_LO" \
  --zip "$TAG_LO=$(zipof $TAG_LO)" --zip "$TAG_MID=$(zipof $TAG_MID)" --zip "$TAG_HI=$(zipof $TAG_HI)" \
  --out "$ROOT/dist" >/dev/null || { echo "build.py failed"; exit 2; }
S="$ROOT/dist/atomity-azure.sh"
SRC="$HERE/atomity-azure.sh"
ZIP=$(zipof $TAG_HI)
marker() { tr -d '\n' < "$ROOT/work/marker.tf" 2>/dev/null; }

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
check "source has the two placeholders" \
  'grep -q "@@SCRIPT_VERSION@@" "$SRC" && grep -q "@@PINNED_MODULES@@" "$SRC"'
check "built script has none left" \
  '! grep -qE "@@(SCRIPT_VERSION|PINNED_MODULES)@@" "$S"'
check "built script checksum file verifies" '(cd "$ROOT/dist" && sha256sum -c atomity-azure.sh.sha256 >/dev/null 2>&1)'
run python3 "$HERE/build.py" --tf-tags v1 --version 1.0.0 --out "$ROOT/x"
check "build.py rejects a bad tag" '[[ $rc -ne 0 ]] && has "azure-tf-vX.Y.Z"'
run python3 "$HERE/build.py" --tf-tags azure-tf-v1.0.0 --version 1.0 --out "$ROOT/x"
check "build.py rejects a bad --version" '[[ $rc -ne 0 ]] && has "X.Y.Z"'

pin_zips=(); while read -r t; do pin_zips+=(--zip "$t=$ZIP"); done < <(grep -vE '^[[:space:]]*(#|$)' "$HERE/TERRAFORM_TAGS")
run python3 "$HERE/build.py" --version 1.0.0 "${pin_zips[@]}" --out "$ROOT/x"
check "build.py reads the pins from TERRAFORM_TAGS" 'has "Terraform pin  : $(grep -vE "^[[:space:]]*(#|$)" "$HERE/TERRAFORM_TAGS" | sed -n 1p)"'

check "stamped pins are newest first by version number" 'grep -q "^PINNED_MODULES=\"$TAG_HI " "$S"'
run python3 "$HERE/build.py" --version 1.0.0 --tf-tags "$TAG_HI,$TAG_HI" --out "$ROOT/x"
check "build.py rejects duplicate tags" '[[ $rc -ne 0 ]] && has "Duplicate"'
run python3 "$HERE/build.py" --version 1.0.0 --tf-tags "$TAG_HI" --zip "azure-tf-v0.0.1=$ZIP" --out "$ROOT/x"
check "build.py rejects a --zip for a tag that is not pinned" '[[ $rc -ne 0 ]] && has "must be TAG=PATH"'
mkdir -p "$ROOT/bt" && cp "$HERE/build.py" "$HERE/atomity-azure.sh" "$ROOT/bt/"
run python3 "$ROOT/bt/build.py" --version 1.0.0 --out "$ROOT/x"
check "build.py without TERRAFORM_TAGS or --tf-tags says what to do" '[[ $rc -ne 0 ]] && has "TERRAFORM_TAGS"'
printf '# only a comment\n\n' > "$ROOT/bt/TERRAFORM_TAGS"
run python3 "$ROOT/bt/build.py" --version 1.0.0 --out "$ROOT/x"
check "build.py with an empty pin file refuses" '[[ $rc -ne 0 ]] && has "No Terraform releases to pin"'
printf '# comment\n\n%s\n  %s  \n' "$TAG_LO" "$TAG_HI" > "$ROOT/bt/TERRAFORM_TAGS"
run python3 "$ROOT/bt/build.py" --version 1.0.0 --zip "$TAG_LO=$ZIP" --zip "$TAG_HI=$ZIP" --out "$ROOT/x"
check "build.py ignores comments and blank lines and trims spaces" '[[ $rc -eq 0 ]] && has "$TAG_LO" && has "$TAG_HI"'

# ---------------------------------------------------------------- arguments
echo "## arguments and validation"
reset
run bash "$S" --version
check "--version names the default release" 'has "atomity-azure.sh 1.2.3 (default Terraform module azure-tf-v9.10.0)"'
check "--version lists every pin, newest first by version number" 'has "Pinned Terraform modules: azure-tf-v9.10.0 azure-tf-v9.9.9 azure-tf-v9.9.8"'
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
check "tampered archive rejected" 'has "Checksum mismatch for $TAG_HI"'
check "tampered newest release: no fallback to an older one" '! has "Trying the next" && ! has "Downloading $TAG_MID"'
check "nothing but the version check ran" '[[ "$(calls)" == "terraform version;" ]]' "$(calls)"
check "no module files installed" '[[ -z "$(ls "$ROOT"/work/*.tf 2>/dev/null)" ]]'
mv "$ZIP.orig" "$ZIP"
reset; ATOMITY_RELEASES_BASE=file:///nonexistent run bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes
check "every pinned release missing: clear error" 'has "None of the pinned Terraform releases could be downloaded"'
reset; run bash "$SRC" apply "${BASE[@]}" --management-group-id "$T" --yes
check "unstamped development copy refuses to download" 'has "This is a development copy of the script"'
reset; run bash "$SRC" plan "${BASE[@]}" --management-group-id "$T" --module-dir "$MODULE_DIR"
check "--module-dir works for a development copy" 'has "Development mode" && has "Plan: 5 to add"'
run bash "$SRC" plan "${BASE[@]}" --management-group-id "$T" --module-dir /tmp
check "--module-dir without main.tf rejected" 'has "No main.tf in /tmp"'

mkdir -p "$ROOT/nested/azure" "$ROOT/rel2/$TAG_MID"
cp "$MODULE_DIR"/*.tf "$ROOT/nested/azure/"
python3 - "$ROOT/nested" "$ROOT/rel2/$TAG_MID/$TAG_MID.zip" <<'PY'
import sys, zipfile, glob, os
base, dst = sys.argv[1:3]
with zipfile.ZipFile(dst, "w") as z:
    for f in sorted(glob.glob(os.path.join(base, "azure", "*.tf"))):
        z.write(f, os.path.join("azure", os.path.basename(f)))
PY
python3 "$HERE/build.py" --tf-tags "$TAG_MID" --version 1.2.3 --zip "$TAG_MID=$ROOT/rel2/$TAG_MID/$TAG_MID.zip" --out "$ROOT/dist2" >/dev/null
reset; ATOMITY_RELEASES_BASE="file://$ROOT/rel2" run bash "$ROOT/dist2/atomity-azure.sh" plan "${BASE[@]}" --management-group-id "$T"
check "module inside a top-level folder of the archive" 'has "Plan: 5 to add"'

# ---------------------------------------------------------------- several pins
echo "## several pinned releases"
gone() { mv "$ROOT/rel/$1" "$ROOT/gone_$1"; }
back() { mv "$ROOT/gone_$1" "$ROOT/rel/$1"; }
PLAN=(plan "${BASE[@]}" --management-group-id "$T")

reset; run bash "$S" "${PLAN[@]}"
check "default runs the newest pin by version (9.10.0, not 9.9.9)" '[[ "$(marker)" == "# $TAG_HI" ]] && has "Downloading $TAG_HI"' "marker=$(marker)"
check "default does not download the older pins" '! has "Downloading $TAG_MID" && ! has "Downloading $TAG_LO"'

reset; run bash "$S" "${PLAN[@]}" --module-tag "$TAG_LO"
check "--module-tag runs an older pinned release" '[[ "$(marker)" == "# $TAG_LO" ]] && ! has "Downloading $TAG_HI"' "marker=$(marker)"
reset; run bash "$S" "${PLAN[@]}" --module-tag azure-tf-v0.0.1
check "--module-tag outside the pinned list is refused, with the list" '[[ $rc -ne 0 ]] && has "not one of this script" && has "$TAG_HI $TAG_MID $TAG_LO"'
check "a refused --module-tag downloads and runs nothing" '! logged "init|plan" && ! has "Downloading"'
run bash "$S" "${PLAN[@]}" --module-tag
check "--module-tag needs a value" 'has "Option --module-tag needs a value"'
run bash "$SRC" plan "${BASE[@]}" --management-group-id "$T" --module-dir "$MODULE_DIR" --module-tag "$TAG_LO"
check "--module-dir and --module-tag cannot be combined" 'has "either --module-dir or --module-tag"'
sed -E "s/^($TAG_MID) [0-9a-f]{64}/\1 notahash/" "$S" > "$ROOT/damaged.sh"
run bash "$ROOT/damaged.sh" "${PLAN[@]}"
check "a hand-damaged pin list is refused" 'has "damaged list of Terraform releases"'

echo "## fallback only when a release is gone"
gone "$TAG_HI"; reset; run bash "$S" "${PLAN[@]}"
check "newest removed: falls back to the next pin with a warning" \
  '[[ "$(marker)" == "# $TAG_MID" ]] && has "$TAG_HI is no longer available" && has "using $TAG_MID because $TAG_HI is unavailable"' "marker=$(marker)"
gone "$TAG_MID"; reset; run bash "$S" "${PLAN[@]}"
check "two removed: falls back to the oldest" '[[ "$(marker)" == "# $TAG_LO" ]]' "marker=$(marker)"
gone "$TAG_LO"; reset; run bash "$S" "${PLAN[@]}"
check "all removed: stops, naming every release it tried" '[[ $rc -ne 0 ]] && has "None of the pinned Terraform releases could be downloaded" && has "$TAG_HI" && has "$TAG_LO"'
back "$TAG_MID"; back "$TAG_LO"
reset; run bash "$S" "${PLAN[@]}" --module-tag "$TAG_HI"
check "an explicit --module-tag that is gone does not fall back" '[[ $rc -ne 0 ]] && has "$TAG_HI could not be found" && ! has "Downloading $TAG_MID"'
back "$TAG_HI"

# Real HTTP status codes, so the decision is tested on curl's own status-code path.
cat > "$ROOT/serve.py" <<'PY'
import http.server, json, os, sys
root, codes_path, port_path = sys.argv[1:4]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        code = json.load(open(codes_path)).get(parts[0])
        if code and code != 200:
            self.send_response(code); self.end_headers(); return
        f = os.path.join(root, *parts)
        if os.path.isfile(f):
            data = open(f, "rb").read()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(port_path, "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
echo '{}' > "$ROOT/codes.json"
python3 "$ROOT/serve.py" "$ROOT/rel" "$ROOT/codes.json" "$ROOT/port" & SRV_PID=$!
for _ in $(seq 1 50); do [[ -s "$ROOT/port" ]] && break; sleep 0.1; done
HTTP="http://127.0.0.1:$(cat "$ROOT/port")"
setcode() { printf '{"%s": %s}' "$1" "$2" > "$ROOT/codes.json"; }
for code in 404 410; do
  setcode "$TAG_HI" $code; reset; ATOMITY_RELEASES_BASE=$HTTP run bash "$S" "${PLAN[@]}"
  check "HTTP $code on the newest: falls back to the next pin" '[[ "$(marker)" == "# $TAG_MID" ]]' "marker=$(marker) $out"
done
for code in 403 500 503; do
  setcode "$TAG_HI" $code; reset; ATOMITY_RELEASES_BASE=$HTTP run bash "$S" "${PLAN[@]}"
  check "HTTP $code on the newest: stops, does not fall back" '[[ $rc -ne 0 ]] && has "Could not download" && ! has "Trying the next" && ! has "Downloading $TAG_MID"' "$out"
done
echo '{}' > "$ROOT/codes.json"; reset; ATOMITY_RELEASES_BASE=$HTTP run bash "$S" "${PLAN[@]}"
check "HTTP 200 works the same as file://" '[[ "$(marker)" == "# $TAG_HI" ]]'
reset; ATOMITY_RELEASES_BASE=http://127.0.0.1:1 run bash "$S" "${PLAN[@]}"
check "network error: stops, does not fall back" '[[ $rc -ne 0 ]] && has "Could not download" && ! has "Trying the next"'

echo "## remove uses the release that created the connection"
reset; bash "$S" "${PLAN[@]/plan/apply}" --module-tag "$TAG_LO" --yes >/dev/null 2>&1
check "apply records the release it used" '[[ "$(cat "$ROOT/work/.atomity-module")" == "$TAG_LO" ]]' "$(cat "$ROOT/work/.atomity-module" 2>/dev/null)"
run bash "$S" remove --yes
check "remove picks that release, not the newest" 'has "Downloading $TAG_LO" && ! has "Downloading $TAG_HI" && has "are removed."'

reset; bash "$S" apply "${BASE[@]}" --management-group-id "$T" --module-tag "$TAG_LO" --yes >/dev/null 2>&1
bash "$S" apply "${BASE[@]}" --management-group-id "$T" --yes >/dev/null 2>&1
check "applying again without --module-tag moves to the newest and records it" '[[ "$(cat "$ROOT/work/.atomity-module")" == "$TAG_HI" ]]'

reset; bash "$S" "${PLAN[@]/plan/apply}" --module-tag "$TAG_LO" --yes >/dev/null 2>&1
echo "azure-tf-v0.0.1" > "$ROOT/work/.atomity-module"
run bash "$S" remove --yes
check "recorded release no longer included: says so and uses the newest" 'has "no longer includes" && has "Downloading $TAG_HI" && has "are removed."' "$out"

reset; bash "$S" "${PLAN[@]/plan/apply}" --module-tag "$TAG_LO" --yes >/dev/null 2>&1
gone "$TAG_LO"
run bash "$S" remove --yes
check "recorded release removed from GitHub: falls back and still removes" 'has "$TAG_LO is no longer available" && has "Downloading $TAG_HI" && has "are removed."' "$out"
back "$TAG_LO"

reset; run bash "$S" "${PLAN[@]}"
check "plan never records a release (nothing was created)" '[[ ! -f "$ROOT/work/.atomity-module" ]]'

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