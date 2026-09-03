# syntax=docker/dockerfile:1

#=======================================================
# Stage 1 - BUILD
FROM maven:3.9-eclipse-temurin-8 AS build

WORKDIR /app

# Cache dependencies
RUN --mount=type=bind,source=myapp/pom.xml,target=pom.xml \
    --mount=type=cache,target=/root/.m2 \
    mvn dependency:go-offline -B

#Copy source files
COPY myapp/pom.xml ./pom.xml
COPY myapp/src ./src

# Stamp Version, Skip tests on docker
ARG APP_VERSION=1.0.0

# Multi thread-core execution.
RUN --mount=type=cache,target=/root/.m2 \
    mvn versions:set -DnewVersion=${APP_VERSION} -DgenerateBackupPoms=false && \
    mvn -B -T 1C clean package -DskipTests



#=======================================================
# Stage 2 - Packaging
FROM gcr.io/distroless/java:8 AS final

WORKDIR /app

# VFS Bypass
USER 65532:65532

#Copy the compiled JAR from Stage 1
COPY --chown=65532:65532 --from=build /app/target/*.jar app.jar

#Run the application
ENTRYPOINT [ "java", "-jar", "app.jar" ]

# Optional need for Limiting resources, Because Java 7-8 limitations
# ENTRYPOINT [ "java", \
#     "-XX:+UnlockExperimentalVMOptions", \
#     "-XX:+UseCGroupMemoryLimitForHeap", \
#     "-XX:InitialRAMPercentage=50.0", \
#     "-XX:MaxRAMPercentage=75.0", \
#     "-jar", "app.jar" ]
