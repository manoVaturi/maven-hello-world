# myapp — Containerized Java Hello World

A minimal Java 7/8 app acting as a playground for a production-ready CI/CD pipeline (Maven, GitHub Actions, Docker multi-stage, Helm/Kubernetes).

> **Heads up on Java 7/8:** This uses legacy Java to meet strict source code requirements. Since older JVMs are completely blind to Linux Cgroups, I had to manually inject memory flags into the Dockerfile. Without them, the JVM over-allocates RAM, and the Linux OOM Killer shoots the process on sight. Upgrading to Java 17/21+ is highly recommended to drop these hacks.

**Under the Hood:**

- **Multi-Stage BuildKit & Caching:** Uses Docker BuildKit's aggressive mount caching (--mount=type=cache) for Maven dependencies, completely bypassing redundant network I/O on rebuilds and isolating heavy compilation from the final image.

- **Distroless Runtime:** Zero OS overhead. No `/bin/sh`, no package managers. This kills OS-level CVEs and shrinks the attack surface.

- **VFS & Kernel-Level Security:** Bypasses Virtual File System text lookups by pinning the runtime directly to numeric IDs (USER 65532:65532). Inode ownership is rewritten on-the-fly (--chown=65532:65532) during the multi-stage copy to ensure strict, unprivileged isolation.

- **Trunk-Based CI/CD:** Fully automated GH Actions for change detection, version bumping, artifact packaging, Docker Hub pushes, container smoke testing, and a Helm/Kubernetes deploy.

- **SAST on Fetch:** Semgrep runs straight off checkout, before any build — no compile step required, cheapest possible failure point. Report-only for now (same posture as the Trivy scan below).

**Structure:**

```text
myapp/
  pom.xml
  src/
Dockerfile
helm/
  Chart.yaml
  values.yaml
  templates/
.github/workflows/

```

**Init project**

Fork, Clone repo:

GitHub:
settings -> brances -> add rule for "master"
require pull request before merging
require status checks to pass (build-test-and-scan)
do not allow force pushes

**Build and run locally**

```
cd myapp
mvn clean package
java -jar target/myapp-1.0.0.jar
```

**Docker (Multi-stage build)**

Build stage:
Used maven:3.9-eclipse-temurin-8 image for build, closest image i found for Java 7

Final stage:
Used gcr.io/distroless/java:8: Distoless

- With eclipse-temurin-8: Image size 444mb
- With gcr.io/distroless/java:8: Image size 188mb (Also have "nonroot" user already)

**CI, Stage 1**
Trunk-based development, master is protected.

PR -> master the gate. Compile, unit tests, image build, container smoke test and a Trivy scan run here. Nothing is published — the image never leaves the runner, no tag is created, nothing is deployed.

push -> master the release. Same steps, plus: publish to Docker Hub, pull it back, deploy with Helm, verify, tag the commit.

The `push` trigger only fires on `master` (not feature branches) — a feature branch commit only runs the `pull_request` pipeline. Feature branches used to also be matched by `push`, which meant every commit on an open PR ran the *entire* pipeline twice (once as `push`, once as `pull_request`), including a second Docker Hub publish and a second Helm deploy racing the first.

**Change detection**

A `changes` job (`dorny/paths-filter`) checks whether the push/PR actually touches `myapp/**` or `Dockerfile`. `docker-image-build` — and everything downstream of it (`docker-pull-run`, `helm-deploy`) — only runs when that's true. A commit that only touches the workflow, the Helm chart, or docs still runs `maven-build` (compile/test) for validation, but doesn't build/publish/deploy an image or bump the version.

To force a full run regardless (e.g. testing a CI/Helm-only change end to end), trigger the workflow manually via `workflow_dispatch` with the `force_run` input checked — `gh workflow run ci.yaml -f force_run=true`, or "Run workflow" in the Actions tab.

**Versioning**

Version is resolved from git tags at build time, not stored in `pom.xml` (pom stays `1.0.0` on purpose — the bump only happens inside the CI run). `maven-build` reads the last `vSERIES.*` tag and bumps the patch, stamping it into the pom for that build only. If no tag exists yet in the series, it starts at `SERIES.0`, not `.1` — a fresh repo (or one that's had its tags wiped, as this one was) produces `v1.0.0` first.

The git tag itself (`vX.Y.Z`) is created and pushed as the very last step of `docker-image-build`, after the image has built, smoke-tested, scanned, and actually pushed to Docker Hub — not right after the Maven build. That way a tag only ever exists for a version that genuinely shipped; if the Docker stage fails for any reason, no tag gets created for it (`contents: write` scoped to just that job). Combined with the change-detection gate above, a tag (and a new version) only ever gets created when the app actually changed.

Considered and skipped: committing the bumped pom back to master (bot commit on every push, drifts/conflicts), a third-party version-bump Action (low-trust maintainer, same commit-back problem), GitVersion (real tool, but overkill for a single-branch repo with no release/hotfix flow — revisit if that changes). Tags win here: no bot commits, no third-party trust, and tags don't retrigger the workflow.

**CI, Stage 2 — Docker image**

`docker-image-build` builds, smoke-tests, and Trivy-scans the image on every run where the change-detection gate passes (PR or push) — Trivy runs with `--exit-code 0` (report-only, never blocks the build). It also `docker save`s the built image and uploads it as a workflow artifact, so `helm-deploy` can load it directly instead of pulling it back from Docker Hub. The publish steps (Docker Hub login, push, and git tag) are separately guarded to only run on `push` to `master` or a manual `force_run` dispatch, so a PR build never publishes an image or creates a release tag, even though it still exercises the full build/scan/smoke-test path.

Branch ruleset requires the `maven-build` check by name — job id was renamed to match (`build` -> `maven-build`), which is also why `needs['maven-build']` uses bracket syntax instead of dot notation (a hyphen in a GH Actions expression reads as subtraction).

**CI, Stage 3 — Helm deploy**

`helm-deploy` only runs alongside a real publish (push to `master`, or a manual `force_run`/`tag` dispatch) — deploying only makes sense once an image actually exists.

The app is modeled in the chart as a Kubernetes `Job`, not a `Deployment`. It's genuinely one-shot — `ENTRYPOINT ["java", "-jar", "app.jar"]` prints and exits — and as a `Deployment` that meant a permanent restart loop (`restartPolicy: Always` restarts a container even on a clean `exit 0`, and it never settles into `Ready`). A `Job` (`restartPolicy: Never`, `backoffLimit: 2`) reaches a real `Complete` status instead. First attempt at fixing this tried keeping the Deployment and wiring a `command: sh -c "java -jar app.jar && sleep infinity"` override to fake a long-running process — that doesn't work at all, because `gcr.io/distroless/java:8` has no shell to run `sh -c` with. The chart carries no Service, ServiceAccount, Ingress, HTTPRoute, or autoscaling either — this app doesn't serve traffic, so none of that would be real.

What the job does, in order:
- **Lints and renders the chart** (`helm lint` + `helm template`) *before* the `kind` cluster even exists, so a broken chart fails fast without paying for cluster bootstrap.
- Creates the `kind` cluster, then creates a `dockerhub-secret` image-pull secret **idempotently** (`--dry-run=client | kubectl apply`, not a bare `create`) and wires it into the chart via `imagePullSecrets` — a fallback pull path, not the primary one.
- **Gets the image via a workflow artifact**, not another Docker Hub pull: `docker-image-build` `docker save`s the image it already built and uploads it; this job downloads and `docker load`s it. `docker-pull-run` still does a real Docker Hub pull earlier in the pipeline — that's the actual "did the publish work" check — so re-pulling here would just be slower, redundant internal plumbing.
- **Preloads the image into the cluster's node** with `kind load docker-image` (`imagePullPolicy: IfNotPresent`) instead of letting the cluster pull anything over the network — that network pull was slow and occasionally blew through Helm's `--wait --timeout`.
- Installs with `helm upgrade --install --wait --wait-for-jobs`. The `--wait-for-jobs` matters specifically: for a bare `Job`, plain `--wait` only waits for the object to be *created*, not for it to finish — without it, this step reported success while the pod was still `ContainerCreating`.
- **Verifies the deploy**: `kubectl wait --for=condition=complete` on the Job, then greps the pod's logs for the expected output. This has to live here rather than in a Helm test hook, because a hook pod running the same shell-less distroless image could only assert on its own exit code (which `--wait-for-jobs` already covers), not on log content.
- On failure, dumps job/pod status, `describe`, `kubectl get events`, and the pod's logs, so a failed run explains itself instead of reporting a bare timeout.

Also: `timeout-minutes: 10` at the job level (GH Actions defaults to 6 hours otherwise) and explicit `permissions: contents: read` (this job doesn't push tags, unlike `docker-image-build`). The chart sets a small `resources.requests` in `values.yaml` but deliberately no `limits` — this JVM isn't cgroup-aware (see the Java 7/8 note up top), so it sizes its default heap off host RAM rather than any container limit; a `limits.memory` here would likely trigger an immediate `OOMKilled` rather than act as a real cap.
