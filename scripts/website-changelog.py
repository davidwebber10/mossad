#!/usr/bin/env python3
"""Adds one release to the website's changelog, newest first.

    scripts/website-changelog.py <version> "<notes>" [--date YYYY-MM-DD] [--file website/content/changelog.json]

The notes are the string scripts/release.sh takes: one change per line, each line may start with "- ".
A version that is already in the file is an error, so a release is never listed twice.
"""
import argparse
import datetime
import json
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_FILE = os.path.join(ROOT, "website", "content", "changelog.json")


def note_lines(notes):
    lines = []
    for line in notes.splitlines():
        line = re.sub(r"^\s*[-*]\s+", "", line).strip()
        if line:
            lines.append(line)
    return lines


def main(argv):
    parser = argparse.ArgumentParser(description="Add a release to the website changelog.")
    parser.add_argument("version")
    parser.add_argument("notes")
    parser.add_argument("--date", default=datetime.date.today().isoformat())
    parser.add_argument("--file", default=DEFAULT_FILE)
    args = parser.parse_args(argv)

    if not re.fullmatch(r"\d+(\.\d+){1,3}", args.version):
        sys.exit(f"Not a version: {args.version}")
    try:
        datetime.date.fromisoformat(args.date)
    except ValueError:
        sys.exit(f"Not a date (YYYY-MM-DD): {args.date}")
    notes = note_lines(args.notes)
    if not notes:
        sys.exit("The notes are empty.")

    if os.path.exists(args.file):
        with open(args.file, encoding="utf-8") as f:
            changelog = json.load(f)
    else:
        changelog = {"schemaVersion": 1, "releases": []}
    releases = changelog.setdefault("releases", [])
    if any(r.get("version") == args.version for r in releases):
        sys.exit(f"{args.version} is already in {args.file}.")

    releases.insert(0, {"version": args.version, "date": args.date, "notes": notes})

    # Written to a temporary file and moved, so a failure never leaves half a file.
    folder = os.path.dirname(os.path.abspath(args.file))
    os.makedirs(folder, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=folder, suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(changelog, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(temp, 0o644)
    os.replace(temp, args.file)
    print(f"Added {args.version} ({args.date}) to {args.file}")


if __name__ == "__main__":
    main(sys.argv[1:])
