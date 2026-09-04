#!/usr/bin/env python3
"""Three-way merge of an Xcode String Catalog at the JSON-tree level.

Textual merges of .xcstrings files conflict on every line whenever one side was
re-serialised with different whitespace (Xcode writes `"key" : value`, json.dumps
writes `"key": value`). Merging the parsed trees sidesteps that: a leaf changed on
one side only takes that side, unchanged leaves stay, and only a leaf changed
differently on both sides is a real conflict (reported, theirs kept unless --ours).

Usage (inside a stopped `git merge`):
    Tools/merge-xcstrings.py <base-rev> <ours-rev> <theirs-rev> <path> [--ours]
Writes the merged catalog to <path> with json.dumps(indent=2, ensure_ascii=False),
which reproduces upstream's own serialisation byte-for-byte.
"""
import json, subprocess, sys

def load(rev, path):
    raw = subprocess.check_output(["git", "show", f"{rev}:{path}"])
    return json.loads(raw)

def merge(base, ours, theirs, trail, conflicts, prefer_ours):
    if isinstance(base, dict) and isinstance(ours, dict) and isinstance(theirs, dict):
        out = {}
        for k in dict.fromkeys(list(theirs) + list(ours) + list(base)):
            b, o, t = base.get(k, MISSING), ours.get(k, MISSING), theirs.get(k, MISSING)
            v = merge(b, o, t, trail + [k], conflicts, prefer_ours)
            if v is not MISSING:
                out[k] = v
        return out
    if o_eq(ours, theirs):
        return ours
    if o_eq(base, ours):
        return theirs
    if o_eq(base, theirs):
        return ours
    conflicts.append("/".join(map(str, trail)))
    return ours if prefer_ours else theirs

class _Missing:  # sentinel distinct from None (None is a valid JSON leaf)
    def __repr__(self): return "MISSING"
MISSING = _Missing()

def o_eq(a, b):
    return (a is MISSING and b is MISSING) or (a is not MISSING and b is not MISSING and a == b)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    prefer_ours = "--ours" in sys.argv
    base_rev, ours_rev, theirs_rev, path = args
    base, ours, theirs = (load(r, path) for r in (base_rev, ours_rev, theirs_rev))
    conflicts = []
    merged = merge(base, ours, theirs, [], conflicts, prefer_ours)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(merged, indent=2, ensure_ascii=False))
        fh.write("\n")
    print(f"{path}: {len(merged.get('strings', {}))} keys, {len(conflicts)} leaf conflicts")
    for c in conflicts:
        print("  CONFLICT", c)

if __name__ == "__main__":
    main()
