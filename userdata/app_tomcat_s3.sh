#!/bin/bash
# App tier (Ubuntu 24.04): Tomcat 10 + deploy the VProfile WAR straight from S3.
# Used as user data for app01 AND the Auto Scaling launch template, so every new
# app server configures itself (no hand-made AMI needed).
# Needs: an instance profile (IAM role) with s3:GetObject on the artifact bucket.
set -euo pipefail
ARTIFACT_BUCKET="__ARTIFACT_BUCKET__"     # replaced at launch time
ARTIFACT_KEY="vprofile-v2.war"

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y openjdk-17-jdk tomcat10 unzip curl

# AWS CLI v2 (to pull the artifact using the instance role - no access keys on the server)
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install

systemctl stop tomcat10
rm -rf /var/lib/tomcat10/webapps/ROOT /var/lib/tomcat10/webapps/ROOT.war
/usr/local/bin/aws s3 cp "s3://${ARTIFACT_BUCKET}/${ARTIFACT_KEY}" /var/lib/tomcat10/webapps/ROOT.war
chown tomcat:tomcat /var/lib/tomcat10/webapps/ROOT.war
systemctl enable --now tomcat10
