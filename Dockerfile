# syntax=docker/dockerfile:1.4

#=======================================================
# Stage 1 - BUILD (The Compiler & Assembler)
#=======================================================
FROM maven:3.9-eclipse-temurin-8 AS build

# Syscall: chdir() - sets the process working directory within the VFS
WORKDIR /build

# Copying ONLY the pom to maximize OverlayFS cache hits and minimize disk I/O
COPY myapp/pom.xml ./pom.xml

# Fetching dependencies to local .m2 (Disk I/O intensive operation)
RUN mvn -B -ntp dependency:go-offline > /dev/null

# Copying the actual source code (Invalidates cache only if code changes)
COPY myapp/src ./src

# In-memory variable for the build process (Not persisted in final image layers)
ARG APP_VERSION=1.0.0

# 1. versions:set updates the XML tree in memory and flushes to disk.
# 2. package compiles bytecode utilizing 1 thread per logical CPU core (-T 1C).
RUN mvn versions:set -DnewVersion=${APP_VERSION} -DgenerateBackupPoms=false && \
    mvn -B -ntp -T 1C clean package -DskipTests

#=======================================================
# Stage 2 - RUNTIME (The Secure Execution Environment)
#=======================================================
FROM gcr.io/distroless/java:8 AS final

WORKDIR /app

# VFS Bypass & Privilege Drop - Kernel blocks root access, securing the host
USER 65532:65532

# Cross-stage VFS copy of the compiled artifact
COPY --chown=65532:65532 --from=build /build/target/*.jar app.jar

# JVM Kernel Awareness & Memory Cgroups binding
ENTRYPOINT [ \
  "java", \
  "-XX:+UnlockExperimentalVMOptions", \
  "-XX:+UseCGroupMemoryLimitForHeap", \
  "-XX:MaxMetaspaceSize=128m", \
  "-XX:+ExitOnOutOfMemoryError", \
  "-Djava.security.egd=file:/dev/./urandom", \
  "-jar", \
  "app.jar" \
]
