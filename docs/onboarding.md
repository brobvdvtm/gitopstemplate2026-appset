# Onboarding a new application

> Who does this: the **application team**, in a single pull request against this
> repo. No ApplicationSet is edited, no AppProject is edited, nobody has to run
> `kubectl`.

Onboarding is entirely a matter of creating directories in the shape the
environment ApplicationSets already look for. See
[applicationsets.md](applicationsets.md) for why that works and
[appprojects.md](appprojects.md) for the policy that admits the result.

## Before you start

1. **Your team directory must have AppProjects.** Check that
   `projects/<team>/<env>.yaml` exists for every environment you intend to
   deploy to. If your team is new, a cluster admin has to add them — see
   *Onboarding a team* in [appprojects.md](appprojects.md). Without them your
   Applications are generated but refuse to sync.
2. **Pick a name that fits the namespace budget.** The namespace is
   `<env>-<team>-<app>`, capped at 63 characters; if you also want pull request
   previews it becomes `dev-<team>-<app>-pr-<n>` and `validate.sh` budgets six
   digits of PR counter. Short team and app names pay off.
3. **Have `kustomize` or `kubectl` on your PATH** so you can run
   `./scripts/validate.sh`.

## Step 1 — create the directories

```bash
team=devo
app=myapp
mkdir -p applications/$team/$app/{base,overlays/dev}
```

Start with `dev` only. Every other environment is added later by copying the
overlay — that is the promotion model.

## Step 2 — write the base

Environment-agnostic manifests plus a `kustomization.yaml`. Keep the image tag
here; overlays override it if they need to.

```yaml
# applications/devo/myapp/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

labels:
  - pairs:
      app.kubernetes.io/name: myapp

resources:
  - deployment.yaml
  - service.yaml

images:
  - name: ghcr.io/example/myapp
    newTag: 1.0.0
```

The Deployment and Service are ordinary manifests with **no `namespace:` field**
and no environment-specific values — see `applications/devo/podinfo/base/` for a
worked example with probes and resource requests.

## Step 3 — write the dev overlay

```yaml
# applications/devo/myapp/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# NOTE: do not set `namespace:` here.
# The namespace is owned by the ApplicationSet destination.

labels:
  - pairs:
      environment: dev
    includeSelectors: false      # keep selectors stable across environments
    includeTemplates: true       # label pods too

resources:
  - ../../base

replicas:
  - name: myapp
    count: 1
```

Two rules that are not optional:

- **Never set `namespace:` in an overlay.** The destination namespace is owned by
  the ApplicationSet. Setting it in kustomize as well lets the two drift apart
  silently, and if it drifts outside `<env>-<team>-*` the AppProject rejects the
  sync outright.
- **Never set `metadata.name` prefixes/suffixes that change per environment**
  unless you mean it — the Application name and namespace already carry the
  environment, so the resources inside do not need to.

Environment differences belong here: replica counts, resource requests, config
values, ingress hosts. `applications/devo/podinfo/overlays/` shows the pattern
with a JSON patch per environment.

## Step 4 — validate locally

```bash
./scripts/validate.sh
```

It renders every overlay in the repo, prints the namespace each will land in,
and fails on:

- an overlay that does not build,
- an overlay naming an environment that has no `applicationsets/<env>.yaml`
  (nothing would ever deploy it — silent otherwise),
- a team/environment pair with no `projects/<team>/<env>.yaml` (Applications that
  cannot sync),
- a malformed `preview.yaml`.

Expected output for a new dev-only app:

```
  ok    applications/devo/myapp/overlays/dev                 -> namespace dev-devo-myapp
```

## Step 5 — commit and open a pull request

Nothing else is required. On merge to `main`:

1. The `dev` ApplicationSet re-scans (≈3 minutes, or instantly on webhook) and
   sees the new `overlays/dev` directory.
2. It generates Application `dev-devo-myapp` in project `dev-devo`.
3. Argo CD creates namespace `dev-devo-myapp` (`CreateNamespace=true`) and syncs
   the rendered overlay with `prune` and `selfHeal` enabled.

| | |
| ----------- | ------------------------------- |
| Application | `dev-devo-myapp` |
| Namespace   | `dev-devo-myapp` |
| AppProject  | `dev-devo` |
| Source      | `applications/devo/myapp/overlays/dev` at `main` |
| Labels      | `team=devo`, `environment=dev`, `app.kubernetes.io/name=myapp` |

Watch it land:

```bash
kubectl get application -n argocd dev-devo-myapp
argocd app get dev-devo-myapp        # if you have the CLI
```

## Step 6 — promote through environments

Promotion is one directory per step. Copy the dev overlay, adjust it, validate,
commit:

```bash
cp -r applications/devo/myapp/overlays/dev applications/devo/myapp/overlays/integ
# edit environment label, replicas, config
./scripts/validate.sh
```

`integ` → `nonprod` → `prod` the same way. There is no enable flag and no list to
join: the `prod` ApplicationSet deploys exactly the applications that have a
`prod` overlay, so an app is in an environment if and only if the directory
exists. Check the AppProject exists for each environment before promoting
(step 0).

For prod specifically, confirm with your platform team whether prod syncs
automatically — `applicationsets/prod.yaml` currently runs `automated` with
`prune` and `selfHeal`, so a merge deploys straight to production.

## Optional — opt into pull request previews

Add one file next to `base/`:

```yaml
# applications/devo/myapp/preview.yaml
azureDevOpsProject: my-project     # Azure DevOps project holding the SOURCE code
azureDevOpsRepo: myapp             # repo whose pull requests trigger previews
image: ghcr.io/example/myapp       # image name to re-tag, as written in base/
```

The file's presence *is* the opt-in; delete it and previews stop. Team and
application stay positional in the path, so this file cannot claim a different
team.

Then make the build pipeline for that source repo:

1. build and push `<image>:<8-char short SHA>` of the PR head commit,
2. **then** add the `preview` label to the pull request.

Within 5 minutes you get `preview-devo-myapp-pr-42` in namespace
`dev-devo-myapp-pr-42`, running your **dev overlay** with the image re-tagged to
the PR's commit. Closing the PR or removing the label deletes the Application and
its namespace.

Requirements and caveats before you rely on it:

- `overlays/dev` must exist — previews render it, they do not ship their own.
- `image:` must match the image name exactly as written in `base/deployment.yaml`
  or kustomize silently matches nothing and you preview the base tag. Use
  `old-name=new-name` if previews are built into a different registry.
- Tag length must match your pipeline (`head_short_sha` is 8 chars; see
  [applicationsets.md](applicationsets.md#4-the-preview-applicationsets-lifecycle)).
- Values patched by the dev overlay are inherited as-is — only the image, the
  namespace and the `environment`/`pull-request` labels differ.
- No ResourceQuota is applied by default. Previews are unbounded.
- Run `./scripts/validate.sh`: a malformed `preview.yaml` breaks **every team's**
  previews, so it is a hard failure there.

## Offboarding

| Goal | Change |
| ---- | ------ |
| Remove from one environment | delete `applications/<team>/<app>/overlays/<env>` |
| Remove entirely | delete `applications/<team>/<app>/` |
| Stop previews only | delete `applications/<team>/<app>/preview.yaml` |

Deletion is not passive: the Application is deleted, and its
`resources-finalizer` prunes the workloads **and the namespace**. Make sure
anything stateful in there is backed up first.

## Checklist

- [ ] `projects/<team>/<env>.yaml` exists for every environment being added
- [ ] `base/` has no `namespace:` and no environment-specific values
- [ ] no overlay sets `namespace:`
- [ ] `<env>-<team>-<app>` (and `dev-<team>-<app>-pr-<n>` if previewing) fits in 63 chars
- [ ] `./scripts/validate.sh` passes
- [ ] previews only: pipeline pushes the image **before** it adds the `preview` label

## Troubleshooting

| Symptom | Likely cause |
| ------- | ------------ |
| No Application appears | overlay directory not at exactly `applications/<team>/<app>/overlays/<env>`; or the generator has not re-scanned yet (≈3 min) |
| Application exists, `project does not exist` | missing `projects/<team>/<env>.yaml` — needs a cluster admin |
| `destination is not permitted in project` | a `namespace:` in the overlay pushed it outside `<env>-<team>-*` |
| Deployed but empty namespace name mismatch | you set `namespace:` in kustomize; remove it |
| Manual `kubectl edit` keeps reverting | `selfHeal: true` — change git, not the cluster |
| Preview stuck `ImagePullBackOff` | label added before the image push, or tag length mismatch (`head_short_sha` vs `head_short_sha_7`) |
| Every team's previews vanished | one malformed `preview.yaml` failed the shared matrix generator |
