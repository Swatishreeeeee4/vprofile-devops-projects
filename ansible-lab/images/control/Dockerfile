# Ansible control node
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssh-client curl && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir "ansible-core>=2.17,<2.18" \
 && ansible-galaxy collection install community.mysql
WORKDIR /ansible
# keys shared from Windows look world-readable; ssh refuses such private keys, so copy + chmod 600
CMD ["sh", "-c", "mkdir -p /root/.ssh && cp /keys/id_ed25519 /root/.ssh/id_ed25519 && chmod 600 /root/.ssh/id_ed25519 && sleep infinity"]
