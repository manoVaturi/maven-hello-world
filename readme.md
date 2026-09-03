# myapp — Java Hello World, containerized and shipped via CI/CD

A minimal Java 7 "Hello World" app, that i built a CI Pipeline with: Maven, GitHub Actions, Docker (Multi-stage build).

## Project Structure

```
myapp/
  pom.xml
  src/main/java/com/myapp/App.java
  src/test/java/com/myapp/AppTest.java
Dockerfile
.github/workflows/ci.yaml
```

## Init project

Fork, Clone repo:

GitHub:
settings -> brances -> add rule for "master"
require pull request before merging
require status checks to pass (build-test-and-scan)
do not allow force pushes

## Build and run locally

```
cd myapp
mvn clean package
java -jar target/myapp-1.0.0.jar
```

## Docker (Multi-stage build)

Build stage:
Used maven:3.9-eclipse-temurin-8 image for build, closest image i found for Java 7

Final stage:
Used gcr.io/distroless/java:8: Distoless

- With eclipse-temurin-8: Image size 444mb
- With gcr.io/distroless/java:8: Image size 188mb (Also have "nonroot" user already)
