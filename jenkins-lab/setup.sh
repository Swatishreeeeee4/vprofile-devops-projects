#!/bin/bash
# Bring up the CI lab (Jenkins + SonarQube + Nexus) fully configured, with no UI clicks.
# Generated passwords/tokens go to jenkins-lab/.env (git-ignored).
set -euo pipefail
cd "$(dirname "$0")"
export MSYS_NO_PATHCONV=1
gen(){ python -c "import secrets,string;a=string.ascii_letters+string.digits;print(''.join(secrets.choice(a) for _ in range(18)))"; }
wait_http(){ for i in $(seq 1 90); do curl -s -o /dev/null -w "%{http_code}" "$1" | grep -qE "$2" && return 0; sleep 5; done; echo "timeout: $1"; return 1; }

[ -f .env ] || printf "JENKINS_ADMIN_PASSWORD=%s\nSONAR_ADMIN_PASSWORD=%s\nNEXUS_PASSWORD=%s\nSONAR_TOKEN=\n" "$(gen)" "$(gen)" "$(gen)" > .env
set -a; source .env; set +a

echo "== start SonarQube + Nexus"; docker compose up -d sonarqube nexus

echo "== SonarQube: wait, set admin password, token, webhook to Jenkins"
for i in $(seq 1 90); do curl -s localhost:9000/api/system/status | grep -q '"status":"UP"' && break; sleep 5; done
curl -s -o /dev/null -u admin:admin -X POST "localhost:9000/api/users/change_password" \
  -d "login=admin&previousPassword=admin&password=$SONAR_ADMIN_PASSWORD" || true
if [ -z "${SONAR_TOKEN:-}" ]; then
  SONAR_TOKEN=$(curl -s -u "admin:$SONAR_ADMIN_PASSWORD" -X POST "localhost:9000/api/user_tokens/generate" \
    -d "name=jenkins-$(date +%s)" | python -c "import sys,json;print(json.load(sys.stdin)['token'])")
  sed -i "s/^SONAR_TOKEN=.*/SONAR_TOKEN=$SONAR_TOKEN/" .env
fi
curl -s -o /dev/null -u "admin:$SONAR_ADMIN_PASSWORD" -X POST "localhost:9000/api/webhooks/create" \
  -d "name=jenkins&url=http://jenkins:8080/sonarqube-webhook/" || true

echo "== Nexus: wait, set admin password, disable anonymous, create maven repo"
wait_http localhost:8081/service/rest/v1/status 200
if docker exec nexus test -f /nexus-data/admin.password; then
  INIT=$(docker exec nexus cat /nexus-data/admin.password)
  curl -s -o /dev/null -u "admin:$INIT" -X PUT -H "Content-Type: text/plain" \
    --data "$NEXUS_PASSWORD" localhost:8081/service/rest/v1/security/users/admin/change-password
fi
curl -s -o /dev/null -u "admin:$NEXUS_PASSWORD" -X PUT -H "Content-Type: application/json" \
  -d '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' localhost:8081/service/rest/v1/security/anonymous
curl -s -o /dev/null -u "admin:$NEXUS_PASSWORD" -X POST -H "Content-Type: application/json" \
  -d '{"name":"vprofile-repo","online":true,"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW_ONCE"},"maven":{"versionPolicy":"RELEASE","layoutPolicy":"PERMISSIVE"}}' \
  localhost:8081/service/rest/v1/repositories/maven/hosted || true

echo "== build + start Jenkins (configuration as code)"
docker compose up -d --build jenkins
wait_http localhost:8080/login 200
echo "READY  Jenkins http://localhost:8080 (admin / see .env)  SonarQube http://localhost:9000  Nexus http://localhost:8081"
