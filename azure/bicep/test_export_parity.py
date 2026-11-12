#!/usr/bin/env python3
"""The export command in the module README must send the same export definition as the
Terraform module. They are two writings of one definition, so this test fails CI when they
disagree: a changed constant, a field added or removed on one side, a different default, a
different API version, export name or provider.

    python3 -m venv .venv && .venv/bin/pip install python-hcl2==8.2.0
    .venv/bin/python test_export_parity.py

Run it in a clean virtualenv. Other packages can install a different `hcl2` module over this one
(checkov's bc-python-hcl2 does), and python-hcl2 changed its output format between major versions.
The helpers below accept both formats: block labels and string values with or without their quote
characters, and values with or without a one element list around them.

It reads ../README.md, ../main.tf and ../variables.tf (the Azure module's own files).
"""
import json
import re
import sys
import unittest
from pathlib import Path

try:
    import hcl2
except ImportError:
    sys.exit("This test needs python-hcl2. Run: pip install python-hcl2==8.2.0")

ROOT = Path(__file__).resolve().parent.parent

SHELL_VARS = ("STORAGE_ID", "CONTAINER", "ROOT_FOLDER", "FROM")


def first(x):
    """Older python-hcl2 wraps many values in a one element list."""
    while isinstance(x, list) and len(x) == 1:
        x = x[0]
    return x


def unq(x):
    """python-hcl2 8 keeps the quotes of string literals and block labels. Older versions do not."""
    x = first(x)
    if isinstance(x, str) and len(x) >= 2 and x[0] == '"' and x[-1] == '"':
        return x[1:-1].replace('\\"', '"')
    return x


def is_expression(x) -> bool:
    return isinstance(x, str) and x.startswith("${") and x.endswith("}")


def norm_expr(x: str) -> str:
    return re.sub(r"\s+", "", x)


def tf_variable_default(variables_tf: str, name: str):
    for block in hcl2.loads(variables_tf).get("variable", []):
        for label, body in block.items():
            if unq(label) == name:
                return unq(body.get("default"))
    raise AssertionError(f"variables.tf has no variable {name!r}")


def tf_resource(parsed: dict, rtype: str, name: str):
    for r in parsed.get("resource", []):
        for type_label, by_name in r.items():
            if unq(type_label) != rtype:
                continue
            for name_label, body in by_name.items():
                if unq(name_label) == name:
                    return body
    return None


def tf_local(parsed: dict, name: str):
    for block in parsed.get("locals", []):
        if name in block:
            v = first(block[name])
            return v if is_expression(v) else unq(v)
    return None


def readme_command(readme: str) -> str:
    blocks = [b for b in re.findall(r"```bash\n(.*?)```", readme, re.S) if "az rest --method put" in b]
    if len(blocks) != 1:
        raise AssertionError(f"expected exactly one README bash block with 'az rest --method put', found {len(blocks)}")
    return blocks[0]


def readme_body(command: str) -> dict:
    m = re.search(r"<<EOF\n(.*?)\nEOF\n", command, re.S)
    if not m:
        raise AssertionError("the README command has no <<EOF ... EOF request body")
    text = m.group(1)
    for name in SHELL_VARS:
        text = text.replace(f'"${name}"', f'"<<{name}>>"')
    return json.loads(text)


def compare(tf, doc, path, expr_map, problems):
    tf = first(tf)
    if isinstance(tf, dict):
        if not isinstance(doc, dict):
            problems.append(f"{path}: Terraform has an object, the README does not")
            return
        tf = {k: v for k, v in tf.items() if not (k.startswith("__") and k.endswith("__"))}
        for k in sorted(set(tf) - set(doc)):
            problems.append(f"{path}.{k}: in Terraform but missing from the README")
        for k in sorted(set(doc) - set(tf)):
            problems.append(f"{path}.{k}: in the README but missing from Terraform")
        for k in sorted(set(tf) & set(doc)):
            compare(tf[k], doc[k], f"{path}.{k}", expr_map, problems)
        return
    if is_expression(tf):
        known = {norm_expr(k): v for k, v in expr_map.items()}
        if norm_expr(tf) not in known:
            problems.append(f"{path}: Terraform uses {tf!r}, which this test does not know how to compare. Update the test and the README command together")
            return
        want = known[norm_expr(tf)]
        if doc != want:
            problems.append(f"{path}: Terraform expects {want!r}, the README has {doc!r}")
        return
    tf = unq(tf)
    if tf != doc:
        problems.append(f"{path}: Terraform has {tf!r}, the README has {doc!r}")


def check(readme: str, main_tf: str, variables_tf: str) -> list:
    problems = []
    command = readme_command(readme)
    parsed = hcl2.loads(main_tf)   # everything below reads parsed Terraform, never comments

    resource = tf_resource(parsed, "azapi_resource", "focus_export")
    if resource is None:
        return ["main.tf has no azapi_resource.focus_export"]

    # the request body
    expr_map = {
        "${var.data_overwrite_behavior}": tf_variable_default(variables_tf, "data_overwrite_behavior"),
        "${var.focus_dataset_version}": tf_variable_default(variables_tf, "focus_dataset_version"),
        "${var.container_name}": "<<CONTAINER>>",
        "${local.storage_account_id}": "<<STORAGE_ID>>",
        "${local.root_folder_path}": "<<ROOT_FOLDER>>",
        '${timeadd(time_static.export_start.rfc3339,"24h")}': "<<FROM>>",
    }
    compare(resource["body"], readme_body(command), "body", expr_map, problems)

    # the folder default
    folder_expr = tf_local(parsed, "root_folder_path") or ""
    default_folder = re.search(r'coalesce\(local\.root_folder_cleaned,\s*\\?"([^"\\]+)\\?"\)', folder_expr)
    readme_folder = re.search(r'^ROOT_FOLDER="([^"]*)"', command, re.M)
    if not default_folder or not readme_folder or default_folder.group(1) != readme_folder.group(1):
        problems.append(f"root folder default: Terraform {default_folder and default_folder.group(1)!r}, README {readme_folder and readme_folder.group(1)!r}")

    # the schedule start
    if "timeadd(" in json.dumps(resource["body"]) and "date -u -d '+1 day'" not in command:
        problems.append("the schedule starts 24 hours after creation in Terraform, and the README FROM is not now plus one day")

    # the API version, on every URL in the command
    tf_api = re.search(r"@(\d{4}-\d{2}-\d{2})", unq(resource["type"]) or "")
    urls = re.findall(r"api-version=(\d{4}-\d{2}-\d{2})", command)
    if not tf_api or not urls or set(urls) != {tf_api.group(1)}:
        problems.append(f"API version: Terraform {tf_api and tf_api.group(1)!r}, README {sorted(set(urls))}")

    # the export name and the billing account scope
    export_name = tf_variable_default(variables_tf, "export_name")
    if f"/exports/{export_name}" not in command:
        problems.append(f"export name: Terraform default is {export_name!r}, the README URL does not use it")
    scope = tf_local(parsed, "billing_scope")
    if scope != "/providers/Microsoft.Billing/billingAccounts/${var.billing_account_id}":
        problems.append(f"billing scope: Terraform builds {scope!r}")
    if "providers/Microsoft.Billing/billingAccounts/$BILLING_ACCOUNT/providers/Microsoft.CostManagement/exports/" not in command:
        problems.append("the README URL is not on the billing account scope the Terraform module uses")

    # the resource provider that is registered
    register = tf_resource(parsed, "azapi_resource_action", "register_exports_rp")
    namespace = re.search(r"/providers/([A-Za-z.]+)$", unq(register["resource_id"]) or "") if register else None
    if not namespace or f"--namespace {namespace.group(1)}" not in command:
        problems.append(f"the provider registered by Terraform ({namespace and namespace.group(1)}) and by the README command differ")

    # the optional first run
    run = tf_resource(parsed, "azapi_resource_action", "run_export_now")
    if run and unq(run.get("action")) == "run" and "/run?api-version" not in command:
        problems.append("Terraform runs the export once, and the README command does not")
    return problems


class ParityTest(unittest.TestCase):
    def setUp(self):
        self.readme = (ROOT / "README.md").read_text()
        self.main_tf = (ROOT / "main.tf").read_text()
        self.variables_tf = (ROOT / "variables.tf").read_text()

    def problems(self, readme=None, main_tf=None, variables_tf=None):
        return check(readme or self.readme, main_tf or self.main_tf, variables_tf or self.variables_tf)

    def mutate(self, text, old, new):
        self.assertIn(old, text, f"test setup: {old!r} not found")
        return text.replace(old, new, 1)

    def test_the_command_and_the_module_agree(self):
        self.assertEqual(self.problems(), [])

    # ---- drift on the README side
    def test_a_changed_constant_in_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, '"compressionMode": "snappy"', '"compressionMode": "gzip"'))
        self.assertTrue(any("compressionMode" in x for x in p), p)

    def test_a_field_missing_from_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, '    "partitionData": true,\n', ""))
        self.assertTrue(any("partitionData" in x and "missing from the README" in x for x in p), p)

    def test_an_extra_field_in_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, '"format": "Parquet",', '"format": "Parquet",\n    "extra": 1,'))
        self.assertTrue(any("extra" in x and "missing from Terraform" in x for x in p), p)

    def test_a_different_dataset_version_in_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, '"dataVersion": "1.2-preview"', '"dataVersion": "1.0r2"'))
        self.assertTrue(any("dataVersion" in x for x in p), p)

    def test_a_different_folder_default_in_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, 'ROOT_FOLDER="atomity-exports"', 'ROOT_FOLDER="exports"'))
        self.assertTrue(any("root folder default" in x for x in p), p)

    def test_a_different_api_version_in_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, '--url "$EXPORT_URL?api-version=2025-03-01"', '--url "$EXPORT_URL?api-version=2024-08-01"'))
        self.assertTrue(any("API version" in x for x in p), p)

    def test_a_missing_run_step_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, '"$EXPORT_URL/run?api-version=2025-03-01"', '"$EXPORT_URL?api-version=2025-03-01"'))
        self.assertTrue(any("runs the export once" in x for x in p), p)

    def test_a_different_export_name_in_the_readme_is_caught(self):
        p = self.problems(readme=self.mutate(self.readme, "exports/atomity-focus", "exports/other-name"))
        self.assertTrue(any("export name" in x for x in p), p)

    # ---- drift on the Terraform side
    def test_a_changed_constant_in_terraform_is_caught(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, 'format                = "Parquet"', 'format                = "Csv"'))
        self.assertTrue(any("format" in x for x in p), p)

    def test_a_new_terraform_field_is_caught(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, "partitionData         = true", "partitionData         = true\n      newSetting            = \"x\""))
        self.assertTrue(any("newSetting" in x and "missing from the README" in x for x in p), p)

    def test_a_new_terraform_default_is_caught(self):
        p = self.problems(variables_tf=self.mutate(self.variables_tf, 'default     = "1.2-preview"', 'default     = "1.2"'))
        self.assertTrue(any("dataVersion" in x for x in p), p)

    def test_a_new_terraform_expression_is_not_silently_accepted(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, "dataOverwriteBehavior = var.data_overwrite_behavior", "dataOverwriteBehavior = upper(var.data_overwrite_behavior)"))
        self.assertTrue(any("does not know how to compare" in x for x in p), p)

    def test_a_different_terraform_root_folder_default_is_caught(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, '"atomity-exports"', '"billing"'))
        self.assertTrue(any("root folder default" in x for x in p), p)

    def test_a_different_terraform_api_version_is_caught(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, "exports@2025-03-01", "exports@2026-01-01"))
        self.assertTrue(any("API version" in x for x in p), p)

    def test_a_comment_cannot_satisfy_the_check(self):
        # the provider name appears in a comment too, so changing only the code must still be caught
        self.assertIn("# POSTs to", self.main_tf)
        mutated = self.mutate(self.main_tf, 'resource_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.CostManagementExports"',
                              'resource_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.Other"')
        self.assertIn("Microsoft.CostManagementExports", mutated, "the comment must still contain the old name")
        self.assertTrue(any("provider" in x for x in self.problems(main_tf=mutated)))

    def test_a_removed_terraform_run_step_is_not_required_of_the_readme(self):
        mutated = self.mutate(self.main_tf, 'action      = "run"', 'action      = "other"')
        self.assertFalse(any("runs the export once" in x for x in self.problems(main_tf=mutated)))

    def test_a_different_billing_scope_in_terraform_is_caught(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, "billingAccounts/${var.billing_account_id}", "billingAccounts/${var.other}"))
        self.assertTrue(any("billing scope" in x for x in p), p)

    def test_a_different_terraform_provider_is_caught(self):
        p = self.problems(main_tf=self.mutate(self.main_tf, 'resource_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.CostManagementExports"', 'resource_id = "/subscriptions/${local.storage_subscription_id}/providers/Microsoft.Other"'))
        self.assertTrue(any("provider" in x for x in p), p)


if __name__ == "__main__":
    unittest.main(verbosity=1)