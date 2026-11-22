#!/usr/bin/env python3
"""Archive local checkout state into a new directory and verify it offline."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile

from worktree_inventory import inventory


def git(root, *args, data=None):
    return subprocess.run(["git", "--no-optional-locks", "-C", str(root), *args],
                          input=data, stdout=subprocess.PIPE, check=True).stdout


def names(raw):
    return [os.fsdecode(entry) for entry in raw.split(b"\0") if entry]


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def payload(root):
    untracked = names(git(root, "ls-files", "--others", "--exclude-standard", "-z"))
    ignored = names(git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"))
    return untracked, ignored


def snapshot(root):
    return {
        "head": git(root, "rev-parse", "HEAD").decode().strip(),
        "status": git(root, "status", "--porcelain=v2", "-z", "--untracked-files=normal"),
        "index": git(root, "ls-files", "--stage", "-z"),
        "staged": git(root, "diff", "--cached", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", "HEAD"),
        "unstaged": git(root, "diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv"),
    }


def json_file(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=True) + "\n")


def save_worktree(root, out, registered):
    if git(root, "ls-files", "-u"):
        raise ValueError(f"{root} has unmerged index stages. Preserve the active merge on the source host.")
    for lock in ("index.lock", "HEAD.lock"):
        if Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-path", lock)).strip()).exists():
            raise ValueError(f"{root} is locked by an active Git process")
    state = snapshot(root)
    untracked, ignored = payload(root)
    json_file(out / "extra-files.json", {"untracked": untracked, "ignored": ignored})
    for key in ("status", "index", "staged", "unstaged"):
        (out / key).write_bytes(state[key])
    with tarfile.open(out / "extra-files.tar", "x", dereference=False) as archive:
        for name in [*untracked, *ignored]:
            src = root / name
            if src.is_dir() and not src.is_symlink() and src.resolve() in registered:
                continue  # The linked checkout has its own complete archive and restore verification.
            if src.is_dir() and not src.is_symlink():
                raise ValueError(f"{src} is a nested repository or directory. Archive it independently before cleanup.")
            if not src.is_symlink() and not src.is_file():
                raise ValueError(f"{src} is a special file. Quiesce its owner before archiving.")
            archive.add(src, arcname=name, recursive=False)
    # Compare every archived file to its live counterpart. Verify symlinks as
    # links, including targets outside the worktree, without following them.
    verify_payload(root, out / "extra-files.tar")
    if snapshot(root) != state or payload(root) != (untracked, ignored):
        raise ValueError(f"{root} changed during archive construction")
    return state["head"]


def verify_payload(root, archive_path):
    with tarfile.open(archive_path) as archive:
        for member in archive:
            path = root / member.name
            if member.issym():
                if not path.is_symlink() or os.readlink(path) != member.linkname:
                    raise ValueError(f"Symlink changed: {path}")
            elif member.isfile():
                with archive.extractfile(member) as body:
                    if (path.is_symlink() or path.stat().st_mode & 0o7777 != member.mode or
                            hashlib.file_digest(body, "sha256").hexdigest() != digest(path)):
                        raise ValueError(f"Payload verification failed: {path}")
            elif member.islnk():
                if not os.path.samefile(path, root / member.linkname):
                    raise ValueError(f"Hard link changed: {path}")
            else:
                raise ValueError(f"Unexpected archive member: {member.name}")


def restore_payload(root, archive_path):
    def destination(name):
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Invalid archive path: {name}")
        result = root / relative
        if not result.parent.resolve().is_relative_to(root):
            raise ValueError(f"Archive path leaves restore root: {name}")
        result.parent.mkdir(parents=True, exist_ok=True)
        if result.exists() or result.is_symlink():
            raise ValueError(f"Duplicate or tracked archive path: {name}")
        return result

    import shutil
    with tarfile.open(archive_path) as archive:
        for member in archive:
            path = destination(member.name)
            if member.issym():
                path.symlink_to(member.linkname)
            elif member.isfile():
                with archive.extractfile(member) as source, path.open("xb") as output:
                    shutil.copyfileobj(source, output)
                path.chmod(member.mode)
            elif member.islnk():
                target = (root / member.linkname).resolve()
                if not target.is_relative_to(root) or not target.is_file():
                    raise ValueError(f"Invalid archived hardlink: {member.name}")
                os.link(target, path)
            else:
                raise ValueError(f"Unexpected archive member: {member.name}")
    verify_payload(root, archive_path)


def verify_restore(out, records, stashes):
    with tempfile.TemporaryDirectory(prefix="pleazyng-archive-restore-") as temp:
        restore = Path(temp) / "restore"
        git(temp, "init", "--quiet", str(restore))
        git(restore, "bundle", "verify", str(out / "history.bundle"))
        git(restore, "fetch", "--quiet", str(out / "history.bundle"), "+refs/archive/*:refs/archive/*")
        for row in records:
            if "folder" not in row:
                continue
            folder = out / row["folder"]
            git(restore, "checkout", "--detach", "-f", row["HEAD"])
            git(restore, "clean", "-ffdqx")  # only the private disposable offline clone
            for key, options in (("staged", ["--index"]), ("unstaged", [])):
                patch = (folder / key).read_bytes()
                if patch:
                    git(restore, "apply", "--binary", "--whitespace=nowarn", *options, "-", data=patch)
            if git(restore, "ls-files", "--stage", "-z") != (folder / "index").read_bytes():
                raise ValueError(f"Restored index differs for {row['worktree']}")
            if snapshot(restore)["unstaged"] != (folder / "unstaged").read_bytes():
                raise ValueError(f"Restored tracked work differs for {row['worktree']}")
            restore_payload(restore, folder / "extra-files.tar")
        for sha in stashes:
            parents = git(restore, "rev-list", "--parents", "-1", sha).decode().split()[1:]
            git(restore, "checkout", "--detach", "-f", parents[0])
            git(restore, "clean", "-ffdqx")
            git(restore, "stash", "apply", "--index", sha)
            if git(restore, "write-tree") != git(restore, "rev-parse", parents[1] + "^{tree}"):
                raise ValueError(f"Restored stash index differs: {sha}")
            git(restore, "diff", "--quiet", sha, "--")
            if len(parents) == 3:
                for record in names(git(restore, "ls-tree", "-r", "-z", parents[2])):
                    metadata, name = record.split("\t", 1)
                    mode, _, oid = metadata.split()
                    path = restore / name
                    if mode == "120000":
                        actual = git(restore, "hash-object", "--stdin", data=os.fsencode(os.readlink(path)))
                    else:
                        if bool(path.stat().st_mode & 0o100) != (mode == "100755"):
                            raise ValueError(f"Restored stash mode differs: {name}")
                        actual = git(restore, "hash-object", "--", name)
                    if actual.decode().strip() != oid:
                        raise ValueError(f"Restored stash payload differs: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    root, out = args.repo.resolve(), args.destination.resolve()
    report = inventory(root)
    records, stashes = report["worktrees"], report["stash_commits"]
    common = Path(os.fsdecode(git(root, "rev-parse", "--path-format=absolute", "--git-common-dir")).strip())
    if any(out.is_relative_to(Path(row["worktree"]).resolve()) for row in records) or out.is_relative_to(common):
        parser.error("Choose a new durable directory outside the source clone and its worktrees")
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Unique local refs keep detached work recoverable even before the bundle finishes.
    archive_id = hashlib.sha256(os.fsencode(out)).hexdigest()[:20]
    refs = []
    for index, row in enumerate(records):
        if row.get("bare"):
            continue
        work = Path(row["worktree"])
        name = f"wt-{index:04}"
        folder = out / name
        folder.mkdir()
        head = save_worktree(work, folder, {Path(item["worktree"]).resolve() for item in records})
        if head != row["HEAD"]:
            raise ValueError(f"{work} moved since inventory")
        row["folder"] = name
        ref = f"refs/archive/wt/{archive_id}/{name}"
        git(root, "update-ref", ref, head, "0" * len(head))
        refs.append(ref)
    stash_dir = out / "stashes"
    stash_dir.mkdir()
    for index, sha in enumerate(stashes):
        ref = f"refs/archive/stash/{archive_id}/{index:04}"
        git(root, "update-ref", ref, sha, "0" * len(sha))
        refs.append(ref)
        (stash_dir / f"{index:04}.patch").write_bytes(
            git(root, "stash", "show", "--binary", "--full-index", "--include-untracked", "--patch", sha))
    json_file(out / "inventory.json", report)
    git(root, "bundle", "create", str(out / "history.bundle"), "--stdin", data=("\n".join(refs) + "\n").encode())
    verify_restore(out, records, stashes)
    if inventory(root)["stash_commits"] != stashes:
        raise ValueError("Stash reflog changed during verification")
    json_file(out / "sha256.json", {str(p.relative_to(out)): digest(p) for p in sorted(out.rglob("*")) if p.is_file()})
    print(f"Verified {len(refs)} archive refs and every extra-file payload in {out}")


if __name__ == "__main__":
    main()
