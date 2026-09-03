# myapp — Containerized Java Hello World

A minimal Java 7/8 app acting as a playground for a production-ready CI/CD pipeline (Maven, GitHub Actions, Docker multi-stage).

> **Heads up on Java 7/8:** This uses legacy Java to meet strict source code requirements. Since older JVMs are completely blind to Linux Cgroups, I had to manually inject memory flags into the Dockerfile. Without them, the JVM over-allocates RAM, and the Linux OOM Killer shoots the process on sight. Upgrading to Java 17/21+ is highly recommended to drop these hacks.

**Under the Hood:**

- **Multi-Stage BuildKit & Caching:** Uses Docker BuildKit's aggressive mount caching (--mount=type=cache) for Maven dependencies, completely bypassing redundant network I/O on rebuilds and isolating heavy compilation from the final image.

- **Distroless Runtime:** Zero OS overhead. No `/bin/sh`, no package managers. This kills OS-level CVEs and shrinks the attack surface.

- **VFS & Kernel-Level Security:** Bypasses Virtual File System text lookups by pinning the runtime directly to numeric IDs (USER 65532:65532). Inode ownership is rewritten on-the-fly (--chown=65532:65532) during the multi-stage copy to ensure strict, unprivileged isolation.

- **Trunk-Based CI/CD:** Fully automated GH Actions for version bumping, artifact packaging, Docker Hub pushes, and container smoke testing.

**Structure:**

```text
myapp/
  pom.xml
  src/
Dockerfile
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

PR -> master the gate. Everything that can fail cheaply runs here:
compile, unit tests, image build, security scan, container
smoke test, helm lint. Nothing is published.

push -> master the release. Same steps, plus: publish to Docker Hub,
pull it back, deploy with Helm, verify, tag the commit.

**Versioning**

Version is resolved from git tags at build time, not stored in `pom.xml` (pom stays `1.0.0` on purpose — the bump only happens inside the CI run). `maven-build` reads the last `vSERIES.*` tag, bumps the patch, stamps it into the pom for that build only, and — on a push to master — tags the commit `vX.Y.Z` and pushes just the tag (`contents: write` scoped to that one job).

Considered and skipped: committing the bumped pom back to master (bot commit on every push, drifts/conflicts), a third-party version-bump Action (low-trust maintainer, same commit-back problem), GitVersion (real tool, but overkill for a single-branch repo with no release/hotfix flow — revisit if that changes). Tags win here: no bot commits, no third-party trust, and tags don't retrigger the workflow.

**CI, Stage 2 — Docker image**

`docker-image-build` only runs on push to master, not on PRs — Trivy runs with `--exit-code 0` (report-only, never blocks the build), so running the full image build + scan on every PR was pure cost with no gate benefit. It builds, smoke-tests, and Trivy-scans the image, then (master only) logs into Docker Hub and pushes.

Branch ruleset requires the `maven-build` check by name — job id was renamed to match (`build` -> `maven-build`), which is also why `needs['maven-build']` uses bracket syntax instead of dot notation (a hyphen in a GH Actions expression reads as subtraction).
