#!/usr/bin/env bash
set -euo pipefail

plugin_root=$(cd -- "$(dirname -- "$0")/.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

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
printf 'Bash %s: all checks passed\n' "$BASH_VERSION"
