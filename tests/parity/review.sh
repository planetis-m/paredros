#!/bin/sh
# tests/parity/review.sh CLAUDE_DIR SESSION STATE [CONFIG]: builds the pages with
# the Python hitl and with bin/hitl from copies of STATE (an XDG_STATE_HOME) and
# compares every file they write, byte for byte, and what they print.
set -e
cd "$(dirname "$0")/../.."
claude_dir=$1; session=$2; state=$3; config=$4
out=nimcache/parity/review; rm -rf $out; mkdir -p $out
for impl in py nim; do
  cp -r $state $out/$impl-state
  if [ $impl = py ]; then cmd="python3 -B $HOME/Projects/hitl/hitl.py --session $session ${config:+--config $config} review --out $PWD/$out/$impl"
  else cmd="bin/hitl --session=$session ${config:+--config=$config} review --out=$PWD/$out/$impl"; fi
  CLAUDE_CONFIG_DIR=$claude_dir XDG_STATE_HOME=$PWD/$out/$impl-state HITL_NO_CLIPBOARD=1 \
    $cmd > $out/$impl.stdout 2>&1 || echo "exit $?" >> $out/$impl.stdout
done
sed -i "s|/py/|/X/|; s|/nim/|/X/|" $out/py.stdout $out/nim.stdout
cmp -s $out/py.stdout $out/nim.stdout || { echo "DIFF stdout"; diff $out/py.stdout $out/nim.stdout | head -5; }
# Normalized: each run's state directory in the pages (the compare button names
# the scratch folder), and JSON files are compared parsed (whitespace).
for impl in py nim; do sed -i "s|/$impl-state/|/STATE/|g" $out/$impl/*.html; done
n=0; bad=0
for f in $(cd $out/py && ls -A); do
  n=$((n+1))
  case $f in
    *.json) python3 -c "import json,sys; sys.exit(json.load(open(sys.argv[1])) != json.load(open(sys.argv[2])))" $out/py/$f $out/nim/$f || { bad=$((bad+1)); echo "DIFF $f"; } ;;
    *) cmp -s $out/py/$f $out/nim/$f || { bad=$((bad+1)); echo "DIFF $f"; } ;;
  esac
done
[ "$(cd $out/py && ls -A)" = "$(cd $out/nim && ls -A)" ] || echo "DIFF file lists"
echo "files: $n  differ: $bad"
