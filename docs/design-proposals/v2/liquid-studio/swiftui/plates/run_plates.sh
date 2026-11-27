#!/bin/zsh
# usage: ./run_plates.sh plate...   one locked Azure call per plate
cd "${0:A:h}"
for s in "$@"; do
  until mkdir /tmp/viaform-azure.lock 2>/dev/null; do sleep 3; done
  ( trap 'rmdir /tmp/viaform-azure.lock 2>/dev/null' EXIT INT TERM; python3 -I gen_plates.py "$s" )
done
