"""Gives every file in the working tree a modification time derived from its content.

A fresh checkout stamps every file with the current time, so the Swift compiler's incremental
build (in Xcode's DerivedData and in SwiftPM's .build) would treat every file as changed and a
restored build cache would save nothing. With this script a file keeps the same time as long as
its content is the same, and gets a different time as soon as one byte changes (the time is
taken from a SHA-256 of the content, to the nanosecond). Compilers compare these times for
equality, never "newer than", so a changed file is always recompiled: the cache can only save
work, never hide a change.

Usage: python3 stable_mtimes.py [root]   (skips .git, .build, build and DerivedData)
"""
import hashlib
import os
import sys

SKIP_DIRS = {".git", ".build", "build", "DerivedData", "node_modules"}
BASE = 946_684_800  # 2000-01-01, far from any real checkout time


def stamp(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    value = int.from_bytes(digest.digest()[:8], "big")
    seconds = BASE + value % 500_000_000          # about 16 years of seconds
    nanos = (value // 500_000_000) % 1_000_000_000
    ns = seconds * 1_000_000_000 + nanos
    os.utime(path, ns=(ns, ns))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    count = 0
    for directory, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            path = os.path.join(directory, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            stamp(path)
            count += 1
    print(f"STABLE_MTIMES {count} files")


if __name__ == "__main__":
    main()
