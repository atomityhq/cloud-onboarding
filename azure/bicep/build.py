#!/usr/bin/env python3
"""Build and check the ARM templates, which are compiled from the Bicep source.

There are two templates, because the two scopes are deployed with different commands:

    main.bicep          ->  atomity.json               management group scope (az deployment mg create)
    subscription.bicep  ->  atomity-subscription.json  subscription scope (az deployment sub create)

The ARM templates are generated. Never edit them by hand. Each is the compiler's output, byte for
byte, from the Bicep compiler pinned in BICEP_VERSION (install it with install-bicep.sh).

    python3 build.py            compile the Bicep and rewrite both templates
    python3 build.py --check    change nothing. Exit 1 if either template is not exactly what its
                                Bicep compiles to (this is what CI runs)

What it enforces, and fails hard on:
  * the compiler is the pinned version, because a different version produces a different template
  * each Bicep file compiles with no errors and no warnings
  * each template equals the compiler output. Any difference counts, not only parameter names
  * each template does what Atomity promises, checked on the compiled template:
      - it deploys at the scope its schema says
      - the only roles it can assign are Reader and Storage Blob Data Reader
      - the only resource types it contains are role assignments and nested deployments
      - every role assignment is for a Service Principal
      - it takes exactly the parameters the docs and the wizard rely on
  * the two templates take the storage account parameters in exactly the same way

To check a copy of the source somewhere else, for example the extracted release zip against the
released templates:
    python3 build.py --check --source /path/to/extracted --output /path/to/dist

Standard library only.
"""
import argparse
import difflib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Built-in Azure roles. These are the same two roles the Terraform module assigns.
ROLE_READER = "acdd72a7-3385-48ef-bd42-f606fba81ae7"
ROLE_STORAGE_BLOB_DATA_READER = "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1"
ALLOWED_ROLES = {ROLE_READER, ROLE_STORAGE_BLOB_DATA_READER}

ALLOWED_RESOURCE_TYPES = {"Microsoft.Authorization/roleAssignments", "Microsoft.Resources/deployments"}

# Taken the same way by both templates.
SHARED_PARAMS = (
    "atomityServicePrincipalObjectId",
    "storageAccountSubscriptionId",
    "storageAccountResourceGroupName",
    "storageAccountName",
)

TEMPLATES = (
    {
        "name": "management group",
        "source": "main.bicep",
        "output": "atomity.json",
        "schema": "https://schema.management.azure.com/schemas/2019-08-01/managementGroupDeploymentTemplate.json#",
        "params": set(SHARED_PARAMS),
    },
    {
        "name": "subscription",
        "source": "subscription.bicep",
        "output": "atomity-subscription.json",
        "schema": "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#",
        "params": set(SHARED_PARAMS) | {"subscriptionIds"},
        "min_length": {"subscriptionIds": 1},
    },
)

GUID_RE = re.compile(r"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b")


def die(message: str):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def compiler():
    """Return (command prefix, how to ask for its version, how to pass the source file)."""
    if shutil.which("bicep"):
        return ["bicep"], ["--version"], lambda f: ["build", f, "--stdout"]
    if shutil.which("az"):
        return ["az", "bicep"], ["version"], lambda f: ["build", "--file", f, "--stdout"]
    die("No Bicep compiler found. Run install-bicep.sh, then put its install directory on your PATH.")


def check_compiler_version(prefix, version_args):
    pinned = (HERE / "BICEP_VERSION").read_text().strip()
    r = subprocess.run(prefix + version_args, capture_output=True, text=True)
    m = re.search(r"version (\d+\.\d+\.\d+)", r.stdout + r.stderr)
    found = m.group(1) if m else "unknown"
    if found != pinned:
        die(f"Bicep {found} is installed but these templates are built with {pinned}. "
            f"Run install-bicep.sh and put its install directory first on your PATH.")


def compile_template(prefix, build_args, source: Path) -> str:
    if not source.is_file():
        die(f"{source} does not exist.")
    r = subprocess.run(prefix + build_args(str(source)), capture_output=True, text=True)
    if r.returncode != 0:
        die(f"{source.name} does not compile:\n{r.stderr.strip()}")
    if r.stderr.strip():
        die(f"{source.name} compiles with diagnostics. Fix them so the template is clean:\n{r.stderr.strip()}")
    return r.stdout


def walk_resources(resources):
    if isinstance(resources, dict):  # templates compiled with symbolic names
        resources = list(resources.values())
    for res in resources or []:
        yield res
        template = (res.get("properties") or {}).get("template")
        if isinstance(template, dict):
            yield from walk_resources(template.get("resources"))


def strip_metadata(node):
    if isinstance(node, dict):
        return {k: strip_metadata(v) for k, v in node.items() if k != "metadata"}
    if isinstance(node, list):
        return [strip_metadata(v) for v in node]
    return node


def contract_problems(spec: dict, data: dict) -> list:
    problems = []
    if data.get("$schema") != spec["schema"]:
        problems.append(f"$schema must be {spec['schema']}, got {data.get('$schema')!r}")

    # Descriptions may mention other GUIDs (the Atomity application ID, for one). Only the
    # template's logic counts: variables, resources and outputs.
    guids = {g.lower() for g in GUID_RE.findall(json.dumps(strip_metadata(data)))}
    if guids != ALLOWED_ROLES:
        problems.append(
            "the template may reference exactly the Reader and Storage Blob Data Reader role IDs, "
            f"but it references {sorted(guids)}")

    for res in walk_resources(data.get("resources")):
        rtype = res.get("type")
        if rtype not in ALLOWED_RESOURCE_TYPES:
            problems.append(f"unexpected resource type {rtype!r}. Only role assignments and nested deployments are allowed")
        if rtype == "Microsoft.Authorization/roleAssignments":
            if (res.get("properties") or {}).get("principalType") != "ServicePrincipal":
                problems.append("every role assignment must set principalType to ServicePrincipal")

    params = data.get("parameters") or {}
    if set(params) != spec["params"]:
        missing = sorted(spec["params"] - set(params))
        extra = sorted(set(params) - spec["params"])
        problems.append(f"the parameters must be exactly {sorted(spec['params'])} (missing {missing}, unexpected {extra})")
    for name, minimum in (spec.get("min_length") or {}).items():
        if (params.get(name) or {}).get("minLength") != minimum:
            problems.append(f"{name} must have minLength {minimum}")
    return problems


def shared_param_problems(compiled: dict) -> list:
    problems = []
    first_name, first = next(iter(compiled.items()))
    for other_name, other in list(compiled.items())[1:]:
        for p in SHARED_PARAMS:
            a = strip_metadata((first.get("parameters") or {}).get(p))
            b = strip_metadata((other.get("parameters") or {}).get(p))
            if a != b:
                problems.append(f"parameter {p} differs between the {first_name} and {other_name} templates: {a} vs {b}")
    return problems


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--check", action="store_true", help="Change nothing. Exit 1 if a template is not what its Bicep compiles to.")
    p.add_argument("--source", default=str(HERE), help="Directory that contains the .bicep files (default: next to this script)")
    p.add_argument("--output", default=str(HERE), help="Directory that holds, or receives, the ARM templates (default: next to this script)")
    a = p.parse_args()
    source, output = Path(a.source), Path(a.output)

    prefix, version_args, build_args = compiler()
    check_compiler_version(prefix, version_args)

    compiled_text, compiled = {}, {}
    problems = []
    for spec in TEMPLATES:
        text = compile_template(prefix, build_args, source / spec["source"])
        try:
            data = json.loads(text)
        except json.JSONDecodeError as e:
            die(f"the compiler did not produce valid JSON for {spec['source']}: {e}")
        compiled_text[spec["name"]] = text if text.endswith("\n") else text + "\n"
        compiled[spec["name"]] = data
        problems += [f"{spec['source']}: {x}" for x in contract_problems(spec, data)]
    problems += shared_param_problems(compiled)
    if problems:
        die("the templates break their contract:\n  - " + "\n  - ".join(problems))

    if not a.check:
        for spec in TEMPLATES:
            (output / spec["output"]).write_text(compiled_text[spec["name"]], encoding="utf-8")
            print(f"Wrote {output / spec['output']}")
        return 0

    drift = []
    for spec in TEMPLATES:
        target = output / spec["output"]
        if not target.is_file():
            drift.append(f"{spec['output']} is missing. Run build.py without --check.")
            continue
        try:
            committed = json.loads(target.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            drift.append(f"{spec['output']} is not valid JSON: {e}")
            continue
        if committed != compiled[spec["name"]]:
            diff = list(difflib.unified_diff(
                json.dumps(committed, indent=2).splitlines(), json.dumps(compiled[spec["name"]], indent=2).splitlines(),
                f"{spec['output']} (committed)", f"compiled from {spec['source']}", lineterm="", n=2))
            print("\n".join(diff[:60]), file=sys.stderr)
            if len(diff) > 60:
                print(f"... {len(diff) - 60} more lines", file=sys.stderr)
            drift.append(f"{spec['output']} is not what {spec['source']} compiles to. It is generated: run build.py and commit "
                         "the result. Do not edit it by hand.")
    if drift:
        die("\n".join(drift))
    for spec in TEMPLATES:
        print(f"{spec['output']} is exactly what {spec['source']} compiles to, and the contract holds.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
