#!/bin/zsh
# Serialise Azure image calls across agents.
until mkdir /tmp/viaform-azure.lock 2>/dev/null; do sleep 3; done
trap 'rmdir /tmp/viaform-azure.lock 2>/dev/null' EXIT INT TERM
python3 "${0:A:h}/gen.py" "$@"
