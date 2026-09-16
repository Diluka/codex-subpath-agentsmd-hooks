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
[[ "$output" == *'Project documentation map'* ]]
touch "$fixture/empty/README.md"
output=$(cd "$fixture/empty" && "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line README.md

for name in $'root\nname' $'root\n'; do
  mkdir -p "$fixture/$name/src"
  git init -q "$fixture/$name"
  touch "$fixture/$name/README.md"
  output=$(cd "$fixture/$name/src" && "$BASH" "$plugin_root/scripts/project_map.sh")
  assert_line README.md
done
# Selected ignore rules replace, rather than merge with, the other sources.
rules="$fixture/rules"
mkdir "$rules"
git init -q "$rules"
for path in tracked/README.md node_modules/README.md nested/README.md top/README.md \
  child/top/README.md tree/deep/README.md open/README.md closed/README.md '#hash/README.md' '#comment/README.md'; do
  mkdir -p "$rules/${path%/*}"
  touch "$rules/$path"
done
git -C "$rules" add tracked/README.md
git init -q "$rules/nested"
printf 'tracked/\n' > "$rules/.gitignore"
printf '%s\n' '#comment/' '/top/' 'tree/**' 'open/*' '!open/README.md' \
  'closed/' '!closed/README.md' '\#hash/' > "$rules/.ignore"
for stage in selected empty git default; do
  case "$stage" in
    empty) : > "$rules/.ignore" ;;
    git) rm "$rules/.ignore" ;;
    default) rm "$rules/.gitignore" ;;
  esac
  output=$(cd "$rules" && "$BASH" "$plugin_root/scripts/project_map.sh")
  for path in tracked/README.md node_modules/README.md nested/README.md top/README.md \
    child/top/README.md tree/deep/README.md open/README.md closed/README.md '#hash/README.md' '#comment/README.md'; do
    excluded=false
    case "$stage:$path" in
      selected:top/*|selected:tree/*|selected:closed/*|selected:\#hash/*|git:tracked/*|default:node_modules/*) excluded=true ;;
    esac
    escaped=$(printf '%q' "$path")
    if $excluded; then
      if printf '%s\n' "$output" | grep -Fqx -- "$escaped"; then
        printf 'Unexpected entry (%s): %s\n' "$stage" "$path" >&2; exit 1
      fi
    else
      assert_line "$escaped"
    fi
  done
done
# Excluded directories must be pruned before attempting to enumerate them.
chmod 000 "$rules/node_modules"
if output=$(cd "$rules" && "$BASH" "$plugin_root/scripts/project_map.sh"); then
  chmod 700 "$rules/node_modules"
else
  chmod 700 "$rules/node_modules"
  exit 1
fi
assert_line tracked/README.md
mkdir "$fixture/sentinel"
output=$(cd "$rules/tracked" && GIT_DIR="$fixture/sentinel" "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line tracked/README.md
[[ ! -e "$fixture/sentinel/config" && ! -e "$fixture/sentinel/HEAD" ]]
mkdir "$fixture/cleanup"
output=$(cd "$rules" && TMPDIR="$fixture/cleanup" "$BASH" "$plugin_root/scripts/project_map.sh")
assert_line tracked/README.md
kept=("$fixture/cleanup"/*)
[[ ${#kept[@]} -eq 1 && ${kept[0]##*/} =~ ^project-map-ignore-[0-9a-f]{64}$ ]]
# Concurrent sessions reuse the hash directory, but never share Git locks or trees.
(cd "$rules" && TMPDIR="$fixture/cleanup" "$BASH" "$plugin_root/scripts/project_map.sh" > "$fixture/first-map") &
first_pid=$!
(cd "$rules/tracked" && TMPDIR="$fixture/cleanup" "$BASH" "$plugin_root/scripts/project_map.sh" > "$fixture/second-map") &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
runs=("${kept[0]}"/run.*)
[[ ${#runs[@]} -eq 3 ]]
for run in "${runs[@]}"; do [[ -f "$run/meta/HEAD" ]]; done
output=$(cd "$fixture/empty" && TMPDIR="$fixture/cleanup" "$BASH" "$plugin_root/scripts/project_map.sh")
kept=("$fixture/cleanup"/*)
[[ ${#kept[@]} -eq 2 ]]
printf 'Bash %s: all checks passed\n' "$BASH_VERSION"
