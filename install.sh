#!/usr/bin/env bash
# Install this Claude Code setup into ~/.claude (or $CLAUDE_CONFIG_DIR).
#
# Every file it replaces is copied to a backup folder first, and
# `install.sh --uninstall` puts those files back.

set -euo pipefail

REPO_URL="${MY_CLAUDE_MD_REPO:-https://github.com/kr1shna4garwal/my-claude-md.git}"
TARGET="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
BACKUP="$TARGET/backups/my-claude-md-$(date +%Y%m%d-%H%M%S)"

MODE=install
DRY_RUN=0
WITH_SETTINGS=0
WITH_SKILLS=1
CHANGED=0
SRC=""
TMP=""

usage() {
    cat <<'EOF'
Usage: install.sh [options]

Installs into ~/.claude (or $CLAUDE_CONFIG_DIR):
  CLAUDE.md             global instructions
  hooks/statusline.sh   two-line statusline
  settings.json         only the statusLine key is set, the rest is kept
  skills                caveman, caveman-commit, caveman-compress,
                        i-have-adhd, unlazy (through `npx skills`)

Options:
  --settings    also merge every key from claude/settings.json into yours.
                It turns on auto permission mode and forces claude.ai login,
                so read the file first.
  --no-skills   do not install the skills
  --dry-run     print what would change and change nothing
  --uninstall   put back the files saved by the most recent install
  -h, --help    show this help
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$TMP" ]; then
        rm -rf "$TMP"
    fi
}
trap cleanup EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --settings) WITH_SETTINGS=1 ;;
        --no-skills) WITH_SKILLS=0 ;;
        --dry-run) DRY_RUN=1 ;;
        --uninstall) MODE=uninstall ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "unknown option: $1"
            ;;
    esac
    shift
done

# Use the files next to this script. When the script is piped into bash
# there are none, so fetch the repo into a temp folder.
find_source() {
    local script="${BASH_SOURCE[0]:-}"
    local dir=""
    if [ -n "$script" ] && [ -f "$script" ]; then
        dir="$(cd "$(dirname "$script")" && pwd)"
    fi
    if [ -n "$dir" ] && [ -f "$dir/claude/CLAUDE.md" ]; then
        SRC="$dir"
        return
    fi
    command -v git >/dev/null 2>&1 || die "git is needed to download the setup"
    TMP="$(mktemp -d)"
    say "Downloading $REPO_URL"
    git clone --depth 1 --quiet "$REPO_URL" "$TMP/repo"
    SRC="$TMP/repo"
}

# Save the current copy of a file before it changes. A file that did not
# exist is recorded in .created so --uninstall can remove it again.
backup() {
    local rel="$1"
    mkdir -p "$BACKUP/$(dirname "$rel")"
    if [ -e "$TARGET/$rel" ]; then
        cp -p "$TARGET/$rel" "$BACKUP/$rel"
    else
        printf '%s\n' "$rel" >>"$BACKUP/.created"
    fi
}

install_file() {
    local src="$1" rel="$2" mode="$3"
    local dest="$TARGET/$rel"
    if [ -f "$dest" ] && cmp -s "$src" "$dest"; then
        say "  ok       $rel"
        return
    fi
    if [ -f "$dest" ]; then
        say "  replace  $rel"
    else
        say "  create   $rel"
    fi
    CHANGED=1
    if [ "$DRY_RUN" = 1 ]; then
        return
    fi
    backup "$rel"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    chmod "$mode" "$dest"
}

install_settings() {
    local rel="settings.json"
    local dest="$TARGET/$rel"
    local current="{}" new command keys

    if [ -f "$dest" ]; then
        if ! jq -e 'type == "object"' "$dest" >/dev/null 2>&1; then
            warn "$dest is not a JSON object. Left untouched: fix it and run again."
            return
        fi
        current="$(cat "$dest")"
    fi

    if [ "$TARGET" = "$HOME/.claude" ]; then
        command='bash ~/.claude/hooks/statusline.sh'
    else
        command="bash \"$TARGET/hooks/statusline.sh\""
    fi

    if [ "$WITH_SETTINGS" = 1 ]; then
        new="$(jq -n --argjson cur "$current" --slurpfile repo "$SRC/claude/settings.json" \
            --arg cmd "$command" \
            '$cur * $repo[0] | .statusLine = {type: "command", command: $cmd}')"
    else
        new="$(jq -n --argjson cur "$current" --arg cmd "$command" \
            '$cur | .statusLine = {type: "command", command: $cmd}')"
    fi

    keys="$(jq -rn --argjson a "$current" --argjson b "$new" \
        '[$b | keys[] | select($a[.] != $b[.])] | join(", ")')"
    if [ -f "$dest" ] && [ -z "$keys" ]; then
        say "  ok       $rel"
        return
    fi
    if [ -f "$dest" ]; then
        say "  update   $rel (keys: $keys)"
    else
        say "  create   $rel (keys: $keys)"
    fi
    CHANGED=1
    if [ "$DRY_RUN" = 1 ]; then
        return
    fi
    backup "$rel"
    mkdir -p "$TARGET"
    printf '%s\n' "$new" >"$dest.tmp"
    mv "$dest.tmp" "$dest"
}

# Skills come from their own repos, so they stay up to date with
# `npx skills update` and this repo does not carry copies of them.
install_skills() {
    local spec repo skill missing
    for spec in \
        "JuliusBrussee/caveman caveman caveman-commit caveman-compress" \
        "ayghri/i-have-adhd i-have-adhd" \
        "Leonxlnx/unlazy unlazy"; do
        # shellcheck disable=SC2086
        set -- $spec
        repo="$1"
        shift
        missing=0
        for skill in "$@"; do
            if [ ! -e "$TARGET/skills/$skill/SKILL.md" ]; then
                missing=1
            fi
        done
        if [ "$missing" = 0 ]; then
            say "  ok       skills: $*"
            continue
        fi
        say "  install  skills: $* (from $repo)"
        if [ "$DRY_RUN" = 1 ]; then
            continue
        fi
        if ! command -v npx >/dev/null 2>&1; then
            warn "npx not found. Install Node.js, then run: npx skills add $repo --skill $* --global --agent claude-code --yes"
            continue
        fi
        if ! npx --yes skills add "$repo" --skill "$@" --global --agent claude-code --yes </dev/null >/dev/null 2>&1; then
            warn "could not install $*. Run by hand: npx skills add $repo --skill $* --global --agent claude-code --yes"
        fi
    done
}

uninstall() {
    local latest="" dir rel
    for dir in "$TARGET"/backups/my-claude-md-*; do
        if [ -d "$dir" ]; then
            latest="$dir"
        fi
    done
    [ -n "$latest" ] || die "no backup found in $TARGET/backups"

    say "Restoring from $latest"
    if [ -f "$latest/.created" ]; then
        while IFS= read -r rel; do
            say "  remove   $rel"
            if [ "$DRY_RUN" = 0 ]; then
                rm -f "$TARGET/$rel"
            fi
        done <"$latest/.created"
    fi
    while IFS= read -r rel; do
        rel="${rel#./}"
        say "  restore  $rel"
        if [ "$DRY_RUN" = 0 ]; then
            mkdir -p "$TARGET/$(dirname "$rel")"
            cp -p "$latest/$rel" "$TARGET/$rel"
        fi
    done < <(cd "$latest" && find . -type f ! -name .created)
    if [ "$DRY_RUN" = 0 ]; then
        rm -rf "$latest"
    fi
    say "Done. Skills stay installed: remove one with 'npx skills remove <name> --global'."
}

if [ "$MODE" = uninstall ]; then
    uninstall
    exit 0
fi

command -v jq >/dev/null 2>&1 ||
    die "jq is needed (the statusline uses it). Install it: 'brew install jq' or 'sudo apt install jq'."

find_source

if [ "$DRY_RUN" = 1 ]; then
    say "Dry run: nothing will change in $TARGET"
else
    say "Installing into $TARGET"
fi

install_file "$SRC/claude/CLAUDE.md" "CLAUDE.md" 644
install_file "$SRC/claude/hooks/statusline.sh" "hooks/statusline.sh" 755
install_settings
if [ "$WITH_SKILLS" = 1 ]; then
    install_skills
fi

if [ "$DRY_RUN" = 1 ]; then
    exit 0
fi
if [ -d "$BACKUP" ]; then
    say "Old files saved in $BACKUP"
    say "Undo with: install.sh --uninstall"
fi
if [ "$CHANGED" = 1 ]; then
    say "Done. Start a new Claude Code session to pick up the changes."
else
    say "Already up to date."
fi
