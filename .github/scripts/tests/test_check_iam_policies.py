from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import check_iam_policies  # noqa: E402

PLAN_FIXTURE = {
    "planned_values": {
        "root_module": {
            "resources": [
                {
                    "address": "data.aws_iam_policy_document.ci_deploy_network",
                    "mode": "data",
                    "type": "aws_iam_policy_document",
                    "values": {"json": '{"Statement": []}'},
                },
                {
                    "address": "aws_iam_policy.ci_deploy_network",
                    "mode": "managed",
                    "type": "aws_iam_policy",
                    "values": {"policy": '{"Statement": [{"Effect": "Allow"}]}'},
                },
                {
                    "address": "aws_iam_role.ci_deploy",
                    "mode": "managed",
                    "type": "aws_iam_role",
                    "values": {"assume_role_policy": '{"Statement": []}'},
                },
            ],
            "child_modules": [
                {
                    "resources": [
                        {
                            "address": "module.nested.aws_iam_role_policy.inline",
                            "mode": "managed",
                            "type": "aws_iam_role_policy",
                            "values": {
                                "policy": '{"Statement": [{"Effect": "Allow"}]}'
                            },
                        }
                    ]
                }
            ],
        }
    }
}


class IterTargetResourcesTests(unittest.TestCase):
    def test_extracts_managed_iam_policy_and_role_policy(self):
        results = dict(check_iam_policies.iter_target_resources(PLAN_FIXTURE))
        self.assertEqual(
            set(results.keys()),
            {
                "aws_iam_policy.ci_deploy_network",
                "module.nested.aws_iam_role_policy.inline",
            },
        )

    def test_skips_data_sources_and_unrelated_resource_types(self):
        results = dict(check_iam_policies.iter_target_resources(PLAN_FIXTURE))
        self.assertNotIn("data.aws_iam_policy_document.ci_deploy_network", results)
        self.assertNotIn("aws_iam_role.ci_deploy", results)

    def test_supports_state_json_shape(self):
        state_shaped = {"values": PLAN_FIXTURE["planned_values"]}
        results = dict(check_iam_policies.iter_target_resources(state_shaped))
        self.assertIn("aws_iam_policy.ci_deploy_network", results)

    def test_empty_document_yields_nothing(self):
        self.assertEqual(list(check_iam_policies.iter_target_resources({})), [])

    def test_policy_not_yet_known_is_none(self):
        fixture = {
            "planned_values": {
                "root_module": {
                    "resources": [
                        {
                            "address": "aws_iam_policy.pending",
                            "mode": "managed",
                            "type": "aws_iam_policy",
                            "values": {"policy": None},
                        }
                    ]
                }
            }
        }
        results = dict(check_iam_policies.iter_target_resources(fixture))
        self.assertIsNone(results["aws_iam_policy.pending"])


class ValidatePolicyDocumentTests(unittest.TestCase):
    def test_returns_findings_on_success(self):
        fake_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps({"findings": [{"findingType": "ERROR"}]}),
            stderr="",
        )
        with unittest.mock.patch("subprocess.run", return_value=fake_result) as run:
            findings = check_iam_policies.validate_policy_document('{"Statement": []}')
        self.assertEqual(findings, [{"findingType": "ERROR"}])
        args = run.call_args.args[0]
        self.assertIn("accessanalyzer", args)
        self.assertIn("IDENTITY_POLICY", args)

    def test_raises_on_nonzero_exit(self):
        fake_result = subprocess.CompletedProcess(
            args=[], returncode=254, stdout="", stderr="Unable to locate credentials"
        )
        with unittest.mock.patch("subprocess.run", return_value=fake_result):
            with self.assertRaises(RuntimeError):
                check_iam_policies.validate_policy_document('{"Statement": []}')


class MainTests(unittest.TestCase):
    def _write_plan(self, tmp_dir: str, data: dict) -> Path:
        path = Path(tmp_dir) / "plan.json"
        path.write_text(json.dumps(data))
        return path

    def test_clean_policies_exit_zero(self):
        clean_result = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=json.dumps({"findings": []}), stderr=""
        )
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan_path = self._write_plan(tmp_dir, PLAN_FIXTURE)
            with unittest.mock.patch("subprocess.run", return_value=clean_result):
                exit_code = check_iam_policies.main([str(plan_path)])
        self.assertEqual(exit_code, 0)

    def test_error_finding_causes_nonzero_exit(self):
        error_result = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=json.dumps(
                {
                    "findings": [
                        {
                            "findingType": "ERROR",
                            "issueCode": "INVALID_SERVICE_CONDITION_KEY",
                            "findingDetails": "bad condition key",
                        }
                    ]
                }
            ),
            stderr="",
        )
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan_path = self._write_plan(tmp_dir, PLAN_FIXTURE)
            with unittest.mock.patch("subprocess.run", return_value=error_result):
                exit_code = check_iam_policies.main([str(plan_path)])
        self.assertEqual(exit_code, 1)

    def test_no_target_resources_exits_zero(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            plan_path = self._write_plan(
                tmp_dir, {"planned_values": {"root_module": {}}}
            )
            exit_code = check_iam_policies.main([str(plan_path)])
        self.assertEqual(exit_code, 0)


if __name__ == "__main__":
    unittest.main()
