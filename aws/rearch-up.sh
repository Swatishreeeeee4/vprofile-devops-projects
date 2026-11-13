#!/bin/bash
# VProfile "Re-architecting" on AWS managed services, built with the AWS CLI.
#   RDS MySQL  +  ElastiCache Memcached  +  Amazon MQ (RabbitMQ, TLS 5671)
#   Elastic Beanstalk (Tomcat 10 / Corretto 17, ALB, Auto Scaling)  +  CloudFront (HTTPS)
# Passwords are generated per run and kept only in aws/.state.env (git-ignored).
# Usage (repo root):  bash aws/rearch-up.sh      Teardown:  bash aws/rearch-down.sh
set -euo pipefail
export MSYS_NO_PATHCONV=1 AWS_PAGER=""
export AWS_REGION=${AWS_REGION:-ap-southeast-2}
P=vpro-rearch
STATE=aws/.state.env
log(){ echo -e "\n=== $(date +%H:%M:%S) $*"; }
save(){ echo "$1='$2'" >> "$STATE"; }
gen(){ python -c "import secrets,string;a=string.ascii_letters+string.digits;print(''.join(secrets.choice(a) for _ in range($1)))"; }
waitfor(){ # description, command producing a status, wanted status, max minutes
  local d=$1 cmd=$2 want=$3 max=${4:-30} s
  for ((i=0;i<max*4;i++)); do s=$(eval "$cmd" 2>/dev/null || true)
    [ "$s" = "$want" ] && { echo "$d: $s"; return 0; }; sleep 15; done
  echo "TIMEOUT waiting for $d (last: $s)"; return 1; }
: > "$STATE"

ACCT=$(aws sts get-caller-identity --query Account --output text); save ACCT "$ACCT"
log "Account $ACCT region $AWS_REGION"
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text); save VPC "$VPC"
read -r SUB1 SUB2 <<<"$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" \
  Name=availability-zone,Values=${AWS_REGION}a,${AWS_REGION}b --query 'Subnets[].SubnetId' --output text)"
save SUB1 "$SUB1"; save SUB2 "$SUB2"
DBPASS=$(gen 20); MQPASS=$(gen 20); save DBPASS "$DBPASS"; save MQPASS "$MQPASS"

log "Backend security group (managed services; opened to the Beanstalk instances later)"
BE_SG=$(aws ec2 create-security-group --group-name $P-backend-sg --description "RDS/ElastiCache/MQ" \
  --vpc-id "$VPC" --query GroupId --output text); save BE_SG "$BE_SG"
aws ec2 authorize-security-group-ingress --group-id "$BE_SG" --protocol -1 --source-group "$BE_SG" >/dev/null

log "RDS MySQL (private, free-tier size)"
aws rds create-db-subnet-group --db-subnet-group-name $P-rds-sub --db-subnet-group-description "$P" \
  --subnet-ids "$SUB1" "$SUB2" >/dev/null
aws rds create-db-instance --db-instance-identifier $P-db --engine mysql --engine-version 8.0.46 \
  --db-instance-class db.t4g.micro --allocated-storage 20 --storage-type gp2 --no-multi-az \
  --master-username admin --master-user-password "$DBPASS" --db-name accounts \
  --vpc-security-group-ids "$BE_SG" --db-subnet-group-name $P-rds-sub --no-publicly-accessible \
  --backup-retention-period 0 --tags Key=Project,Value=$P >/dev/null

log "ElastiCache Memcached"
aws elasticache create-cache-subnet-group --cache-subnet-group-name $P-mc-sub \
  --cache-subnet-group-description "$P" --subnet-ids "$SUB1" "$SUB2" >/dev/null
aws elasticache create-cache-cluster --cache-cluster-id $P-mc --engine memcached \
  --cache-node-type cache.t3.micro --num-cache-nodes 1 --cache-subnet-group-name $P-mc-sub \
  --security-group-ids "$BE_SG" >/dev/null

log "Amazon MQ RabbitMQ (private, single instance)"
MQID=$(aws mq create-broker --broker-name $P-rmq --engine-type RABBITMQ --engine-version 3.13 \
  --host-instance-type mq.m7g.medium --deployment-mode SINGLE_INSTANCE --no-publicly-accessible \
  --auto-minor-version-upgrade --subnet-ids "$SUB1" --security-groups "$BE_SG" \
  --users Username=rabbit,Password="$MQPASS" --query BrokerId --output text); save MQID "$MQID"

log "IAM: instance role (Beanstalk web tier + SSM) and Beanstalk service role"
echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > aws/.t1.json
echo '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"elasticbeanstalk.amazonaws.com"},"Action":"sts:AssumeRole"}]}' > aws/.t2.json
aws iam create-role --role-name $P-ec2-role --assume-role-policy-document file://aws/.t1.json >/dev/null
for pol in AWSElasticBeanstalkWebTier AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name $P-ec2-role --policy-arn arn:aws:iam::aws:policy/$pol; done
aws iam create-instance-profile --instance-profile-name $P-ec2-profile >/dev/null
aws iam add-role-to-instance-profile --instance-profile-name $P-ec2-profile --role-name $P-ec2-role
aws iam create-role --role-name $P-eb-service-role --assume-role-policy-document file://aws/.t2.json >/dev/null
for pol in service-role/AWSElasticBeanstalkEnhancedHealth AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy; do
  aws iam attach-role-policy --role-name $P-eb-service-role --policy-arn arn:aws:iam::aws:policy/$pol; done
rm -f aws/.t1.json aws/.t2.json

log "Waiting for RDS / ElastiCache / MQ (10-20 min)"
waitfor RDS "aws rds describe-db-instances --db-instance-identifier $P-db --query 'DBInstances[0].DBInstanceStatus' --output text" available 30
waitfor ElastiCache "aws elasticache describe-cache-clusters --cache-cluster-id $P-mc --query 'CacheClusters[0].CacheClusterStatus' --output text" available 30
waitfor AmazonMQ "aws mq describe-broker --broker-id $MQID --query BrokerState --output text" RUNNING 40
DB_HOST=$(aws rds describe-db-instances --db-instance-identifier $P-db --query 'DBInstances[0].Endpoint.Address' --output text)
MC_HOST=$(aws elasticache describe-cache-clusters --cache-cluster-id $P-mc --query 'CacheClusters[0].ConfigurationEndpoint.Address' --output text)
MQ_EP=$(aws mq describe-broker --broker-id $MQID --query 'BrokerInstances[0].Endpoints[0]' --output text)
MQ_HOST=${MQ_EP#amqps://}; MQ_HOST=${MQ_HOST%:5671}
save DB_HOST "$DB_HOST"; save MC_HOST "$MC_HOST"; save MQ_HOST "$MQ_HOST"
echo "DB=$DB_HOST  MC=$MC_HOST  MQ=$MQ_HOST"

log "Initialise the DB schema from a temporary instance via SSM Run Command"
AL2023=$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text)
sleep 10
INIT=$(aws ec2 run-instances --image-id "$AL2023" --instance-type t3.micro --subnet-id "$SUB1" \
  --security-group-ids "$BE_SG" --iam-instance-profile Name=$P-ec2-profile \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Project,Value=$P},{Key=Name,Value=$P-dbinit}]" \
  --query 'Instances[0].InstanceId' --output text); save INIT "$INIT"
waitfor "SSM agent on dbinit" "aws ssm describe-instance-information --filters Key=InstanceIds,Values=$INIT --query 'InstanceInformationList[0].PingStatus' --output text" Online 10
cat > aws/.init.json <<EOF
{"commands":[
 "set -e",
 "dnf install -y -q mariadb105 git",
 "rm -rf /tmp/v && git clone -q -b awsrefactor https://github.com/hkhcoder/vprofile-project.git /tmp/v",
 "mysql -h $DB_HOST -u admin -p'$DBPASS' accounts < /tmp/v/src/main/resources/db_backup.sql",
 "mysql -h $DB_HOST -u admin -p'$DBPASS' accounts -N -e 'show tables' | tr '\\\\n' ' '"
]}
EOF
CMD=$(aws ssm send-command --instance-ids "$INIT" --document-name AWS-RunShellScript \
  --parameters file://aws/.init.json --query Command.CommandId --output text); rm -f aws/.init.json
waitfor "DB init command" "aws ssm get-command-invocation --command-id $CMD --instance-id $INIT --query Status --output text" Success 10
echo "tables: $(aws ssm get-command-invocation --command-id $CMD --instance-id $INIT --query StandardOutputContent --output text)"
aws ec2 terminate-instances --instance-ids "$INIT" >/dev/null

log "Build the WAR with the real endpoints (placeholders restored afterwards)"
F=src/main/resources/application.properties
cp $F aws/.props.bak
sed -i -e "s#__DB_HOST__#$DB_HOST#" -e "s#__DB_PASS__#$DBPASS#" -e "s#__MC_HOST__#$MC_HOST#" \
       -e "s#__MQ_HOST__#$MQ_HOST#" -e "s#__MQ_PASS__#$MQPASS#" $F
env -u MSYS_NO_PATHCONV mvn -q -DskipTests package   # Maven needs Git Bash path conversion
cp aws/.props.bak $F && rm aws/.props.bak

log "Elastic Beanstalk application + environment (Tomcat 10 / Corretto 17)"
EBBUCKET=$(aws elasticbeanstalk create-storage-location --query S3Bucket --output text); save EBBUCKET "$EBBUCKET"
KEY="$P/vprofile-v2-$(date +%s).war"
aws s3 cp target/vprofile-v2.war "s3://$EBBUCKET/$KEY" --only-show-errors
aws elasticbeanstalk create-application --application-name $P >/dev/null
aws elasticbeanstalk create-application-version --application-name $P --version-label v1 \
  --source-bundle S3Bucket="$EBBUCKET",S3Key="$KEY" >/dev/null
STACK=$(aws elasticbeanstalk list-available-solution-stacks \
  --query "SolutionStacks[?contains(@,'Tomcat 10 Corretto 17')]|[0]" --output text)
cat > aws/.eb.json <<EOF
[
 {"Namespace":"aws:elasticbeanstalk:environment","OptionName":"EnvironmentType","Value":"LoadBalanced"},
 {"Namespace":"aws:elasticbeanstalk:environment","OptionName":"LoadBalancerType","Value":"application"},
 {"Namespace":"aws:elasticbeanstalk:environment","OptionName":"ServiceRole","Value":"$P-eb-service-role"},
 {"Namespace":"aws:autoscaling:launchconfiguration","OptionName":"IamInstanceProfile","Value":"$P-ec2-profile"},
 {"Namespace":"aws:autoscaling:launchconfiguration","OptionName":"DisableIMDSv1","Value":"true"},
 {"Namespace":"aws:ec2:instances","OptionName":"InstanceTypes","Value":"t3.micro"},
 {"Namespace":"aws:autoscaling:asg","OptionName":"MinSize","Value":"1"},
 {"Namespace":"aws:autoscaling:asg","OptionName":"MaxSize","Value":"2"},
 {"Namespace":"aws:ec2:vpc","OptionName":"VPCId","Value":"$VPC"},
 {"Namespace":"aws:ec2:vpc","OptionName":"Subnets","Value":"$SUB1,$SUB2"},
 {"Namespace":"aws:ec2:vpc","OptionName":"ELBSubnets","Value":"$SUB1,$SUB2"},
 {"Namespace":"aws:ec2:vpc","OptionName":"AssociatePublicIpAddress","Value":"true"},
 {"Namespace":"aws:elasticbeanstalk:environment:process:default","OptionName":"HealthCheckPath","Value":"/"},
 {"Namespace":"aws:elasticbeanstalk:environment:process:default","OptionName":"MatcherHTTPCode","Value":"200-399"},
 {"Namespace":"aws:elasticbeanstalk:environment:process:default","OptionName":"StickinessEnabled","Value":"true"},
 {"Namespace":"aws:elasticbeanstalk:healthreporting:system","OptionName":"SystemType","Value":"enhanced"}
]
EOF
aws elasticbeanstalk create-environment --application-name $P --environment-name $P-prod \
  --cname-prefix "$P-$ACCT" --solution-stack-name "$STACK" --version-label v1 \
  --option-settings file://aws/.eb.json >/dev/null; rm -f aws/.eb.json
save EBENV "$P-prod"
waitfor "Beanstalk environment" "aws elasticbeanstalk describe-environments --environment-names $P-prod --query 'Environments[0].Status' --output text" Ready 30

log "Allow the Beanstalk instances into the backend SG, then restart the app"
EBINST=$(aws elasticbeanstalk describe-environment-resources --environment-name $P-prod --query 'EnvironmentResources.Instances[0].Id' --output text)
EB_SG=$(aws ec2 describe-instances --instance-ids "$EBINST" --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' --output text)
save EB_SG "$EB_SG"
aws ec2 authorize-security-group-ingress --group-id "$BE_SG" --protocol -1 --source-group "$EB_SG" >/dev/null
aws elasticbeanstalk restart-app-server --environment-name $P-prod
EBURL=$(aws elasticbeanstalk describe-environments --environment-names $P-prod --query 'Environments[0].CNAME' --output text)
save EBURL "http://$EBURL"

log "CloudFront distribution (HTTPS for users, HTTP to the Beanstalk load balancer)"
cat > aws/.cf.json <<EOF
{"CallerReference":"$P-$(date +%s)","Comment":"$P","Enabled":true,"PriceClass":"PriceClass_All",
 "Origins":{"Quantity":1,"Items":[{"Id":"eb","DomainName":"$EBURL",
   "CustomOriginConfig":{"HTTPPort":80,"HTTPSPort":443,"OriginProtocolPolicy":"http-only"}}]},
 "DefaultCacheBehavior":{"TargetOriginId":"eb","ViewerProtocolPolicy":"redirect-to-https",
   "AllowedMethods":{"Quantity":7,"Items":["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
     "CachedMethods":{"Quantity":2,"Items":["GET","HEAD"]}},
   "CachePolicyId":"4135ea2d-6df8-44a3-9df3-4b5a84be39ad",
   "OriginRequestPolicyId":"216adef6-5c7f-47e4-b989-5492eafa07d3","Compress":true}}
EOF
read -r CFID CFDOMAIN <<<"$(aws cloudfront create-distribution --distribution-config file://aws/.cf.json \
  --query 'Distribution.[Id,DomainName]' --output text)"; rm -f aws/.cf.json
save CFID "$CFID"; save URL "https://$CFDOMAIN"
waitfor CloudFront "aws cloudfront get-distribution --id $CFID --query Distribution.Status --output text" Deployed 30

log "DONE  Beanstalk: http://$EBURL   CloudFront: https://$CFDOMAIN   (login admin_vp / admin_vp)"
