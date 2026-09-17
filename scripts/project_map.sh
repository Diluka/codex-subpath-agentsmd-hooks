#!/usr/bin/env bash
# Codex runs hooks in the session cwd and accepts plain-text SessionStart output.
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

command -v git >/dev/null || { echo 'Project documentation map requires Git' >&2; exit 1; }
if project_root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null && printf .); then
  # Preserve trailing newlines in directory names across command substitution.
  project_root=${project_root%$'\n.'}
else
  exit 0
fi
cd -- "$project_root"

# Isolate .ignore from repository and global rules without modifying the project.
ignore_root=$project_root
custom_ignore=false
if [[ -f .ignore && ! -L .ignore ]]; then
  custom_ignore=true
  ignore_root=$(mktemp -d)
  trap 'rm -rf -- "$ignore_root"' EXIT
  git -c init.templateDir= init -q "$ignore_root"
fi

# ponytail: one Git process per directory/document; batch if large trees hit the hook timeout.
is_ignored() {
  local status=0
  if $custom_ignore; then
    if [[ -d "$1" ]]; then
      mkdir -p -- "$ignore_root/$1"
    elif [[ "$1" == */* ]]; then
      mkdir -p -- "$ignore_root/${1%/*}"
    fi
    git -C "$ignore_root" -c core.excludesFile="$project_root/.ignore" check-ignore --no-index --quiet -- "$1" || status=$?
  else
    git check-ignore --no-index --quiet -- "$1" || status=$?
  fi
  if [[ $status -gt 1 ]]; then exit "$status"; fi
  return "$status"
}

shopt -s dotglob nullglob
scan() {
  local path relative
  [[ -r "$1" && -x "$1" ]] || { printf 'Cannot scan directory: %s\n' "$1" >&2; exit 1; }
  for path in "$1"/*; do
    [[ ! -L "$path" ]] || continue
    [[ ${path##*/} != .git ]] || continue
    relative=${path#./}
    if [[ -d "$path" ]]; then
      if is_ignored "$relative"; then continue; fi
      # Linked worktrees have a commondir file; submodules and ordinary repos do not.
      if [[ -f "$path/.git" ]] && (
        cd -- "$path"
        common_file=$(git rev-parse --git-path commondir 2>/dev/null) && [[ -f "$common_file" ]]
      ); then continue; fi
      scan "$path"
    elif [[ -f "$path" ]]; then
      case ${path##*/} in
        [Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd]|[Rr][Ee][Aa][Dd][Mm][Ee].[Mm][Dd])
          if ! is_ignored "$relative"; then printf '%q\n' "$relative"; fi ;;
      esac
    fi
  done
}

printf '%s\n' 'Project documentation map'
printf 'Project root: %q\n' "$project_root"
printf '%s\n' \
  'Before working in a directory, read the applicable AGENTS.md files from the root down' \
  'and relevant README.md files. Nested instructions apply within their directory scope.' \
  'Documentation paths (Bash-escaped):'

scan . | LC_ALL=C sort
