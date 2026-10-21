#!/bin/sh
# Copy the agent CLIs into the directory named by the first argument, usually a
# volume mounted at /opt/symphony in both the init container and the app
# container. Idempotent, so it can run on every pod start.
set -eu

target="${1:-}"

if [ -z "$target" ]; then
  echo "usage: copy-agent-tools <target-dir>" >&2
  exit 64
fi

mkdir -p "$target"
cp -a /opt/symphony/. "$target"/
