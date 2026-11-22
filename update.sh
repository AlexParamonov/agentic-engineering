#!/usr/bin/env bash
# Update every repository under the given groups to its upstream tip.
# No arguments means every group except EXCLUDE. Only fast-forwards are applied;
# anything else is reported for a human to resolve.
set -uo pipefail

# Skipped by the no-argument sweep; naming a group explicitly overrides this.
EXCLUDE="mine harnesses/leak"

excluded() { case " $EXCLUDE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR" || exit 1

if [ "$#" -gt 0 ]; then
  groups=("$@")
  explicit=1
else
  groups=()
  for dir in */; do
    name="${dir%/}"
    excluded "$name" && continue
    groups+=("$name")
  done
  explicit=0
fi

for group in "${groups[@]}"; do
  [ -d "${group%/}" ] || { echo "ERROR: no such group folder: ${group%/}"; exit 1; }
done

logdir=$(mktemp -d) || exit 1
trap 'rm -rf "$logdir"' EXIT

update_repo() {
  local name="$1" before after
  # Untracked files cannot block a fast-forward; on a path collision git aborts.
  if [ -n "$(git -C "$name" status --porcelain --untracked-files=no)" ]; then
    echo "SKIPPED: uncommitted changes to tracked files, commit or stash them first"
    return 1
  fi
  before=$(git -C "$name" rev-parse --short HEAD)
  # Plain pull, never --refetch. -q keeps the output to one line per repository.
  if ! git -C "$name" pull --ff-only --quiet; then
    echo "FAILED: pull did not fast-forward, see git output above (auth, network or divergence)"
    return 1
  fi
  after=$(git -C "$name" rev-parse --short HEAD)
  if [ "$before" = "$after" ]; then
    echo "up to date ($after)"
  else
    echo "updated $before -> $after"
  fi
}

pending=()
for group in "${groups[@]}"; do
  group="${group%/}"
  found=0
  for dir in "$group"/*/; do
    [ -e "$dir/.git" ] || continue
    name="${dir%/}"
    found=1
    log="$logdir/${name//\//_}.log"
    if [ "$explicit" -eq 0 ] && excluded "$name"; then
      echo "EXCLUDED: listed in EXCLUDE, name its group to update it" > "$log"
      pending+=("$name|$log|")
      continue
    fi
    update_repo "$name" >"$log" 2>&1 &
    pending+=("$name|$log|$!")
  done
  if [ "$found" -eq 0 ]; then
    echo "no repositories yet" > "$logdir/empty-$group.log"
    pending+=("$group|$logdir/empty-$group.log|")
  fi
done

failed=0
for entry in "${pending[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*|}"
  log="${rest%%|*}"
  pid="${rest#*|}"
  if [ -n "$pid" ]; then
    wait "$pid" || failed=1
  fi
  printf '\n=== %s\n' "$name"
  cat "$log"
done

exit "$failed"
