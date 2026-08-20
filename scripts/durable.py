#!/usr/bin/env python3
"""
The ordering that makes the migration survive a power cut.

A rename is not durable because it returned. Until the *directory* holding the
new name has been fsynced, the kernel is free to persist a later operation while
losing the rename — so a migration that renamed a staged copy into place and then
unlinked the source can, after a reboot, present a host where the unlink survived
and the rename did not. That is the split install the transaction exists to make
unreachable, arriving by the one route the transaction did not model.

The first version of this fsynced one temporary file and nothing else, beneath a
comment claiming power-loss durability. This module exists so that the ordering
is written down once, in one place, and so that a test can pin the sequence of
calls rather than trusting the comment.

The order the migration uses, and why each step is where it is:

    file      <staged>          data before any name refers to it
    tree      <staging>         the whole staged copy, before it is trusted
    dir       <root>            after the manifest rename, BEFORE services stop:
                                a manifest that does not survive the crash that
                                interrupted it is worse than no manifest
    dir       <dest parent>     after each commit rename, BEFORE any source is
                                unlinked, so the two copies are never both at
                                risk
    dir       <source parent>   after each unlink, so a reboot cannot resurrect
                                a legacy entry that was deleted
    dir       <root>            after staging and the manifest are removed,
                                BEFORE success is reported, so a reboot cannot
                                resurrect a transaction that already finished

Usage:

    durable.py file PATH...     fsync each file
    durable.py dir PATH...      fsync each directory
    durable.py tree PATH...     fsync every file and directory beneath, and it

Set AGENTEIAMAIL_TEST_SYNC_LOG to a file and every call appends
`<kind>\t<path>` to it. scripts/test_durable.py asserts the sequence, because an
ordering nobody checks is an ordering that drifts back to one fsync and a
comment.
"""

import os
import sys
from pathlib import Path


def _log(kind, path):
    destination = os.environ.get("AGENTEIAMAIL_TEST_SYNC_LOG")
    if not destination:
        return
    with open(destination, "a", encoding="utf-8") as handle:
        handle.write(f"{kind}\t{path}\n")


def sync_file(path):
    """Flush a file's data. Opening read-only is enough for fsync on Linux."""
    _log("file", path)
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sync_dir(path):
    """
    Flush a directory entry, which is what makes a rename or unlink durable.

    O_DIRECTORY, because fsync on the *file* says nothing about whether the name
    pointing at it survived.
    """
    _log("dir", path)
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def sync_tree(path):
    """
    Every file and directory at or beneath `path`, depth first.

    Depth first so a directory is flushed after the entries it names, and
    symlinks are not followed: the link itself is the durable thing, and
    chasing it would sync something outside the tree.
    """
    _log("tree", path)
    root = Path(path)
    if root.is_symlink():
        sync_dir(root.parent)
        return
    if root.is_file():
        sync_file(root)
        sync_dir(root.parent)
        return
    for current, directories, files in os.walk(root, topdown=False, followlinks=False):
        for name in files:
            candidate = Path(current) / name
            if not candidate.is_symlink():
                sync_file(candidate)
        sync_dir(current)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    kind, paths = argv[1], argv[2:]
    actions = {"file": sync_file, "dir": sync_dir, "tree": sync_tree}
    if kind not in actions:
        print(f"durable: unknown sync kind: {kind}", file=sys.stderr)
        return 2
    for path in paths:
        actions[kind](path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
