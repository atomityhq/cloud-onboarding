#!/usr/bin/env bash
#
# Atomity Azure connection for Azure Cloud Shell.
#
# A thin wrapper around the released Atomity Terraform module. It downloads a
# pinned release, verifies its checksum, shows you the plan, and only changes
# anything after you confirm. It holds no access definitions of its own.
#
#   bash atomity-azure.sh [apply|plan|remove] [options]
#
# The onboarding wizard generates the full command with your values filled in.

set -euo pipefail

# Stamped at release time by build.py. A copy that still has the placeholders
# is a development copy and refuses to download anything.
SCRIPT_VERSION="@@SCRIPT_VERSION@@"
# The Terraform releases this script may run, one "tag sha256" per line. The newest
# is used by default. Every one can be chosen with --module-tag.
PINNED_MODULES="@@PINNED_MODULES@@"

RELEASES_BASE="${ATOMITY_RELEASES_BASE:-https://github.com/atomityhq/cloud-onboarding/releases/download}"
# $HOME is persistent in Cloud Shell, so the Terraform state survives sessions.
WORKDIR="${ATOMITY_WORKDIR:-$HOME/atomity-azure}"
MIN_TERRAFORM="1.5.7"
ATOMITY_APP_ID="c4b84012-e86e-4ea0-9c42-5e015c1c30f4"

CMD="apply"
TENANT_ID=""
STORAGE_ACCOUNT=""
CONTAINER=""
BILLING_ACCOUNT=""
SCOPE="management-group"
MANAGEMENT_GROUP_ID=""
SUBSCRIPTION_IDS=""
ROOT_FOLDER=""
STORAGE_SUBSCRIPTION=""
STORAGE_ACCOUNT_ID=""
MODULE_DIR=""
MODULE_TAG=""
USED_TAG=""
MODULE_RECORD=".atomity-module"   # which pinned release created the state, kept for remove
MOD_TAGS=()
MOD_SHAS=()
ASSUME_YES=0
TMP=""
SHIFT=1

die()  { printf 'Error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }

cleanup() { if [[ -n "$TMP" && -d "$TMP" ]]; then rm -rf -- "$TMP"; fi; }
trap cleanup EXIT

usage() {
  cat <<'USAGE'
Usage: bash atomity-azure.sh [apply|plan|remove] [options]

Commands
  apply    Show the plan, ask for confirmation, then create everything (default)
  plan     Show the plan and stop. Nothing is created.
  remove   Show what will be removed, ask for confirmation, then remove it

Options (apply and plan)
  --tenant-id ID             Your Entra tenant ID
  --storage-account NAME     Existing storage account that receives the export
  --container NAME           Container for the export
  --billing-account ID       Billing account the export is created on
  --scope SCOPE              management-group (default) or subscription
  --management-group-id ID   Root management group ID (scope management-group)
  --subscription-ids A,B     Subscriptions to grant Reader on (scope subscription).
                             Leave empty to let Atomity auto-discover.
  --root-folder PATH         Folder inside the container (default: atomity-exports)
  --storage-subscription ID  Subscription that holds the storage account, if it
                             is not the Cloud Shell default
  --storage-account-id ID    Full resource ID of the storage account, if needed

General
  --yes                      Skip the confirmation prompt
  --module-tag TAG           Run this pinned Terraform release instead of the newest one.
                             --version lists the releases this script includes.
  --module-dir DIR           Development only: use a local copy of the module
  --version                  Print the script version and its pinned Terraform releases
  -h, --help                 Show this help
USAGE
}

# A required value must be present and must not be the next option.
need_value() {
  [[ $# -ge 2 && "$2" != --* ]] || die "Option $1 needs a value."
}

# A value that may be empty. Sets SHIFT to 2 when a value was given, else 1.
optional_value() {
  if [[ $# -ge 2 && "$2" != --* ]]; then SHIFT=2; OPTVAL=$2; else SHIFT=1; OPTVAL=""; fi
}

# Values end up inside a generated terraform.tfvars, so only plain characters
# are accepted. This also rules out quotes and interpolation.
safe() {
  local name=$1 value=$2 pattern=${3:-'^[A-Za-z0-9._:-]*$'}
  [[ "$value" =~ $pattern ]] || die "$name contains characters that are not allowed: $value"
}

# True when $1 >= $2. Uses sed rather than head: with pipefail, head closing the
# pipe early can make the producer die with SIGPIPE.
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | sed -n '1p')" == "$2" ]]; }

# Reads PINNED_MODULES into MOD_TAGS and MOD_SHAS, newest first. The order is decided here by
# version number (1.10.0 is newer than 1.9.0), not by the order they were stamped in.
load_pins() {
  [[ "$PINNED_MODULES" != @@* ]] || return 0
  local tag sha
  while read -r tag sha; do
    [[ -n "$tag" ]] || continue
    if [[ ! "$tag" =~ ^[a-z]+-tf-v[0-9]+\.[0-9]+\.[0-9]+$ || ! "$sha" =~ ^[0-9a-f]{64}$ ]]; then
      die "This copy of the script has a damaged list of Terraform releases. Download it again."
    fi
    MOD_TAGS+=("$tag")
    MOD_SHAS+=("$sha")
  done < <(printf '%s\n' "$PINNED_MODULES" | awk 'NF { v=$1; sub(/^.*-v/, "", v); print v, $1, $2 }' | sort -rV | awk '{ print $2, $3 }')
}

print_version() {
  if [[ ${#MOD_TAGS[@]} -gt 0 ]]; then
    info "atomity-azure.sh ${SCRIPT_VERSION} (default Terraform module ${MOD_TAGS[0]})"
    info "Pinned Terraform modules: ${MOD_TAGS[*]}"
  else
    info "atomity-azure.sh ${SCRIPT_VERSION} (development copy, no pinned Terraform modules)"
  fi
}

pin_sha() {
  local i
  for i in "${!MOD_TAGS[@]}"; do
    if [[ "${MOD_TAGS[$i]}" == "$1" ]]; then printf '%s' "${MOD_SHAS[$i]}"; return 0; fi
  done
  return 1
}

# The releases to try, in order. --module-tag means exactly that one. Otherwise the newest
# first. For remove, the release that created the state goes first, because a newer module
# may expect inputs the saved settings do not have.
module_candidates() {
  local i recorded="" t
  if [[ -n "$MODULE_TAG" ]]; then printf '%s\n' "$MODULE_TAG"; return 0; fi
  if [[ "$CMD" == "remove" && -f "$WORKDIR/$MODULE_RECORD" ]]; then
    recorded=$(sed -n '1p' "$WORKDIR/$MODULE_RECORD")
  fi
  if [[ -n "$recorded" ]] && pin_sha "$recorded" >/dev/null; then printf '%s\n' "$recorded"; fi
  for i in "${!MOD_TAGS[@]}"; do
    t=${MOD_TAGS[$i]}
    if [[ "$t" != "$recorded" ]]; then printf '%s\n' "$t"; fi
  done
}

# Downloads one pinned release into $TMP/module.zip and verifies it.
# Returns 1 if the release no longer exists (404 or 410). Stops the script on a checksum
# mismatch or on any other download error: those must never fall back to another version.
download_module() {
  local tag=$1 want=$2 url="$RELEASES_BASE/$1/$1.zip" code rc=0 actual
  code=$(curl -fsSL -o "$TMP/module.zip" -w '%{http_code}' "$url" 2>"$TMP/curl.err") || rc=$?
  if [[ $rc -ne 0 ]]; then
    # 22: HTTP error, where 404 and 410 mean the release is gone. 37: file not found (tests).
    if [[ $rc -eq 37 || ( $rc -eq 22 && ( "$code" == "404" || "$code" == "410" ) ) ]]; then return 1; fi
    die "Could not download $url: $(tr '\n' ' ' < "$TMP/curl.err")"
  fi
  actual=$(sha256sum "$TMP/module.zip" | awk '{print $1}')
  [[ "$actual" == "$want" ]] \
    || die "Checksum mismatch for $tag. Expected $want but got $actual. The release was changed after this script was built, so nothing was changed and no other version was tried."
  return 0
}

parse_args() {
  if [[ $# -gt 0 && "$1" != -* ]]; then CMD=$1; shift; fi
  case "$CMD" in
    apply|plan|remove) ;;
    help) usage; exit 0 ;;
    *) usage >&2; die "Unknown command: $CMD" ;;
  esac
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tenant-id)            need_value "$@"; TENANT_ID=$2; shift 2 ;;
      --storage-account)      need_value "$@"; STORAGE_ACCOUNT=$2; shift 2 ;;
      --container)            need_value "$@"; CONTAINER=$2; shift 2 ;;
      --billing-account)      need_value "$@"; BILLING_ACCOUNT=$2; shift 2 ;;
      --scope)                need_value "$@"; SCOPE=$2; shift 2 ;;
      --management-group-id)  need_value "$@"; MANAGEMENT_GROUP_ID=$2; shift 2 ;;
      --subscription-ids)     optional_value "$@"; SUBSCRIPTION_IDS=$OPTVAL; shift "$SHIFT" ;;
      --root-folder)          optional_value "$@"; ROOT_FOLDER=$OPTVAL; shift "$SHIFT" ;;
      --storage-subscription) need_value "$@"; STORAGE_SUBSCRIPTION=$2; shift 2 ;;
      --storage-account-id)   need_value "$@"; STORAGE_ACCOUNT_ID=$2; shift 2 ;;
      --module-tag)           need_value "$@"; MODULE_TAG=$2; shift 2 ;;
      --module-dir)           need_value "$@"; MODULE_DIR=$2; shift 2 ;;
      --yes|-y)               ASSUME_YES=1; shift ;;
      --version)              print_version; exit 0 ;;
      -h|--help)              usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
  done
}

validate_inputs() {
  local guid='^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$'
  [[ -n "$TENANT_ID" ]]       || die "--tenant-id is required."
  [[ -n "$STORAGE_ACCOUNT" ]] || die "--storage-account is required."
  [[ -n "$CONTAINER" ]]       || die "--container is required."
  [[ -n "$BILLING_ACCOUNT" ]] || die "--billing-account is required."
  [[ "$TENANT_ID" =~ $guid ]] || die "--tenant-id must be a GUID."
  safe "--storage-account" "$STORAGE_ACCOUNT"
  safe "--container" "$CONTAINER"
  safe "--billing-account" "$BILLING_ACCOUNT"
  safe "--root-folder" "$ROOT_FOLDER" '^[A-Za-z0-9._/-]*$'
  safe "--storage-account-id" "$STORAGE_ACCOUNT_ID" '^[A-Za-z0-9._/-]*$'
  if [[ -n "$STORAGE_SUBSCRIPTION" ]]; then
    [[ "$STORAGE_SUBSCRIPTION" =~ $guid ]] || die "--storage-subscription must be a GUID."
  fi
  case "$SCOPE" in
    management-group)
      [[ -n "$MANAGEMENT_GROUP_ID" ]] || die "--management-group-id is required with --scope management-group."
      # Management group IDs may contain letters, digits, - _ ( ) .
      safe "--management-group-id" "$MANAGEMENT_GROUP_ID" '^[A-Za-z0-9._()-]+$' ;;
    subscription)
      local s subs=()
      IFS=',' read -r -a subs <<< "$SUBSCRIPTION_IDS"
      for s in ${subs[@]+"${subs[@]}"}; do
        s=${s//[[:space:]]/}
        [[ -z "$s" || "$s" =~ $guid ]] || die "Not a subscription GUID: $s"
      done ;;
    *) die "--scope must be management-group or subscription." ;;
  esac
}

write_tfvars() {
  local f="$WORKDIR/terraform.tfvars" s list="" first=1 subs=()
  {
    echo "# Written by atomity-azure.sh ${SCRIPT_VERSION}. Deleted by the remove command."
    echo "tenant_id            = \"$TENANT_ID\""
    echo "storage_account_name = \"$STORAGE_ACCOUNT\""
    echo "container_name       = \"$CONTAINER\""
    echo "billing_account_id   = \"$BILLING_ACCOUNT\""
    if [[ "$SCOPE" == "management-group" ]]; then
      echo "scope_mode           = \"management_group\""
      echo "management_group_id  = \"$MANAGEMENT_GROUP_ID\""
    else
      IFS=',' read -r -a subs <<< "$SUBSCRIPTION_IDS"
      for s in ${subs[@]+"${subs[@]}"}; do
        s=${s//[[:space:]]/}
        [[ -z "$s" ]] && continue
        if [[ $first -eq 1 ]]; then list="\"$s\""; first=0; else list="$list, \"$s\""; fi
      done
      echo "scope_mode           = \"subscription\""
      echo "subscription_ids     = [$list]"
    fi
    if [[ -n "$ROOT_FOLDER" ]];          then echo "root_folder_path     = \"$ROOT_FOLDER\""; fi
    if [[ -n "$STORAGE_SUBSCRIPTION" ]]; then echo "subscription_id      = \"$STORAGE_SUBSCRIPTION\""; fi
    if [[ -n "$STORAGE_ACCOUNT_ID" ]];   then echo "storage_account_id   = \"$STORAGE_ACCOUNT_ID\""; fi
  } > "$f"
  chmod 600 "$f"
}

tfvar() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" "$WORKDIR/terraform.tfvars" | sed -n '1p'; }

preflight() {
  step "Checking your environment"
  if [[ -z "${ACC_CLOUD:-}" ]]; then
    info "Note: this script is made for Azure Cloud Shell. It also works elsewhere if the Azure CLI and Terraform are installed and signed in."
  fi
  local tool
  for tool in az terraform curl unzip sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "'$tool' was not found. Azure Cloud Shell (Bash) includes it."
  done
  local tfv
  tfv=$(terraform version | sed -nE '1s/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  version_ge "$tfv" "$MIN_TERRAFORM" || die "Terraform $MIN_TERRAFORM or newer is required. Found $tfv."

  local current
  current=$(az account show --query tenantId -o tsv 2>/dev/null) \
    || die "Not signed in to Azure. In Cloud Shell you are signed in automatically; elsewhere run 'az login'."
  if [[ "$(tr '[:upper:]' '[:lower:]' <<<"$current")" != "$(tr '[:upper:]' '[:lower:]' <<<"$TENANT_ID")" ]]; then
    die "You are signed in to tenant $current, but this connection is for $TENANT_ID. Switch directory in the Azure portal (Settings, Directories + subscriptions), open Cloud Shell again, and rerun."
  fi
  info "Signed in to tenant $TENANT_ID. Terraform $tfv."

  # The azurerm provider needs a subscription. Use the storage account's if
  # given, otherwise the Cloud Shell default.
  ARM_SUBSCRIPTION_ID="${STORAGE_SUBSCRIPTION:-$(az account show --query id -o tsv)}"
  export ARM_SUBSCRIPTION_ID
}

fetch_module() {
  step "Getting the Atomity Terraform module"
  TMP=$(mktemp -d)
  local src
  if [[ -n "$MODULE_DIR" ]]; then
    info "Development mode: using the local module in $MODULE_DIR. Checksum verification is skipped."
    [[ -f "$MODULE_DIR/main.tf" ]] || die "No main.tf in $MODULE_DIR."
    src=$MODULE_DIR
  else
    if [[ ${#MOD_TAGS[@]} -eq 0 ]]; then
      die "This is a development copy of the script. Download the released script from the onboarding wizard."
    fi
    local cand sha first="" tried="" main recorded=""
    if [[ "$CMD" == "remove" && -z "$MODULE_TAG" && -f "$WORKDIR/$MODULE_RECORD" ]]; then
      recorded=$(sed -n '1p' "$WORKDIR/$MODULE_RECORD")
      if [[ -n "$recorded" ]] && ! pin_sha "$recorded" >/dev/null; then
        info "This connection was created with $recorded, which this script no longer includes. Using the newest included release instead."
      fi
    fi
    while read -r cand; do
      [[ -n "$cand" ]] || continue
      sha=$(pin_sha "$cand") || die "$cand is not one of this script's pinned Terraform releases. Available: ${MOD_TAGS[*]}"
      if [[ -z "$first" ]]; then first=$cand; fi
      info "Downloading $cand"
      if download_module "$cand" "$sha"; then USED_TAG=$cand; break; fi
      tried="$tried $cand"
      if [[ -n "$MODULE_TAG" ]]; then die "$cand could not be found. It may have been removed."; fi
      info "Warning: $cand is no longer available. Trying the next pinned release."
    done < <(module_candidates)
    [[ -n "$USED_TAG" ]] || die "None of the pinned Terraform releases could be downloaded:$tried"
    if [[ "$USED_TAG" != "$first" ]]; then info "Warning: using $USED_TAG because $first is unavailable."; fi
    info "Checksum verified."
    mkdir "$TMP/x"
    unzip -q "$TMP/module.zip" -d "$TMP/x"
    main=$(find "$TMP/x" -maxdepth 2 -name main.tf | sed -n '1p')
    [[ -n "$main" ]] || die "The release archive does not contain a module."
    src=$(dirname "$main")
  fi
  # Replace the module's own files. State, tfvars and .terraform stay.
  find "$WORKDIR" -maxdepth 1 -name '*.tf' -type f -delete
  cp "$src"/*.tf "$WORKDIR"/
  if [[ -f "$src/.terraform.lock.hcl" ]]; then cp "$src/.terraform.lock.hcl" "$WORKDIR"/; fi
}

tf_init() {
  step "Preparing Terraform"
  (cd "$WORKDIR" && { terraform init -input=false -no-color >/dev/null 2>&1 \
    || terraform init -input=false -upgrade -no-color; })
}

confirm() {
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  # -r /dev/tty is not enough: the node exists even with no terminal attached.
  # Try to open it for real.
  if ! ( : </dev/tty ) 2>/dev/null; then
    die "No terminal to ask for confirmation. Rerun with --yes to proceed without asking."
  fi
  local answer=""
  read -r -p "$1 Type 'yes' to continue: " answer </dev/tty || true
  [[ "$answer" == "yes" ]]
}

do_apply() {
  validate_inputs
  mkdir -p "$WORKDIR"; chmod 700 "$WORKDIR"
  preflight
  write_tfvars
  fetch_module
  tf_init
  step "Plan: what will be created"
  (cd "$WORKDIR" && terraform plan -input=false -out=tfplan)
  if [[ "$CMD" == "plan" ]]; then
    info; info "This was only a plan. Nothing was created. Run the same command with 'apply' to continue."
    return 0
  fi
  info
  if ! confirm "Create these resources in tenant $TENANT_ID?"; then
    info "Cancelled. Nothing was changed."
    return 0
  fi
  step "Applying"
  (cd "$WORKDIR" && terraform apply -input=false tfplan)
  if [[ -n "$USED_TAG" ]]; then printf '%s\n' "$USED_TAG" > "$WORKDIR/$MODULE_RECORD"; fi
  step "Done"
  (cd "$WORKDIR" && terraform output connection_details)
  info
  info "Back in Atomity, choose Validate connection."
  info "The first export files can take up to 24 hours to appear. You can finish connecting before then."
  info "To remove Atomity's access later, run this script again with 'remove'."
}

no_state_help() {
  printf '%s\n' \
    "Error: No Terraform state found in $WORKDIR." \
    "This script can only remove what it created itself, and that record is gone." \
    "To remove Atomity's access by hand:" \
    "  1. Entra ID, Enterprise applications: delete the application with ID $ATOMITY_APP_ID." \
    "     This removes every role assignment at once." \
    "  2. Cost Management, Exports (on your billing account): delete the Atomity export." >&2
  exit 1
}

do_remove() {
  if [[ ! -f "$WORKDIR/terraform.tfstate" || ! -f "$WORKDIR/terraform.tfvars" ]]; then no_state_help; fi
  TENANT_ID=$(tfvar tenant_id)
  [[ -n "$TENANT_ID" ]] || die "Could not read tenant_id from $WORKDIR/terraform.tfvars."
  STORAGE_SUBSCRIPTION=$(tfvar subscription_id)
  preflight
  fetch_module
  tf_init
  step "Plan: what will be removed"
  (cd "$WORKDIR" && terraform plan -destroy -input=false -out=tfplan)
  info
  if ! confirm "Remove Atomity's access from tenant $TENANT_ID?"; then
    info "Cancelled. Nothing was changed."
    return 0
  fi
  step "Removing"
  (cd "$WORKDIR" && terraform apply -input=false tfplan)
  step "Done"
  info "Atomity's Service Principal, its role assignments and the export are removed."
  info "Your storage account, container and exported files were not touched. Delete them yourself if you want them gone."
  if [[ -n "$WORKDIR" && "$WORKDIR" != "/" && "$WORKDIR" != "$HOME" ]]; then
    rm -rf -- "$WORKDIR"
  fi
}

main() {
  load_pins
  parse_args "$@"
  if [[ -n "$MODULE_DIR" && -n "$MODULE_TAG" ]]; then die "Use either --module-dir or --module-tag, not both."; fi
  # The working directory is wiped of *.tf files on every run and deleted by
  # remove, so it must never be the home directory or the root.
  if [[ -z "$WORKDIR" || "$WORKDIR" == "/" || "$WORKDIR" == "$HOME" || "$WORKDIR" == "$HOME/" ]]; then
    die "Refusing to use '$WORKDIR' as the working directory."
  fi
  case "$CMD" in
    apply|plan) do_apply ;;
    remove)     do_remove ;;
  esac
}

main "$@"
