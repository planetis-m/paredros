#!/bin/sh
# build.sh [FILE.nim [OUT]] [-- flags]: build paredros (default) or another program.
# Uses the toolchain copy in nimcache/toolchain so no build ever writes into
# the nimony checkout: plugins and compile-time consts ignore --stdcache
# (bug-reports/108). Make the copy with:  ./build.sh --toolchain
set -e
cd "$(dirname "$0")"
NIMONY_SRC=${NIMONY_SRC:-$HOME/Projects/nimony}
TC=$PWD/nimcache/toolchain
if [ "$1" = "--toolchain" ]; then
  rm -rf "$TC"; mkdir -p "$TC"
  cp -r "$NIMONY_SRC/bin" "$NIMONY_SRC/lib" "$NIMONY_SRC/src" "$NIMONY_SRC/doc" "$TC/"
  exit 0
fi
[ -x "$TC/bin/nimony" ] || { echo "no toolchain copy: run ./build.sh --toolchain" >&2; exit 1; }
file=${1:-paredros.nim}; [ $# -gt 0 ] && shift
name=$(basename "$file" .nim)
out=${1:-bin/$name}; [ $# -gt 0 ] && [ "$1" != "--" ] && shift
[ "$1" = "--" ] && shift
mkdir -p "$(dirname "$out")"
exec "$TC/bin/nimony" c --stdcache:"$TC/stdcache" --nimcache:"nimcache/$name" -o:"$PWD/$out" "$@" "$file"
