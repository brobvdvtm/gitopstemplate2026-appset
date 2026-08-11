#!/usr/bin/env bash
# Renders every application overlay and reports the namespace each one will
# land in, so convention breaks are caught before a commit reaches Argo CD.
#
# Layout under test:  applications/<team>/<app>/overlays/<env>
# Namespace produced: <env>-<team>-<app>
#
# Team and app are taken from the directory hierarchy here exactly as the
# ApplicationSet takes them from .path.segments, so the two cannot drift.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if command -v kustomize >/dev/null 2>&1; then
  build() { kustomize build "$1"; }
elif command -v kubectl >/dev/null 2>&1; then
  build() { kubectl kustomize "$1"; }
else
  echo "neither kustomize nor kubectl found in PATH" >&2
  exit 1
fi

failed=0
found=0
missing_project=0
missing_appset=0
seen_pairs=" "

while IFS= read -r overlay; do
  found=$((found + 1))
  # applications/<team>/<app>/overlays/<env>
  env="$(basename "$overlay")"
  app="$(basename "$(dirname "$(dirname "$overlay")")")"
  team="$(basename "$(dirname "$(dirname "$(dirname "$overlay")")")")"
  ns="${env}-${team}-${app}"

  if build "$overlay" >/dev/null; then
    printf '  ok    %-52s -> namespace %s\n' "$overlay" "$ns"
  else
    printf '  FAIL  %s\n' "$overlay"
    failed=$((failed + 1))
  fi

  # An overlay that names an environment with no ApplicationSet is simply never
  # deployed — silent, so call it out.
  if [ ! -f "applicationsets/${env}.yaml" ]; then
    printf '  WARN  %s -> no applicationsets/%s.yaml, nothing will deploy it\n' "$overlay" "$env"
    missing_appset=$((missing_appset + 1))
  fi

  # The env ApplicationSet templates `project: <env>-<team>`. That AppProject is
  # NOT generated, so a new team directory without one yields Applications that
  # fail to sync with "project does not exist".
  case "$seen_pairs" in
    *" ${team}/${env} "*) ;;
    *)
      seen_pairs="${seen_pairs}${team}/${env} "
      if [ ! -f "projects/${team}/${env}.yaml" ]; then
        printf '  WARN  team %s has a %s overlay but no projects/%s/%s.yaml (AppProject %s-%s)\n' \
          "$team" "$env" "$team" "$env" "$env" "$team"
        missing_project=$((missing_project + 1))
      fi
      ;;
  esac
done < <(find applications -mindepth 4 -maxdepth 4 -type d -path 'applications/*/*/overlays/*' | sort)

if [ "$found" -eq 0 ]; then
  echo "no overlays found under applications/*/*/overlays/*" >&2
  exit 1
fi

echo
if [ "$missing_appset" -gt 0 ]; then
  echo "$missing_appset overlay(s) target an environment with no ApplicationSet" >&2
fi
if [ "$missing_project" -gt 0 ]; then
  echo "$missing_project team/environment pair(s) are missing an AppProject" >&2
fi
if [ "$failed" -gt 0 ]; then
  echo "$failed of $found overlay(s) failed to build" >&2
  exit 1
fi
if [ "$missing_appset" -gt 0 ] || [ "$missing_project" -gt 0 ]; then
  exit 1
fi
echo "all $found overlay(s) built successfully"
