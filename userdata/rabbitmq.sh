#!/bin/bash
# rmq01 (Amazon Linux 2023): RabbitMQ from the official GitHub release RPMs.
# The course's yum repos (novemberain mirrors + Cloudsmith) are gone (DNS fail / HTTP 404), so
# the old script silently installed nothing. Versions pinned for repeatable builds.
set -euo pipefail
ERLANG_RPM="https://github.com/rabbitmq/erlang-rpm/releases/download/v27.3.4.19/erlang-27.3.4.19-1.el9.x86_64.rpm"
RABBIT_RPM="https://github.com/rabbitmq/rabbitmq-server/releases/download/v4.2.9/rabbitmq-server-4.2.9-1.el8.noarch.rpm"

rpm --import https://github.com/rabbitmq/signing-keys/releases/download/3.0/rabbitmq-release-signing-key.asc
dnf install -y socat logrotate
dnf install -y "$ERLANG_RPM" "$RABBIT_RPM"
systemctl enable --now rabbitmq-server

# Application user (matches rabbitmq.username/password in application.properties)
rabbitmqctl await_startup
rabbitmqctl add_user test test || true
rabbitmqctl set_user_tags test administrator
rabbitmqctl set_permissions -p / test ".*" ".*" ".*"
