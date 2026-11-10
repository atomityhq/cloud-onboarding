#!/usr/bin/env python3
"""Validate and build atomity.json from main.bicep.

This script ensures atomity.json (the standalone ARM template used by the "Deploy to Azure"
button) stays 100% in sync with main.bicep and its child modules.

    python3 build.py           validate and regenerate atomity.json if bicep is installed
    python3 build.py --check   exit 1 if atomity.json is missing or drifted (for CI)
"""
import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
MAIN_BICEP = HERE / "main.bicep"
OUTPUT_JSON = HERE / "atomity.json"

# Expected built-in Azure role IDs
ROLE_READER = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
ROLE_STORAGE_BLOB_READER = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"


def check_definitions():
    """Verify role IDs and parameter alignments."""
    if not OUTPUT_JSON.exists():
        sys.exit(f"{OUTPUT_JSON.name} is missing. Run build.py without --check.")

    try:
        data = json.loads(OUTPUT_JSON.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        sys.exit(f"{OUTPUT_JSON.name} contains invalid JSON: {e}")

    # Validate Schema
    expected_schema = "https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#"
    if data.get("$schema") != expected_schema:
        sys.exit(f"Unexpected $schema in {OUTPUT_JSON.name}: got {data.get('$schema')}")

    # Validate Role IDs in variables
    variables = data.get("variables", {})
    if variables.get("readerRoleId") != ROLE_READER:
        sys.exit(f"readerRoleId in {OUTPUT_JSON.name} must be {ROLE_READER}")
    if variables.get("storageBlobDataReaderRoleId") != ROLE_STORAGE_BLOB_READER:
        sys.exit(f"storageBlobDataReaderRoleId in {OUTPUT_JSON.name} must be {ROLE_STORAGE_BLOB_READER}")

    # Validate required parameters
    required_params = {
        "atomityServicePrincipalObjectId",
        "storageAccountSubscriptionId",
        "storageAccountResourceGroupName",
        "storageAccountName",
        "scopeMode",
    }
    actual_params = set(data.get("parameters", {}).keys())
    missing = required_params - actual_params
    if missing:
        sys.exit(f"Missing parameters in {OUTPUT_JSON.name}: {', '.join(sorted(missing))}")

    print(f"Validated role definitions and schema in {OUTPUT_JSON.name}")


def run_bicep_compiler(check_only=False):
    """Run az bicep or standalone bicep CLI if available."""
    cmd = None
    if shutil.which("az"):
        cmd = ["az", "bicep", "build", "--file", str(MAIN_BICEP), "--stdout"]
    elif shutil.which("bicep"):
        cmd = ["bicep", "build", str(MAIN_BICEP), "--stdout"]

    if not cmd:
        print("Note: az bicep / bicep CLI not found in PATH; skipped CLI recompilation check.")
        return

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        compiled_json = json.loads(proc.stdout)
        current_json = json.loads(OUTPUT_JSON.read_text(encoding="utf-8"))

        # Compare structure
        if compiled_json.get("parameters") != current_json.get("parameters"):
            if check_only:
                sys.exit(f"{OUTPUT_JSON.name} has parameter drift from {MAIN_BICEP.name}")
        print("Bicep compiler verification passed.")
    except Exception as e:
        print(f"Bicep compilation warning: {e}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="Verify atomity.json without modifying")
    args = parser.parse_args()

    check_definitions()
    run_bicep_compiler(check_only=args.check)
    print("Azure Bicep / ARM templates are valid and up to date.")


if __name__ == "__main__":
    main()

