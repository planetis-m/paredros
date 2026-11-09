#!/bin/sh
# tests/parity/brief.sh CLAUDE_DIR SESSION PLAN: runs `brief` with the Python
# hitl and with bin/hitl, each with its own state directory and the fake claude,
# and compares stdout, the prompts the model got, the ledger and the briefs.
# The ledger and briefs are compared parsed, without `generated` (a time stamp).
set -e
cd "$(dirname "$0")/../.."
claude_dir=$1; session=$2; plan=$3
out=nimcache/parity/brief; rm -rf $out; mkdir -p $out
for impl in py nim; do
  mkdir -p $out/$impl/state
  if [ $impl = py ]; then cmd="python3 -B $HOME/Projects/hitl/hitl.py --session $session brief"
  else cmd="bin/hitl --session=$session brief"; fi
  CLAUDE_CONFIG_DIR=$claude_dir XDG_STATE_HOME=$PWD/$out/$impl/state HITL_NO_CLIPBOARD=1 \
    PATH=$PWD/nimcache/tests/bin:$PATH FAKE_PLAN=$plan FAKE_LOG=$PWD/$out/$impl/calls \
    $cmd > $out/$impl/stdout 2> $out/$impl/stderr || echo "exit $?" >> $out/$impl/stdout
done
python3 - $out <<'PY'
import json, sys, glob, hashlib, os
out = sys.argv[1]
def calls(impl):
    return sorted(open(p).read() for p in glob.glob(f"{out}/{impl}/calls/*.prompt"))
def state(impl):
    d = {}
    for p in sorted(glob.glob(f"{out}/{impl}/state/hitl/briefs/*/*.json")):
        j = json.load(open(p)); j.pop("generated", None)
        d[os.path.basename(p)] = j
    return d
ok = True
for what, a, b in [("stdout", open(f"{out}/py/stdout").read(), open(f"{out}/nim/stdout").read()),
                   ("stderr", open(f"{out}/py/stderr").read(), open(f"{out}/nim/stderr").read()),
                   ("prompts", calls("py"), calls("nim"))]:
    if a != b:
        ok = False; print(f"DIFF {what}")
pa, pn = state("py"), state("nim")
if set(pa) != set(pn): ok = False; print("DIFF state files", sorted(pa), sorted(pn))
for k in pa:
    a, b = pa[k], pn.get(k)
    if k != "items.json" and b is not None:   # the port writes every field of an entry's type
        for sec in ("open_decisions", "spec_conflicts", "needs_review", "bug_risks", "decisions_made"):
            for e in b["brief"].get(sec, []):
                for f in ("why",):
                    if e.get(f) == "" and sec != "decisions_made": e.pop(f)
    if a != b: ok = False; print("DIFF", k)
print("prompts:", len(calls("py")), " state files:", len(pa), " ->", "SAME" if ok else "DIFFERENT")
PY
