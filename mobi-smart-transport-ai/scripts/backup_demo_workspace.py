"""Read-only Git/source backup, including untracked non-ignored files. No restore/reset."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]

def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args], cwd=ROOT)

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def verify(folder: Path) -> None:
    manifest = json.loads((folder / "BACKUP_MANIFEST.json").read_text(encoding="utf-8"))
    for name, expected in manifest["files"].items():
        path = (folder / name).resolve()
        if not path.is_relative_to(folder) or not path.is_file() or digest(path) != expected["sha256"]:
            raise ValueError("Backup verification failed: " + name)
    print("BACKUP_VERIFIED:", len(manifest["files"]), "files; HEAD", manifest["head"])

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path)
    mode.add_argument("--verify", type=Path)
    parser.add_argument("--artifact", type=Path, action="append", default=[])
    args = parser.parse_args()
    if args.verify:
        verify(args.verify.resolve())
        return
    folder = args.output.resolve()
    worktree = Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve()
    if folder.is_relative_to(worktree):
        raise ValueError("Backup must be outside the whole Git worktree")
    if folder.exists():
        raise ValueError("Use a new backup directory; existing evidence is never overwritten")
    head_at_start = git("rev-parse", "HEAD").decode().strip()
    state_at_start = {
        "unstaged.patch": git("diff", "--binary"),
        "staged.patch": git("diff", "--cached", "--binary"),
        "status.txt": git("status", "--short", "--untracked-files=all"),
    }
    folder.mkdir(parents=True, exist_ok=False)
    source_files = sorted(set(filter(None, git("ls-files", "-c", "-o", "--exclude-standard", "-z").decode().split("\0"))))
    tracked = set(filter(None, git("ls-files", "-z").decode().split("\0")))
    files, originals, deleted = {}, {}, []
    def copy(source: Path, name: str) -> None:
        if not source.is_file():
            raise ValueError("Missing backup input: " + str(source))
        expected = digest(source)
        target = folder / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if digest(target) != expected:
            raise ValueError("Copy hash mismatch: " + name)
        originals[str(source)] = expected
        files[name] = {"sha256": expected, "bytes": target.stat().st_size}
    for name in source_files:
        source = (ROOT / name).resolve()
        if not source.is_relative_to(ROOT):
            raise ValueError("External symlink/junction input is not copied: " + name)
        if not source.exists() and name in tracked:
            deleted.append(name)
            continue
        copy(source, "source/" + name)
    for i, artifact in enumerate(args.artifact):
        copy(artifact.resolve(), f"artifacts/{i:02d}-" + artifact.name)
    git_dir = folder / "git"
    git_dir.mkdir()
    for name, value in state_at_start.items():
        target = git_dir / name
        target.write_bytes(value)
        files["git/" + name] = {"sha256": digest(target), "bytes": target.stat().st_size}
    bundle = git_dir / "history.bundle"
    subprocess.run(["git", "bundle", "create", str(bundle), "HEAD"], cwd=ROOT, check=True, timeout=180)
    verified = subprocess.run(["git", "bundle", "verify", str(bundle)], cwd=ROOT, capture_output=True, check=True)
    files["git/history.bundle"] = {"sha256": digest(bundle), "bytes": bundle.stat().st_size}
    (git_dir / "bundle-verification.txt").write_bytes(verified.stdout + verified.stderr)
    files["git/bundle-verification.txt"] = {"sha256": digest(git_dir / "bundle-verification.txt"), "bytes": (git_dir / "bundle-verification.txt").stat().st_size}
    for source, expected in originals.items():
        if digest(Path(source)) != expected:
            raise ValueError("Source changed during backup; preserve this folder and create a fresh snapshot")
    current_state = {
        "unstaged.patch": git("diff", "--binary"),
        "staged.patch": git("diff", "--cached", "--binary"),
        "status.txt": git("status", "--short", "--untracked-files=all"),
    }
    if current_state != state_at_start or git("rev-parse", "HEAD").decode().strip() != head_at_start:
        raise ValueError("Git/source state changed during backup; preserve this folder and create a fresh snapshot")
    manifest = {
        "createdAtUtc": datetime.now(timezone.utc).isoformat(), "projectRoot": str(ROOT),
        "head": head_at_start,
        "branch": git("branch", "--show-current").decode().strip(),
        "sourceFiles": len(source_files) - len(deleted), "deletedTrackedPaths": deleted,
        "excluded": "Git-ignored caches, .venv, .env and credentials; ADC is not read or copied",
        "files": files,
    }
    (folder / "BACKUP_MANIFEST.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    verify(folder)
    print("BACKUP_CREATED:", folder)

if __name__ == "__main__":
    main()
