from __future__ import annotations

import argparse
import logging
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from style_configs import LINT_DIR, check_config
from style_imports import check_imports
from style_scan import Finding
from style_sources import RustExpect, check_generated, check_source, language_of, rust_expects

if TYPE_CHECKING:
    from types import TracebackType

VENDORED_FILE = "vendored-paths.txt"
LOCAL_FILE = "vendored-paths.local.txt"
APPROVED_FILE = "approved-suppressions.local.txt"
SUPPRESSION = "lint suppression (GEN-4)"
ATTRIBUTE_SPAN = 6
SEGMENT = r"(?!\.+/)[A-Za-z0-9_.@+-]+/"
LEAF = r"(?!\.+$)[A-Za-z0-9_.@+-]+"
ENTRY = re.compile(rf"/(?:{SEGMENT})+|/(?:{SEGMENT})*{LEAF}|{SEGMENT}")
APPROVED_ENTRY = re.compile(rf"(/(?:{SEGMENT})*{LEAF})((?:[ \t]+\S+)+)")
RULE = re.compile(r"[A-Za-z][A-Za-z0-9_]*")
RUST_LINT = re.compile(r"[a-z][a-z0-9_]*(?:::[a-z][a-z0-9_]*)?")
RUST_LINT_GROUPS = frozenset(
    {
        "clippy",
        "clippy::all",
        "clippy::cargo",
        "clippy::complexity",
        "clippy::correctness",
        "clippy::nursery",
        "clippy::pedantic",
        "clippy::perf",
        "clippy::restriction",
        "clippy::style",
        "clippy::suspicious",
        "deprecated_safe",
        "future_incompatible",
        "keyword_idents",
        "let_underscore",
        "nonstandard_style",
        "refining_impl_trait",
        "rust_2018_compatibility",
        "rust_2018_idioms",
        "rust_2021_compatibility",
        "rust_2024_compatibility",
        "rustdoc",
        "rustdoc::all",
        "unknown_or_malformed_diagnostic_attributes",
        "unused",
        "warnings",
    },
)


@dataclass(frozen=True, slots=True)
class VendoredPaths:
    names: frozenset[str]
    prefixes: tuple[str, ...]
    files: frozenset[str]

    def covers(self, path: str) -> bool:
        if path in self.files or path.startswith(self.prefixes):
            return True
        return any(part in self.names for part in path.split("/")[:-1])


@dataclass(frozen=True, slots=True)
class Approval:
    number: int
    path: str
    rules: tuple[str, ...]


def parse_approval(name: str, number: int, entry: str) -> Approval:
    match = APPROVED_ENTRY.fullmatch(entry)
    path = match.group(1) if match else ""
    rules = tuple(match.group(2).split()) if match else ()
    if not path.endswith(".rs"):
        if len(rules) == 1 and RULE.fullmatch(rules[0]):
            return Approval(number, path.lstrip("/"), rules)
        message = f"{name}:{number}: {entry!r} isn't a /path/file from the repo root and a rule id"
        raise ValueError(message)
    if not all(RUST_LINT.fullmatch(lint) for lint in rules) or len(set(rules)) < len(rules):
        message = f"{name}:{number}: {entry!r} isn't a /path/file.rs from the repo root and its lints, each named once"
        raise ValueError(message)
    groups = [lint for lint in rules if lint in RUST_LINT_GROUPS]
    if groups:
        message = f"{name}:{number}: {', '.join(groups)} is a lint group; name each lint on its own"
        raise ValueError(message)
    return Approval(number, path.lstrip("/"), rules)


def read_approvals(path: Path) -> list[Approval]:
    approvals: list[Approval] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        entry = raw.strip()
        if entry:
            approvals.append(parse_approval(path.name, number, entry))
    return approvals


def attribute_text(root: Path, finding: Finding) -> str:
    try:
        lines = (root / finding.path).read_text(encoding="utf-8-sig", errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[max(finding.line - 1, 0) : finding.line - 1 + ATTRIBUTE_SPAN])


def csharp_approved(root: Path, kept: list[Finding], approval: Approval) -> Finding | None:
    rule = re.compile(
        rf'^[^\n]*?\bSuppressMessage(?:Attribute)?\s*\(\s*"[^"\n]*"\s*,\s*"{re.escape(approval.rules[0])}\b',
    )
    return next(
        (
            finding
            for finding in kept
            if finding.path == approval.path
            and finding.message == SUPPRESSION
            and rule.search(attribute_text(root, finding))
        ),
        None,
    )


def rust_approved(kept: list[Finding], approval: Approval, left: list[RustExpect]) -> Finding | None:
    wanted = frozenset(approval.rules)
    for expect in left:
        finding = Finding(approval.path, expect.line, SUPPRESSION)
        if expect.lints == wanted and finding in kept:
            left.remove(expect)
            return finding
    return None


def file_expects(root: Path, path: str) -> list[RustExpect]:
    try:
        return rust_expects((root / path).read_text(encoding="utf-8-sig", errors="replace"))
    except OSError:
        return []


def apply_approvals(root: Path, findings: list[Finding], approvals: list[Approval]) -> list[Finding]:
    kept = list(findings)
    expects: dict[str, list[RustExpect]] = {}
    for approval in approvals:
        if approval.path.endswith(".rs"):
            if approval.path not in expects:
                expects[approval.path] = file_expects(root, approval.path)
            approved = rust_approved(kept, approval, expects[approval.path])
            missing = f"expect({', '.join(approval.rules)})"
        else:
            approved = csharp_approved(root, kept, approval)
            missing = f"{approval.rules[0]} suppression"
        if approved is None:
            message = f"{approval.path} has no {missing} left; remove this line (GEN-4)"
            kept.append(Finding(f"{LINT_DIR}/{APPROVED_FILE}", approval.number, message))
        else:
            kept.remove(approved)
    return sorted(kept)


def read_entries(path: Path) -> list[str]:
    entries: list[str] = []
    for number, raw in enumerate(path.read_text(encoding="utf-8-sig").splitlines(), 1):
        entry = raw.strip()
        if not entry:
            continue
        if not ENTRY.fullmatch(entry):
            message = (
                f"{path.name}:{number}: {entry!r} isn't a folder name/, a /path/ or a /path/file from the repo root"
            )
            raise ValueError(message)
        entries.append(entry)
    return entries


def vendored_paths(entries: list[str]) -> VendoredPaths:
    names = {entry.strip("/") for entry in entries if not entry.startswith("/")}
    rooted = [entry.lstrip("/") for entry in entries if entry.startswith("/")]
    prefixes = tuple(entry for entry in rooted if entry.endswith("/"))
    files = frozenset(entry for entry in rooted if not entry.endswith("/"))
    return VendoredPaths(frozenset(names), prefixes, files)


def unfolded(shared: list[str], local: list[str]) -> list[Finding]:
    return [
        Finding(f"{LINT_DIR}/{LOCAL_FILE}", 0, f"{entry} isn't in {VENDORED_FILE} yet. Run Install-Lint again (GEN-1)")
        for entry in local
        if entry not in shared
    ]


def tracked_files(root: Path) -> list[str]:
    git = shutil.which("git")
    if git is None:
        message = "git isn't on PATH"
        raise OSError(message)
    result = subprocess.run(
        [git, "-C", str(root), "ls-files", "-z"],
        capture_output=True,
        check=True,
        timeout=120,
    )
    return [entry for entry in result.stdout.decode("utf-8", errors="replace").split("\0") if entry]


def check_repo(root: Path, vendored: VendoredPaths) -> list[Finding]:
    own = [path for path in tracked_files(root) if not vendored.covers(path)]
    tracked = frozenset(own)
    findings: list[Finding] = []
    python: dict[str, str] = {}
    for path in own:
        full = root / path
        if not full.is_file():
            continue
        findings.extend(check_config(path, root))
        findings.extend(check_generated(path, tracked))
        try:
            text = full.read_text(encoding="utf-8-sig", errors="replace")
        except OSError as error:
            findings.append(Finding(path, 0, f"can't read: {error.strerror}"))
            continue
        findings.extend(check_source(path, text))
        if language_of(path, text) == "python":
            python[path] = text
    findings.extend(check_imports(python))
    return sorted(findings)


def report_unhandled(error_type: type[BaseException], error: BaseException, traceback: TracebackType | None) -> None:
    logging.getLogger(__name__).error("Style check failed", exc_info=(error_type, error, traceback))
    sys.stderr.write("Style check failed; fix the error above and run it again.\n")


def unslashed(root: Path, path: Path, entries: list[str]) -> list[Finding]:
    folders = {entry for entry in entries if not entry.endswith("/") and (root / entry.lstrip("/")).is_dir()}
    if not folders:
        return []
    name = path.relative_to(root).as_posix()
    lines = path.read_text(encoding="utf-8-sig").splitlines()
    return [
        Finding(name, number, f"{line.strip()} is a folder; end it with /")
        for number, line in enumerate(lines, 1)
        if line.strip() in folders
    ]


def main() -> int:
    sys.excepthook = report_unhandled
    parser = argparse.ArgumentParser(
        description="Check a repo for comments, lint suppressions, long files and nested lint configs.",
    )
    parser.add_argument("root", nargs="?", default=".", help="repo root (default: the current folder)")
    args = parser.parse_args()
    root = Path(str(args.root)).resolve()
    list_path = Path(__file__).resolve().with_name(VENDORED_FILE)
    if not list_path.is_file():
        sys.stderr.write(f"{VENDORED_FILE} is missing next to {Path(__file__).name}. Run Install-Lint again.\n")
        return 2
    lint = root / LINT_DIR
    local_path = lint / LOCAL_FILE
    approved_path = lint / APPROVED_FILE
    try:
        shared = read_entries(list_path)
        local = read_entries(local_path) if local_path.is_file() else []
        approvals = read_approvals(approved_path) if approved_path.is_file() else []
    except (OSError, ValueError) as error:
        sys.stderr.write(f"can't read the lists in {LINT_DIR}: {error}\n")
        return 2
    try:
        findings = check_repo(root, vendored_paths(shared + local))
    except (subprocess.CalledProcessError, OSError) as error:
        sys.stderr.write(f"can't list the files in {root} with git: {error}\n")
        return 2
    findings = apply_approvals(root, findings, approvals)
    findings += unslashed(root, local_path, local)
    if list_path.parent == lint:
        findings = sorted(findings + unfolded(shared, local))
    for finding in findings:
        sys.stdout.write(finding.render() + "\n")
    if findings:
        sys.stdout.write(f"{len(findings)} findings\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
