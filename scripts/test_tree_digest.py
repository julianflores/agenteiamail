#!/usr/bin/env python3
"""
Filenames are data, and the digest is stable.

The first version of this digest was a shell pipeline:

    find . -print0 | sort -z | xargs -0 -I{} sh -c 'printf "%s" "{}"; cat "{}"'

`-I{}` substitutes each pathname into the *program text* of `sh -c`, so a
filename is executed rather than read. A file named `"; touch PWNED; #` ran a
command — and the state tree, which this digest is computed over, is a directory
the migration copies wholesale from a location any process running as the user
can write to.

The injection cases here are the point of the file. The stability cases are what
makes the digest usable as evidence at all.

    scripts/test_tree_digest.py
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIGEST = ROOT / "scripts" / "tree_digest.py"

passed = failed = 0


def check(description, expected, actual):
    global passed, failed
    if expected == actual:
        print(f"ok   {description}")
        passed += 1
    else:
        print(f"FAIL {description}\n       expected: {expected}\n       actual:   {actual}")
        failed += 1


def digest(path):
    result = subprocess.run([sys.executable, str(DIGEST), str(path)],
                            capture_output=True, text=True)
    return result.stdout.strip()


def canaries(*roots):
    """Any file a payload would have created, wherever it might have landed."""
    found = []
    for root in roots:
        root = Path(root)
        if not root.is_dir():
            continue
        found.extend(sorted(str(p) for p in root.glob("PWNED*")))
    return found


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)

    # --- filenames are never executed ------------------------------------
    #
    # The payload names are single components on purpose. An earlier version of
    # this test embedded an absolute canary path inside each filename; that
    # contains "/", so write_text raised OSError, a broad `except OSError: pass`
    # swallowed it, and every command-bearing fixture was silently skipped. The
    # assertion below then passed over benign names and proved nothing.
    #
    # The old pipeline ran with the tree as its working directory, so a relative
    # `touch` inside a filename lands in the tree itself — which is where the
    # canaries are looked for, along with the cwd this test runs from.
    hostile = tmp / "hostile"
    hostile.mkdir()
    executing = [
        '"; touch PWNED; #',
        "$(touch PWNED2)",
        "`touch PWNED3`",
        "; touch PWNED4; #",
    ]
    awkward = [
        "--not-an-option",
        "with a space.log",
        "with'quote.json",
        'with"doublequote.json',
        "with\nnewline.json",
        "with|pipe&and;semicolon",
    ]

    # Every execution-bearing payload must actually exist. A fixture that failed
    # to be created is a test that cannot fail, and skipping one silently is how
    # this test came to prove nothing the first time.
    for name in executing:
        (hostile / name).write_text("contents")
        check(f"the payload [{name}] exists", True, (hostile / name).is_file())

    for name in awkward:
        try:
            (hostile / name).write_text("contents")
        except OSError:
            pass   # a filesystem that refuses a merely-awkward name is fine

    value = digest(hostile)
    check("a tree of hostile filenames still digests", 64, len(value))
    check("and nothing was executed", [], canaries(hostile, tmp, Path.cwd()))

    # --- stability --------------------------------------------------------
    check("the same tree digests the same twice", digest(hostile), digest(hostile))

    a = tmp / "a"
    b = tmp / "b"
    for root in (a, b):
        (root / "inner").mkdir(parents=True)
        (root / "inner" / "file").write_text("same")
    check("two identical trees agree", digest(a), digest(b))

    (b / "inner" / "file").write_text("different")
    check("a changed file changes the digest", True, digest(a) != digest(b))

    # --- names are content, not only bytes -------------------------------
    #
    # Two trees holding the same bytes under different names are different
    # trees, and a rename that lost a file must not digest the same.
    c = tmp / "c"
    d = tmp / "d"
    (c).mkdir()
    (d).mkdir()
    (c / "one").write_text("x")
    (d / "two").write_text("x")
    check("the same bytes under a different name differ", True, digest(c) != digest(d))

    e = tmp / "e"
    e.mkdir()
    (e / "one").write_text("")
    (e / "two").write_text("")
    f = tmp / "f"
    f.mkdir()
    (f / "onetwo").write_text("")
    check("concatenated names cannot collide", True, digest(e) != digest(f))

    # --- types are content ------------------------------------------------
    g = tmp / "g"
    g.mkdir()
    (g / "thing").write_text("target")
    h = tmp / "h"
    h.mkdir()
    (h / "thing").symlink_to(tmp / "elsewhere")
    check("a file and a symlink of the same name differ", True, digest(g) != digest(h))

    # A symlink is digested by where it points, never by following it: chasing
    # one would read something outside the tree, and for a fifo would block.
    i = tmp / "i"
    i.mkdir()
    (i / "thing").symlink_to(tmp / "somewhere-else")
    check("symlinks pointing elsewhere differ", True, digest(h) != digest(i))

    # --- absent is not an error ------------------------------------------
    check("something absent digests as absent", "absent", digest(tmp / "not-here"))

    # --- a plain file ------------------------------------------------------
    single = tmp / "single"
    single.write_text("content")
    check("a regular file digests", 64, len(digest(single)))
    check("and its digest is not its directory's", True, digest(single) != digest(tmp))

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
