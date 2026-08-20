#!/usr/bin/env python3
"""
The durability helper does what its docstring claims.

Narrow on purpose: this covers the helper's own semantics. The *ordering* the
migration uses it in is pinned separately, in scripts/test_migrate.sh, because
the ordering is a property of the migration rather than of this module.

Neither of them is a power-loss test. They are syscall-order and crash-boundary
*model* tests: they assert that the right fsync happens at the right point
relative to the rename and the unlink around it. Calling them power-loss tests
would be the same overclaim as the comment that started this — a real one needs
hardware that can be cut mid-write.

    scripts/test_durable.py
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DURABLE = ROOT / "scripts" / "durable.py"

passed = failed = 0


def check(description, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok   {description}")
        passed += 1
    else:
        print(f"FAIL {description}\n       expected: {expected}\n       actual:   {actual}")
        failed += 1


def run(kind, *paths, log=None):
    environ = dict(os.environ)
    if log:
        environ["AGENTEIAMAIL_TEST_SYNC_LOG"] = str(log)
    else:
        environ.pop("AGENTEIAMAIL_TEST_SYNC_LOG", None)
    return subprocess.run([sys.executable, str(DURABLE), kind, *map(str, paths)],
                          capture_output=True, text=True, env=environ)


def logged(log):
    if not Path(log).exists():
        return []
    return [line.split("\t") for line in Path(log).read_text().splitlines()]


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    log = tmp / "sync.log"

    # --- a file, and the directory naming it ------------------------------
    target = tmp / "a-file"
    target.write_text("contents")
    result = run("file", target, log=log)
    check("syncing a file succeeds", 0, result.returncode)
    check("and logs one file sync", [["file", str(target)]], logged(log))

    # --- a directory ------------------------------------------------------
    log.unlink()
    result = run("dir", tmp, log=log)
    check("syncing a directory succeeds", 0, result.returncode)
    check("and logs one directory sync", [["dir", str(tmp)]], logged(log))

    # --- a tree, depth first ----------------------------------------------
    log.unlink()
    tree = tmp / "tree"
    (tree / "inner").mkdir(parents=True)
    (tree / "inner" / "deep").write_text("deep")
    (tree / "shallow").write_text("shallow")
    result = run("tree", tree, log=log)
    check("syncing a tree succeeds", 0, result.returncode)

    entries = [tuple(entry) for entry in logged(log)]
    kinds = [kind for kind, _ in entries]
    check("a tree syncs files before the directory naming them", True,
          entries.index(("file", str(tree / "inner" / "deep")))
          < entries.index(("dir", str(tree / "inner"))))
    check("and the inner directory before the outer one", True,
          entries.index(("dir", str(tree / "inner")))
          < entries.index(("dir", str(tree))))
    check("and the tree root is synced last", ("dir", str(tree)), entries[-1])

    # --- symlinks are not followed ----------------------------------------
    #
    # Chasing one would sync something outside the tree, which is both useless
    # and, for a link pointing at a device or a fifo, capable of blocking.
    log.unlink()
    outside = tmp / "outside"
    outside.write_text("not part of the tree")
    linked = tmp / "linked-tree"
    linked.mkdir()
    (linked / "link").symlink_to(outside)
    result = run("tree", linked, log=log)
    check("a tree containing a symlink succeeds", 0, result.returncode)
    check("and never syncs through the link", False,
          any(path == str(outside) for _, path in logged(log)))

    # --- a missing path is an error, not a shrug --------------------------
    result = run("dir", tmp / "does-not-exist")
    check("syncing something absent fails", False, result.returncode == 0)

    # --- an unknown kind is refused ---------------------------------------
    result = run("sideways", tmp)
    check("an unknown sync kind is refused", 2, result.returncode)

    # --- the log is opt-in -------------------------------------------------
    quiet = tmp / "quiet.log"
    run("dir", tmp)
    check("nothing is logged without the test variable", False, quiet.exists())

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
