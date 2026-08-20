#!/usr/bin/env python3
"""
A stable digest of a file or a directory tree, computed without a shell.

The evidence a migration resume checks committed artifacts against. It exists as
its own program because the first version was a shell pipeline:

    find . -print0 | sort -z | xargs -0 -I{} sh -c 'printf "%s" "{}"; cat "{}"'

`-I{}` substitutes each pathname into the *program text* of `sh -c`, so a
filename is executed rather than read. A file named `"; touch PWNED; #` inside
the state tree was enough to run a command, and the state tree is a directory
this project copies wholesale during a migration. Filenames are data. There is
no safe amount of interpolating them into a shell.

What goes into the digest, and why each part is needed:

  path    relative and POSIX-normalised, so the same tree digests the same from
          any working directory
  type    a directory, a regular file and a symlink with identical names are
          different trees
  target  where a symlink points, which is content for a link
  size    cheap mismatch detection before the contents are read
  bytes   the contents of regular files

Sorted, so ordering is deterministic rather than whatever readdir returned. Names
are hashed as UTF-8 with surrogateescape, so an undecodable filename is still
distinguishable rather than an error.

    tree_digest.py PATH
"""

import hashlib
import os
import sys
from pathlib import Path

CHUNK = 1024 * 1024


def _feed(digest, label, value):
    """Length-prefixed, so `a` + `bc` cannot collide with `ab` + `c`."""
    encoded = value if isinstance(value, bytes) else str(value).encode(
        "utf-8", "surrogateescape")
    digest.update(f"{label}:{len(encoded)}:".encode("ascii"))
    digest.update(encoded)
    digest.update(b"\n")


def digest_path(target):
    target = Path(target)
    digest = hashlib.sha256()

    if not target.exists() and not target.is_symlink():
        return "absent"

    if target.is_symlink():
        _feed(digest, "type", "symlink")
        _feed(digest, "target", os.readlink(target))
        return digest.hexdigest()

    if target.is_file():
        _feed(digest, "type", "file")
        _feed(digest, "size", target.stat().st_size)
        with target.open("rb") as handle:
            while True:
                chunk = handle.read(CHUNK)
                if not chunk:
                    break
                digest.update(chunk)
        return digest.hexdigest()

    if not target.is_dir():
        # A fifo, socket or device. Its identity is its type; reading it could
        # block forever, which is not a thing a digest should risk.
        _feed(digest, "type", "special")
        return digest.hexdigest()

    _feed(digest, "type", "directory")
    entries = []
    for current, directories, files in os.walk(target, followlinks=False):
        directories.sort()
        files.sort()
        for name in list(directories) + list(files):
            entries.append(Path(current) / name)
    # Sorted on the relative path rather than on walk order, which is not stable
    # across filesystems.
    for entry in sorted(entries, key=lambda p: p.relative_to(target).as_posix()):
        relative = entry.relative_to(target).as_posix()
        _feed(digest, "path", relative)
        if entry.is_symlink():
            _feed(digest, "type", "symlink")
            _feed(digest, "target", os.readlink(entry))
        elif entry.is_dir():
            _feed(digest, "type", "directory")
        elif entry.is_file():
            _feed(digest, "type", "file")
            _feed(digest, "size", entry.stat().st_size)
            with entry.open("rb") as handle:
                while True:
                    chunk = handle.read(CHUNK)
                    if not chunk:
                        break
                    digest.update(chunk)
        else:
            _feed(digest, "type", "special")
    return digest.hexdigest()


def main(argv):
    if len(argv) != 2:
        print("usage: tree_digest.py PATH", file=sys.stderr)
        return 2
    print(digest_path(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
