# VProfile: Containerized with Docker & Docker Compose

The multi-tier VProfile Java app (Nginx → Tomcat → MySQL / Memcached / RabbitMQ) packaged as Docker images
and run with one command. This is the same app as the VM and AWS projects; here every tier is a container.

> Built while following the *Decoding DevOps* course (Imran Teli, Udemy). The course leaves the Dockerfiles and
> compose file to the student; these are my versions, with the improvements listed below.

## Architecture

```
 Browser ──:80──▶ vproweb (Nginx 1.27, reverse proxy)
                        │ vproapp:8080
                        ▼
                  vproapp (Tomcat 10 / JDK 21, ROOT.war built in a multi-stage image)
           ┌────────────┼──────────────┐
           ▼            ▼              ▼
   vprodb (MySQL 8.0.33   vprocache01        vpromq01
   + accounts schema)     (Memcached 1.6)    (RabbitMQ 4.0)
   named volume vprodbdata
```

Containers find each other by **service name** through Compose's built-in DNS. Only port 80 is published.

## Run it

Requires Docker Engine / Docker Desktop with the Compose plugin.

```bash
docker compose up -d --build       # builds 3 images, starts 5 containers
docker compose ps                  # vprodb shows (healthy) before vproapp starts
# open http://localhost  → login admin_vp / admin_vp
docker compose down -v             # stop and remove containers, network and the DB volume
```

Optional: put `DB_ROOT_PASSWORD=...` in a `.env` file (git-ignored) to override the default DB password.

## Images

| Image | Dockerfile | Notes |
|---|---|---|
| `vprocontainers/vprofileapp` | `Docker-files/app/Dockerfile` | **Multi-stage**: `maven:3.9.9-eclipse-temurin-21` builds the WAR from this repo's source → `tomcat:10-jdk21` runs it as `ROOT.war` |
| `vprocontainers/vprofiledb` | `Docker-files/db/Dockerfile` | `mysql:8.0.33`; `db_backup.sql` in `/docker-entrypoint-initdb.d/` creates the schema on first start |
| `vprocontainers/vprofileweb` | `Docker-files/web/Dockerfile` | `nginx:1.27` with the `vproapp` upstream config |
| `memcached:1.6`, `rabbitmq:4.0` | official images | used as-is |

## What I changed compared with the course's approach

- **App image builds from the local source** (build context = repo root + `.dockerignore`) instead of
  `git clone`-ing a remote branch inside the Dockerfile, so the image always matches the commit being built.
- **Dependency layer caching**: `pom.xml` is copied and dependencies resolved before the source, so code changes
  don't re-download every Maven dependency.
- **Healthcheck + `depends_on: condition: service_healthy`**: the app waits until MySQL actually accepts
  connections, instead of starting too early and failing.
- **Removed the `vproappdata` volume on Tomcat's webapps**: a volume there keeps the *old* WAR after rebuilds,
  so new images silently run stale code.
- **Only the web tier publishes a port** (80); DB, cache, queue and Tomcat stay on the internal network.
- Pinned image versions (MySQL 8.0.33, Memcached 1.6, RabbitMQ 4.0, Nginx 1.27) for repeatable builds.
- `.gitattributes` keeps Dockerfiles/configs on LF line endings when cloned on Windows.
- `vagrant/windowsAndMacIntel/Vagrantfile`: Docker host VM that installs Docker + Compose automatically
  (with a longer boot timeout). On Windows with Hyper-V/WSL2 active, VirtualBox falls back to a very slow
  mode, so Docker Desktop is the better choice there.

## Debugging notes

| Symptom | Cause | Fix |
|---|---|---|
| Vagrant: "Timed out while waiting for the machine to boot" | VirtualBox log: `VT-x is not available, fall back to NEM` (Hyper-V active) | Use Docker Desktop (WSL2), or disable Hyper-V for VirtualBox |
| User page shows no "Data is From…" message | That user ID doesn't exist in this DB dump (IDs 7, 8, 9) | Use an ID from the "All Users" list |

## Tech

Docker · Dockerfile (multi-stage) · Docker Compose · Nginx · Tomcat 10 · JDK 21 · Maven · MySQL 8 · Memcached · RabbitMQ
