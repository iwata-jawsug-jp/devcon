from __future__ import annotations

import sys
import unittest
import unittest.mock
from datetime import UTC, datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import scorecard_metrics  # noqa: E402


def _catalog(**overrides: int) -> dict:
    axes = {key: {"score": 3, "note": ""} for key in scorecard_metrics.AXES}
    for key, score in overrides.items():
        axes[key]["score"] = score
    return {
        "owner": "test",
        "golden_path_version": "v0.0.0",
        "last_reviewed": "2026-01-01",
        "axes": axes,
    }


class ComputeAggregatesTests(unittest.TestCase):
    def test_all_axes_at_max_score_five(self):
        catalog = _catalog(**{key: 5 for key in scorecard_metrics.AXES})
        gp, idp = scorecard_metrics.compute_aggregates(catalog)
        self.assertEqual(gp, 10.0)
        self.assertEqual(idp, 10.0)

    def test_all_axes_at_min_score_one(self):
        catalog = _catalog(**{key: 1 for key in scorecard_metrics.AXES})
        gp, idp = scorecard_metrics.compute_aggregates(catalog)
        self.assertEqual(gp, 2.0)
        self.assertEqual(idp, 2.0)

    def test_golden_path_and_idp_axes_are_independent(self):
        # self_service / org_scalability は IDP軸。他を1にしても IDP は5点満点(=10)のまま。
        catalog = _catalog(self_service=5, org_scalability=5)
        for key in scorecard_metrics.AXES:
            if scorecard_metrics.AXES[key][1] == "golden_path":
                catalog["axes"][key]["score"] = 1
        gp, idp = scorecard_metrics.compute_aggregates(catalog)
        self.assertEqual(gp, 2.0)
        self.assertEqual(idp, 10.0)

    def test_axis_count_matches_criteria_doc(self):
        gp_axes = [
            k for k, (_, cat) in scorecard_metrics.AXES.items() if cat == "golden_path"
        ]
        idp_axes = [k for k, (_, cat) in scorecard_metrics.AXES.items() if cat == "idp"]
        self.assertEqual(len(gp_axes), 8)
        self.assertEqual(len(idp_axes), 2)
        self.assertEqual(len(scorecard_metrics.AXES), 10)


class Level4SignalTests(unittest.TestCase):
    def test_all_checks_pass_supports_level_four(self):
        checks = [
            scorecard_metrics.Check("devcontainer_present", True, ""),
            scorecard_metrics.Check("make_dev_target", True, ""),
        ]
        self.assertTrue(
            scorecard_metrics._level4_signal("dev_environment_standardization", checks)
        )

    def test_one_failing_gate_check_fails_level_four(self):
        checks = [
            scorecard_metrics.Check("devcontainer_present", True, ""),
            scorecard_metrics.Check("make_dev_target", False, ""),
        ]
        self.assertFalse(
            scorecard_metrics._level4_signal("dev_environment_standardization", checks)
        )

    def test_unknown_axis_returns_none(self):
        self.assertIsNone(scorecard_metrics._level4_signal("not_a_real_axis", []))


class RenderMarkdownTests(unittest.TestCase):
    def test_flags_declared_score_unsupported_by_signals(self):
        catalog = _catalog(api_contract=5)
        checks = {
            key: (
                [
                    scorecard_metrics.Check("gen_types_target", True, "detail"),
                    scorecard_metrics.Check("ci_drift_check", False, "detail"),
                ]
                if key == "api_contract"
                else [scorecard_metrics.Check("dummy", True, "detail")]
            )
            for key in scorecard_metrics.AXES
        }
        output = scorecard_metrics.render_markdown(catalog, checks)
        self.assertIn("⚠️", output)
        self.assertIn("API契約管理", output)

    def test_no_warning_when_no_level4_gate_defined_axis_missing_from_gates(self):
        # api_contract を score=3 のままにすれば(レベル4未満)、機械信号がNGでも警告は出ない
        catalog = _catalog(api_contract=3)
        checks = {
            key: (
                [
                    scorecard_metrics.Check("gen_types_target", True, "detail"),
                    scorecard_metrics.Check("ci_drift_check", False, "detail"),
                ]
                if key == "api_contract"
                else [scorecard_metrics.Check("dummy", True, "detail")]
            )
            for key in scorecard_metrics.AXES
        }
        output = scorecard_metrics.render_markdown(catalog, checks)
        self.assertNotIn("⚠️", output)


class LastLiveSmokeSuccessTests(unittest.TestCase):
    def test_no_owner_repo_token_returns_none_without_calling_api(self):
        get = unittest.mock.Mock()
        result = scorecard_metrics._last_live_smoke_success(None, None, None, get=get)
        self.assertIsNone(result)
        get.assert_not_called()

    def test_finds_most_recent_success_across_workflows(self):
        def fake_get(path, token):
            if "cd-app-sandbox.yml/runs" in path:
                return {"workflow_runs": [{"id": 1}]}
            if "cd-app.yml/runs" in path:
                return {"workflow_runs": [{"id": 2}]}
            if "cd-sandbox-cycle.yml/runs" in path:
                return {"workflow_runs": []}
            if path.endswith("/runs/1/jobs"):
                return {
                    "jobs": [
                        {
                            "name": "smoke-test",
                            "conclusion": "success",
                            "completed_at": "2026-07-01T00:00:00Z",
                        }
                    ]
                }
            if path.endswith("/runs/2/jobs"):
                return {
                    "jobs": [
                        {
                            "name": "smoke-test / check",
                            "conclusion": "success",
                            "completed_at": "2026-07-10T00:00:00Z",
                        }
                    ]
                }
            raise AssertionError(f"unexpected path {path}")

        result = scorecard_metrics._last_live_smoke_success(
            "itouhi", "devcon", "tok", get=fake_get
        )
        self.assertEqual(result, "2026-07-10T00:00:00Z")

    def test_ignores_non_smoke_jobs_and_non_success_conclusions(self):
        def fake_get(path, token):
            if path.endswith("/runs"):
                return {"workflow_runs": [{"id": 1}]}
            return {
                "jobs": [
                    {"name": "build", "conclusion": "success", "completed_at": "x"},
                    {
                        "name": "smoke-test",
                        "conclusion": "failure",
                        "completed_at": "y",
                    },
                ]
            }

        result = scorecard_metrics._last_live_smoke_success(
            "itouhi", "devcon", "tok", get=fake_get
        )
        self.assertIsNone(result)

    def test_network_error_on_one_workflow_does_not_abort_the_others(self):
        import urllib.error

        def fake_get(path, token):
            if "cd-app-sandbox.yml" in path:
                raise urllib.error.URLError("boom")
            if "/runs?" in path:
                return {"workflow_runs": [{"id": 1}]}
            return {
                "jobs": [
                    {
                        "name": "smoke-test",
                        "conclusion": "success",
                        "completed_at": "2026-07-05T00:00:00Z",
                    }
                ]
            }

        result = scorecard_metrics._last_live_smoke_success(
            "itouhi", "devcon", "tok", get=fake_get
        )
        self.assertEqual(result, "2026-07-05T00:00:00Z")


class LiveSmokeRecencyCheckTests(unittest.TestCase):
    def test_missing_credentials_fails_without_crashing(self):
        checks = scorecard_metrics._live_smoke_recency_check(None, None, None)
        self.assertEqual(len(checks), 1)
        self.assertFalse(checks[0].passed)
        self.assertIn("GITHUB_TOKEN", checks[0].detail)

    def test_recent_success_passes(self):
        recent = (
            (datetime.now(UTC) - timedelta(days=1)).isoformat().replace("+00:00", "Z")
        )
        with unittest.mock.patch.object(
            scorecard_metrics, "_last_live_smoke_success", return_value=recent
        ):
            checks = scorecard_metrics._live_smoke_recency_check("o", "r", "t")
        self.assertTrue(checks[0].passed)

    def test_stale_success_fails(self):
        stale = (
            (
                datetime.now(UTC)
                - timedelta(days=scorecard_metrics.LIVE_SMOKE_STALE_AFTER_DAYS + 1)
            )
            .isoformat()
            .replace("+00:00", "Z")
        )
        with unittest.mock.patch.object(
            scorecard_metrics, "_last_live_smoke_success", return_value=stale
        ):
            checks = scorecard_metrics._live_smoke_recency_check("o", "r", "t")
        self.assertFalse(checks[0].passed)


if __name__ == "__main__":
    unittest.main()
