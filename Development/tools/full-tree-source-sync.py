#!/usr/bin/env python3
"""Sync the user's main local RTL88WiFi source tree to GitHub main.

Local source is authoritative for files present locally. This tool adds/updates
files in one Git commit. It deliberately does not delete GitHub-only files and
does not overwrite the repository's Development records, build output, or run logs.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import getpass
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

REPOSITORY = "shammu2bd/Realtek-WiFi-Native-macOS"
BRANCH = "main"
KEYCHAIN_SERVICE = "realtek-wifi-native-macos-upload"
DEFAULT_ROOT = pathlib.Path.home() / "Downloads" / "RTL88WiFi-1.0.11-WCL-Sequoia-24H32-stage26-clean-source"
API_ROOT = "https://api.github.com/repos/" + REPOSITORY
MAX_FILE_BYTES = 50 * 1024 * 1024
MAX_OUTPUT_LOG_BYTES = 850 * 1024

EXCLUDED_DIR_NAMES = {
    ".git", ".svn", ".hg", "__pycache__", ".pytest_cache", ".mypy_cache",
    ".ruff_cache", "DerivedData", "build", "Build", "run log",
}
EXCLUDED_FILE_NAMES = {".DS_Store", "Thumbs.db"}
EXCLUDED_SUFFIXES = {".pyc", ".pyo", ".swp", ".tmp"}


class SyncError(RuntimeError):
    pass


def api_request(method: str, url: str, token: str, payload: dict | None = None):
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode("utf-8")
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": "Bearer " + token,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "RTL88WiFi-Full-Tree-Sync",
    }
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=90) as response:
            raw = response.read()
            if not raw:
                return None
            return json.loads(raw.decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")
        raise SyncError("{} {} failed: HTTP {} {}".format(method, url, exc.code, detail[:1800])) from exc
    except (urllib.error.URLError, TimeoutError) as exc:
        raise SyncError("{} {} failed: {}".format(method, url, exc)) from exc


def get_token() -> str:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        return token.strip()

    if platform.system() == "Darwin":
        try:
            result = subprocess.run(
                ["security", "find-generic-password", "-a", os.environ.get("USER", ""),
                 "-s", KEYCHAIN_SERVICE, "-w"],
                check=True, capture_output=True, text=True, timeout=15,
            )
            if result.stdout.strip():
                return result.stdout.strip()
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            pass

    try:
        result = subprocess.run(
            ["gh", "auth", "token"], check=True, capture_output=True, text=True, timeout=15
        )
        if result.stdout.strip():
            return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        pass

    token = getpass.getpass(
        "GitHub fine-grained token (Contents read/write for " + REPOSITORY + "): "
    ).strip()
    if not token:
        raise SyncError("No GitHub token supplied; no files were uploaded.")

    if platform.system() == "Darwin":
        try:
            subprocess.run(
                ["security", "add-generic-password", "-U", "-a",
                 os.environ.get("USER", ""), "-s", KEYCHAIN_SERVICE, "-w", token],
                check=True, capture_output=True, text=True, timeout=15,
            )
            print("GitHub credential saved in macOS Keychain.")
        except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
            print("Warning: could not save the token in Keychain; it was used only for this run.")
    return token


def git_blob_sha(data: bytes) -> str:
    header = ("blob " + str(len(data)) + "\0").encode("ascii")
    return hashlib.sha1(header + data).hexdigest()


def excluded_relative_path(relative: pathlib.PurePosixPath) -> bool:
    if not relative.parts:
        return True
    # The new repository's Development folder contains canonical project history,
    # audit records and uploaded logs. Preserve it as GitHub-managed metadata.
    if relative.parts[0] == "Development":
        return True
    if any(part in EXCLUDED_DIR_NAMES for part in relative.parts[:-1]):
        return True
    if relative.name in EXCLUDED_FILE_NAMES or relative.suffix.lower() in EXCLUDED_SUFFIXES:
        return True
    return False


def scan_local(root: pathlib.Path):
    files: dict[str, tuple[pathlib.Path, bytes, str, str]] = {}
    skipped: list[str] = []
    for current, dirs, names in os.walk(root, topdown=True, followlinks=False):
        current_path = pathlib.Path(current)
        kept_dirs = []
        for dirname in dirs:
            full = current_path / dirname
            rel = full.relative_to(root).as_posix()
            pure = pathlib.PurePosixPath(rel)
            if dirname in EXCLUDED_DIR_NAMES or (pure.parts and pure.parts[0] == "Development"):
                continue
            if full.is_symlink():
                skipped.append(rel + " (symlink directory)")
                continue
            kept_dirs.append(dirname)
        dirs[:] = kept_dirs

        for filename in names:
            full = current_path / filename
            rel = full.relative_to(root).as_posix()
            pure = pathlib.PurePosixPath(rel)
            if excluded_relative_path(pure):
                continue
            try:
                if full.is_symlink() or not full.is_file():
                    skipped.append(rel + " (not a regular file)")
                    continue
                size = full.stat().st_size
                if size > MAX_FILE_BYTES:
                    skipped.append(rel + " ({} bytes; over 50 MiB upload safety limit)".format(size))
                    continue
                data = full.read_bytes()
                blob = git_blob_sha(data)
                mode = "100755" if (full.stat().st_mode & 0o111) else "100644"
                files[rel] = (full, data, blob, mode)
            except OSError as exc:
                skipped.append(rel + " (read error: " + str(exc) + ")")
    return files, skipped


def get_branch_head(token: str) -> str:
    data = api_request(
        "GET", API_ROOT + "/git/ref/heads/" + urllib.parse.quote(BRANCH, safe=""),
        token
    )
    try:
        return data["object"]["sha"]
    except (TypeError, KeyError) as exc:
        raise SyncError("Could not resolve GitHub main branch head.") from exc


def get_tree(token: str, commit_sha: str):
    commit = api_request("GET", API_ROOT + "/git/commits/" + commit_sha, token)
    tree_sha = commit["tree"]["sha"]
    tree = api_request("GET", API_ROOT + "/git/trees/" + tree_sha + "?recursive=1", token)
    if tree.get("truncated"):
        raise SyncError("GitHub returned a truncated repository tree; refusing an incomplete sync.")
    entries = {}
    for item in tree.get("tree", []):
        if item.get("type") == "blob":
            entries[item["path"]] = item
    return tree_sha, entries


def upload_blob(token: str, relative: str, data: bytes) -> str:
    response = api_request(
        "POST", API_ROOT + "/git/blobs", token,
        {"content": base64.b64encode(data).decode("ascii"), "encoding": "base64"},
    )
    sha = response.get("sha")
    if not sha:
        raise SyncError("GitHub did not return a blob SHA for " + relative)
    return sha


def commit_source_changes(token: str, head_sha: str, base_tree: str, changes):
    tree_items = []
    for relative, blob_sha, mode in changes:
        tree_items.append({
            "path": relative,
            "mode": mode,
            "type": "blob",
            "sha": blob_sha,
        })
    tree = api_request(
        "POST", API_ROOT + "/git/trees", token,
        {"base_tree": base_tree, "tree": tree_items},
    )
    commit = api_request(
        "POST", API_ROOT + "/git/commits", token,
        {
            "message": "Sync local RTL88WiFi source tree ({})".format(
                dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            ),
            "tree": tree["sha"],
            "parents": [head_sha],
        },
    )
    api_request(
        "PATCH", API_ROOT + "/git/refs/heads/" + BRANCH, token,
        {"sha": commit["sha"], "force": False},
    )
    return commit["sha"]


def put_text_file(token: str, path: str, content: str, message: str):
    url = API_ROOT + "/contents/" + urllib.parse.quote(path, safe="/")
    branch_url = url + "?ref=" + urllib.parse.quote(BRANCH, safe="")
    current = None
    try:
        current = api_request("GET", branch_url, token)
    except SyncError as exc:
        if "HTTP 404" not in str(exc):
            raise
    payload = {
        "message": message,
        "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
        "branch": BRANCH,
    }
    if current is not None:
        payload["sha"] = current["sha"]
    return api_request("PUT", url, token, payload)


def publish_report(token: str, run_id: str, report: str):
    remote_dir = "Development/Logs/full-tree-sync/" + run_id
    put_text_file(
        token, remote_dir + "/sync-report.txt", report,
        "Record full local source-tree sync " + run_id,
    )

    output_path = "Development/output.log"
    url = API_ROOT + "/contents/" + urllib.parse.quote(output_path, safe="/")
    current = api_request(
        "GET", url + "?ref=" + urllib.parse.quote(BRANCH, safe=""), token
    )
    old_bytes = base64.b64decode(current.get("content", ""))
    record = (
        "\n========== AUTOMATED FULL SOURCE TREE SYNC ==========\n"
        "RUN_ID: " + run_id + "\n"
        "SYNC_REPORT: " + remote_dir + "/sync-report.txt\n"
        "SYNC_MODE: LOCAL_SOURCE_ADDS_AND_UPDATES; NO_REMOTE_DELETIONS\n"
        "=====================================================\n"
    ).encode("utf-8")
    if len(old_bytes) + len(record) <= MAX_OUTPUT_LOG_BYTES:
        payload = {
            "message": "Record full source-tree sync " + run_id,
            "content": base64.b64encode(old_bytes + record).decode("ascii"),
            "branch": BRANCH,
            "sha": current["sha"],
        }
        api_request("PUT", url, token, payload)
        return remote_dir, True
    return remote_dir, False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=pathlib.Path, default=DEFAULT_ROOT)
    args = parser.parse_args()

    root = args.root.expanduser().resolve()
    if not root.is_dir():
        raise SyncError("Main source folder not found: " + str(root))
    if not (root / "driver" / "RTL88WiFi").is_dir():
        raise SyncError("This does not look like the expected RTL88WiFi source root: " + str(root))

    run_id = "run-" + dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:10]
    local_report_dir = root / "run log" / "full-tree-sync" / run_id
    local_report_dir.mkdir(parents=True, exist_ok=True)

    print("MAIN_LOCAL_SOURCE: " + str(root))
    print("GITHUB_TARGET: https://github.com/" + REPOSITORY + "/tree/" + BRANCH)
    print("RUN_ID: " + run_id)
    print("Scanning local source files (Development, build outputs and run log are excluded)...")
    local_files, skipped = scan_local(root)
    print("LOCAL_SOURCE_FILES: " + str(len(local_files)))
    print("SKIPPED_LOCAL_ITEMS: " + str(len(skipped)))

    token = get_token()

    head_sha = get_branch_head(token)
    base_tree, remote_files = get_tree(token, head_sha)

    changed = []
    unchanged = 0
    local_paths = set(local_files)
    remote_source_paths = {
        path for path in remote_files
        if not path.startswith("Development/")
        and not excluded_relative_path(pathlib.PurePosixPath(path))
    }
    remote_only = sorted(remote_source_paths - local_paths)

    for relative, (_, data, blob_sha, mode) in local_files.items():
        remote = remote_files.get(relative)
        if remote and remote.get("sha") == blob_sha:
            unchanged += 1
        else:
            changed.append((relative, data, blob_sha, mode))

    additions = sum(1 for relative, *_ in changed if relative not in remote_files)
    updates = len(changed) - additions
    print("UNCHANGED_FILES: " + str(unchanged))
    print("FILES_TO_ADD: " + str(additions))
    print("FILES_TO_UPDATE: " + str(updates))
    print("GITHUB_ONLY_SOURCE_FILES_RETAINED: " + str(len(remote_only)))
    print("No GitHub-only files will be deleted.")

    uploaded_changes = []
    for index, (relative, data, _local_sha, mode) in enumerate(changed, start=1):
        print("[{}/{}] Uploading {}".format(index, len(changed), relative))
        uploaded_sha = upload_blob(token, relative, data)
        uploaded_changes.append((relative, uploaded_sha, mode))

    if uploaded_changes:
        new_head = commit_source_changes(token, head_sha, base_tree, uploaded_changes)
    else:
        new_head = head_sha

    report_lines = [
        "RTL88WiFi full local source-tree sync report",
        "RUN_ID: " + run_id,
        "DATE_UTC: " + dt.datetime.now(dt.timezone.utc).isoformat(),
        "LOCAL_SOURCE: " + str(root),
        "GITHUB_REPOSITORY: " + REPOSITORY,
        "GITHUB_BRANCH: " + BRANCH,
        "BASE_COMMIT: " + head_sha,
        "RESULTING_COMMIT: " + new_head,
        "LOCAL_FILES_SCANNED: " + str(len(local_files)),
        "FILES_UNCHANGED: " + str(unchanged),
        "FILES_ADDED: " + str(additions),
        "FILES_UPDATED: " + str(updates),
        "GITHUB_ONLY_SOURCE_FILES_RETAINED: " + str(len(remote_only)),
        "SKIPPED_LOCAL_ITEMS: " + str(len(skipped)),
        "SYNC_POLICY: Local source adds/updates are authoritative; no remote-only deletion.",
        "EXCLUSIONS: top-level Development; .git/.svn/.hg; build/Build/DerivedData; run log; caches; OS metadata.",
        "SOURCE_COMMIT: " + new_head,
        "",
        "CHANGED_FILES:",
    ]
    report_lines.extend("{} {}".format("ADD" if path not in remote_files else "UPDATE", path) for path, *_ in changed)
    report_lines.extend(["", "GITHUB_ONLY_SOURCE_FILES_RETAINED (first 100):"])
    report_lines.extend(remote_only[:100] or ["NONE"])
    report_lines.extend(["", "SKIPPED_LOCAL_ITEMS (first 100):"])
    report_lines.extend(skipped[:100] or ["NONE"])
    report = "\n".join(report_lines) + "\n"
    (local_report_dir / "sync-report.txt").write_text(report, encoding="utf-8")

    remote_dir, output_log_updated = publish_report(token, run_id, report)
    print("")
    print("FULL_TREE_SYNC: PASS")
    print("SOURCE_COMMIT: " + new_head)
    print("ADDED: {} | UPDATED: {} | UNCHANGED: {}".format(additions, updates, unchanged))
    print("REMOTE_ONLY_RETAINED: {}".format(len(remote_only)))
    print("SKIPPED_ITEMS: {}".format(len(skipped)))
    print("OUTPUT_LOG_POINTER: " + ("UPDATED" if output_log_updated else "SKIPPED_NEAR_SIZE_LIMIT"))
    print("GITHUB_REPORT: https://github.com/" + REPOSITORY + "/blob/" + BRANCH + "/" + remote_dir + "/sync-report.txt")
    print("GITHUB_SOURCE: https://github.com/" + REPOSITORY + "/tree/" + BRANCH)
    print("LOCAL_REPORT: " + str(local_report_dir / "sync-report.txt"))
    if skipped:
        print("WARNING: some local items were skipped; inspect the report before claiming full parity.")
        return 2
    if remote_only:
        print("NOTE: GitHub-only source files were retained, so this is a safe union sync, not a destructive mirror.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SyncError as exc:
        print("SYNC_ERROR: " + str(exc), file=sys.stderr)
        sys.exit(1)
