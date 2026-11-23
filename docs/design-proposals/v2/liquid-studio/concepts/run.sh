#!/bin/zsh
# usage: ./run.sh <suffix> screen...   one locked Azure call per screen
cd "${0:A:h}"
suf=$1; shift
for s in "$@"; do
  until mkdir /tmp/viaform-azure.lock 2>/dev/null; do sleep 3; done
  ( trap 'rmdir /tmp/viaform-azure.lock 2>/dev/null' EXIT INT TERM; python3 -I gen.py "$s" "$suf" )
done
