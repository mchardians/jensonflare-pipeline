#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$ROOT/resources/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$STUB_LOG"
case "$1" in
  login)  cat > "$STUB_LOG.logintoken"; exit 0 ;;
  logout) exit 0 ;;
  rmi)    exit 0 ;;
  inspect) [ -n "${STUB_STATES:-}" ] && printf '%s\n' $STUB_STATES; exit 0 ;;
  image)
    if [ "$2" = "ls" ]; then
      printf '%s\n' \
        '2026-10-03 22:00:05 +0700 WIB|v1.0.0-9-aaa' \
        '2026-10-03 21:00:05 +0700 WIB|v1.0.0-8-bbb' \
        '2026-10-03 20:00:05 +0700 WIB|v1.0.0-7-ccc' \
        '2026-10-02 20:00:05 +0700 WIB|v1.0.0-6-ddd' \
        '2026-10-01 20:00:05 +0700 WIB|v1.0.0-5-eee' \
        '2026-10-03 22:00:05 +0700 WIB|latest'
    fi
    exit 0 ;;
  compose)
    tag="$(grep -E '^IMAGE_TAG=' .release.env 2>/dev/null | cut -d= -f2-)"
    case " $* " in
      *" ps "*)               printf '%s\n' ${STUB_PS_IDS:-c1 c2}; exit 0 ;;
      *" pull "*)             [ -n "${FAIL_PULL:-}" ] && exit 1; exit 0 ;;
      *" exec "*)             [ -n "${FAIL_BACKUP:-}" ] && exit 1; printf -- '-- dump\n'; exit 0 ;;
      *" run "*)              [ -n "${FAIL_MIGRATE:-}" ] && exit 1; exit 0 ;;
      *" --remove-orphans "*) [ -n "${FAIL_UP_TAG:-}" ] && [ "$tag" = "$FAIL_UP_TAG" ] && exit 1; exit 0 ;;
      *) exit 0 ;;
    esac ;;
esac
exit 0
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
[ -n "${FAIL_HTTP:-}" ] && exit 22
exit 0
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/curl"

setup_scenario() {
  local dir="$TMP/$1"; rm -rf "$dir"; mkdir -p "$dir/.release"
  printf 'PROJECT_NAME=sipp\nDB_PASSWORD=secret\n' > "$dir/.env"
  [ -n "${2:-}" ] && printf 'IMAGE_TAG=%s\n' "$2" >> "$dir/.env"
  [ -n "${3:-}" ] && printf 'IMAGE_REGISTRY_PREFIX=ghcr.io/o/sipp\nIMAGE_TAG=%s\n' "$3" > "$dir/.release.env"
  cp "$SCRIPTS/deploy.sh" "$SCRIPTS/prune-images.sh" "$dir/.release/"
  echo 'services: {}' > "$dir/.release/compose.base.yaml"
  {
    echo "APP_DIR='$dir'"; echo "IMAGE='ghcr.io/o/sipp'"; echo "NEW_TAG='v1.0.0-10-fff'"
    echo "HEALTH_URL='${4:-}'"; echo "HEALTH_RETRIES='2'"; echo "HEALTH_INTERVAL='0'"
    echo "RECHECK_SECONDS='1'"; echo "RECHECK_INTERVAL='1'"
    [ -n "${EXTRA_PARAMS:-}" ] && printf '%s\n' "$EXTRA_PARAMS"
    [ -n "${5:-}" ] && echo "GHCR_USER='${5}'"
  } > "$dir/.release/deploy.params"
  STUB_LOG="$TMP/$1.log"; export STUB_LOG; : > "$STUB_LOG"
}

run_deploy() {
  local dir="$TMP/$1" exit_code
  if [ -n "${2:-}" ]; then
    printf '%s\n' "$2" | PATH="$TMP/bin:$PATH" bash "$dir/.release/deploy.sh" > "$TMP/$1.out" 2>&1; exit_code=$?
  else
    PATH="$TMP/bin:$PATH" bash "$dir/.release/deploy.sh" < /dev/null > "$TMP/$1.out" 2>&1; exit_code=$?
  fi
  echo "$exit_code"
}

release_tag_of() { { grep -E '^IMAGE_TAG=' "$TMP/$1/.release.env" 2>/dev/null || true; } | cut -d= -f2-; }
count_matches()  { { grep -c -- "$2" "$TMP/$1" 2>/dev/null || true; }; }
count_files()    { find "$1" -maxdepth 1 -type f -name "$2" 2>/dev/null | wc -l | tr -d ' '; }

passed=0; failed=0
assert_equal() {
  if [ "$2" = "$3" ]; then echo "  ✔ $1"; passed=$((passed + 1))
  else echo "  ✘ $1  (expected='$3' actual='$2')"; failed=$((failed + 1)); fi
}

echo "[1] first deploy (new server, no previous tag)"
setup_scenario s1; exit_code=$(run_deploy s1)
assert_equal "exit code is 0" "$exit_code" 0
assert_equal ".release.env holds the new tag" "$(release_tag_of s1)" v1.0.0-10-fff
assert_equal "up --remove-orphans runs exactly once" "$(count_matches s1.log --remove-orphans)" 1
assert_equal "pulls application images only" "$(count_matches s1.log 'pull nginx php-fpm queue')" 1
assert_equal "migration uses --no-deps" "$(count_matches s1.log 'run --rm --no-deps -T php-cli php artisan migrate --force')" 1
assert_equal ".env is unchanged" "$(md5sum < "$TMP/s1/.env")" "$(printf 'PROJECT_NAME=sipp\nDB_PASSWORD=secret\n' | md5sum)"

echo "[2] existing server: tag still in .env, no .release.env yet"
setup_scenario s2 v1.0.0-9-aaa; env_checksum_before="$(md5sum < "$TMP/s2/.env")"; exit_code=$(run_deploy s2)
assert_equal "exit code is 0" "$exit_code" 0
assert_equal ".release.env holds the new tag" "$(release_tag_of s2)" v1.0.0-10-fff
assert_equal "legacy .env is untouched" "$(md5sum < "$TMP/s2/.env")" "$env_checksum_before"

echo "[3] migration fails: old containers untouched, pointer restored"
setup_scenario s3 "" v1.0.0-9-aaa; exit_code=$(FAIL_MIGRATE=1 run_deploy s3)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "pointer is back on the old tag" "$(release_tag_of s3)" v1.0.0-9-aaa
assert_equal "no up --remove-orphans was run" "$(count_matches s3.log --remove-orphans)" 0

echo "[4] container replacement fails: automatic rollback to the previous tag"
setup_scenario s4 "" v1.0.0-9-aaa; exit_code=$(FAIL_UP_TAG=v1.0.0-10-fff run_deploy s4)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "pointer is the old tag" "$(release_tag_of s4)" v1.0.0-9-aaa
assert_equal "up runs twice (new tag, then rollback)" "$(count_matches s4.log --remove-orphans)" 2
assert_equal "log reports ROLLBACK SUCCEEDED" "$(count_matches s4.out 'ROLLBACK SUCCEEDED')" 1

echo "[5] HTTP check fails: rollback"
setup_scenario s5 "" v1.0.0-9-aaa http://x/up; exit_code=$(FAIL_HTTP=1 run_deploy s5)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "pointer is the old tag" "$(release_tag_of s5)" v1.0.0-9-aaa
assert_equal "curl is attempted twice (retry)" "$(count_matches s5.log '^curl')" 2

echo "[6] replacement fails on the FIRST deploy (no previous tag)"
setup_scenario s6; exit_code=$(FAIL_UP_TAG=v1.0.0-10-fff run_deploy s6)
assert_equal "exit code is 1 (no crash)" "$exit_code" 1
assert_equal "message says there is no previous tag" "$(count_matches s6.out 'No previous tag')" 1

echo "[7] pull fails: nothing changes"
setup_scenario s7 "" v1.0.0-9-aaa; exit_code=$(FAIL_PULL=1 run_deploy s7)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "pointer is the old tag" "$(release_tag_of s7)" v1.0.0-9-aaa
assert_equal "no migration was run" "$(count_matches s7.log ' run ')" 0

echo "[8] GHCR token via stdin: never leaked, automatic logout"
setup_scenario s8 "" "" "" ghuser; exit_code=$(run_deploy s8 "ghp_SECRET_TOKEN_123")
assert_equal "exit code is 0" "$exit_code" 0
assert_equal "login uses --password-stdin" "$(count_matches s8.log 'login ghcr.io -u ghuser --password-stdin')" 1
assert_equal "token reaches docker via stdin" "$(cat "$TMP/s8.log.logintoken" 2>/dev/null)" "ghp_SECRET_TOKEN_123"
assert_equal "token is absent from the call log" "$(count_matches s8.log 'ghp_SECRET')" 0
assert_equal "token is absent from the script output" "$(count_matches s8.out 'ghp_SECRET')" 0
assert_equal "logout is called" "$(count_matches s8.log 'docker logout ghcr.io')" 1

echo "[9] token requested but not sent: fails fast"
setup_scenario s9 "" "" "" ghuser; exit_code=$(run_deploy s9)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "no compose calls were made" "$(count_matches s9.log 'docker compose')" 0

echo "[10] prune: keep 3 newest, protect new/previous tags, never touch latest"
setup_scenario s10 "" v1.0.0-6-ddd; exit_code=$(run_deploy s10)
removed_tags="$(grep -o 'rmi ghcr.io/o/sipp-nginx:[^ ]*' "$TMP/s10.log" | sed 's/.*://' | tr '\n' ' ')"
assert_equal "nginx: only eee is removed (ddd is protected as the previous tag)" "$removed_tags" "v1.0.0-5-eee "
assert_equal "does not use 'system prune'" "$(count_matches s10.log 'system prune')" 0

echo "[11] two simultaneous deploys: the second is rejected (flock)"
setup_scenario s11; ( exec 9>"$TMP/s11/.deploy.lock"; flock -n 9; sleep 3 ) &
sleep 0.5; exit_code=$(run_deploy s11); wait
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "message says another deployment is running" "$(count_matches s11.out 'Another deployment is already running')" 1

echo "[12] up --wait fails but containers recover on recheck: NO rollback"
setup_scenario s12 "" v1.0.0-9-aaa; exit_code=$(FAIL_UP_TAG=v1.0.0-10-fff STUB_STATES="healthy running" run_deploy s12)
assert_equal "exit code is 0" "$exit_code" 0
assert_equal "pointer is the new tag" "$(release_tag_of s12)" v1.0.0-10-fff
assert_equal "up runs once (no rollback)" "$(count_matches s12.log --remove-orphans)" 1
assert_equal "log reports recovery" "$(count_matches s12.out 'Containers recovered')" 1

echo "[13] up --wait fails and containers stay unhealthy: rollback"
setup_scenario s13 "" v1.0.0-9-aaa; exit_code=$(FAIL_UP_TAG=v1.0.0-10-fff STUB_STATES="healthy unhealthy" run_deploy s13)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "pointer is the old tag" "$(release_tag_of s13)" v1.0.0-9-aaa
assert_equal "up runs twice (new tag, then rollback)" "$(count_matches s13.log --remove-orphans)" 2

echo "[14] generic parameters: another tech stack, no migration, custom services"
EXTRA_PARAMS=$'PULL_SERVICES=\'web worker\'\nMIGRATE_CMD=\'\'\nIMAGE_SERVICES=\'web worker\'' setup_scenario s14 "" v1.0.0-6-ddd; exit_code=$(run_deploy s14)
assert_equal "exit code is 0" "$exit_code" 0
assert_equal "pulls the services from params" "$(count_matches s14.log 'pull web worker')" 1
assert_equal "migration is skipped" "$(count_matches s14.log ' run ')" 0
assert_equal "prune uses the services from params" "$(grep -c 'sipp-web:' "$TMP/s14.log" || true)" 1

echo "[15] generic parameters: custom migration command on a custom service"
EXTRA_PARAMS=$'MIGRATE_SERVICE=\'app\'\nMIGRATE_CMD=\'bin/rails db:migrate\'' setup_scenario s15; exit_code=$(run_deploy s15)
assert_equal "exit code is 0" "$exit_code" 0
assert_equal "custom migration command is used" "$(count_matches s15.log 'run --rm --no-deps -T app bin/rails db:migrate')" 1

echo "[16] backup before migration: created, rotated, correct order"
EXTRA_PARAMS=$'BACKUP_SERVICE=\'mysql\'\nBACKUP_KEEP=\'2\'' setup_scenario s16 "" v1.0.0-9-aaa
mkdir -p "$TMP/s16/backups"
for n in 1 2 3; do echo x | gzip > "$TMP/s16/backups/old$n.sql.gz"; touch -d "2026-01-0$n" "$TMP/s16/backups/old$n.sql.gz"; done
exit_code=$(run_deploy s16)
assert_equal "exit code is 0" "$exit_code" 0
assert_equal "new backup file exists" "$(count_files "$TMP/s16/backups" 'v1.0.0-10-fff-*.sql.gz')" 1
assert_equal "backup content is valid" "$(gzip -dc "$TMP"/s16/backups/v1.0.0-10-fff-*.sql.gz)" "-- dump"
assert_equal "rotation keeps 2 files" "$(count_files "$TMP/s16/backups" '*.sql.gz')" 2
backup_line="$(grep -n -m1 ' exec ' "$TMP/s16.log" | cut -d: -f1)"
migrate_line="$(grep -n -m1 ' run ' "$TMP/s16.log" | cut -d: -f1)"
assert_equal "backup runs before migration" "$([ "$backup_line" -lt "$migrate_line" ] && echo yes)" yes

echo "[17] backup fails: migration and container replacement do NOT run"
EXTRA_PARAMS=$'BACKUP_SERVICE=\'mysql\'' setup_scenario s17 "" v1.0.0-9-aaa; exit_code=$(FAIL_BACKUP=1 run_deploy s17)
assert_equal "exit code is 1" "$exit_code" 1
assert_equal "pointer is the old tag" "$(release_tag_of s17)" v1.0.0-9-aaa
assert_equal "no migration was run" "$(count_matches s17.log ' run ')" 0
assert_equal "no up --remove-orphans was run" "$(count_matches s17.log --remove-orphans)" 0
assert_equal "no leftover backup files" "$(count_files "$TMP/s17/backups" '*')" 0

echo "[18] remote-guard: only 'upload' and 'run' are allowed; bundle is filtered"
guard_script="$SCRIPTS/remote-guard.sh"; guard_app_dir="$TMP/guard"; bundle_dir="$TMP/guard-bundle"
mkdir -p "$guard_app_dir" "$bundle_dir"
echo 'echo deploy-ran' > "$bundle_dir/deploy.sh"; echo "APP_DIR='$guard_app_dir'" > "$bundle_dir/deploy.params"
tar -C "$bundle_dir" -c . | SSH_ORIGINAL_COMMAND=upload bash "$guard_script" "$guard_app_dir" > /dev/null 2>&1; exit_code=$?
assert_equal "valid upload: exit code is 0" "$exit_code" 0
assert_equal "uploaded script is installed and executable" "$([ -x "$guard_app_dir/.release/deploy.sh" ] && echo yes)" yes
assert_equal "run executes deploy.sh" "$(SSH_ORIGINAL_COMMAND=run bash "$guard_script" "$guard_app_dir" </dev/null 2>&1)" deploy-ran
SSH_ORIGINAL_COMMAND="rm -rf /" bash "$guard_script" "$guard_app_dir" >/dev/null 2>&1; assert_equal "arbitrary command is rejected" "$?" 1
SSH_ORIGINAL_COMMAND="" bash "$guard_script" "$guard_app_dir" >/dev/null 2>&1; assert_equal "no command (interactive shell) is rejected" "$?" 1
echo x > "$bundle_dir/evil.sh"; tar -C "$bundle_dir" -c . | SSH_ORIGINAL_COMMAND=upload bash "$guard_script" "$guard_app_dir" >/dev/null 2>&1
assert_equal "file outside the allowlist is rejected" "$?" 1
rm "$bundle_dir/evil.sh"; mkdir "$bundle_dir/subdir"; tar -C "$bundle_dir" -c . | SSH_ORIGINAL_COMMAND=upload bash "$guard_script" "$guard_app_dir" >/dev/null 2>&1
assert_equal "subdirectory is rejected" "$?" 1

echo "[19] dependencies: default starts mysql; empty (static tech stack) starts nothing"
setup_scenario s19; exit_code=$(run_deploy s19)
assert_equal "default: mysql is started before migration" "$(count_matches s19.log 'up -d --wait --wait-timeout 180 mysql')" 1
EXTRA_PARAMS=$'DEPENDENCY_SERVICES=\'\'\nMIGRATE_CMD=\'\'\nPULL_SERVICES=\'nginx\'\nIMAGE_SERVICES=\'nginx\'' setup_scenario s20; exit_code=$(run_deploy s20)
assert_equal "static tech stack: exit code is 0" "$exit_code" 0
assert_equal "static tech stack: no dependency-only up" "$(count_matches s20.log 'wait-timeout 180 ')" 0
assert_equal "static tech stack: pulls nginx only" "$(count_matches s20.log 'pull nginx$')" 1
assert_equal "static tech stack: no migration" "$(count_matches s20.log ' run ')" 0
assert_equal "static tech stack: replacement runs once" "$(count_matches s20.log --remove-orphans)" 1

echo
echo "RESULT: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
