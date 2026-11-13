# VProfile CI with Jenkins, SonarQube and Nexus (everything as code)

A classic Jenkins CI pipeline for a Java web app: **build → unit tests (+JaCoCo) → Checkstyle → SonarQube
analysis → Quality Gate → publish the WAR to Nexus**. The whole toolchain runs in Docker and is configured
**without touching a UI**: Jenkins Configuration as Code (JCasC), Job DSL, and SonarQube/Nexus REST APIs.

> Built while following the *Decoding DevOps* course (Imran Teli, Udemy); the lab automation, fixes and
> design are mine. See **What I changed**.

## Architecture

```
 git push ──▶ GitHub (branch jenkins-ci)
                 ▲ polled every 2 min (pollSCM)
 ┌──────────────────── docker compose (jenkins-lab/) ────────────────────┐
 │ Jenkins (JDK 21 + Maven, plugins, JCasC)  ──analysis──▶ SonarQube      │
 │      │  pipeline from ./Jenkinsfile        ◀─webhook──  (quality gate) │
 │      └─ publish WAR ───────────────────────────────────▶ Nexus 3       │
 │                                                          vprofile-repo │
 └────────────────────────────────────────────────────────────────────────┘
```

## Pipeline stages (`Jenkinsfile`)

| Stage | What | Fails the build when |
|---|---|---|
| Build | `mvn install -DskipTests`, archive the WAR (fingerprinted) | it doesn't compile |
| Unit Tests | `mvn test jacoco:report`, publish JUnit results | a test fails |
| Checkstyle | `mvn checkstyle:checkstyle` (report fed to Sonar) | n/a (report only) |
| SonarQube Analysis | sonar-scanner with tests, coverage and checkstyle reports | the scanner errors |
| Quality Gate | `waitForQualityGate abortPipeline: true` (SonarQube calls back via webhook) | the gate fails |
| Publish to Nexus | `nexusArtifactUploader` → `QA/vproapp/<build>-<commit>/` | upload/auth fails |

## Run it

Requires Docker Desktop (about 6 GB RAM for the three containers).

```bash
cd jenkins-lab
bash setup.sh          # starts SonarQube + Nexus, configures them via API, builds and starts Jenkins
# Jenkins http://localhost:8080 (admin / password in jenkins-lab/.env), Sonar :9000, Nexus :8081
# the vprofile-ci job exists already; it builds on every push (or click Build Now)
docker compose down -v --rmi local    # remove everything
```

## Verified results

- Build #1: all stages green, 9/9 unit tests passed, Quality Gate OK, WAR (83 MB) stored in Nexus.
- Build #2: **triggered automatically by a push** (SCM polling); coverage reported (5.5%), version `2-87278ac`.
- SonarQube on 18k lines: 0 vulnerabilities, 30 bugs, 746 code smells (for future clean-up).

## What I changed compared with the course

- **Everything as code**: Jenkins admin, credentials, SonarQube server and scanner tool, and the job itself are in
  `jenkins-lab/casc.yaml` (JCasC + Job DSL); SonarQube token and webhook, Nexus password, anonymous-off and the
  Maven repo are created by `setup.sh` through REST APIs. The course does all of this by hand in three UIs.
- **Secrets** are generated per setup into a git-ignored `.env`, never committed.
- **Coverage fix**: the course's `mvn test` never produced `jacoco.xml`, so Sonar showed 0% coverage;
  `jacoco:report` fixes it.
- **Traceable artifact versions**: `<build>-<commit>` instead of a timestamp with spaces in the path.
- **Race condition fix**: Nexus reports healthy slightly before its security layer is ready, so the
  first password change can be silently lost; the script now retries until the new password works.
- Sandbox-safe Groovy (`substring` instead of `take`) so the pipeline needs no script approvals.

## Production notes

Run builds on agents (not the controller), store JCasC in Git with secrets from a vault, use webhooks
instead of polling, put Jenkins behind HTTPS + SSO, back up `JENKINS_HOME`, and pin plugin versions.

## Tech

Jenkins (Declarative Pipeline, JCasC, Job DSL) · Maven · JUnit · JaCoCo · Checkstyle · SonarQube · Nexus 3 ·
Docker Compose · Bash · REST APIs
