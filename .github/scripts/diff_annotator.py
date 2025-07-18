#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["PyGithub"]
# ///
"""
sdr_diff_integrator.py
----------------------

Run inside GitHub Actions with:

    uv run .github/scripts/sdr_diff_integrator.py

Environment variables required:

* GH_TOKEN   – `GITHUB_TOKEN` or a PAT with `checks:write` scope
* GITHUB_REPOSITORY – owner/repo (injected by Actions)
* BASE_REF   – branch to diff against (default: develop)
"""

from __future__ import annotations
import os
import subprocess
from pathlib import Path
from typing import List

from github import Github, GithubException  # PyGithub >= 2.3

# ---------------------------------------------------------------------------
# Constants / environment ----------------------------------------------------
# ---------------------------------------------------------------------------

REPO_FULL = os.getenv("GITHUB_REPOSITORY")
TOKEN     = os.getenv("GH_TOKEN") or os.getenv("GITHUB_TOKEN")
BASE      = os.getenv("BASE_REF", "develop")
CSV_GLOB  = "test/base_results/upgrades/sdr_annual/*.csv"
ROOT      = Path(__file__).resolve().parents[2]  # repo root guess

if not (REPO_FULL and TOKEN):
    raise SystemExit("GH_TOKEN and GITHUB_REPOSITORY must be set")

HEAD_SHA = subprocess.check_output(["git", "rev-parse", "HEAD"]).decode().strip()

# ---------------------------------------------------------------------------
# Helpers --------------------------------------------------------------------
# ---------------------------------------------------------------------------


def run(cmd: List[str]) -> str:
    """Return stdout of a shell command, raising on non‑zero exit."""
    return subprocess.check_output(cmd).decode()


def changed_csv_files() -> List[str]:
    diff = run(
        ["git", "diff", "--name-only", f"origin/{BASE}...HEAD", "--", CSV_GLOB]
    )
    return [p for p in diff.splitlines() if p]


def diff_report(path: str) -> tuple[str, str]:
    """
    Re‑use existing diff script.  Falls back to plain `git diff` if that
    helper isn’t present so the integrator stays self‑contained.
    """
    helper = ROOT / ".github" / "scripts" / "get_diff_report.py"
    if helper.exists():
        plain = run(["uv", "run", str(helper), path])
        md    = run(["uv", "run", str(helper), path, "--markdown"])
        return plain, md
    else:
        plain = run(["git", "diff", f"origin/{BASE}...HEAD", "--", path])
        return plain, f"```diff\n{plain}\n```"


def chunk(seq, size):
    for i in range(0, len(seq), size):
        yield seq[i : i + size]


def github_repo():
    return Github(TOKEN, per_page=100).get_repo(REPO_FULL)


def main() -> None:
    repo  = github_repo()
    files = changed_csv_files()

    run_obj = repo.create_check_run(
        name="SDR diff", head_sha=HEAD_SHA, status="in_progress"
    )  # PyGithub Check‑Run API :contentReference[oaicite:0]{index=0}

    if not files:
        run_obj.edit(
            conclusion="success",
            status="completed",
            output={
                "title": "SDR diff",
                "summary": "No SDR annual CSV changes.",
            },
        )
        print("No CSV changes; exiting cleanly.")
        return

    annotations, md_blocks = [], []
    for f in files:
        plain, md = diff_report(f)
        md_blocks.append(md)
        annotations.append(
            {
                "path": f,
                "start_line": 1,
                "end_line": 1,
                "annotation_level": "notice",
                "message": plain[:8000],  # API per‑annotation limit
            }
        )

    # GitHub limits 50 annotations per request; chunk if needed
    summary = "\n\n".join(md_blocks)[:65535]
    for batch in chunk(annotations, 50):
        run_obj.edit(
            status="completed" if batch is annotations[-50:] else "in_progress",
            conclusion="success",
            output={
                "title": "SDR results diff",
                "summary": summary if batch is annotations[-50:] else "",
                "annotations": batch,
            },
        )

    print(f"Completed check‑run #{run_obj.id} with {len(annotations)} annotation(s).")


if __name__ == "__main__":
    try:
        main()
    except GithubException as exc:
        print(f"GitHub API error: {exc.data}")
        raise
