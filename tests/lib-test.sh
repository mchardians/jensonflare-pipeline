#!/usr/bin/env bash

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

passed=0; failed=0
pass() { echo "  ✔ $1"; passed=$((passed + 1)); }
fail() { echo "  ✘ $1"; failed=$((failed + 1)); }
check_file_exists() { if [ -f "$1" ]; then pass "$2"; else fail "$3"; fi; }

shopt -s nullglob
techStackFiles=(resources/techstacks/*.json)
[ "${#techStackFiles[@]}" -gt 0 ] || { echo "no tech stack files found"; exit 1; }

for techStackFile in "${techStackFiles[@]}"; do
  techStack="$(basename "$techStackFile" .json)"
  echo "[tech stack: $techStack]"

  if jq empty "$techStackFile" 2>/dev/null; then pass "techStack file is valid JSON"; else fail "techStack file is not valid JSON"; continue; fi

  for key in bakeResource bakeTarget imageServices pullServices securityServices; do
    if jq -e --arg key "$key" 'has($key) and .[$key] != null' "$techStackFile" >/dev/null; then
      pass "key '$key' is present"
    else
      fail "key '$key' is missing"
    fi
  done

  bake_file="resources/$(jq -r '.bakeResource' "$techStackFile")"
  check_file_exists "$bake_file" "bake file exists ($bake_file)" "bake file is missing ($bake_file)"

  compose_file="production/$techStack/docker-compose.yaml"
  check_file_exists "$compose_file" "compose template exists" "compose template is missing ($compose_file)"
  check_file_exists "production/$techStack/.env.prod.example" ".env.prod.example exists" ".env.prod.example is missing"

  for service in $(jq -r '.pullServices[]' "$techStackFile"); do
    if grep -qE "^  ${service}:\s*$" "$compose_file" 2>/dev/null; then
      pass "service '$service' is defined in compose"
    else
      fail "service '$service' is not defined in compose"
    fi
  done

  for service in $(jq -r '.imageServices[]' "$techStackFile"); do
    if grep -qE "^target \"${service}\"" "$bake_file" 2>/dev/null; then
      pass "bake target '$service' exists"
    else
      fail "bake target '$service' is missing"
    fi
  done
done

echo "[vars/ step names]"
for step_file in vars/*.groovy; do
  step_name="$(basename "$step_file" .groovy)"
  if [[ "$step_name" =~ ^[a-z][A-Za-z0-9]*$ ]]; then pass "$step_name is camelCase"; else fail "$step_name is not camelCase"; fi
  if grep -qE '^[A-Za-z<>]+ call\(' "$step_file"; then pass "$step_name defines call()"; else fail "$step_name does not define call()"; fi
done

echo
echo "RESULT: $passed passed, $failed failed"
[ "$failed" -eq 0 ]