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

Version is resolved from git tags at build time, not stored in `pom.xml` (pom stays `1.0.0` on purpose — the bump only happens inside the CI run). `maven-build` reads the last `vSERIES.*` tag and bumps the patch, stamping it into the pom for that build only.

The git tag itself (`vX.Y.Z`) is created and pushed as the very last step of `docker-image-build`, after the image has built, smoke-tested, scanned, and actually pushed to Docker Hub — not right after the Maven build. That way a tag only ever exists for a version that genuinely shipped; if the Docker stage fails for any reason, no tag gets created for it (`contents: write` scoped to just that job). Combined with the change-detection gate above, a tag (and a new version) only ever gets created when the app actually changed.

Considered and skipped: committing the bumped pom back to master (bot commit on every push, drifts/conflicts), a third-party version-bump Action (low-trust maintainer, same commit-back problem), GitVersion (real tool, but overkill for a single-branch repo with no release/hotfix flow — revisit if that changes). Tags win here: no bot commits, no third-party trust, and tags don't retrigger the workflow.

**CI, Stage 2 — Docker image**

`docker-image-build` builds, smoke-tests, and Trivy-scans the image on every run where the change-detection gate passes (PR or push) — Trivy runs with `--exit-code 0` (report-only, never blocks the build). The publish steps (Docker Hub login, push, and git tag) are separately guarded to only run on `push` to `master` or a manual `force_run` dispatch, so a PR build never publishes an image or creates a release tag, even though it still exercises the full build/scan/smoke-test path.

Branch ruleset requires the `maven-build` check by name — job id was renamed to match (`build` -> `maven-build`), which is also why `needs['maven-build']` uses bracket syntax instead of dot notation (a hyphen in a GH Actions expression reads as subtraction).

**CI, Stage 3 — Helm deploy**

`helm-deploy` only runs alongside a real publish (push to `master`, or manual `force_run`) — deploying only makes sense once an image actually exists on Docker Hub. It spins up a throwaway `kind` cluster, creates a `dockerhub-secret` image-pull secret, and then preloads the just-published image straight into the cluster's node with `kind load docker-image` (with `imagePullPolicy: IfNotPresent` on install) rather than letting the cluster pull it over the network — that pull was slow and occasionally exceeded Helm's `--wait --timeout 3m` outright.

The deploy previously targeted `image.tag=sha-<commit-sha>`, a tag that only ever existed in `docker-image-build`'s local Docker cache and was never actually pushed — every deploy was `--wait`ing on a pod stuck in `ImagePullBackOff` until it timed out. It now deploys the same version tag (`image.tag=<vX.Y.Z>`) that was just verified in `docker-pull-run`.

The Helm chart itself is intentionally minimal: no Service, ServiceAccount, Ingress, HTTPRoute, or autoscaling — this app doesn't serve traffic, so none of that is real. The one thing that matters is that the container stays up: the Dockerfile's `ENTRYPOINT` just runs `java -jar app.jar`, prints, and exits, which under a Deployment's default `restartPolicy: Always` becomes a restart loop that never reaches `Ready`. `values.yaml`'s `command` (`sh -c "java -jar app.jar && sleep infinity"`) is wired into the container spec specifically to keep it alive after printing so the Deployment can actually become Ready and `helm upgrade --install --wait` can return.
