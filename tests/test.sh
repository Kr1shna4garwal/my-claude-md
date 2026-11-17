#!/usr/bin/env bash
# Tests for install.sh and the statusline. Every test runs against a
# throwaway HOME, so the real ~/.claude is never touched.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf '  pass  %s\n' "$1"
}
bad() {
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n' "$1"
}
check() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}
check_not() {
    local name="$1"
    shift
    if "$@" >/dev/null 2>&1; then bad "$name"; else ok "$name"; fi
}

# Run the installer with HOME pointed at a sandbox folder.
install_in() {
    local home="$1"
    shift
    env -u CLAUDE_CONFIG_DIR HOME="$home" bash "$ROOT/install.sh" --no-skills "$@"
}
backup_count() {
    find "$1/.claude/backups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '
}

echo "statusline"
out="$(jq --arg dir "$WORK" '.workspace.current_dir = $dir' "$ROOT/tests/fixtures/statusline-input.json" |
    bash "$ROOT/claude/hooks/statusline.sh" | sed $'s/\033\\[[0-9;]*m//g')"
check "shows the model" grep -qF "[Opus 4.8]" <<<"$out"
check "shows the folder" grep -qF "$(basename "$WORK")" <<<"$out"
check "shows context used" grep -qF "42%" <<<"$out"
# shellcheck disable=SC2016
check "shows cost" grep -qF '$1.23' <<<"$out"
check "shows session time" grep -qF "1h 2m" <<<"$out"
check "shows cache hit rate" grep -qF "↻90%" <<<"$out"
check "survives empty input" bash -c "echo '{}' | bash '$ROOT/claude/hooks/statusline.sh'"

echo "fresh install"
H="$WORK/fresh"
mkdir -p "$H"
check "installer exits 0" install_in "$H"
check "CLAUDE.md copied" cmp -s "$ROOT/claude/CLAUDE.md" "$H/.claude/CLAUDE.md"
check "statusline copied" cmp -s "$ROOT/claude/hooks/statusline.sh" "$H/.claude/hooks/statusline.sh"
check "statusline is executable" test -x "$H/.claude/hooks/statusline.sh"
check "settings has only statusLine" jq -e 'keys == ["statusLine"]' "$H/.claude/settings.json"
check "statusLine points at the hook" jq -e '.statusLine.command == "bash ~/.claude/hooks/statusline.sh"' "$H/.claude/settings.json"

echo "second run changes nothing"
before="$(backup_count "$H")"
sum_before="$(cat "$H/.claude/CLAUDE.md" "$H/.claude/settings.json" | cksum)"
install_in "$H" >/dev/null 2>&1
check "no new backup" test "$(backup_count "$H")" = "$before"
check "files unchanged" test "$(cat "$H/.claude/CLAUDE.md" "$H/.claude/settings.json" | cksum)" = "$sum_before"

echo "existing config"
H="$WORK/existing"
mkdir -p "$H/.claude"
echo "my own rules" >"$H/.claude/CLAUDE.md"
echo '{"model":"mine","statusLine":{"type":"command","command":"old.sh"},"env":{"KEEP":"1"}}' >"$H/.claude/settings.json"
cp "$H/.claude/CLAUDE.md" "$WORK/orig-CLAUDE.md"
cp "$H/.claude/settings.json" "$WORK/orig-settings.json"
check "installer exits 0" install_in "$H"
check "own model kept" jq -e '.model == "mine"' "$H/.claude/settings.json"
check "own env kept" jq -e '.env.KEEP == "1"' "$H/.claude/settings.json"
check "statusLine replaced" jq -e '.statusLine.command == "bash ~/.claude/hooks/statusline.sh"' "$H/.claude/settings.json"
B="$(find "$H/.claude/backups" -mindepth 1 -maxdepth 1 -type d | head -1)"
check "old CLAUDE.md in backup" cmp -s "$WORK/orig-CLAUDE.md" "$B/CLAUDE.md"
check "old settings in backup" cmp -s "$WORK/orig-settings.json" "$B/settings.json"

echo "uninstall"
check "uninstall exits 0" install_in "$H" --uninstall
check "CLAUDE.md restored" cmp -s "$WORK/orig-CLAUDE.md" "$H/.claude/CLAUDE.md"
check "settings restored" cmp -s "$WORK/orig-settings.json" "$H/.claude/settings.json"
check_not "statusline removed" test -e "$H/.claude/hooks/statusline.sh"
check_not "uninstall with no backup fails" install_in "$H" --uninstall

echo "--settings"
check "installer exits 0" install_in "$H" --settings
check "repo keys merged" jq -e '.permissions.defaultMode == "auto"' "$H/.claude/settings.json"
check "repo env merged" jq -e '.env.DISABLE_ERROR_REPORTING == "1"' "$H/.claude/settings.json"
check "own env still kept" jq -e '.env.KEEP == "1"' "$H/.claude/settings.json"

echo "--dry-run"
H="$WORK/dry"
mkdir -p "$H"
check "installer exits 0" install_in "$H" --dry-run
check_not "nothing written" test -e "$H/.claude"

echo "broken settings.json"
H="$WORK/broken"
mkdir -p "$H/.claude"
echo '{not json' >"$H/.claude/settings.json"
check "installer exits 0" install_in "$H"
check "broken file left untouched" test "$(cat "$H/.claude/settings.json")" = "{not json"

echo "CLAUDE_CONFIG_DIR"
H="$WORK/custom"
mkdir -p "$H"
check "installer exits 0" env HOME="$H" CLAUDE_CONFIG_DIR="$H/cfg" bash "$ROOT/install.sh" --no-skills
check "installed into the custom folder" test -f "$H/cfg/CLAUDE.md"
# shellcheck disable=SC2016
check "statusLine uses the custom folder" jq -e --arg c "bash \"$H/cfg/hooks/statusline.sh\"" '.statusLine.command == $c' "$H/cfg/settings.json"

echo "piped install (curl | bash)"
if command -v git >/dev/null 2>&1; then
    R="$WORK/remote"
    mkdir -p "$R"
    cp -R "$ROOT/claude" "$ROOT/install.sh" "$R/"
    (cd "$R" && git init -q && git add -A &&
        git -c user.name=test -c user.email=test@example.com commit -qm init) >/dev/null 2>&1
    H="$WORK/piped"
    mkdir -p "$H"
    check "installer exits 0" env -u CLAUDE_CONFIG_DIR HOME="$H" MY_CLAUDE_MD_REPO="file://$R" \
        bash -s -- --no-skills <"$ROOT/install.sh"
    check "CLAUDE.md copied" cmp -s "$ROOT/claude/CLAUDE.md" "$H/.claude/CLAUDE.md"
else
    echo "  skip  git not found"
fi

echo "repo hygiene"
check "settings.json is valid JSON" jq -e . "$ROOT/claude/settings.json"
check_not "no personal paths" grep -rIE "/(Users|home)/[A-Za-z0-9._-]+/" \
    "$ROOT/claude" "$ROOT/install.sh" "$ROOT/README.md"
check_not "unknown option is rejected" install_in "$WORK/fresh" --nope

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
