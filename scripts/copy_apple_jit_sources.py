#!/usr/bin/env python3
"""Create a tracked Apple source workspace without copying caches or xattrs."""

import argparse
import re
import subprocess
from pathlib import Path
from urllib.parse import urlsplit


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def copy_sources(source, destination, revision, remote_url=None):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("An exact GitHub source SHA is required.")
    if source.is_symlink() or not source.is_dir():
        raise ValueError("The source must be a real Git checkout.")
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise ValueError("The task destination must be an existing empty directory.")
    source = source.resolve()
    destination = destination.resolve()
    if source == destination or source in destination.parents:
        raise ValueError("The source workspace cannot contain the task destination.")
    if Path(git(source, "rev-parse", "--show-toplevel")).resolve() != source:
        raise ValueError("The source must be the checkout root.")
    if git(source, "rev-parse", "HEAD") != revision:
        raise ValueError("The source checkout does not match the requested revision.")
    if remote_url is not None:
        parsed = urlsplit(remote_url)
        if (parsed.scheme != "https" or parsed.hostname != "github.com" or parsed.port not in (None, 443)
                or parsed.path != "/snapetech-org/pleazyng.git" or parsed.username
                or parsed.password or parsed.query or parsed.fragment or not parsed.path.endswith(".git")):
            raise ValueError("The source remote must be the credential-free canonical Pleazyng GitHub HTTPS URL.")
        subprocess.run(["git", "init", "--quiet", str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "remote", "add", "origin", remote_url], check=True)
        subprocess.run(["git", "-C", str(destination), "fetch", "--no-tags", "--depth=1", "origin", revision], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"], check=True)
    else:
        # Local Apple native CI can use its checked-out source, but release jobs
        # pass remote_url so the private Mac never traverses NFS source files.
        subprocess.run(["git", "clone", "--shared", "--dissociate", "--no-checkout", "--no-tags",
                        "--", str(source), str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", revision], check=True)
    if git(destination, "rev-parse", "HEAD") != revision:
        raise RuntimeError("The Apple source workspace has an unexpected revision.")
    print(f"Prepared tracked Apple sources at {destination} from {revision}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("revision")
    parser.add_argument("--remote-url")
    args = parser.parse_args()
    copy_sources(args.source, args.destination, args.revision, args.remote_url)


if __name__ == "__main__":
    main()
