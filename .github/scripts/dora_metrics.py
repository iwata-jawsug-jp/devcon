#!/usr/bin/env python3
"""Aggregate DORA deployment frequency / lead time for changes.

Measurement definitions: docs/adr/0006-dora-deployment-frequency-and-lead-time-definitions.md
Python standard library only — no third-party dependencies.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

API_ROOT = "https://api.github.com"
DEPLOY_WORKFLOW_FILE = "cd-app.yml"
DEPLOY_JOB_NAMES = {"backend": "deploy-api", "frontend": "frontend"}


def _parse_dt(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _iso_week_key(dt: datetime) -> str:
    year, week, _ = dt.isocalendar()
    return f"{year}-W{week:02d}"


class GitHubClient:
    def __init__(
        self, owner: str, repo: str, token: str | None = None, api_root: str = API_ROOT
    ):
        self.owner = owner
        self.repo = repo
        self.token = token
        self.api_root = api_root

    def _get_page(self, url: str):
        req = urllib.request.Request(url)
        req.add_header("Accept", "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req) as resp:  # noqa: S310 - fixed https://api.github.com host
            body = json.load(resp)
            link = resp.headers.get("Link", "") or ""
        next_url = None
        for part in link.split(","):
            if 'rel="next"' in part:
                next_url = part.split(";")[0].strip().strip("<>")
        return body, next_url

    def _get_all(self, path: str, params: dict | None = None) -> list:
        query = urllib.parse.urlencode({**(params or {}), "per_page": 100})
        url = f"{self.api_root}{path}?{query}"
        items: list = []
        while url:
            body, url = self._get_page(url)
            if isinstance(body, dict):
                for key in ("workflow_runs", "jobs", "items"):
                    if key in body:
                        items.extend(body[key])
                        break
                else:
                    items.append(body)
            else:
                items.extend(body)
        return items

    def list_workflow_runs(self, since: datetime, until: datetime) -> list:
        created = f"{since.date().isoformat()}..{until.date().isoformat()}"
        return self._get_all(
            f"/repos/{self.owner}/{self.repo}/actions/workflows/{DEPLOY_WORKFLOW_FILE}/runs",
            {
                "branch": "main",
                "event": "push",
                "created": created,
                "status": "success",
            },
        )

    def list_run_jobs(self, run_id: int) -> list:
        return self._get_all(
            f"/repos/{self.owner}/{self.repo}/actions/runs/{run_id}/jobs"
        )

    def list_merged_pulls(self, since: datetime, until: datetime) -> list:
        q = (
            f"repo:{self.owner}/{self.repo} is:pr is:merged base:main "
            f"merged:{since.date().isoformat()}..{until.date().isoformat()}"
        )
        return self._get_all(
            "/search/issues", {"q": q, "sort": "created", "order": "asc"}
        )

    def list_pull_commits(self, number: int) -> list:
        return self._get_all(f"/repos/{self.owner}/{self.repo}/pulls/{number}/commits")


@dataclass(frozen=True)
class DeployEvent:
    job: str  # "backend" | "frontend"
    run_id: int
    sha: str
    completed_at: datetime


@dataclass(frozen=True)
class LeadTimeSample:
    job: str
    pr_number: int
    deploy_completed_at: datetime
    lead_time_seconds: float
    approximated: (
        bool  # True when the PR had no commit data, so merged_at was used as the origin
    )


def extract_deploy_events(runs_with_jobs: list[dict]) -> list[DeployEvent]:
    events = []
    for run in runs_with_jobs:
        for job_key, job_name in DEPLOY_JOB_NAMES.items():
            job = next((j for j in run["jobs"] if j["name"] == job_name), None)
            if job and job.get("conclusion") == "success":
                events.append(
                    DeployEvent(
                        job=job_key,
                        run_id=run["id"],
                        sha=run["head_sha"],
                        completed_at=_parse_dt(job["completed_at"]),
                    )
                )
    return events


def compute_lead_times(
    events: list[DeployEvent],
    pulls_by_merge: list[tuple[int, datetime]],
    pull_first_commit_at: dict[int, datetime | None],
) -> list[LeadTimeSample]:
    samples = []
    by_job: dict[str, list[DeployEvent]] = {}
    for event in events:
        by_job.setdefault(event.job, []).append(event)

    for job, job_events in by_job.items():
        job_events.sort(key=lambda e: e.completed_at)
        window_start = None
        for event in job_events:
            for pr_number, merged_at in pulls_by_merge:
                in_window = (
                    window_start is None or merged_at > window_start
                ) and merged_at <= event.completed_at
                if not in_window:
                    continue
                first_commit_at = pull_first_commit_at.get(pr_number)
                approximated = first_commit_at is None
                origin = first_commit_at or merged_at
                samples.append(
                    LeadTimeSample(
                        job=job,
                        pr_number=pr_number,
                        deploy_completed_at=event.completed_at,
                        lead_time_seconds=(event.completed_at - origin).total_seconds(),
                        approximated=approximated,
                    )
                )
            window_start = event.completed_at
    return samples


def _percentile(values: list[float], pct: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    rank = (len(ordered) - 1) * pct
    lo = int(rank)
    hi = min(lo + 1, len(ordered) - 1)
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (rank - lo)


def _stats(values: list[float]) -> dict:
    if not values:
        return {"count": 0, "median": None, "p85": None}
    return {
        "count": len(values),
        "median": statistics.median(values),
        "p85": _percentile(values, 0.85),
    }


def aggregate_weekly(
    events: list[DeployEvent], lead_time_samples: list[LeadTimeSample]
) -> dict:
    weeks: dict[str, dict] = {}
    any_run_ids_by_week: dict[str, set] = {}

    def bucket(key: str) -> dict:
        return weeks.setdefault(
            key,
            {
                "backend_deploys": 0,
                "frontend_deploys": 0,
                "lead_times": {"backend": [], "frontend": []},
            },
        )

    for event in events:
        key = _iso_week_key(event.completed_at)
        bucket(key)[f"{event.job}_deploys"] += 1
        any_run_ids_by_week.setdefault(key, set()).add(event.run_id)

    for sample in lead_time_samples:
        key = _iso_week_key(sample.deploy_completed_at)
        bucket(key)["lead_times"][sample.job].append(sample.lead_time_seconds)

    result = {}
    for key in sorted(weeks):
        row = weeks[key]
        combined = row["lead_times"]["backend"] + row["lead_times"]["frontend"]
        result[key] = {
            "backend_deploys": row["backend_deploys"],
            "frontend_deploys": row["frontend_deploys"],
            "any_deploys": len(any_run_ids_by_week.get(key, set())),
            "lead_time_seconds": _stats(combined),
        }
    return result


def collect(
    owner: str,
    repo: str,
    since: datetime,
    until: datetime,
    token: str | None = None,
    client_cls=GitHubClient,
) -> dict:
    client = client_cls(owner, repo, token)

    runs = client.list_workflow_runs(since, until)
    runs_with_jobs = [{**run, "jobs": client.list_run_jobs(run["id"])} for run in runs]
    events = extract_deploy_events(runs_with_jobs)
    if not events:
        # No deploys in range: skip the per-PR commit lookups entirely (there is
        # nothing to compute lead time against, and this range may hold dozens
        # of merged PRs — each an extra API round trip for no benefit).
        return aggregate_weekly(events, [])

    merged = client.list_merged_pulls(since, until)
    pulls_by_merge = []
    pull_first_commit_at: dict[int, datetime | None] = {}
    for item in merged:
        number = item["number"]
        merged_at = _parse_dt(item["pull_request"]["merged_at"])
        pulls_by_merge.append((number, merged_at))
        commits = client.list_pull_commits(number)
        pull_first_commit_at[number] = (
            _parse_dt(commits[0]["commit"]["author"]["date"]) if commits else None
        )
    pulls_by_merge.sort(key=lambda t: t[1])

    lead_time_samples = compute_lead_times(events, pulls_by_merge, pull_first_commit_at)
    return aggregate_weekly(events, lead_time_samples)


def render_markdown(weekly: dict) -> str:
    header = (
        "| Week | Backend | Frontend | Any | Lead median (h) | Lead p85 (h) | Lead n |"
    )
    lines = [header, "| --- | --- | --- | --- | --- | --- | --- |"]
    for week, row in weekly.items():
        lt = row["lead_time_seconds"]
        median_h = f"{lt['median'] / 3600:.1f}" if lt["median"] is not None else "-"
        p85_h = f"{lt['p85'] / 3600:.1f}" if lt["p85"] is not None else "-"
        cells = [
            week,
            row["backend_deploys"],
            row["frontend_deploys"],
            row["any_deploys"],
        ]
        cells += [median_h, p85_h, lt["count"]]
        lines.append("| " + " | ".join(str(c) for c in cells) + " |")
    return "\n".join(lines)


def trailing_average_line(weekly: dict) -> str:
    """One-line moving average across every week present in `weekly` (caller controls
    the window by choosing --since/--until, e.g. a 4-week range for a 4-week average)."""
    rows = list(weekly.values())
    if not rows:
        return "Trailing average: no data in range"
    n = len(rows)
    backend_avg = sum(r["backend_deploys"] for r in rows) / n
    frontend_avg = sum(r["frontend_deploys"] for r in rows) / n
    any_avg = sum(r["any_deploys"] for r in rows) / n
    medians = [
        r["lead_time_seconds"]["median"]
        for r in rows
        if r["lead_time_seconds"]["median"] is not None
    ]
    lead_time_desc = f"{(sum(medians) / len(medians)) / 3600:.1f}h" if medians else "-"
    return (
        f"Trailing {n}-week average: backend {backend_avg:.1f}/week, frontend {frontend_avg:.1f}/week, "
        f"any {any_avg:.1f}/week, lead time median avg {lead_time_desc}"
    )


def parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Aggregate DORA deployment frequency / lead time from GitHub Actions + PR data."
    )
    parser.add_argument("--owner", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--since", required=True, help="YYYY-MM-DD, inclusive")
    parser.add_argument("--until", required=True, help="YYYY-MM-DD, inclusive")
    parser.add_argument(
        "--token", default=None, help="GitHub token; falls back to $GITHUB_TOKEN"
    )
    parser.add_argument(
        "--format", choices=["json", "markdown", "summary"], default="json"
    )
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = parse_args(argv)
    token = args.token or os.environ.get("GITHUB_TOKEN")
    since = datetime.fromisoformat(args.since).replace(tzinfo=UTC)
    until = datetime.fromisoformat(args.until).replace(tzinfo=UTC) + timedelta(
        days=1, seconds=-1
    )

    try:
        weekly = collect(args.owner, args.repo, since, until, token)
    except urllib.error.HTTPError as exc:
        print(f"GitHub API error: {exc.code} {exc.reason}", file=sys.stderr)
        return 1

    if args.format == "json":
        print(json.dumps(weekly, indent=2))
    elif args.format == "markdown":
        print(render_markdown(weekly))
    else:
        print(trailing_average_line(weekly))
    return 0


if __name__ == "__main__":
    sys.exit(main())
