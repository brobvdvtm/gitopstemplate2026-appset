# gitops-apps

Argo CD GitOps repository. Applications are defined once under
`applications/<team>/<app>/` with one overlay per environment, and each
environment has a **single** ApplicationSet that discovers and deploys the
overlays belonging to it, across every team.

## Documentation

| Document | Covers |
| -------- | ------ |
| [docs/applicationsets.md](docs/applicationsets.md) | The five ApplicationSets, the discovery glob, and their full lifecycle — bootstrap, re-scan loops, ownership, cascade deletion and orphaning, plus the preview matrix generator. |
| [docs/appprojects.md](docs/appprojects.md) | The policy plane owned by cluster admins: how an Application is bound to `<env>-<team>`, what the AppProject enforces, why projects are never generated, and how to tighten them. |
| [docs/onboarding.md](docs/onboarding.md) | Step-by-step onboarding of a new application by an application team, promotion between environments, preview opt-in, offboarding, and a checklist. |

The sections below are the quick reference; the documents above are the detail.

## Layout

```
applications/                      applications/<team>/<application>/
  devo/
    podinfo/
      base/                        environment-agnostic manifests
      preview.yaml                 opts into ephemeral PR environments
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
  preview.yaml                     ephemeral, one per open pull request

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

## Ephemeral pull request environments

`applicationsets/preview.yaml` gives every open pull request its own namespace,
running that branch's build. It is the one ApplicationSet whose output is not a
function of this repo alone — it is a **matrix** of (applications that opted in)
× (their open pull requests in Azure DevOps).

Opt an application in by adding one file next to its `base/`:

```yaml
# applications/devo/podinfo/preview.yaml
azureDevOpsProject: CHANGEME-project
azureDevOpsRepo: podinfo                  # repo holding the SOURCE CODE
image: ghcr.io/stefanprodan/podinfo       # image name to re-tag
```

Pull request 42 then produces:

| | |
| ------------- | ---------------------------------------- |
| Application   | `preview-devo-podinfo-pr-42`             |
| namespace     | `dev-devo-podinfo-pr-42`                 |
| AppProject    | `dev-devo`                               |
| manifests     | `applications/devo/podinfo/overlays/dev` at `main` |
| image         | `ghcr.io/stefanprodan/podinfo:<PR head short SHA>` |

Three deliberate reuses keep this cheap:

- **The dev overlay is rendered verbatim.** No ephemeral overlay is ever
  committed, so previews cannot leave dead directories behind and the four
  environment ApplicationSets are untouched. The image tag is overridden from
  the Application, not from git.
- **The dev AppProject is reused.** `projects/<team>/dev.yaml` already permits
  `dev-<team>-*`, which covers `dev-<team>-<app>-pr-<n>`, so previews need no
  AppProject and adding a team stays exactly as documented above. The tradeoff:
  Argo CD RBAC over `dev-<team>/*` also grants control over that team's previews.
- **Only `main` is ever a manifest source.** The pull request lives in the
  application's source repo and contributes exactly one thing: a commit SHA.

### What the build pipeline must do

The ApplicationSet is gated on a pull request **label**, and that gate is what
makes the whole thing work:

1. Build and push `<image>:<8-char short SHA>` for the PR head commit.
2. **Then** add the `preview` label to the pull request.

In that order, an Application is never generated for an image that does not
exist yet. Reverse it and the preview sits in `ImagePullBackOff` until the push
lands. If your pipeline tags with 7 characters or the full SHA, change
`head_short_sha` to `head_short_sha_7` or `head_sha` in the ApplicationSet — a
mismatch is not an error, it is an `ImagePullBackOff`.

### Things worth knowing

- **Polling only, ~5 minutes.** The pull request generator supports webhooks for
  GitHub and GitLab but not Azure DevOps, so `requeueAfterSeconds: 300` *is* the
  feedback loop. Lowering it multiplies API calls by the number of opted-in
  repositories against one PAT's rate limit.
- **Namespaces are pruned.** `CreateNamespace=true` alone leaves an untracked
  namespace behind on every closed PR; `managedNamespaceMetadata` makes the
  Namespace a managed resource so it is deleted with the Application.
- **`environment` is relabelled to `preview`.** The dev overlay stamps
  `environment=dev` on everything it renders; the Application's `commonLabels`
  overrides it so previews are not swept up by anything selecting on dev. A
  kustomize `patch` cannot do this — the `labels:` transformer runs after
  patches and stamps `dev` back over it.
- **Application-level values still say `dev`.** Anything the dev overlay patches
  into the manifests (for podinfo, `PODINFO_UI_MESSAGE: dev`) is inherited as-is.
  Only the image, the namespace and the labels differ.
- **No resource quota is applied.** Previews are unbounded until you add a
  ResourceQuota, either into the dev overlay (where it would also apply to real
  dev) or via `kustomize.patches` in `applicationsets/preview.yaml` only.

### Setup

Beyond the repo URL, `applicationsets/preview.yaml` has two extra placeholders
(`CHANGEME-org`, and `CHANGEME-project` in each `preview.yaml`), plus a token:

```bash
kubectl create secret generic azure-devops-pat -n argocd \
  --from-literal=token=<PAT with Code: Read on every opted-in repo>
```

## Local validation

```bash
./scripts/validate.sh
```

Renders every `applications/*/*/overlays/*` with kustomize (falling back to
`kubectl kustomize`), prints the namespace each overlay will land in, and fails
if an overlay names an environment that has no ApplicationSet or a
team/environment pair that has no AppProject.

It also checks every `applications/*/*/preview.yaml`: required keys present, an
`overlays/dev` to render, and a `dev-<team>-<app>-pr-<n>` namespace that stays
under 63 characters once the PR counter reaches six digits. These are hard
failures rather than warnings because `applicationsets/preview.yaml` runs with
`missingkey=error` across a single matrix generator spanning all teams — one
malformed `preview.yaml` fails the generator and takes *every* team's previews
with it, not just its own.

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
