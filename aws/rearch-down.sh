#!/bin/bash
# Delete everything created by rearch-up.sh. Safe to re-run.
export MSYS_NO_PATHCONV=1 AWS_PAGER=""
export AWS_REGION=${AWS_REGION:-ap-southeast-2}
P=vpro-rearch
STATE=aws/.state.env
[ -f "$STATE" ] && source "$STATE"
try(){ "$@" >/dev/null 2>&1 || true; }
log(){ echo "=== $(date +%H:%M:%S) $*"; }
waitgone(){ # description, command that prints something while the resource still exists, max minutes
  for ((i=0;i<${3:-30}*4;i++)); do out=$(eval "$2" 2>/dev/null); [ -z "$out" ] || [ "$out" = None ] && { echo "$1 gone"; return; }; sleep 15; done
  echo "WARNING: $1 still present"; }

log "CloudFront: disable, wait, delete"
CFID=${CFID:-$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='$P'].Id|[0]" --output text 2>/dev/null)}
if [ -n "$CFID" ] && [ "$CFID" != None ]; then
  aws cloudfront get-distribution-config --id "$CFID" --output json > aws/.cfg.json
  ETAG=$(python -c "import json;print(json.load(open('aws/.cfg.json'))['ETag'])")
  python -c "import json;d=json.load(open('aws/.cfg.json'))['DistributionConfig'];d['Enabled']=False;json.dump(d,open('aws/.cfg2.json','w'))"
  try aws cloudfront update-distribution --id "$CFID" --if-match "$ETAG" --distribution-config file://aws/.cfg2.json
  waitgone "CloudFront deploy" "aws cloudfront get-distribution --id $CFID --query \"Distribution.Status=='InProgress' && 'busy' || ''\" --output text" 30
  ETAG=$(aws cloudfront get-distribution --id "$CFID" --query ETag --output text)
  try aws cloudfront delete-distribution --id "$CFID" --if-match "$ETAG"
  rm -f aws/.cfg.json aws/.cfg2.json
fi

log "Backend SG: drop the rule that references Beanstalk's SG (so Beanstalk can delete its SG)"
BE_SG=${BE_SG:-$(aws ec2 describe-security-groups --filters Name=group-name,Values=$P-backend-sg --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)}
if [ -n "$BE_SG" ] && [ "$BE_SG" != None ]; then
  aws ec2 describe-security-groups --group-ids "$BE_SG" --query 'SecurityGroups[0].IpPermissions' --output json > aws/.perm.json 2>/dev/null
  try aws ec2 revoke-security-group-ingress --group-id "$BE_SG" --ip-permissions file://aws/.perm.json
  rm -f aws/.perm.json
fi

log "Elastic Beanstalk environment + application"
try aws elasticbeanstalk terminate-environment --environment-name $P-prod
waitgone "Beanstalk environment" "aws elasticbeanstalk describe-environments --environment-names $P-prod --query \"Environments[?Status!='Terminated'].Status\" --output text" 30
try aws elasticbeanstalk delete-application --application-name $P --terminate-env-by-force

log "Amazon MQ, ElastiCache, RDS (deleted in parallel)"
MQID=${MQID:-$(aws mq list-brokers --query "BrokerSummaries[?BrokerName=='$P-rmq'].BrokerId|[0]" --output text 2>/dev/null)}
[ -n "$MQID" ] && [ "$MQID" != None ] && try aws mq delete-broker --broker-id "$MQID"
try aws elasticache delete-cache-cluster --cache-cluster-id $P-mc
try aws rds delete-db-instance --db-instance-identifier $P-db --skip-final-snapshot --delete-automated-backups
waitgone "RDS" "aws rds describe-db-instances --db-instance-identifier $P-db --query 'DBInstances[0].DBInstanceStatus' --output text" 30
waitgone "ElastiCache" "aws elasticache describe-cache-clusters --cache-cluster-id $P-mc --query 'CacheClusters[0].CacheClusterStatus' --output text" 30
waitgone "Amazon MQ" "aws mq list-brokers --query \"BrokerSummaries[?BrokerName=='$P-rmq'].BrokerState\" --output text" 30
try aws rds delete-db-subnet-group --db-subnet-group-name $P-rds-sub
try aws elasticache delete-cache-subnet-group --cache-subnet-group-name $P-mc-sub

log "Any leftover instances tagged Project=$P (dbinit)"
IDS=$(aws ec2 describe-instances --filters Name=tag:Project,Values=$P Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
[ -n "$IDS" ] && aws ec2 terminate-instances --instance-ids $IDS >/dev/null && aws ec2 wait instance-terminated --instance-ids $IDS

log "IAM roles"
try aws iam remove-role-from-instance-profile --instance-profile-name $P-ec2-profile --role-name $P-ec2-role
try aws iam delete-instance-profile --instance-profile-name $P-ec2-profile
for pol in AWSElasticBeanstalkWebTier AmazonSSMManagedInstanceCore; do
  try aws iam detach-role-policy --role-name $P-ec2-role --policy-arn arn:aws:iam::aws:policy/$pol; done
try aws iam delete-role --role-name $P-ec2-role
for pol in service-role/AWSElasticBeanstalkEnhancedHealth AWSElasticBeanstalkManagedUpdatesCustomerRolePolicy; do
  try aws iam detach-role-policy --role-name $P-eb-service-role --policy-arn arn:aws:iam::aws:policy/$pol; done
try aws iam delete-role --role-name $P-eb-service-role

log "Beanstalk S3 bucket"
ACCT=${ACCT:-$(aws sts get-caller-identity --query Account --output text)}
EBBUCKET=${EBBUCKET:-elasticbeanstalk-$AWS_REGION-$ACCT}
try aws s3api delete-bucket-policy --bucket "$EBBUCKET"
try aws s3 rb "s3://$EBBUCKET" --force

log "Backend security group"
for i in 1 2 3 4 5 6 7 8; do
  id=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$P-backend-sg --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  [ -z "$id" ] || [ "$id" = None ] && break
  aws ec2 delete-security-group --group-id "$id" >/dev/null 2>&1 && break; sleep 30
done

log "Leftovers check (all should be empty):"
echo "RDS:         $(aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output text)"
echo "ElastiCache: $(aws elasticache describe-cache-clusters --query 'CacheClusters[].CacheClusterId' --output text)"
echo "Amazon MQ:   $(aws mq list-brokers --query 'BrokerSummaries[].BrokerName' --output text)"
echo "Beanstalk:   $(aws elasticbeanstalk describe-environments --query "Environments[?Status!='Terminated'].EnvironmentName" --output text)"
echo "CloudFront:  $(aws cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text)"
echo "Instances:   $(aws ec2 describe-instances --filters Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)"
echo "LBs:         $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text)"
echo "Buckets:     $(aws s3api list-buckets --query 'Buckets[].Name' --output text)"
echo "SGs:         $(aws ec2 describe-security-groups --query "SecurityGroups[?GroupName!='default'].GroupName" --output text)"
rm -f "$STATE"
echo "Teardown finished."
