#!/usr/bin/env python3
"""Compute the platform maturity scorecard (10 axes, 2 aggregate scores).

Score level definitions: docs/metrics/scorecard-criteria.md
Declared per-axis scores are human-reviewed and live in the catalog file
(docs/metrics/scorecard/catalog.json); this script cross-checks them against
machine-detectable signals in the working tree and flags drift (a declared
score that the signals no longer support).

Python standard library only -- no third-party dependencies (matches
dora_metrics.py; catalog uses JSON rather than YAML so no PyYAML install is
needed in CI). The live-smoke recency check reuses dora_metrics.py's
GitHub-API-via-urllib approach rather than adding a dependency.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = REPO_ROOT / "docs" / "metrics" / "scorecard" / "catalog.json"

API_ROOT = "https://api.github.com"
# Workflows whose `smoke-test` job runs the live-smoke gate (#376).
LIVE_SMOKE_WORKFLOWS = ("cd-app-sandbox.yml", "cd-app.yml", "cd-sandbox-cycle.yml")
# Matches docs/metrics/README.md's "月1回程度を目安に手動実行" cadence guidance for
# these workflows, plus a small buffer.
LIVE_SMOKE_STALE_AFTER_DAYS = 35

# Axis key -> (Japanese label, aggregate category). Order matches
# docs/metrics/scorecard-criteria.md and .github/ISSUE_TEMPLATE/verification.md.
AXES: dict[str, tuple[str, str]] = {
    "dev_environment_standardization": ("開発環境の標準化", "golden_path"),
    "ci_cd": ("CI/CD", "golden_path"),
    "quality_gates": ("品質ゲート", "golden_path"),
    "docs_adr": ("ドキュメント/ADR", "golden_path"),
    "security_guardrails": ("セキュリティガードレール", "golden_path"),
    "observability_metrics": ("観測性/メトリクス", "golden_path"),
    "self_service": ("セルフサービス性", "idp"),
    "api_contract": ("API契約管理", "golden_path"),
    "infra_hardening": ("インフラ堅牢化", "golden_path"),
    "org_scalability": ("組織スケーラビリティ", "idp"),
}


@dataclass
class Check:
    name: str
    passed: bool
    detail: str


def _exists(*parts: str) -> bool:
    return (REPO_ROOT.joinpath(*parts)).exists()


def _read(*parts: str) -> str | None:
    path = REPO_ROOT.joinpath(*parts)
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def _any_workflow_matches(pattern: str) -> bool:
    workflows_dir = REPO_ROOT / ".github" / "workflows"
    if not workflows_dir.is_dir():
        return False
    rx = re.compile(pattern)
    return any(
        rx.search(p.read_text(encoding="utf-8", errors="replace"))
        for p in workflows_dir.glob("*.yml")
    )


def _no_workflow_matches(pattern: str) -> bool:
    return not _any_workflow_matches(pattern)


def _dora_snapshot_exists() -> bool:
    metrics_dir = REPO_ROOT / "docs" / "metrics"
    if not metrics_dir.is_dir():
        return False
    return any(
        re.fullmatch(r"\d{4}-\d{2}\.md", p.name) for p in metrics_dir.glob("*.md")
    )


def _adr_count_at_least(minimum: int) -> bool:
    adr_dir = REPO_ROOT / "docs" / "adr"
    if not adr_dir.is_dir():
        return False
    count = sum(1 for p in adr_dir.glob("[0-9][0-9][0-9][0-9]-*.md"))
    return count >= minimum


def _github_get(path: str, token: str) -> dict:
    req = urllib.request.Request(f"{API_ROOT}{path}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(req) as resp:  # noqa: S310 - fixed https://api.github.com host
        return json.load(resp)


def _last_live_smoke_success(
    owner: str | None, repo: str | None, token: str | None, get=_github_get
) -> str | None:
    """ISO timestamp of the most recent successful `smoke-test` job across
    LIVE_SMOKE_WORKFLOWS, or None if none is found or the API can't be
    reached (no owner/repo/token -- e.g. running locally without auth, or a
    transient network error). Best-effort: this is a diagnostic signal, not
    a hard requirement for scorecard generation to succeed.
    """
    if not owner or not repo or not token:
        return None
    best: str | None = None
    for workflow_file in LIVE_SMOKE_WORKFLOWS:
        try:
            runs = get(
                f"/repos/{owner}/{repo}/actions/workflows/{workflow_file}/runs"
                "?status=success&per_page=5",
                token,
            )
        except (urllib.error.URLError, OSError):
            continue
        for run in runs.get("workflow_runs", []):
            try:
                jobs = get(
                    f"/repos/{owner}/{repo}/actions/runs/{run['id']}/jobs", token
                )
            except (urllib.error.URLError, OSError):
                continue
            for job in jobs.get("jobs", []):
                # The caller job is "smoke-test" (blocking) or, after #376's
                # reusable-workflow extraction, reported as "smoke-test / check".
                if (
                    job.get("name", "").startswith("smoke-test")
                    and job.get("conclusion") == "success"
                ):
                    completed = job.get("completed_at")
                    if completed and (best is None or completed > best):
                        best = completed
    return best


def _live_smoke_recency_check(
    owner: str | None, repo: str | None, token: str | None
) -> list[Check]:
    last = _last_live_smoke_success(owner, repo, token)
    if last is None:
        if not (owner and repo and token):
            detail = "GITHUB_TOKEN/リポジトリ情報が無いため未実施（GITHUB_REPOSITORY・GITHUB_TOKEN環境変数が必要）"
        else:
            detail = f"{', '.join(LIVE_SMOKE_WORKFLOWS)} のいずれにも直近の成功実行が見つからない"
        return [Check("live_smoke_recent_success", False, detail)]
    last_dt = datetime.fromisoformat(last.replace("Z", "+00:00"))
    age_days = (datetime.now(UTC) - last_dt).days
    passed = age_days <= LIVE_SMOKE_STALE_AFTER_DAYS
    detail = (
        f"直近の成功: {last}（{age_days}日前、閾値{LIVE_SMOKE_STALE_AFTER_DAYS}日）"
    )
    return [Check("live_smoke_recent_success", passed, detail)]


def _run_checks(
    owner: str | None = None, repo: str | None = None, token: str | None = None
) -> dict[str, list[Check]]:
    makefile = _read("Makefile") or ""
    pyproject = _read("services", "backend", "python", "pyproject.toml") or ""
    vite_config = _read("services", "frontend", "vite.config.ts") or ""
    precommit = _read(".pre-commit-config.yaml") or ""
    bootstrap_tf = _read("infra", "bootstrap", "main.tf") or ""

    return {
        "dev_environment_standardization": [
            Check(
                "devcontainer_present",
                _exists(".devcontainer", "devcontainer.json"),
                ".devcontainer/devcontainer.json",
            ),
            Check(
                "make_dev_target",
                bool(re.search(r"^dev:", makefile, re.MULTILINE)),
                "Makefile の `dev:` ターゲット",
            ),
        ],
        "ci_cd": [
            Check(
                "ci_workflow_present",
                _exists(".github", "workflows", "ci.yml"),
                "ci.yml",
            ),
            Check(
                "reusable_workflow_call",
                _any_workflow_matches(r"workflow_call:"),
                "workflow_call を使う reusable workflow",
            ),
            Check(
                "oidc_id_token",
                _any_workflow_matches(r"id-token:\s*write"),
                "cd-*.yml の id-token: write（OIDC）",
            ),
            Check(
                "no_long_lived_keys",
                _no_workflow_matches(r"AWS_ACCESS_KEY_ID"),
                "workflows 内に AWS_ACCESS_KEY_ID 参照がない",
            ),
        ],
        "quality_gates": [
            Check(
                "backend_coverage_threshold",
                "--cov-fail-under" in pyproject,
                "pyproject.toml の --cov-fail-under",
            ),
            Check(
                "frontend_coverage_threshold",
                "thresholds" in vite_config and "coverage" in vite_config,
                "vite.config.ts の coverage thresholds",
            ),
            Check(
                "e2e_live_smoke",
                _exists("services", "frontend", "e2e", "live-smoke"),
                "services/frontend/e2e/live-smoke（ADR-0008）",
            ),
            *_live_smoke_recency_check(owner, repo, token),
        ],
        "docs_adr": [
            Check("adr_dir_active", _adr_count_at_least(5), "docs/adr/ に5件以上のADR"),
            Check(
                "ai_instructions_doc",
                _exists("docs", "ai-instructions.md"),
                "docs/ai-instructions.md（CLAUDE.md/Copilot 同期規約）",
            ),
        ],
        "security_guardrails": [
            Check(
                "no_hardcoded_keys",
                _no_workflow_matches(r"AWS_ACCESS_KEY_ID"),
                "workflows 内に長期認証情報の参照がない",
            ),
            Check(
                "iam_policy_check_wired",
                "check_iam_policies.py"
                in (_read(".github", "workflows", "cd-infra.yml") or ""),
                "cd-infra.yml が check_iam_policies.py（ADR-0009）を実行",
            ),
            Check(
                "secrets_scan_present",
                "detect-private-key" in precommit or "gitleaks" in precommit,
                "pre-commit の秘密情報スキャン（現状 detect-private-key のみ、汎用スキャナ未導入）",
            ),
        ],
        "observability_metrics": [
            Check(
                "otel_adr_exists",
                any(REPO_ROOT.glob("docs/adr/0007-*.md")),
                "ADR-0007（OpenTelemetry）",
            ),
            Check(
                "dora_snapshot_exists",
                _dora_snapshot_exists(),
                "docs/metrics/*.md（DORAスナップショット）",
            ),
        ],
        "self_service": [
            Check(
                "scaffold_config_exists",
                _exists("copier.yml") or _exists("copier.yaml"),
                "copier.yml（スキャフォールドCLI、#294）",
            ),
            Check(
                "scaffold_verify_target",
                bool(re.search(r"^scaffold-verify:", makefile, re.MULTILINE)),
                "Makefile の `scaffold-verify:` ターゲット",
            ),
        ],
        "api_contract": [
            Check(
                "gen_types_target",
                bool(re.search(r"^gen-types:", makefile, re.MULTILINE)),
                "Makefile の `gen-types:` ターゲット",
            ),
            Check(
                "ci_drift_check",
                _any_workflow_matches(r"gen-types"),
                "CI に生成物と実装の一致を検証するステップ（現状なし）",
            ),
        ],
        "infra_hardening": [
            Check(
                "state_protection",
                "prevent_destroy" in bootstrap_tf
                and "versioning_configuration" in bootstrap_tf,
                "infra/bootstrap: state バケットの prevent_destroy + versioning",
            ),
            Check(
                "policy_as_code_exists",
                _exists("conftest") or _any_workflow_matches(r"\bconftest\b|\bopa\b"),
                "Policy as Code（conftest/OPA、#296は未導入）",
            ),
        ],
        "org_scalability": [
            Check(
                "scaffold_cli_exists",
                _exists("copier.yml") or _exists("copier.yaml"),
                "copier.yml（#294）",
            ),
            Check(
                "shared_module_dir_exists",
                _exists("modules"),
                "タグ付き配布される共有 Terraform モジュール（#239は未導入）",
            ),
        ],
    }


def _level4_signal(axis: str, checks: list[Check]) -> bool | None:
    """Whether the machine-detectable signals support at least a level-4 score.

    Returns None when an axis has no defined level-4 gate (e.g. purely
    qualitative axes) -- callers should skip the drift check in that case.
    """
    by_name = {c.name: c.passed for c in checks}
    gates = {
        "dev_environment_standardization": ["devcontainer_present", "make_dev_target"],
        "ci_cd": ["ci_workflow_present", "oidc_id_token", "no_long_lived_keys"],
        "quality_gates": ["backend_coverage_threshold", "frontend_coverage_threshold"],
        "docs_adr": ["adr_dir_active", "ai_instructions_doc"],
        "security_guardrails": ["no_hardcoded_keys", "iam_policy_check_wired"],
        "observability_metrics": ["otel_adr_exists", "dora_snapshot_exists"],
        "self_service": ["scaffold_config_exists", "scaffold_verify_target"],
        "api_contract": ["gen_types_target", "ci_drift_check"],
        "infra_hardening": ["state_protection"],
        "org_scalability": ["scaffold_cli_exists", "shared_module_dir_exists"],
    }.get(axis)
    if not gates:
        return None
    return all(by_name.get(name, False) for name in gates)


def load_catalog(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


_GP_LINE = re.compile(r"Golden Path テンプレート完成度: ([\d.]+) / 10")
_IDP_LINE = re.compile(r"IDP（組織展開）完成度: ([\d.]+) / 10")


def load_history(scorecard_dir: Path) -> list[tuple[str, float, float]]:
    """Extract (month, golden_path, idp) from past monthly snapshot files.

    Each snapshot file can contain multiple recorded runs (if the workflow
    ran more than once in a month); only the most recent run per file is
    used, matching how dora_metrics.py's trailing average reflects the
    latest state rather than every historical entry.
    """
    if not scorecard_dir.is_dir():
        return []
    history = []
    for path in sorted(scorecard_dir.glob("[0-9][0-9][0-9][0-9]-[0-9][0-9].md")):
        text = path.read_text(encoding="utf-8", errors="replace")
        gp_matches = _GP_LINE.findall(text)
        idp_matches = _IDP_LINE.findall(text)
        if gp_matches and idp_matches:
            history.append((path.stem, float(gp_matches[-1]), float(idp_matches[-1])))
    return history


def render_trend(history: list[tuple[str, float, float]]) -> str:
    if not history:
        return ""
    lines = [
        "",
        "### スコア推移",
        "",
        "| 月 | Golden Path | IDP |",
        "| --- | --- | --- |",
    ]
    for month, gp, idp in history:
        lines.append(f"| {month} | {gp} | {idp} |")
    return "\n".join(lines) + "\n"


def compute_aggregates(catalog: dict) -> tuple[float, float]:
    scores = catalog["axes"]
    gp_scores = [
        scores[k]["score"] for k, (_, cat) in AXES.items() if cat == "golden_path"
    ]
    idp_scores = [scores[k]["score"] for k, (_, cat) in AXES.items() if cat == "idp"]
    gp = round(sum(gp_scores) / len(gp_scores) * 2, 1)
    idp = round(sum(idp_scores) / len(idp_scores) * 2, 1)
    return gp, idp


def render_markdown(catalog: dict, checks: dict[str, list[Check]]) -> str:
    gp, idp = compute_aggregates(catalog)
    lines = [
        f"owner: {catalog.get('owner', '(未設定)')}",
        f"golden_path_version: {catalog.get('golden_path_version', '(未設定)')}",
        f"last_reviewed: {catalog.get('last_reviewed', '(未設定)')}",
        "",
        f"**Golden Path テンプレート完成度: {gp} / 10**",
        f"**IDP（組織展開）完成度: {idp} / 10**",
        "",
        "| 軸 | 宣言スコア | 機械信号 | 整合性 |",
        "| --- | --- | --- | --- |",
    ]
    warnings: list[str] = []
    for key, (label, _cat) in AXES.items():
        declared = catalog["axes"][key]["score"]
        axis_checks = checks[key]
        signal = _level4_signal(key, axis_checks)
        signal_summary = ", ".join(
            f"{c.name}={'OK' if c.passed else 'NG'}" for c in axis_checks
        )
        if signal is None:
            consistency = "-"
        elif declared >= 4 and not signal:
            consistency = "⚠️ 要確認"
            warnings.append(
                f"- **{label}**: 宣言スコア {declared} だが、レベル4の機械信号が揃っていない"
                f"（{'; '.join(c.detail for c in axis_checks if not c.passed)}）"
            )
        else:
            consistency = "✅"
        lines.append(f"| {label} | {declared} | {signal_summary} | {consistency} |")

    if warnings:
        lines += ["", "### ⚠️ 宣言スコアと機械信号の不整合", *warnings]

    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    default_owner, default_repo = (
        os.environ.get("GITHUB_REPOSITORY", "/").split("/", 1)[:2]
        if "/" in os.environ.get("GITHUB_REPOSITORY", "")
        else (None, None)
    )
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--format", choices=["markdown"], default="markdown")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="宣言スコアと機械信号の不整合が1件でもあれば非ゼロで終了する",
    )
    parser.add_argument(
        "--owner",
        default=default_owner,
        help="GitHub owner for the live-smoke recency check (default: $GITHUB_REPOSITORY)",
    )
    parser.add_argument(
        "--repo",
        default=default_repo,
        help="GitHub repo for the live-smoke recency check (default: $GITHUB_REPOSITORY)",
    )
    args = parser.parse_args(argv)
    token = os.environ.get("GITHUB_TOKEN")

    catalog = load_catalog(args.catalog)
    checks = _run_checks(owner=args.owner, repo=args.repo, token=token)
    output = render_markdown(catalog, checks)
    output += render_trend(load_history(args.catalog.parent))
    print(output)

    has_warning = "⚠️" in output
    return 1 if has_warning and args.strict else 0


if __name__ == "__main__":
    raise SystemExit(main())
