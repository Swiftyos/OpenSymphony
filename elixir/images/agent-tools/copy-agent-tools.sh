#!/bin/sh
# Copy the agent CLIs (kept in /agent-tools) into the directory named by the
# first argument, usually a volume mounted at /opt/symphony in both the init
# container and the app container. Idempotent, so it can run on every pod start.
# It runs as the pod's non-root uid: `cp -R` writes the copies as that uid
# rather than trying to preserve the image's (root) ownership like `cp -a`.
set -eu

target="${1:-}"

if [ -z "$target" ]; then
  echo "usage: copy-agent-tools <target-dir>" >&2
  exit 64
fi

mkdir -p "$target"
cp -R /agent-tools/. "$target"/
