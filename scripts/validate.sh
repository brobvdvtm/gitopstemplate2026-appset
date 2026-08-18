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

# ---------------------------------------------------------------------------
# Ephemeral pull request previews.
#
# applications/<team>/<app>/preview.yaml opts an application into
# applicationsets/preview.yaml, which renders the app's dev overlay into
# dev-<team>-<app>-pr-<number> with the image re-tagged to the PR's commit.
#
# These are FAILURES, not warnings, and the blast radius is why: the preview
# ApplicationSet runs with missingkey=error and one matrix generator spanning
# every team, so a single malformed preview.yaml does not just break its own
# application — it fails the generator and takes every other team's previews
# down with it.
# ---------------------------------------------------------------------------
preview_found=0
preview_bad=0

while IFS= read -r manifest; do
  preview_found=$((preview_found + 1))
  app_dir="$(dirname "$manifest")"
  app="$(basename "$app_dir")"
  team="$(basename "$(dirname "$app_dir")")"
  this_bad=0

  # Keys consumed by applicationsets/preview.yaml. Matched loosely on purpose:
  # this only proves the key is present and non-empty, which is exactly the
  # class of mistake missingkey=error turns into an outage.
  for key in azureDevOpsProject azureDevOpsRepo image; do
    if ! grep -Eq "^${key}:[[:space:]]*[^[:space:]#]" "$manifest"; then
      printf '  FAIL  %s -> missing or empty required key `%s`\n' "$manifest" "$key"
      this_bad=$((this_bad + 1))
    fi
  done

  # Previews render the dev overlay rather than an overlay of their own, so an
  # opted-in application without one generates Applications that cannot sync.
  if [ ! -d "${app_dir}/overlays/dev" ]; then
    printf '  FAIL  %s -> no overlays/dev; previews render the dev overlay\n' "$manifest"
    this_bad=$((this_bad + 1))
  fi

  # A namespace is capped at 63 characters, and unlike the fixed
  # <env>-<team>-<app> names this one grows with the PR counter. Budget six
  # digits so the failure lands here at review time rather than months from now
  # when the counter rolls over to five figures and previews silently stop.
  ns_prefix="dev-${team}-${app}-pr-"
  ns_worst=$(( ${#ns_prefix} + 6 ))
  if [ "$ns_worst" -gt 63 ]; then
    printf '  FAIL  %s -> namespace %s<n> reaches %d chars, over the 63 limit\n' \
      "$manifest" "$ns_prefix" "$ns_worst"
    this_bad=$((this_bad + 1))
  fi

  if [ "$this_bad" -eq 0 ]; then
    printf '  ok    %-52s -> namespace %s<n>\n' "$manifest" "$ns_prefix"
  fi
  preview_bad=$((preview_bad + this_bad))
done < <(find applications -mindepth 3 -maxdepth 3 -type f -path 'applications/*/*/preview.yaml' | sort)

# Same class of silent no-op as an overlay with no ApplicationSet: the opt-in
# file is there, and nothing consumes it.
if [ "$preview_found" -gt 0 ] && [ ! -f applicationsets/preview.yaml ]; then
  printf '  WARN  %d preview.yaml file(s) but no applicationsets/preview.yaml\n' "$preview_found"
  preview_bad=$((preview_bad + 1))
fi

echo
if [ "$missing_appset" -gt 0 ]; then
  echo "$missing_appset overlay(s) target an environment with no ApplicationSet" >&2
fi
if [ "$missing_project" -gt 0 ]; then
  echo "$missing_project team/environment pair(s) are missing an AppProject" >&2
fi
if [ "$preview_bad" -gt 0 ]; then
  echo "$preview_bad problem(s) in preview.yaml opt-in file(s)" >&2
fi
if [ "$failed" -gt 0 ]; then
  echo "$failed of $found overlay(s) failed to build" >&2
  exit 1
fi
if [ "$missing_appset" -gt 0 ] || [ "$missing_project" -gt 0 ] || [ "$preview_bad" -gt 0 ]; then
  exit 1
fi
echo "all $found overlay(s) built successfully, $preview_found preview opt-in(s) valid"
