#!/bin/bash
# VProfile "Lift & Shift" to AWS - build everything with the AWS CLI.
#   Backend: db01 (MariaDB), mc01 (Memcached), rmq01 (RabbitMQ)  -> Amazon Linux 2023, private DNS via Route 53
#   App tier: Tomcat 10 on Ubuntu 24.04 in an Auto Scaling Group, WAR pulled from S3 with an IAM role
#   Front: internet-facing Application Load Balancer (HTTP:80) -> target group (8080)
# Usage:  bash aws/liftandshift-up.sh        (from the repo root, after `mvn install`)
# Teardown: bash aws/liftandshift-down.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1            # Git Bash on Windows: don't rewrite "/" arguments into paths
export AWS_REGION=${AWS_REGION:-ap-southeast-2} AWS_PAGER=""   # override: AWS_REGION=us-east-1 bash ...
P=vprofile-ls                         # name prefix + Project tag
STATE=aws/.state.env
TAGS="ResourceType=instance,Tags=[{Key=Project,Value=$P},{Key=Name,Value=NAME}]"
log(){ echo -e "\n=== $*"; }
save(){ echo "$1=$2" >> "$STATE"; }
: > "$STATE"

ACCT=$(aws sts get-caller-identity --query Account --output text); save ACCT "$ACCT"
log "Account $ACCT, region $AWS_REGION"
MYIP="$(curl -s https://checkip.amazonaws.com | tr -d '\r\n')/32"

log "Default VPC + 2 subnets"
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text); save VPC "$VPC"
read -r SUB1 SUB2 <<<"$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" \
  Name=availability-zone,Values=${AWS_REGION}a,${AWS_REGION}b --query 'Subnets[].SubnetId' --output text)"
echo "VPC=$VPC subnets=$SUB1 $SUB2"

log "Key pair"
mkdir -p "$HOME/.ssh"
aws ec2 create-key-pair --key-name $P-key --key-type ed25519 --query KeyMaterial --output text > "$HOME/.ssh/$P-key.pem"
chmod 400 "$HOME/.ssh/$P-key.pem"; save KEY "$P-key"

log "Security groups (ELB -> app -> backend chain)"
sg(){ aws ec2 create-security-group --group-name "$1" --description "$2" --vpc-id "$VPC" --query GroupId --output text; }
ELB_SG=$(sg $P-elb-sg "ALB: HTTP from internet"); save ELB_SG "$ELB_SG"
APP_SG=$(sg $P-app-sg "Tomcat: 8080 only from ALB"); save APP_SG "$APP_SG"
BE_SG=$(sg $P-backend-sg "DB/cache/queue: only from app + each other"); save BE_SG "$BE_SG"
aws ec2 authorize-security-group-ingress --group-id "$ELB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --protocol tcp --port 8080 --source-group "$ELB_SG" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$APP_SG" --protocol tcp --port 22 --cidr "$MYIP" >/dev/null
for port in 3306 11211 5672; do
  aws ec2 authorize-security-group-ingress --group-id "$BE_SG" --protocol tcp --port $port --source-group "$APP_SG" >/dev/null
done
aws ec2 authorize-security-group-ingress --group-id "$BE_SG" --protocol -1 --source-group "$BE_SG" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$BE_SG" --protocol tcp --port 22 --cidr "$MYIP" >/dev/null

log "S3 artifact bucket + upload WAR"
BUCKET="$P-artifacts-$ACCT"; save BUCKET "$BUCKET"
if [ "$AWS_REGION" = us-east-1 ]; then aws s3api create-bucket --bucket "$BUCKET" >/dev/null
else aws s3api create-bucket --bucket "$BUCKET" --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null; fi
aws s3 cp target/vprofile-v2.war "s3://$BUCKET/vprofile-v2.war" --only-show-errors

log "IAM role for app servers (read the artifact + SSM Session Manager)"
cat > aws/.trust.json <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > aws/.s3read.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::$BUCKET/*"}]}
EOF
aws iam create-role --role-name $P-app-role --assume-role-policy-document file://aws/.trust.json >/dev/null
aws iam put-role-policy --role-name $P-app-role --policy-name s3-artifact-read --policy-document file://aws/.s3read.json
aws iam attach-role-policy --role-name $P-app-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam create-instance-profile --instance-profile-name $P-app-profile >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name $P-app-profile --role-name $P-app-role
save ROLE "$P-app-role"; save PROFILE "$P-app-profile"
sleep 15   # IAM is eventually consistent; give the profile time to propagate

AL2023=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
UBUNTU=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)

log "Backend instances"
launch(){ # name userdata
  aws ec2 run-instances --image-id "$AL2023" --instance-type t3.micro --key-name $P-key \
    --security-group-ids "$BE_SG" --subnet-id "$SUB1" --user-data "file://userdata/$2" \
    --tag-specifications "${TAGS/NAME/$1}" --query 'Instances[0].InstanceId' --output text; }
DB=$(launch db01 mysql.sh);      save DB "$DB"
MC=$(launch mc01 memcache.sh);   save MC "$MC"
RMQ=$(launch rmq01 rabbitmq.sh); save RMQ "$RMQ"
aws ec2 wait instance-running --instance-ids "$DB" "$MC" "$RMQ"
ip(){ aws ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text; }

log "Route 53 private hosted zone vprofile.in"
ZONE=$(aws route53 create-hosted-zone --name vprofile.in --caller-reference "$P-$(date +%s)" \
  --vpc VPCRegion=$AWS_REGION,VPCId="$VPC" --hosted-zone-config PrivateZone=true,Comment="$P" \
  --query HostedZone.Id --output text); ZONE=${ZONE#/hostedzone/}; save ZONE "$ZONE"
CH='{"Changes":['
for pair in "db01:$DB" "mc01:$MC" "rmq01:$RMQ"; do
  CH+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"${pair%%:*}.vprofile.in\",\"Type\":\"A\",\"TTL\":60,\"ResourceRecords\":[{\"Value\":\"$(ip ${pair#*:})\"}]}},"
done
CH="${CH%,}]}"; echo "$CH" > aws/.dns.json
aws route53 change-resource-record-sets --hosted-zone-id "$ZONE" --change-batch file://aws/.dns.json >/dev/null

log "Target group + ALB"
TG=$(aws elbv2 create-target-group --name $P-tg --protocol HTTP --port 8080 --vpc-id "$VPC" \
  --health-check-path / --matcher HttpCode=200-399 --health-check-interval-seconds 15 --healthy-threshold-count 2 --query 'TargetGroups[0].TargetGroupArn' --output text); save TG "$TG"
aws elbv2 modify-target-group-attributes --target-group-arn "$TG" \
  --attributes Key=stickiness.enabled,Value=true Key=stickiness.type,Value=lb_cookie >/dev/null
ALB=$(aws elbv2 create-load-balancer --name $P-alb --subnets "$SUB1" "$SUB2" --security-groups "$ELB_SG" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text); save ALB "$ALB"
aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG" >/dev/null

log "Launch template + Auto Scaling group for the app tier"
sed "s/__ARTIFACT_BUCKET__/$BUCKET/" userdata/app_tomcat_s3.sh > aws/.app-userdata.sh
UD=$(base64 -w0 aws/.app-userdata.sh)
cat > aws/.lt.json <<EOF
{"ImageId":"$UBUNTU","InstanceType":"t3.micro","KeyName":"$P-key",
 "SecurityGroupIds":["$APP_SG"],"IamInstanceProfile":{"Name":"$P-app-profile"},"UserData":"$UD",
 "TagSpecifications":[{"ResourceType":"instance","Tags":[{"Key":"Project","Value":"$P"},{"Key":"Name","Value":"app01-asg"}]}]}
EOF
aws ec2 create-launch-template --launch-template-name $P-app-lt --launch-template-data file://aws/.lt.json >/dev/null
save LT "$P-app-lt"
aws autoscaling create-auto-scaling-group --auto-scaling-group-name $P-app-asg \
  --launch-template LaunchTemplateName=$P-app-lt,Version='$Latest' \
  --min-size 1 --desired-capacity 1 --max-size 2 --vpc-zone-identifier "$SUB1,$SUB2" \
  --target-group-arns "$TG" --health-check-type ELB --health-check-grace-period 600
# In a brand-new account the Auto Scaling service-linked role is created on first use and
# takes a moment to become usable -> retry instead of failing (ServiceLinkedRoleFailure).
for try in 1 2 3 4 5 6; do
  aws autoscaling put-scaling-policy --auto-scaling-group-name $P-app-asg --policy-name cpu50 \
    --policy-type TargetTrackingScaling \
    --target-tracking-configuration '{"PredefinedMetricSpecification":{"PredefinedMetricType":"ASGAverageCPUUtilization"},"TargetValue":50}' \
    >/dev/null 2>&1 && break
  echo "scaling policy not ready yet (attempt $try), retrying in 20s"; sleep 20
done
save ASG "$P-app-asg"

DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" --query 'LoadBalancers[0].DNSName' --output text); save URL "http://$DNS"
log "DONE. App will be ready in ~8-10 minutes at: http://$DNS   (login admin_vp / admin_vp)"
rm -f aws/.trust.json aws/.s3read.json aws/.dns.json aws/.lt.json aws/.app-userdata.sh
