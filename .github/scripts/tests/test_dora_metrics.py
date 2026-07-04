from __future__ import annotations

import sys
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import dora_metrics  # noqa: E402


def _dt(s: str) -> datetime:
    return dora_metrics._parse_dt(s)


class IsoWeekKeyTests(unittest.TestCase):
    def test_seven_days_apart_are_different_weeks(self):
        a = dora_metrics._iso_week_key(_dt("2026-06-02T10:00:00Z"))
        b = dora_metrics._iso_week_key(_dt("2026-06-09T10:00:00Z"))
        self.assertNotEqual(a, b)


class PercentileTests(unittest.TestCase):
    def test_empty(self):
        self.assertIsNone(dora_metrics._percentile([], 0.85))

    def test_single_value(self):
        self.assertEqual(dora_metrics._percentile([42.0], 0.85), 42.0)

    def test_interpolates(self):
        # rank = (4-1)*0.5 = 1.5 -> interpolate between index 1 and 2
        self.assertEqual(dora_metrics._percentile([1.0, 2.0, 3.0, 4.0], 0.5), 2.5)


class TrailingAverageLineTests(unittest.TestCase):
    def test_no_data(self):
        self.assertIn("no data", dora_metrics.trailing_average_line({}))

    def test_averages_across_weeks(self):
        weekly = {
            "2026-W01": {
                "backend_deploys": 2,
                "frontend_deploys": 0,
                "any_deploys": 2,
                "lead_time_seconds": {"count": 1, "median": 3600.0, "p85": 3600.0},
            },
            "2026-W02": {
                "backend_deploys": 0,
                "frontend_deploys": 0,
                "any_deploys": 0,
                "lead_time_seconds": {"count": 0, "median": None, "p85": None},
            },
        }
        line = dora_metrics.trailing_average_line(weekly)
        self.assertIn("Trailing 2-week average", line)
        self.assertIn("backend 1.0/week", line)
        self.assertIn("lead time median avg 1.0h", line)


class ExtractDeployEventsTests(unittest.TestCase):
    def test_skips_non_success_and_missing_jobs(self):
        runs = [
            {
                "id": 1,
                "head_sha": "aaa",
                "jobs": [
                    {
                        "name": "deploy-api",
                        "conclusion": "skipped",
                        "completed_at": "2026-06-01T00:00:00Z",
                    },
                    {
                        "name": "frontend",
                        "conclusion": "success",
                        "completed_at": "2026-06-01T01:00:00Z",
                    },
                ],
            },
            {
                "id": 2,
                "head_sha": "bbb",
                "jobs": [
                    {
                        "name": "build",
                        "conclusion": "success",
                        "completed_at": "2026-06-02T00:00:00Z",
                    }
                ],
            },
        ]
        events = dora_metrics.extract_deploy_events(runs)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].job, "frontend")
        self.assertEqual(events[0].run_id, 1)


class CollectIntegrationTests(unittest.TestCase):
    """Exercises collect() end-to-end against a fake GitHubClient (no network)."""

    def test_skips_pull_commit_lookups_when_no_deploys(self):
        commit_lookups = []

        class FakeClient:
            def __init__(self, owner, repo, token):
                pass

            def list_workflow_runs(self, since, until):
                return []

            def list_run_jobs(self, run_id):
                return []

            def list_merged_pulls(self, since, until):
                raise AssertionError(
                    "should not be called when there are no deploy events"
                )

            def list_pull_commits(self, number):
                commit_lookups.append(number)
                return []

        weekly = dora_metrics.collect(
            "itouhi",
            "devcon",
            _dt("2026-06-01T00:00:00Z"),
            _dt("2026-06-14T00:00:00Z"),
            client_cls=FakeClient,
        )

        self.assertEqual(weekly, {})
        self.assertEqual(commit_lookups, [])

    def test_weekly_aggregation(self):
        run1_completed = _dt("2026-06-02T10:00:00Z")
        run2_backend_completed = _dt("2026-06-09T10:00:00Z")
        run2_frontend_completed = _dt("2026-06-09T11:00:00Z")

        class FakeClient:
            def __init__(self, owner, repo, token):
                pass

            def list_workflow_runs(self, since, until):
                return [
                    {"id": 1, "head_sha": "aaa"},
                    {"id": 2, "head_sha": "bbb"},
                ]

            def list_run_jobs(self, run_id):
                if run_id == 1:
                    return [
                        {
                            "name": "deploy-api",
                            "conclusion": "success",
                            "completed_at": "2026-06-02T10:00:00Z",
                        }
                    ]
                return [
                    {
                        "name": "deploy-api",
                        "conclusion": "success",
                        "completed_at": "2026-06-09T10:00:00Z",
                    },
                    {
                        "name": "frontend",
                        "conclusion": "success",
                        "completed_at": "2026-06-09T11:00:00Z",
                    },
                ]

            def list_merged_pulls(self, since, until):
                return [
                    {
                        "number": 10,
                        "pull_request": {"merged_at": "2026-06-01T09:00:00Z"},
                    },
                    {
                        "number": 11,
                        "pull_request": {"merged_at": "2026-06-08T09:00:00Z"},
                    },
                ]

            def list_pull_commits(self, number):
                if number == 10:
                    return [{"commit": {"author": {"date": "2026-05-30T09:00:00Z"}}}]
                return []  # PR 11: no commit data -> falls back to merged_at (approximated)

        weekly = dora_metrics.collect(
            "itouhi",
            "devcon",
            _dt("2026-06-01T00:00:00Z"),
            _dt("2026-06-14T00:00:00Z"),
            client_cls=FakeClient,
        )

        week_a = dora_metrics._iso_week_key(run1_completed)
        week_b = dora_metrics._iso_week_key(run2_backend_completed)
        self.assertEqual(dora_metrics._iso_week_key(run2_frontend_completed), week_b)

        self.assertEqual(weekly[week_a]["backend_deploys"], 1)
        self.assertEqual(weekly[week_a]["frontend_deploys"], 0)
        self.assertEqual(weekly[week_a]["any_deploys"], 1)
        # PR#10: 2026-05-30T09:00 -> 2026-06-02T10:00 = 73h = 262800s
        self.assertEqual(
            weekly[week_a]["lead_time_seconds"], dora_metrics._stats([262800.0])
        )

        self.assertEqual(weekly[week_b]["backend_deploys"], 1)
        self.assertEqual(weekly[week_b]["frontend_deploys"], 1)
        self.assertEqual(
            weekly[week_b]["any_deploys"], 1
        )  # both jobs succeeded on the same run (id=2)
        # backend: PR#11 merged 06-08T09:00 -> run2 backend 06-09T10:00 = 25h = 90000s (approx)
        # frontend: no prior frontend event, so both PR#10 and PR#11 fall in its window
        #   PR#10: 05-30T09:00 -> 06-09T11:00 = 242h = 871200s
        #   PR#11: 06-08T09:00 -> 06-09T11:00 = 26h = 93600s (approximated)
        self.assertEqual(
            weekly[week_b]["lead_time_seconds"],
            dora_metrics._stats([90000.0, 871200.0, 93600.0]),
        )


class GitHubClientPaginationTests(unittest.TestCase):
    def test_get_all_follows_link_header(self):
        calls = []

        class _FakeResponse:
            def __init__(self, body, link=None):
                self._body = body
                self.headers = {"Link": link} if link else {}

            def read(self):
                import json

                return json.dumps(self._body).encode()

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def fake_urlopen(req):
            calls.append(req.full_url)
            if len(calls) == 1:
                return _FakeResponse(
                    {"jobs": [{"id": 1}]},
                    link='<https://api.github.com/next?page=2>; rel="next"',
                )
            return _FakeResponse({"jobs": [{"id": 2}]})

        with mock.patch("urllib.request.urlopen", side_effect=fake_urlopen):
            client = dora_metrics.GitHubClient("o", "r", token=None)
            items = client._get_all("/repos/o/r/actions/runs/1/jobs")

        self.assertEqual([item["id"] for item in items], [1, 2])
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
