# gitops-apps

Argo CD GitOps repository. Applications are defined once under
`applications/<team>/<app>/` with one overlay per environment, and each
environment has a **single** ApplicationSet that discovers and deploys the
overlays belonging to it, across every team.

## Layout

```
applications/                      applications/<team>/<application>/
  devo/
    podinfo/
      base/                        environment-agnostic manifests
      overlays/
        dev/                       deployed by applicationsets/dev.yaml
        integ/                     deployed by applicationsets/integ.yaml
        nonprod/                   deployed by applicationsets/nonprod.yaml
        prod/                      deployed by applicationsets/prod.yaml
  devfront/
    whoami/
      base/
      overlays/
        dev/                       whoami has no integ/nonprod overlay,
        prod/                      so those ApplicationSets ignore it

applicationsets/                   one ApplicationSet per environment,
  dev.yaml  integ.yaml             spanning all teams
  nonprod.yaml  prod.yaml

projects/                          one AppProject per team per environment
  devo/     dev.yaml  integ.yaml  nonprod.yaml  prod.yaml
  devfront/ dev.yaml  integ.yaml  nonprod.yaml  prod.yaml

bootstrap/root.yaml                app-of-apps that manages the two above
scripts/validate.sh                renders every overlay locally
```

## How the scoping works

Each ApplicationSet uses a git **directory generator** with a path glob pinned
to its own environment, with wildcards at the team and application levels:

```yaml
directories:
  - path: applications/*/*/overlays/prod
```

That glob is the whole mechanism. A `*` never matches a `/`, so the pattern
matches exactly five path segments and can only ever land on a directory
literally named `prod` two levels below `applications/`. `applicationsets/prod.yaml`
therefore deploys exactly the prod overlays of every team and nothing else.
Adding `applications/<team>/foo/overlays/prod` enrols `foo` in prod on the next
repo scan; deleting the directory removes the Application. An application with
no `prod` overlay is invisible to the prod ApplicationSet — that's how `whoami`
above ends up in dev and prod only.

Adding a whole new **team** directory needs no ApplicationSet change at all; it
does need AppProjects (see below).

## Namespace convention

Every Application is deployed to `[environment]-[team]-[application]`:

| overlay path                                    | Application            | namespace              |
| ----------------------------------------------- | ---------------------- | ---------------------- |
| `applications/devo/podinfo/overlays/prod`        | `prod-devo-podinfo`    | `prod-devo-podinfo`    |
| `applications/devo/podinfo/overlays/dev`         | `dev-devo-podinfo`     | `dev-devo-podinfo`     |
| `applications/devfront/whoami/overlays/prod`     | `prod-devfront-whoami` | `prod-devfront-whoami` |

The generator exposes the matched path as segments — for
`applications/devo/podinfo/overlays/prod` that is
`[applications, devo, podinfo, overlays, prod]` — so the template reads the
**team out of index 1 and the application out of index 2**:

```yaml
namespace: 'prod-{{ index .path.segments 1 }}-{{ index .path.segments 2 }}'
```

Both are derived positionally from the directory hierarchy. Nothing is read out
of the overlay's own manifests, so an application cannot claim a different team
by editing its YAML — it can only change team by moving directory.

`CreateNamespace=true` means Argo CD creates the namespace on first sync.

Three things enforce the convention rather than merely following it:

- The ApplicationSet templates `project: <env>-{{ index .path.segments 1 }}`,
  so each Application lands in its own team's AppProject.
- That AppProject restricts `destinations` to `<env>-<team>-*`, so a prod devo
  Application physically cannot sync anywhere but a `prod-devo-*` namespace —
  not even into another team's namespace, even though one ApplicationSet now
  spans every team.
- Overlays deliberately **do not** set `namespace:` in their `kustomization.yaml`.
  The destination namespace is owned by the ApplicationSet; setting it in
  kustomize too would let the two drift apart silently.

## Bootstrap

1. Point the repo URL at your own remote (it is a placeholder across
   `applicationsets/`, `projects/` and `bootstrap/`):

   ```bash
   grep -rl 'github.com/CHANGEME/gitops-apps.git' . \
     | xargs sed -i 's#https://github.com/CHANGEME/gitops-apps.git#<your-repo-url>#'
   ```

   Also check `targetRevision: main` and the `https://kubernetes.default.svc`
   destination if you deploy to remote clusters.

2. Commit and push, then apply the app-of-apps once:

   ```bash
   kubectl apply -f bootstrap/root.yaml
   ```

   It syncs `projects/` (sync-wave -1, `recurse: true` because projects are
   grouped in per-team subdirectories) then `applicationsets/` (wave 0), and
   from that point on both directories are managed by Argo CD itself. This
   requires the ApplicationSet controller, which ships with Argo CD 2.3+.

## Adding an application

```bash
mkdir -p applications/<team>/myapp/{base,overlays/dev}
# write base manifests + base/kustomization.yaml
# write overlays/dev/kustomization.yaml with `resources: [../../base]`
./scripts/validate.sh
```

Commit. The dev ApplicationSet picks it up and creates `dev-<team>-myapp` in
namespace `dev-<team>-myapp`. Promote it by adding `overlays/integ`,
`overlays/nonprod`, `overlays/prod` as it moves through your pipeline.

## Adding a team

Create `applications/<team>/` and, in the same commit, an AppProject per
environment under `projects/<team>/`. Copy any existing `projects/*/prod.yaml`
and replace the team name in `metadata.name`, the description, and the
`destinations` pattern.

The AppProjects are **not** generated, so this step is not optional: the
environment ApplicationSet will discover the new team's overlays immediately and
template `project: <env>-<team>`, and any Application whose project does not
exist fails to sync with *"application referencing project ... which does not
exist"*. `scripts/validate.sh` fails the build on a team/environment pair that
is missing its AppProject, so this is caught before the commit lands.

## Adding an environment

Copy any file in `applicationsets/`, replacing the environment name in the
generator glob, the ApplicationSet name, the labels, the templated project, and
the namespace prefix. Then add a `projects/<team>/<env>.yaml` for each team.

## Local validation

```bash
./scripts/validate.sh
```

Renders every `applications/*/*/overlays/*` with kustomize (falling back to
`kubectl kustomize`), prints the namespace each overlay will land in, and fails
if an overlay names an environment that has no ApplicationSet or a
team/environment pair that has no AppProject.

## Sync policy

All four environments currently run automated sync with `prune` and `selfHeal`.
If you want production changes gated behind a manual approval, drop the
`automated:` block from `applicationsets/prod.yaml`; the Applications will still
be generated, they just wait for an explicit sync.

## Migrating from the per-team ApplicationSets

Earlier revisions had one ApplicationSet per team **and** environment
(`applicationsets/<team>/<env>.yaml`, named `<env>-<team>`). The consolidation
generates byte-identical Applications — same names, namespaces and projects —
but ownership moves from `prod-devo` to `prod`.

Generated Applications carry an `ownerReference` to their ApplicationSet, so
letting Argo CD prune the old ApplicationSets would cascade-delete the
Applications and, through their `resources-finalizer`, the running workloads.
Orphan the old ones by hand **before** pushing the commit that removes them:

```bash
kubectl delete applicationset -n argocd \
  dev-devo integ-devo nonprod-devo prod-devo \
  dev-devfront prod-devfront --cascade=orphan
```

The Applications survive; the new per-environment ApplicationSets then adopt
them by name on the next scan and reclaim the `ownerReference`.
