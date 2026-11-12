# VProfile: Lift & Shift to AWS (fully scripted)

A multi-tier Java web application (Spring MVC on Tomcat, MariaDB, Memcached, RabbitMQ) moved
from local VMs to AWS, with the **whole environment created and destroyed by AWS CLI scripts**.

> Built while following the *Decoding DevOps* course (Imran Teli, Udemy), then automated and
> improved by me. See **What I changed** below.

## Architecture

```
            Internet
               │  HTTP :80
     ┌─────────▼──────────┐   SG: elb-sg (80 from anywhere)
     │ Application LB      │
     └─────────┬──────────┘
               │  :8080   (target group, health check /, sticky sessions)
     ┌─────────▼──────────┐   SG: app-sg (8080 only from elb-sg)
     │ Auto Scaling Group  │   Ubuntu 24.04 + Tomcat 10, t3.micro, min 1 / max 2,
     │  app tier           │   target tracking: avg CPU 50%
     └──┬───────┬───────┬─┘   IAM role → reads the WAR from S3 (no keys on servers)
        │       │       │
   db01.vprofile.in  mc01.vprofile.in  rmq01.vprofile.in      ← Route 53 PRIVATE hosted zone
   MariaDB :3306     Memcached :11211  RabbitMQ :5672         SG: backend-sg (ports only from app-sg)
   (Amazon Linux 2023, configured by EC2 user data)

   S3: vprofile-ls-artifacts-<account>  ← vprofile-v2.war (built with Maven)
```

## How to run

Prerequisites: AWS CLI v2 logged in, Java 17, Maven 3, Git Bash (Windows) or any bash.

```bash
mvn -DskipTests install                 # builds target/vprofile-v2.war
bash aws/liftandshift-up.sh             # ~5 min; prints the load balancer URL
# wait ~8-10 min for the app server to finish user data, then open the URL
# login: admin_vp / admin_vp
bash aws/liftandshift-down.sh           # deletes everything and prints a leftovers check
```

Region defaults to `ap-southeast-2`; override with `AWS_REGION=us-east-1 bash aws/liftandshift-up.sh`.

## What the scripts create

| Resource | Purpose |
|---|---|
| 3 security groups (ELB → app → backend) | Each tier accepts traffic **only from the tier in front** (SG references) |
| Key pair | SSH for troubleshooting (from my IP only) |
| S3 bucket + WAR upload | Artifact storage |
| IAM role + instance profile | `s3:GetObject` on the artifact bucket only, plus SSM Session Manager |
| 3 EC2 instances (db01, mc01, rmq01) | Backend services, set up by `userdata/*.sh` |
| Route 53 private hosted zone `vprofile.in` | Stable DNS names used in `application.properties` |
| Target group + Application Load Balancer | Public entry point, health checks, stickiness |
| Launch template + Auto Scaling group | App tier that builds itself from S3 on boot; scales on CPU |

## What I changed compared with the course

- **Infrastructure as code with the AWS CLI** instead of console clicks: one command up, one command down, with a
  leftovers check so nothing is forgotten (and billed).
- **App servers configure themselves** (`userdata/app_tomcat_s3.sh`): the launch template pulls the WAR from S3
  using the instance role, so no hand-made AMI is needed and every scaled-out server is identical.
- **Least-privilege network**: backend ports open only to the app security group; app port only to the ALB.
- **Windows line-ending bug fixed**: user-data scripts had CRLF endings (breaks `#!/bin/bash` on Linux);
  converted to LF and protected with `.gitattributes`.
- Removed a duplicate manual `memcached -d` start (systemd already runs it).
- Handled a real first-run failure in new AWS accounts (Auto Scaling service-linked role not ready) with retries.
- `set -euo pipefail` in the app bootstrap so failures stop loudly.

## Known lab shortcuts (would change for production)

- HTTP only. Production: ACM certificate + HTTPS listener + HTTP→HTTPS redirect (needs a domain).
- Passwords (`admin123`, `test`) are in scripts and `application.properties`. Production: AWS Secrets Manager.
- Backend runs on single EC2 instances in the default VPC. Production: private subnets + NAT, or managed
  services (RDS, ElastiCache, Amazon MQ), which is the next project ("Re-architecting").

## Tech

AWS EC2, ALB, Auto Scaling, Route 53 (private zone), S3, IAM roles, Security Groups, EC2 user data ·
Bash · AWS CLI · Java 17 / Spring · Maven · Tomcat 10 · MariaDB · Memcached · RabbitMQ
