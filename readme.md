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
