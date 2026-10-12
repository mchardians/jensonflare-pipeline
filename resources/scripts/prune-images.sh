#!/usr/bin/env bash

set -euo pipefail

usage="usage: prune-images.sh <image-prefix> <keep> [protected-tag...]"
prefix="${1:?$usage}"
keep="${2:?$usage}"
shift 2
protected=" $* "

for service in ${IMAGE_SERVICES:-nginx php-fpm php-cli}; do
  repository="${prefix}-${service}"
  docker image ls "$repository" --format '{{.CreatedAt}}|{{.Tag}}' \
    | sort -r \
    | awk -F'|' '$2 != "latest" && $2 != "<none>" && $2 != "" { print $2 }' \
    | tail -n +"$((keep + 1))" \
    | while IFS= read -r tag; do
        case "$protected" in *" $tag "*) continue ;; esac
        docker rmi "${repository}:${tag}" >/dev/null 2>&1 || true
      done
done

docker image prune -f >/dev/null