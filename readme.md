# myapp — Containerized Java Hello World

A minimal Java 7/8 app acting as a playground for a CI/CD pipeline (Maven, GitHub Actions, Docker multi-stage, Helm/Kubernetes).

> **Heads up on Java 7/8:** This uses legacy Java to meet strict source code requirements. Since older JVMs are completely blind to Linux cgroups, memory flags are injected manually in the Dockerfile. Without them, the JVM over-allocates RAM and the Linux OOM killer shoots the process on sight. Upgrading to Java 17/21+ would drop these hacks.

**Under the hood:**

- **Layer-cached Maven deps:** `pom.xml` is copied and `dependency:go-offline` runs *before* the source is copied, so dependency resolution is a separate, cacheable layer that only busts when `pom.xml` changes. Combined with buildx's `cache-from/cache-to: type=gha`, this survives across CI runs — but only with the `docker-container` buildx driver (`docker/setup-buildx-action`); the default `docker` driver can't export cache at all.

- **Distroless runtime:** zero OS overhead. No `/bin/sh`, no package manager. Kills OS-level CVEs and shrinks the attack surface.

- **Non-root by UID:** runtime pinned to `USER 65532:65532`, ownership rewritten on copy (`--chown=65532:65532`). The Helm chart's `securityContext` mirrors this exactly (`runAsUser/Group: 65532`, `readOnlyRootFilesystem: true`, all capabilities dropped) since distroless doesn't need a writable root FS.

- **SAST on fetch:** Semgrep runs straight off checkout, before any build. `--error` makes it a real gate — findings fail the job, not just report.

- **Helm/Kubernetes deploy:** a throwaway `kind` cluster is spun up on the runner and the app is deployed with Helm as an end-to-end integration check, not a real deployment target.

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

Fork, clone the repo. On GitHub: Settings → Branches → add a rule for `master` — require a pull request before merging, require the `maven-build` status check, disallow force pushes.

**Build and run locally**

```
cd myapp
mvn clean package
java -jar target/myapp-1.0.0.jar
```

**Docker (multi-stage build)**

Build stage: `maven:3.9-eclipse-temurin-8` — closest available image for Java 7/8.
Final stage: `gcr.io/distroless/java:8` — ships a non-root user already, ~188MB vs ~444MB for the full `eclipse-temurin-8` image.

## CI pipeline

Runs on `push` to **any** branch, and `workflow_dispatch`. No `pull_request` trigger — `push` already fires for every commit, PR or not, so a `pull_request` trigger would just re-run the exact same checks a second time for the same commit.

That has one real cost: a fork's commits never generate a `push` event on this repo, so a fork-submitted PR would get no checks at all. This is a solo repo with no outside contributors, so that's an acceptable trade, not an oversight — revisit if that changes.

**Validation jobs — `changes`, `static-analysis`, `chart-validation`, `maven-build`:**

These run on every push, including a WIP feature branch with no PR open yet — that's the point, you get feedback before you even open a PR, not just once it exists.

- `static-analysis` — hadolint on the Dockerfile, Semgrep SAST (`p/ci` ruleset, `--error` so findings fail the build).
- `chart-validation` — `helm lint --strict`, `helm template` against a placeholder image (the real one isn't built yet at this point), then `kubeconform` against the actual Kubernetes API schema.
- `changes` — `dorny/paths-filter` checks whether `myapp/**`, `Dockerfile`, or `.dockerignore` changed. Its output gates `docker-image-build` below.
- `maven-build` — compiles and runs unit tests, so a broken build fails fast on any branch. This is also the required branch-protection check (`Build, Test & Scan`, matching the job's `name:` field — the check name GitHub reports, not the YAML job id) — it's why `maven-build` deliberately never gates on `needs.changes.outputs.app`: a required check that's conditionally skipped never gets a second run to report success for that commit, so it'd block merging forever on any doc-only or chart-only change.

Earlier this repo tried both `push` and `pull_request` triggers together, with a same-repo-vs-fork guard to avoid double-running. That created two check-runs sharing the identical name `Build, Test & Scan` for one commit (one `success`, one `skipped`) — which GitHub's required-status-check matching resolved inconsistently, occasionally leaving a mergeable PR stuck on "Expected — waiting for status to be reported." Dropping `pull_request` removes the duplicate-name case at the source.

**Build + integration test — `docker-image-build`, `helm-deploy`:**

These run whenever app code actually changed (`needs.changes.outputs.app == 'true'`) — on a feature branch push before a PR even exists, on the PR, and again after merge to `master`. The point: master should never be broken by something a Docker build or a real Helm/Kubernetes deploy would have caught, so both run pre-merge, not just after.

**Publish path — `docker-image-publish`, `docker-pull-run`:**

Gated separately, on `event_name == 'push' && ref == 'refs/heads/master'` (a real merge) or `workflow_dispatch`. `docker-image-publish` needs `docker-image-build` *and* `helm-deploy` to have succeeded first — so even the master-push's own build+integration-test has to pass before anything gets pushed to Docker Hub or tagged. It reuses the image artifact `docker-image-build` already produced in the same workflow run rather than rebuilding, then pushes and creates the git tag. `docker-pull-run` does a separate real pull from Docker Hub afterward as the actual "did the publish work" check.

**Versioning**

Version is resolved from git tags at build time, not stored in `pom.xml` (pom stays `1.0.0` on purpose — the bump only happens inside the CI run). `maven-build` reads the last `vSERIES.*` tag and bumps the patch; if none exists yet in the series it starts at `SERIES.0`.

A manual `workflow_dispatch` run always uses a fixed `1.0.0` test version instead of bumping — it's meant for exercising the pipeline, not shipping a release — and skips the git-tag step entirely (tagging `v1.0.0` a second time would collide with itself).

The real git tag (`vX.Y.Z`) is only created as the last step of `docker-image-build`, after the image has built, smoke-tested, scanned, and actually pushed — so a tag only ever exists for a version that genuinely shipped.

**Docker image stage**

`docker-image-build` builds via buildx, smoke-tests the container (runs it, greps stdout for the expected message), Trivy-scans it (`--exit-code 0`, report-only — doesn't block), and `docker save`s it as a workflow artifact that both `helm-deploy` and (on master) `docker-image-publish` reuse. Publishing (Docker Hub login + push + git tag) lives entirely in `docker-image-publish`, so a PR build never pushes an image or creates a tag, even though it exercises the exact same build/scan path master will.

**Helm deploy stage**

The app is modeled as a Kubernetes `Job`, not a `Deployment` — it's genuinely one-shot (`ENTRYPOINT ["java", "-jar", "app.jar"]` prints and exits), and a `Deployment` would just restart it forever (`restartPolicy: Always` restarts even a clean `exit 0`, and it never reaches `Ready`). The chart carries no Service, Ingress, or autoscaling — this app doesn't serve traffic.

`helm-deploy`:
- Spins up a `kind` cluster on the runner.
- Downloads the image artifact `docker-image-build` already saved (not another Docker Hub pull — `docker-pull-run` already proved the registry copy works, so re-pulling here would just be slower, redundant plumbing) and `kind load docker-image`s it straight onto the cluster's node. `imagePullPolicy: IfNotPresent` means the pod uses that local copy without touching a registry.
- Installs with `helm upgrade --install --wait --wait-for-jobs`. `--wait-for-jobs` matters specifically: plain `--wait` only covers Deployments/StatefulSets/ReplicaSets — it does not wait for a bare `Job` to reach `Complete`, only for it to be created.
- Verifies by looking up the Job via label selector, `kubectl wait --for=condition=complete`, then grepping its logs for the expected output.
- On failure, a dedicated step dumps pod/job state, `describe`, events, and logs, so a failed run explains itself in the Action log instead of reporting a bare timeout.

`values.yaml` sets a small `resources.requests` but deliberately no `limits.memory` — this JVM isn't cgroup-aware by default (see the Java 7/8 note above), so a container memory limit risks a silent kernel OOM-kill that the JVM's own `-XX:+ExitOnOutOfMemoryError` can't catch (that only fires on a Java-heap OOM, not an external cgroup kill).
