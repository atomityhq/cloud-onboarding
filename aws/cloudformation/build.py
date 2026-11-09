#!/usr/bin/env python3
"""Generate atomity.yaml from atomity.src.yaml and the shared definitions.

A CloudFormation template must be one self-contained file, so the policies in
aws/policies/ and the query in aws/focus_query.sql and aws/member_role.yaml are inlined here. Terraform
reads the same files, which is what keeps the two approaches from drifting.

    python3 build.py           write atomity.yaml
    python3 build.py --check   exit 1 if atomity.yaml is out of date (for CI)

Both modes first check that member_role.yaml (the StackSet template for member
accounts) has not drifted from the shared policies. Needs PyYAML for that.

Placeholders in the policy files, written ${Name}:
  Terraform       templatefile() variables of the same name
  CloudFormation  parameters of the same name, or the expansions below
"""
import argparse
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
AWS_DIR = HERE.parent

SOURCE = HERE / "atomity.src.yaml"
OUTPUT = HERE / "atomity.yaml"
TRUST = AWS_DIR / "policies" / "trust.json"
PERMISSION = AWS_DIR / "policies" / "permission.json"
QUERY = AWS_DIR / "focus_query.sql"
MEMBER_ROLE = AWS_DIR / "member_role.yaml"  # also the StackSet template in organizations.tf

# Placeholders that are not a template parameter: expanded before Fn::Sub runs.
EXPANSIONS = {"BucketArn": "arn:aws:s3:::${BucketName}"}
# Placeholders that are template parameters of the same name.
PARAMETERS = {"AtomityRoleArn", "ExternalId", "BucketName"}

PLACEHOLDER = re.compile(r"\$\{([^}]+)\}")
HEADER = (
    "# GENERATED FILE - do not edit.\n"
    "# Edit atomity.src.yaml or the files in aws/policies/, then run: python3 build.py\n"
)


def to_cfn(node):
    """Turn every string containing a placeholder into an Fn::Sub."""
    if isinstance(node, dict):
        return {k: to_cfn(v) for k, v in node.items()}
    if isinstance(node, list):
        return [to_cfn(v) for v in node]
    if isinstance(node, str) and "${" in node:
        whole = PLACEHOLDER.fullmatch(node)
        if whole and whole[1] in PARAMETERS:
            return {"Ref": whole[1]}  # a lone parameter needs no Fn::Sub
        for name in PLACEHOLDER.findall(node):
            if name not in EXPANSIONS and name not in PARAMETERS:
                sys.exit(f"unknown placeholder ${{{name}}} in a policy file")
        for name, text in EXPANSIONS.items():
            node = node.replace("${" + name + "}", text)
        return {"Fn::Sub": node}
    return node


def flow_json(path, pad):
    """JSON is valid YAML, so a policy can be embedded as-is."""
    text = json.dumps(to_cfn(json.loads(path.read_text())), indent=2)
    return text.replace("\n", "\n" + " " * pad)


def block_scalar(path, pad):
    lines = path.read_text().strip().splitlines()
    return "|-\n" + "\n".join((" " * pad + ln) if ln.strip() else "" for ln in lines)


MARKER = re.compile(r"^(?P<indent> *)(?P<key>[\w.-]+:) @@(?P<name>[A-Z_]+)@@$")


def normalize(node):
    """Sort lists so the order of actions or statements does not matter."""
    if isinstance(node, dict):
        return {k: normalize(v) for k, v in node.items()}
    if isinstance(node, list):
        return sorted((normalize(v) for v in node), key=lambda v: json.dumps(v, sort_keys=True))
    return node


def check_member_role():
    """member_role.yaml is a narrower copy of the management-account role.

    Its permission statements must be identical to the statement with the same
    Sid in policies/permission.json, its trust policy must match trust.json,
    and its role name must match the main template. Otherwise a permission
    could change in one place and silently not in the other.
    """
    try:
        import yaml
    except ImportError:
        sys.exit("PyYAML is required for the drift check: pip install pyyaml")

    # BaseLoader keeps every scalar as a string and tolerates CloudFormation's !Ref
    # tags (the tag is dropped, leaving the parameter name).
    template = yaml.load(MEMBER_ROLE.read_text(), Loader=yaml.BaseLoader)
    roles = [r["Properties"] for r in template["Resources"].values() if r["Type"] == "AWS::IAM::Role"]
    if len(roles) != 1:
        sys.exit(f"{MEMBER_ROLE.name}: expected exactly one AWS::IAM::Role, found {len(roles)}")
    role = roles[0]
    problems = []

    expected_name = re.search(r"^\s*RoleName: (\S+)", SOURCE.read_text(), re.M)[1]
    if role.get("RoleName") != expected_name:
        problems.append(f"role name is {role.get('RoleName')!r}, the main template uses {expected_name!r}")

    # Placeholders ${Name} become Name, which is what !Ref leaves behind.
    trust = json.loads(PLACEHOLDER.sub(lambda m: m[1], TRUST.read_text()))
    if normalize(role["AssumeRolePolicyDocument"]) != normalize(trust):
        problems.append("trust policy differs from policies/trust.json")

    management = {s["Sid"]: s for s in json.loads(PERMISSION.read_text())["Statement"]}
    policies = role.get("Policies", [])
    if len(policies) != 1:
        problems.append(f"expected one inline policy, found {len(policies)}")
    for s in policies[0]["PolicyDocument"]["Statement"] if policies else []:
        sid = s.get("Sid")
        if sid not in management:
            problems.append(f"statement {sid!r} is not in policies/permission.json")
        elif normalize(s) != normalize(management[sid]):
            have, want = set(s["Action"]), set(management[sid]["Action"])
            detail = []
            if have - want:
                detail.append("only in member role: " + ", ".join(sorted(have - want)))
            if want - have:
                detail.append("only in permission.json: " + ", ".join(sorted(want - have)))
            if not detail:
                detail.append("same actions, but Effect or Resource differs")
            problems.append(f"statement {sid!r} differs ({'; '.join(detail)})")

    if problems:
        sys.exit(f"{MEMBER_ROLE.name} has drifted from the shared policies:\n  - " + "\n  - ".join(problems))


def build():
    out = []
    for line in SOURCE.read_text().splitlines():
        m = MARKER.match(line)
        if not m:
            out.append(line)
            continue
        pad = len(m["indent"]) + 2
        render = {
            "TRUST": lambda: flow_json(TRUST, pad),
            "PERMISSION": lambda: flow_json(PERMISSION, pad),
            "QUERY": lambda: block_scalar(QUERY, pad),
            "MEMBER_ROLE": lambda: block_scalar(MEMBER_ROLE, pad),
        }.get(m["name"])
        if render is None:
            sys.exit(f"unknown marker @@{m['name']}@@")
        out.append(f"{m['indent']}{m['key']} {render()}")
    result = HEADER + "\n".join(out) + "\n"
    if "@@" in result:
        sys.exit("a @@MARKER@@ was not replaced: check its placement in atomity.src.yaml")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    check_member_role()
    result = build()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != result:
            sys.exit("atomity.yaml is out of date: run python3 build.py")
        print("atomity.yaml is up to date")
    else:
        OUTPUT.write_text(result)
        print(f"wrote {OUTPUT}")


if __name__ == "__main__":
    main()