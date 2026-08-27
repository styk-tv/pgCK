#!/usr/bin/env bash
# ontology-audit.sh — THE mechanical audit of an ontology file. One implementation,
# structured output, every count naming its method (R-8). Cases assert on this
# output; nothing re-implements a check inline. Authors run it BEFORE committing an
# ontology change; the suite runs it forever after.
#
#   usage: ontology-audit.sh <core.ttl> [<required-terms-file>]
#
# Output: key=value lines on stdout. Exit 0 always (the audit REPORTS; the caller
# judges) — except exit 2 for unreadable input, which is not a report.
#
# Checks and their methods (each named because a count without its method is not
# a number):
#   sha256 + sidecar   file plane — byte digest vs <file>.wave-*.sha256 (final first)
#   nodeshapes         asserted `a sh:NodeShape` typing (never the inferred closure)
#   V3' reach          declared owl:*Property tokens vs sh:path tokens (regex plane;
#                      a Turtle parser would be stronger — this is the declared
#                      method, chosen for zero dependencies, and it found the seven)
#   V3  non-vacuity    declared rdfs/owl classes vs sh:targetClass targets
#   namespace line     IRIs minted under a versioned namespace OTHER than the line's
#   delta presence     every term in the required-terms file appears (versioned data,
#                      not code — the v3.12 list lives beside this script)
set -u
f="${1:-}"; req="${2:-}"
[ -r "$f" ] || { echo "audit.error=unreadable input: $f" >&2; exit 2; }
dir="$(cd "$(dirname "$f")" && pwd)"; base="$(basename "$f")"

python3 - "$f" "$req" <<'PY'
import hashlib, re, sys, os, glob

path, req = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""
raw = open(path, encoding="utf-8").read()
# strip comment lines BEFORE any count: a commented example shape is prose, and a
# count that reads prose disagrees with the engine by exactly the prose (measured:
# 31-vs-30 on the v3.12 root, the 31st being the header's illustrative shape).
s = "\n".join(l for l in raw.splitlines() if not l.lstrip().startswith("#"))
findings = 0

print(f"audit.file={path}")

# ---- file plane: digest + sidecar ------------------------------------------
digest = hashlib.sha256(open(path, "rb").read()).hexdigest()
print(f"audit.sha256={digest}")
# The digest-marker contract (ontology/README.md, rules 2+3): the CURRENT
# sidecar is the one that passes against current bytes — exactly one, always;
# historical sidecars are RETAINED and fail by design. So the audit passes iff
# SOME sidecar matches, and only every-sidecar-fails is drift.
sidecars = sorted(glob.glob(path + ".wave-*.sha256"))
if sidecars:
    matching = [p for p in sidecars
                if open(p).read().split()[0] == digest]
    if matching:
        # >1 match is LEGAL: a promotion that keeps the bytes (rc2 -> final)
        # leaves both tags pinning one digest. Zero matches is the only drift.
        print(f"audit.sidecar=match ({os.path.basename(sorted(matching)[-1])}; "
              f"{len(matching)} matching, {len(sidecars)-len(matching)} historical)")
    else:
        print(f"audit.sidecar=MISMATCH (no sidecar matches current bytes; "
              f"{len(sidecars)} checked)")
        findings += 1
else:
    print("audit.sidecar=absent")

# ---- structural counts, methods named --------------------------------------
nodeshapes = len(re.findall(r'\ba sh:NodeShape\b', s))
print(f"audit.nodeshapes={nodeshapes} method=asserted-typing")

# prefix-GENERAL: a module declares under its own prefix (wave:, lex:, recon:) —
# tokens keep their prefix so the same instrument audits core and every module.
classes = set(re.findall(r'(\w+:\w+) a (?:rdfs:Class|owl:Class)', s))
targeted = set(re.findall(r'sh:targetClass (\w+:\w+)', s))
untargeted = sorted(classes - targeted)
print(f"audit.classes={len(classes)} targeted={len(targeted & classes)} "
      f"untargeted={len(untargeted)}" + (":" + ",".join(untargeted) if untargeted else ""))
# untargeted classes are REPORTED, not auto-findings: some (e.g. organ kinds)
# are targeted via their parents. The caller decides against its own expectations.

# ---- V3' property reach (the check that caught the seven constants) --------
declared = set(re.findall(r'(\w+:\w+) a owl:(?:Datatype|Object)Property', s))
paths = set(re.findall(r'sh:path (\w+:\w+)', s))
unreached = sorted(declared - paths)
print(f"audit.properties.declared={len(declared)} reached={len(declared & paths)} "
      f"unreached={len(unreached)}" + (":" + ",".join(unreached) if unreached else ""))
if unreached: findings += 1

# ---- namespace line ---------------------------------------------------------
# the line's namespace is whatever the ckp: prefix binds; any OTHER versioned
# core# namespace appearing in the body is a violation of "the LAW carries the
# version, the namespace does not".
m = re.search(r'@prefix ckp:\s*<([^>]+)>', s)
line_ns = m.group(1) if m else ""
print(f"audit.namespace.line={line_ns}")
others = sorted(set(re.findall(r'<(https?://[^>]*?/ontology/v\d+\.\d+/core#)', s)) - {line_ns})
print(f"audit.namespace.violations={len(others)}" + (":" + ",".join(others) if others else ""))
if others: findings += 1

# ---- delta presence (versioned data file, one term per line, # comments) ---
if req and os.path.exists(req):
    terms = [t.strip() for t in open(req) if t.strip() and not t.startswith("#")]
    missing = [t for t in terms if not re.search(r'\b\w+:' + re.escape(t) + r'\b', s)]
    print(f"audit.delta.required={len(terms)} missing={len(missing)}"
          + (":" + ",".join(missing) if missing else ""))
    if missing: findings += 1

print(f"audit.verdict={'CLEAN' if findings == 0 else 'FINDINGS=' + str(findings)}")
PY
