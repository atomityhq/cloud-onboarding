#!/usr/bin/env python3
"""Tests for build.py. They run the real, pinned Bicep compiler, so they are skipped when it is
not installed (run install-bicep.sh first). Standard library only: python3 test_build.py"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
PINNED = (HERE / "BICEP_VERSION").read_text().strip()
MG, SUB = "atomity.json", "atomity-subscription.json"
CONTRIBUTOR = "b24988ac-6180-42a0-ab88-20f7382dd24c"
READER = "acdd72a7-3385-48ef-bd42-f606fba81ae7"


def have_pinned_compiler() -> bool:
    exe = shutil.which("bicep")
    if not exe:
        return False
    out = subprocess.run([exe, "--version"], capture_output=True, text=True).stdout
    return f"version {PINNED} " in out


@unittest.skipUnless(have_pinned_compiler(), f"Bicep {PINNED} is not on PATH (run install-bicep.sh)")
class BuildTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self._tmp.name)
        for name in ("main.bicep", "subscription.bicep", "BICEP_VERSION", "build.py", MG, SUB):
            shutil.copy(HERE / name, self.dir / name)
        shutil.copytree(HERE / "modules", self.dir / "modules")

    def tearDown(self):
        self._tmp.cleanup()

    def build(self, *args):
        r = subprocess.run([sys.executable, str(self.dir / "build.py"), *args], capture_output=True, text=True, cwd=self.dir)
        return r.returncode, r.stdout, r.stderr

    def edit(self, rel, old, new):
        p = self.dir / rel
        s = p.read_text()
        self.assertIn(old, s, f"test setup: {old!r} not found in {rel}")
        p.write_text(s.replace(old, new, 1))

    def template(self, name):
        return json.loads((self.dir / name).read_text())

    # ----------------------------------------------------------- the good path
    def test_the_committed_templates_are_current(self):
        rc, out, err = self.build("--check")
        self.assertEqual(rc, 0, err)
        self.assertIn("atomity.json is exactly what main.bicep compiles to", out)
        self.assertIn("atomity-subscription.json is exactly what subscription.bicep compiles to", out)

    def test_building_is_repeatable_and_changes_nothing_when_current(self):
        before = {n: (self.dir / n).read_text() for n in (MG, SUB)}
        self.assertEqual(self.build()[0], 0)
        self.assertEqual({n: (self.dir / n).read_text() for n in (MG, SUB)}, before)

    def test_the_compiled_templates_are_written_verbatim(self):
        (self.dir / MG).unlink()
        (self.dir / SUB).unlink()
        rc, _, err = self.build()
        self.assertEqual(rc, 0, err)
        for name, schema in ((MG, "managementGroupDeploymentTemplate"), (SUB, "subscriptionDeploymentTemplate")):
            data = self.template(name)
            self.assertEqual(data["metadata"]["_generator"]["name"], "bicep")
            self.assertIn(schema, data["$schema"])
            self.assertTrue((self.dir / name).read_text().endswith("\n"))

    def test_each_template_has_its_own_parameters(self):
        self.assertNotIn("subscriptionIds", self.template(MG)["parameters"])
        self.assertNotIn("scopeMode", self.template(MG)["parameters"])
        self.assertEqual(self.template(SUB)["parameters"]["subscriptionIds"]["minLength"], 1)

    # ----------------------------------------------------------- drift the old check missed
    def test_a_hand_edit_of_the_management_group_template_is_caught_and_repaired(self):
        self.edit(MG, "Atomity read-only access to billing export", "Atomity read/write access to billing export")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("atomity.json is not what main.bicep compiles to", err)
        self.assertNotIn("atomity-subscription.json is not what", err)
        self.assertIn("Do not edit it by hand", err)
        self.assertEqual(self.build()[0], 0)
        self.assertEqual(self.build("--check")[0], 0)

    def test_a_hand_edit_of_the_subscription_template_is_caught_and_repaired(self):
        self.edit(SUB, "Atomity read-only inventory and metrics access", "Atomity full access")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("atomity-subscription.json is not what subscription.bicep compiles to", err)
        self.assertNotIn("atomity.json is not what", err)
        self.assertEqual(self.build()[0], 0)
        self.assertEqual(self.build("--check")[0], 0)

    def test_a_change_in_a_shared_module_drifts_both_templates(self):
        self.edit("modules/storage-role.bicep", "Atomity read-only access to billing export Parquet files in this storage account.",
                  "Atomity access to this storage account.")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("atomity.json is not what main.bicep compiles to", err)
        self.assertIn("atomity-subscription.json is not what subscription.bicep compiles to", err)

    def test_a_change_in_the_subscription_module_drifts_only_the_subscription_template(self):
        self.edit("modules/subscription-role.bicep", "Atomity read-only inventory and metrics access on this subscription.", "Atomity access.")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("atomity-subscription.json is not what", err)
        self.assertNotIn("atomity.json is not what", err)

    def test_a_missing_template_is_a_clear_error_for_either(self):
        for name in (MG, SUB):
            with self.subTest(name):
                shutil.copy(HERE / name, self.dir / name)
                (self.dir / name).unlink()
                rc, _, err = self.build("--check")
                self.assertEqual(rc, 1)
                self.assertIn(f"{name} is missing", err)
                shutil.copy(HERE / name, self.dir / name)

    def test_a_template_that_is_not_json_is_a_clear_error(self):
        (self.dir / SUB).write_text("{ not json")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("not valid JSON", err)

    # ----------------------------------------------------------- the compiler must be clean
    def test_a_syntax_error_in_either_file_fails_hard_and_names_it(self):
        for rel in ("main.bicep", "subscription.bicep"):
            with self.subTest(rel):
                shutil.copy(HERE / rel, self.dir / rel)
                (self.dir / rel).write_text((self.dir / rel).read_text() + "\nresource broken this is not valid\n")
                rc, _, err = self.build("--check")
                self.assertEqual(rc, 1)
                self.assertIn(f"{rel} does not compile", err)
                shutil.copy(HERE / rel, self.dir / rel)

    def test_a_compiler_warning_fails(self):
        self.edit("subscription.bicep", "param storageAccountName string", "param unusedThing string = 'x'\nparam storageAccountName string")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("diagnostics", err)
        self.assertIn("unusedThing", err)

    def test_the_wrong_compiler_version_is_refused(self):
        (self.dir / "BICEP_VERSION").write_text("0.0.1\n")
        rc, _, err = self.build("--check")
        self.assertEqual(rc, 1)
        self.assertIn("built with 0.0.1", err)

    # ----------------------------------------------------------- the contract
    def test_a_different_role_is_refused_when_building_and_when_checking(self):
        self.edit("main.bicep", READER, CONTRIBUTOR)
        for args in ((), ("--check",)):
            rc, _, err = self.build(*args)
            self.assertEqual(rc, 1, args)
            self.assertIn("break their contract", err)
            self.assertIn(CONTRIBUTOR, err)
        self.assertEqual(self.template(MG)["variables"]["readerRoleDefinitionId"], READER,
                         "a refused build must not overwrite the template")

    def test_a_different_role_in_the_subscription_module_is_refused(self):
        self.edit("modules/subscription-role.bicep", READER, "8e3af657-a8ff-443c-a75c-2fe8c4bcb635")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("break their contract", err)
        self.assertIn("subscription.bicep: the template may reference exactly", err)

    def test_a_role_assignment_without_a_principal_type_is_refused(self):
        self.edit("modules/subscription-role.bicep", "    principalType: 'ServicePrincipal'\n", "")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("principalType", err)
        self.assertIn("subscription.bicep", err)

    def test_the_subscription_list_must_not_be_allowed_to_be_empty(self):
        self.edit("subscription.bicep", "@minLength(1)\nparam subscriptionIds", "param subscriptionIds")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("subscriptionIds must have minLength 1", err)

    def test_an_extra_parameter_is_refused(self):
        self.edit("main.bicep", "// Azure built-in role definition ID", "param extra string = 'x'\n\n// Azure built-in role definition ID")
        self.edit("main.bicep", "@description('The storage account receiving the export.')",
                  "output extra string = extra\n\n@description('The storage account receiving the export.')")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("unexpected ['extra']", err)

    def test_per_subscription_mode_cannot_creep_back_into_the_management_group_template(self):
        self.edit("main.bicep", "// Azure built-in role definition ID", "param subscriptionIds array = []\n\n// Azure built-in role definition ID")
        self.edit("main.bicep", "@description('The storage account receiving the export.')",
                  "output subs array = subscriptionIds\n\n@description('The storage account receiving the export.')")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("unexpected ['subscriptionIds']", err)

    def test_the_wrong_scope_is_refused(self):
        self.edit("subscription.bicep", "targetScope = 'subscription'", "targetScope = 'managementGroup'")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("$schema must be", err)
        self.assertIn("subscriptionDeploymentTemplate", err)

    def test_the_storage_parameters_must_match_in_both_templates(self):
        self.edit("subscription.bicep", "@maxLength(24)\nparam storageAccountName", "@maxLength(30)\nparam storageAccountName")
        rc, _, err = self.build()
        self.assertEqual(rc, 1)
        self.assertIn("parameter storageAccountName differs between", err)

    def test_a_description_that_mentions_the_atomity_app_id_is_not_mistaken_for_a_role(self):
        for name in (MG, SUB):
            self.assertIn("c4b84012-e86e-4ea0-9c42-5e015c1c30f4", json.dumps(self.template(name)["parameters"]))
        self.assertEqual(self.build("--check")[0], 0)

    # ----------------------------------------------------------- checking another copy (the release zip)
    def _extracted(self):
        other = self.dir / "extracted"
        other.mkdir()
        for name in ("main.bicep", "subscription.bicep"):
            shutil.copy(self.dir / name, other / name)
        shutil.copytree(self.dir / "modules", other / "modules")
        return other

    def test_another_copy_of_the_source_can_be_checked_against_the_templates(self):
        other = self._extracted()
        rc, _, err = self.build("--check", "--source", str(other), "--output", str(self.dir))
        self.assertEqual(rc, 0, err)

    def test_another_copy_that_differs_from_the_templates_is_caught(self):
        other = self._extracted()
        p = other / "modules/subscription-role.bicep"
        p.write_text(p.read_text().replace("read-only", "full"))
        rc, _, err = self.build("--check", "--source", str(other), "--output", str(self.dir))
        self.assertEqual(rc, 1)
        self.assertIn("atomity-subscription.json is not what", err)

    def test_a_zip_that_lacks_the_subscription_source_is_caught(self):
        other = self._extracted()
        (other / "subscription.bicep").unlink()
        rc, _, err = self.build("--check", "--source", str(other), "--output", str(self.dir))
        self.assertEqual(rc, 1)
        self.assertIn("subscription.bicep does not exist", err)


if __name__ == "__main__":
    unittest.main(verbosity=1)
