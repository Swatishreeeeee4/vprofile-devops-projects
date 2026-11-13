#!/bin/sh
# Install the control node's public key, then run sshd in the foreground (PID 1).
mkdir -p /home/ansible/.ssh && cp /keys/id_ed25519.pub /home/ansible/.ssh/authorized_keys
chown -R ansible:ansible /home/ansible/.ssh && chmod 700 /home/ansible/.ssh && chmod 600 /home/ansible/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
