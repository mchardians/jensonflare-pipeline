#!/usr/bin/env bash

set -euo pipefail

APP_DIR="${1:?usage: remote-guard.sh <APP_DIR>}"
[ -d "$APP_DIR" ] || { echo "guard: APP_DIR does not exist: $APP_DIR" >&2; exit 1; }

case "${SSH_ORIGINAL_COMMAND:-}" in
  upload)
    release_dir="$APP_DIR/.release"
    mkdir -p "$release_dir"
    find "$release_dir" -mindepth 1 -delete
    staging_dir="$(mktemp -d)"; trap 'rm -rf "$staging_dir"' EXIT
    tar -x --no-same-owner -C "$staging_dir"
    if find "$staging_dir" -mindepth 1 \( -type d -o -type l \) | grep -q .; then
      echo "guard: bundle may only contain regular files" >&2; exit 1
    fi
    for file in "$staging_dir"/*; do
      case "$(basename "$file")" in
        deploy.sh|prune-images.sh|deploy.params|compose.base.yaml|docker-compose.override.yaml) ;;
        *) echo "guard: file not allowed: $(basename "$file")" >&2; exit 1 ;;
      esac
    done
    cp -p "$staging_dir"/* "$release_dir"/
    chmod +x "$release_dir"/*.sh
    echo "guard: bundle received ($(find "$release_dir" -type f | wc -l) files)"
    ;;
  run)
    [ -f "$APP_DIR/.release/deploy.sh" ] || { echo "guard: no bundle yet (run upload first)" >&2; exit 1; }
    exec bash "$APP_DIR/.release/deploy.sh"
    ;;
  *)
    echo "guard: command rejected" >&2; exit 1 ;;
esac