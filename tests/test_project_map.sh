#!/usr/bin/env bash
set -euo pipefail

plugin_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'printf "Test fixtures retained: %s\n" "$fixture"' EXIT

assert_line() {
  if ! printf '%s\n' "$output" | grep -Fqx -- "$1"; then
    printf 'Missing map entry: %s\n%s\n' "$1" "$output" >&2
    exit 1
  fi
}

mkdir -p "$fixture/project/src" "$fixture/project/.hidden" \
  "$fixture/project/node_modules/pkg" "$fixture/project/.venv" \
  "$fixture/project/中文 space"
git init -q "$fixture/project"
printf 'node_modules/\n.venv/\n' > "$fixture/project/.gitignore"
for file in AGENTS.md README.md src/AGENTS.md .hidden/readme.md \
  node_modules/pkg/README.md .venv/AGENTS.md .git/README.md '中文 space/README.md'; do
  printf '%s\n' BODY_MUST_NOT_BE_INJECTED > "$fixture/project/$file"
done
ln -s src "$fixture/project/linked"
ln -s ../README.md "$fixture/project/src/README.md"
mkdir "$fixture/project/pipe"
mkfifo "$fixture/project/pipe/README.md"

output=$(cd "$fixture/project/src" && "$BASH" "$plugin_root/scripts/project_map.sh")
for path in AGENTS.md README.md src/AGENTS.md .hidden/readme.md; do
  assert_line "$path"
done
# Escaped whitespace stays on one line, including under macOS Bash 3.2.
[[ "$output" == *'space'*'/README.md'* ]]
if printf '%s\n' "$output" | grep -Eq 'BODY_MUST_NOT_BE_INJECTED|node_modules/|\.venv/|\.git/|linked/|pipe/|src/README.md'; then
  printf 'Unexpected content or excluded file in map\n%s\n' "$output" >&2
  exit 1
fi

mkdir "$fixture/project/new"
touch "$fixture/project/new/README.MD"
output=$(cd "$fixture/project/src" && "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line new/README.MD

mkdir "$fixture/empty"
output=$(cd "$fixture/empty" && "$BASH" "$plugin_root/scripts/project_map.sh")
[[ -z "$output" ]]
touch "$fixture/empty/README.md"
output=$(cd "$fixture/empty" && "$BASH" "$plugin_root/scripts/project_map.sh")
[[ -z "$output" ]]

for name in $'root\nname' $'root\n'; do
  mkdir -p "$fixture/$name/src"
  git init -q "$fixture/$name"
  touch "$fixture/$name/README.md"
  output=$(cd "$fixture/$name/src" && "$BASH" "$plugin_root/scripts/project_map.sh")
  assert_line README.md
done
# Git owns ignore matching, including nested, local, and configured excludes.
rules="$fixture/rules"
mkdir "$rules"
git init -q "$rules"
for path in tracked/README.md node_modules/README.md nested/README.md top/README.md \
  child/top/README.md tree/deep/README.md open/README.md closed/README.md '#hash/README.md' '#comment/README.md' \
  nested/hidden/README.md local/README.md global/README.md; do
  mkdir -p "$rules/${path%/*}"
  touch "$rules/$path"
done
git -C "$rules" add tracked/README.md
git init -q "$rules/nested"
touch "$rules/nested/.git/README.md"
printf '%s\n' 'tracked/' '#comment/' '/top/' 'tree/**' 'open/*' '!open/README.md' \
  'closed/' '!closed/README.md' '\#hash/' > "$rules/.gitignore"
printf 'hidden/\n' > "$rules/nested/.gitignore"
printf 'local/\n' > "$rules/.git/info/exclude"
printf 'global/\n' > "$fixture/global-ignore"
git -C "$rules" config core.excludesFile "$fixture/global-ignore"
output=$(cd "$rules" && "$BASH" "$plugin_root/scripts/project_map.sh")
for path in node_modules/README.md nested/README.md child/top/README.md open/README.md '#comment/README.md'; do
  assert_line "$(printf '%q' "$path")"
done
for path in tracked/README.md top/README.md tree/deep/README.md closed/README.md '#hash/README.md' \
  nested/hidden/README.md nested/.git/README.md local/README.md global/README.md; do
  if printf '%s\n' "$output" | grep -Fqx -- "$(printf '%q' "$path")"; then
    printf 'Unexpected ignored entry: %s\n' "$path" >&2; exit 1
  fi
done
printf 'node_modules/\n' >> "$rules/.gitignore"
# Excluded directories must be pruned before attempting to enumerate them.
chmod 000 "$rules/node_modules"
if output=$(cd "$rules" && "$BASH" "$plugin_root/scripts/project_map.sh"); then
  chmod 700 "$rules/node_modules"
else
  chmod 700 "$rules/node_modules"
  exit 1
fi
assert_line open/README.md
mkdir "$fixture/sentinel"
output=$(cd "$rules/tracked" && GIT_DIR="$fixture/sentinel" "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line open/README.md
[[ ! -e "$fixture/sentinel/config" && ! -e "$fixture/sentinel/HEAD" ]]
mkdir "$fixture/cleanup"
output=$(cd "$rules" && TMPDIR="$fixture/cleanup" "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line open/README.md
[[ -z "$(find "$fixture/cleanup" -mindepth 1 -print)" ]]
# .ignore is authoritative, including negation, tracked files, and empty rules.
printf '%s\n' 'node_modules/' 'tracked/' 'nested/hidden/' 'open/*' '!open/README.md' > "$rules/.ignore"
output=$(cd "$rules/tracked" && "$BASH" "$plugin_root/scripts/project_map.sh")
for path in top/README.md local/README.md global/README.md open/README.md; do
  assert_line "$path"
done
for path in tracked/README.md node_modules/README.md nested/hidden/README.md; do
  if printf '%s\n' "$output" | grep -Fqx -- "$path"; then
    printf 'Unexpected .ignore entry: %s\n' "$path" >&2; exit 1
  fi
done
: > "$rules/.ignore"
output=$(cd "$rules" && "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line tracked/README.md
assert_line node_modules/README.md
rm "$rules/.ignore"
output=$(cd "$rules" && "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line open/README.md
if printf '%s\n' "$output" | grep -Fqx 'tracked/README.md'; then exit 1; fi
# Linked worktrees are boundaries, regardless of names or ignore rules.
worktrees="$fixture/worktrees"
mkdir "$worktrees"
git init -q "$worktrees"
printf 'root document\n' > "$worktrees/README.md"
git -C "$worktrees" add README.md
git -C "$worktrees" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm fixture
git -C "$worktrees" worktree add -q --detach "$worktrees/custom checkout"
git -C "$worktrees" worktree add -q --detach "$fixture/external checkout"
touch "$fixture/external checkout/AGENTS.md"
mkdir "$worktrees/nested"
git init -q "$worktrees/nested"
touch "$worktrees/nested/AGENTS.md"
git -C "$worktrees/nested" add AGENTS.md
git -C "$worktrees/nested" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false commit -qm fixture
git -C "$worktrees/nested" worktree add -q --detach "$worktrees/nested/another checkout"
git init -q --separate-git-dir="$fixture/separate-metadata" "$worktrees/separate"
touch "$worktrees/separate/README.md"
for mode in defaults empty-ignore; do
  if [[ "$mode" == empty-ignore ]]; then : > "$worktrees/.ignore"; fi
  output=$(cd "$worktrees" && "$BASH" "$plugin_root/scripts/project_map.sh")
  assert_line README.md
  assert_line nested/AGENTS.md
  assert_line separate/README.md
  if printf '%s\n' "$output" | grep -Eq 'checkout|^AGENTS.md$'; then
    printf 'Other worktrees leaked into root map (%s)\n%s\n' "$mode" "$output" >&2
    exit 1
  fi
  for checkout in "$worktrees/custom checkout" "$fixture/external checkout"; do
    if [[ "$mode" == empty-ignore ]]; then : > "$checkout/.ignore"; fi
    output=$(cd "$checkout" && "$BASH" "$plugin_root/scripts/project_map.sh")
    assert_line README.md
    assert_line "Project root: $(printf '%q' "$checkout")"
  done
done
printf 'Bash %s: all checks passed\n' "$BASH_VERSION"
