#!/bin/bash
# Delete EVERYTHING created by liftandshift-up.sh (order matters: ASG -> ALB -> instances -> network bits).
# Safe to re-run: every step ignores "already gone" errors.
export MSYS_NO_PATHCONV=1 AWS_REGION=${AWS_REGION:-ap-southeast-2} AWS_PAGER=""
P=vprofile-ls
STATE=aws/.state.env
[ -f "$STATE" ] && source "$STATE"
try(){ "$@" >/dev/null 2>&1 || true; }
log(){ echo "=== $*"; }

log "Auto Scaling group (first, or it re-creates instances)"
try aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $P-app-asg --force-delete
while aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $P-app-asg \
      --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text 2>/dev/null | grep -q $P; do sleep 10; done
try aws ec2 delete-launch-template --launch-template-name $P-app-lt

log "Load balancer + target group"
ALB=${ALB:-$(aws elbv2 describe-load-balancers --names $P-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)}
[ -n "$ALB" ] && [ "$ALB" != "None" ] && try aws elbv2 delete-load-balancer --load-balancer-arn "$ALB" && \
  try aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB"
TG=${TG:-$(aws elbv2 describe-target-groups --names $P-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)}
sleep 10; [ -n "$TG" ] && [ "$TG" != "None" ] && try aws elbv2 delete-target-group --target-group-arn "$TG"

log "Instances tagged Project=$P"
IDS=$(aws ec2 describe-instances --filters Name=tag:Project,Values=$P \
      Name=instance-state-name,Values=pending,running,stopping,stopped --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -n "$IDS" ]; then aws ec2 terminate-instances --instance-ids $IDS >/dev/null; aws ec2 wait instance-terminated --instance-ids $IDS; fi

log "Route 53 private zone"
for Z in ${ZONE:-} $(aws route53 list-hosted-zones-by-name --dns-name vprofile.in --query "HostedZones[?Config.Comment=='$P'].Id" --output text 2>/dev/null); do
  Z=${Z#/hostedzone/}
  aws route53 list-resource-record-sets --hosted-zone-id "$Z" --query "ResourceRecordSets[?Type=='A']" --output json > aws/.rr.json 2>/dev/null || continue
  python - <<'PY' 2>/dev/null || true
import json; rr=json.load(open('aws/.rr.json'))
json.dump({"Changes":[{"Action":"DELETE","ResourceRecordSet":r} for r in rr]}, open('aws/.del.json','w'))
PY
  [ -s aws/.del.json ] && grep -q ResourceRecordSet aws/.del.json && try aws route53 change-resource-record-sets --hosted-zone-id "$Z" --change-batch file://aws/.del.json
  try aws route53 delete-hosted-zone --id "$Z"
done
rm -f aws/.rr.json aws/.del.json

log "IAM role + instance profile"
try aws iam remove-role-from-instance-profile --instance-profile-name $P-app-profile --role-name $P-app-role
try aws iam delete-instance-profile --instance-profile-name $P-app-profile
try aws iam detach-role-policy --role-name $P-app-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
try aws iam delete-role-policy --role-name $P-app-role --policy-name s3-artifact-read
try aws iam delete-role --role-name $P-app-role

log "S3 bucket"
ACCT=${ACCT:-$(aws sts get-caller-identity --query Account --output text)}
try aws s3 rb "s3://$P-artifacts-$ACCT" --force

log "Security groups (retry until network interfaces are released)"
for i in 1 2 3 4 5 6; do
  left=0
  for name in $P-backend-sg $P-app-sg $P-elb-sg; do
    id=$(aws ec2 describe-security-groups --filters Name=group-name,Values=$name --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
    [ -z "$id" ] || [ "$id" = "None" ] && continue
    # drop cross-references first, then delete
    aws ec2 describe-security-groups --group-ids "$id" --query 'SecurityGroups[0].IpPermissions' --output json > aws/.perm.json 2>/dev/null
    try aws ec2 revoke-security-group-ingress --group-id "$id" --ip-permissions file://aws/.perm.json
    aws ec2 delete-security-group --group-id "$id" >/dev/null 2>&1 || left=1
  done
  [ $left -eq 0 ] && break; sleep 20
done
rm -f aws/.perm.json

log "Key pair"
try aws ec2 delete-key-pair --key-name $P-key
rm -f "$HOME/.ssh/$P-key.pem"

log "Leftovers check (should all be empty):"
aws ec2 describe-instances --filters Name=tag:Project,Values=$P Name=instance-state-name,Values=pending,running,stopped --query 'Reservations[].Instances[].InstanceId' --output text
aws elbv2 describe-load-balancers --query "LoadBalancers[?starts_with(LoadBalancerName,'$P')].LoadBalancerName" --output text
aws ec2 describe-security-groups --filters Name=group-name,Values="$P-*" --query 'SecurityGroups[].GroupName' --output text
rm -f "$STATE"
echo "Teardown finished."
