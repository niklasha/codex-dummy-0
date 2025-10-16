#!/usr/bin/env python3
"""Utilities for managing ape's git submodules during feature work.

This script provides a small command line interface that helps automate
common tasks when developing across multiple nested repositories:

* detect which submodules have local changes
* create feature branches in those submodules
* push the feature branches to a remote
* open merge requests/pull requests using ``glab`` or ``gh`` when available
* update the parent repository's submodule references after committing

The commands are intentionally verbose and perform plenty of safety checks so
that they can be used inside the Codex Cloud environment without surprises.
"""

from __future__ import annotations

import argparse
import configparser
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional


DEBUG = False


@dataclass
class Submodule:
    """Represents a single git submodule entry."""

    name: str
    path: Path


class WorkflowError(RuntimeError):
    """Raised when a git command fails."""


def debug(msg: str) -> None:
    """Emit a message to stderr when the user requests verbose output."""

    if DEBUG:
        print(f"[submodule-workflow] {msg}", file=sys.stderr)


def run_git(directory: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    """Execute a git command inside ``directory``.

    Parameters
    ----------
    directory:
        The repository directory to run git in.
    args:
        Arguments that will be passed to git.
    check:
        When ``True`` (the default) a :class:`WorkflowError` is raised if git
        exits with a non-zero status code. Otherwise the completed process is
        returned without raising.
    """

    cmd = ["git", "-C", str(directory), *args]
    debug("Executing: " + " ".join(cmd))
    result = subprocess.run(cmd, text=True, capture_output=True)
    if check and result.returncode != 0:
        raise WorkflowError(result.stderr.strip() or result.stdout.strip())
    return result


def ensure_repo(path: Path) -> Path:
    """Return an absolute path to ``path`` after sanity checking it."""

    root = path.resolve()
    if not (root / ".gitmodules").exists():
        raise WorkflowError(
            f"Expected to find a .gitmodules file in {root}; is this the ape repository?"
        )
    return root


def load_submodules(root: Path) -> List[Submodule]:
    """Parse ``.gitmodules`` and return the registered submodules."""

    parser = configparser.ConfigParser()
    parser.read(root / ".gitmodules")
    submodules: List[Submodule] = []
    for section in parser.sections():
        path = parser.get(section, "path", fallback=None)
        if not path:
            continue
        submodules.append(Submodule(name=section.split(" ", 1)[-1].strip('"'), path=(root / path)))
    return submodules


def git_status_lines(path: Path) -> List[str]:
    """Return the porcelain status lines for ``path``."""

    result = run_git(path, "status", "--porcelain", check=False)
    if result.returncode != 0:
        return []
    return [line for line in result.stdout.splitlines() if line.strip()]


def changed_submodules(submodules: Iterable[Submodule], include_clean: bool = False) -> List[Submodule]:
    """Return submodules with local modifications."""

    dirty = []
    for submodule in submodules:
        lines = git_status_lines(submodule.path)
        if lines or include_clean:
            debug(f"Submodule {submodule.name} status: {lines!r}")
        if lines:
            dirty.append(submodule)
    return dirty


def get_current_branch(path: Path) -> Optional[str]:
    result = run_git(path, "rev-parse", "--abbrev-ref", "HEAD", check=False)
    if result.returncode != 0:
        return None
    branch = result.stdout.strip()
    return None if branch == "HEAD" else branch


def ensure_branch(path: Path, branch: str, base: Optional[str], remote: str, force: bool) -> str:
    """Create or checkout ``branch`` in the repository located at ``path``."""

    current = get_current_branch(path)
    if current == branch:
        return branch

    existing = run_git(path, "rev-parse", "--verify", branch, check=False)
    if existing.returncode == 0:
        debug(f"Branch {branch} already exists; checking it out.")
        run_git(path, "checkout", branch)
        return branch

    status = git_status_lines(path)
    if base and not status:
        debug(f"Checking out base branch {base} before creating {branch}.")
        run_git(path, "fetch", remote, base, check=False)
        run_git(path, "checkout", base)
        run_git(path, "pull", remote, base, check=False)

    checkout_args = ["checkout", "-B" if force else "-b", branch]
    debug(f"Creating branch {branch} using args: {checkout_args}")
    run_git(path, *checkout_args)
    return branch


def push_branch(path: Path, branch: str, remote: str, set_upstream: bool) -> None:
    args = ["push", remote, branch]
    if set_upstream:
        args.insert(1, "-u")
    run_git(path, *args)


def detect_mr_tool(remote_url: str) -> Optional[str]:
    """Determine whether to use ``glab`` or ``gh`` for creating merge requests."""

    remote_url = remote_url.lower()
    if "gitlab" in remote_url and shutil.which("glab"):
        return "glab"
    if ("github" in remote_url or remote_url.endswith(".git")) and shutil.which("gh"):
        return "gh"
    if shutil.which("glab"):
        return "glab"
    if shutil.which("gh"):
        return "gh"
    return None


def create_merge_request(path: Path, branch: str, target: str, title: Optional[str], draft: bool) -> None:
    remote_url = run_git(path, "remote", "get-url", "origin").stdout.strip()
    tool = detect_mr_tool(remote_url)
    if tool is None:
        print(
            "No supported CLI (glab or gh) detected. Please create the merge request manually.",
            file=sys.stderr,
        )
        print(f"Suggested title: {title or branch}")
        return

    if tool == "glab":
        cmd = [
            "glab",
            "mr",
            "create",
            "--source-branch",
            branch,
            "--target-branch",
            target,
        ]
        if title:
            cmd += ["--title", title]
        if draft:
            cmd.append("--draft")
    else:
        head_ref = branch
        cmd = [
            "gh",
            "pr",
            "create",
            "--head",
            head_ref,
            "--base",
            target,
        ]
        if title:
            cmd += ["--title", title]
        if draft:
            cmd.append("--draft")

    debug("Running MR command: " + " ".join(cmd))
    completed = subprocess.run(cmd, text=True)
    if completed.returncode != 0:
        raise WorkflowError(
            f"Merge request command failed with exit code {completed.returncode}."
        )


def update_parent(root: Path, submodules: Iterable[Submodule]) -> None:
    for module in submodules:
        run_git(root, "add", str(module.path.relative_to(root)))


def parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path.cwd(),
        help="Path to the ape repository that hosts the submodules (defaults to cwd).",
    )
    parser.add_argument(
        "--include-clean",
        action="store_true",
        help="Include clean submodules in the status output (used with the status command).",
    )
    parser.add_argument(
        "--modules",
        nargs="*",
        help="Limit actions to the specified submodule names (default: operate on dirty ones).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Enable debug logging.",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("status", help="Show which submodules have local changes.")

    branch_parser = subparsers.add_parser(
        "branch", help="Create or checkout a feature branch inside dirty submodules."
    )
    branch_parser.add_argument("--name", required=True, help="Name of the feature branch to use.")
    branch_parser.add_argument(
        "--base",
        default=None,
        help="Optional base branch to update before creating the feature branch (ignored when the submodule has uncommitted changes).",
    )
    branch_parser.add_argument(
        "--remote", default="origin", help="Remote to use when fetching the base branch (default: origin)."
    )
    branch_parser.add_argument(
        "--force", action="store_true", help="Force recreate the branch if it already exists."
    )

    push_parser = subparsers.add_parser("push", help="Push feature branches in dirty submodules.")
    push_parser.add_argument("--remote", default="origin", help="Remote to push to (default: origin).")
    push_parser.add_argument(
        "--set-upstream",
        action="store_true",
        help="Set upstream when pushing (equivalent to git push -u).",
    )

    mr_parser = subparsers.add_parser(
        "mr", help="Create merge/pull requests for feature branches in dirty submodules."
    )
    mr_parser.add_argument(
        "--target",
        default="main",
        help="Target branch for the merge request (default: main).",
    )
    mr_parser.add_argument("--title", default=None, help="Title for the merge request/pr.")
    mr_parser.add_argument(
        "--draft", action="store_true", help="Mark the merge request as a draft when supported."
    )

    subparsers.add_parser(
        "update-parent",
        help="Stage updated submodule hashes in the parent repository for dirty submodules.",
    )

    return parser.parse_args(argv)


def resolve_targets(root: Path, submodules: List[Submodule], names: Optional[List[str]]) -> List[Submodule]:
    if not names:
        return submodules

    name_map = {module.name: module for module in submodules}
    missing = [name for name in names if name not in name_map]
    if missing:
        raise WorkflowError(f"Unknown submodule(s): {', '.join(missing)}")
    return [name_map[name] for name in names]


def handle_status(root: Path, target_modules: List[Submodule], include_clean: bool) -> None:
    modules = target_modules if include_clean else changed_submodules(target_modules)
    if not modules:
        print("No dirty submodules detected.")
        return
    for module in modules:
        lines = git_status_lines(module.path)
        print(f"{module.name} ({module.path}):")
        if lines:
            for line in lines:
                print(f"  {line}")
        else:
            print("  clean")


def handle_branch(root: Path, target_modules: List[Submodule], args: argparse.Namespace) -> None:
    modules = changed_submodules(target_modules)
    if not modules:
        print("No dirty submodules detected; nothing to branch.")
        return
    for module in modules:
        branch = ensure_branch(module.path, args.name, args.base, args.remote, args.force)
        print(f"Checked out {branch} in {module.name} ({module.path}).")


def handle_push(root: Path, target_modules: List[Submodule], args: argparse.Namespace) -> None:
    modules = changed_submodules(target_modules)
    if not modules:
        print("No dirty submodules detected; nothing to push.")
        return
    for module in modules:
        branch = get_current_branch(module.path)
        if not branch:
            raise WorkflowError(
                f"Submodule {module.name} is in a detached HEAD state; cannot push without a branch."
            )
        push_branch(module.path, branch, args.remote, args.set_upstream)
        print(f"Pushed {module.name} ({module.path}) to {args.remote}/{branch}.")


def handle_mr(root: Path, target_modules: List[Submodule], args: argparse.Namespace) -> None:
    modules = changed_submodules(target_modules)
    if not modules:
        print("No dirty submodules detected; no merge requests created.")
        return
    for module in modules:
        branch = get_current_branch(module.path)
        if not branch:
            raise WorkflowError(
                f"Submodule {module.name} does not have an active branch; create one before opening an MR."
            )
        create_merge_request(module.path, branch, args.target, args.title, args.draft)
        print(f"Triggered merge request creation for {module.name} ({branch} -> {args.target}).")


def handle_update_parent(root: Path, target_modules: List[Submodule]) -> None:
    modules = changed_submodules(target_modules)
    if not modules:
        print("No dirty submodules detected; nothing to stage in the parent.")
        return
    update_parent(root, modules)
    for module in modules:
        relative = module.path.relative_to(root)
        print(f"Staged updated hash for {module.name} ({relative}).")


def main(argv: Optional[List[str]] = None) -> int:
    global DEBUG
    args = parse_args(argv)
    DEBUG = args.verbose

    try:
        root = ensure_repo(args.repo_root)
        submodules = load_submodules(root)
        if not submodules:
            print("No submodules registered in .gitmodules.")
            return 0
        targets = resolve_targets(root, submodules, args.modules)

        if args.command == "status":
            handle_status(root, targets, args.include_clean)
        elif args.command == "branch":
            handle_branch(root, targets, args)
        elif args.command == "push":
            handle_push(root, targets, args)
        elif args.command == "mr":
            handle_mr(root, targets, args)
        elif args.command == "update-parent":
            handle_update_parent(root, targets)
        else:
            raise AssertionError(f"Unhandled command: {args.command}")
        return 0
    except WorkflowError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
