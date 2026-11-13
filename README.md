# VProfile: Re-architected on AWS managed services (fully scripted)

The same multi-tier Java app as the Lift & Shift project, but every self-managed server is replaced by an
**AWS managed service**, and the whole environment is built and destroyed with AWS CLI scripts.

> Built while following the *Decoding DevOps* course (Imran Teli, Udemy), then automated and improved by me.
> See **What I changed** below.

## Architecture

```
 Users ──HTTPS──▶ CloudFront (global CDN, HTTPS, *.cloudfront.net)
                        │ HTTP
                        ▼
              Elastic Beanstalk environment (Tomcat 10 / Corretto 17)
              ├─ Application Load Balancer (health check "/", stickiness)
              └─ Auto Scaling group: t3.micro, min 1 / max 2
                        │  (backend SG allows only the Beanstalk instances' SG)
        ┌───────────────┼──────────────────────┐
        ▼               ▼                      ▼
  RDS MySQL 8.0    ElastiCache Memcached   Amazon MQ (RabbitMQ 3.13)
  db.t4g.micro     cache.t3.micro          mq.m7g.medium, AMQPS/TLS :5671
  private          private                 private
```

| Lift & Shift (previous project) | Re-architected (this project) |
|---|---|
| MariaDB on EC2 | **Amazon RDS** (managed MySQL) |
| Memcached on EC2 | **Amazon ElastiCache** |
| RabbitMQ on EC2 | **Amazon MQ** (managed RabbitMQ over TLS) |
| Tomcat ASG + ALB built by hand | **Elastic Beanstalk** (platform-managed) |
| HTTP only | **CloudFront** with HTTPS |

## How to run

Prerequisites: AWS CLI v2 logged in, Java 17, Maven 3, Git Bash (Windows) or bash, Python 3.

```bash
bash aws/rearch-up.sh     # ~25 min (RDS / ElastiCache / MQ / Beanstalk / CloudFront)
# open the printed https://xxxx.cloudfront.net URL, log in as admin_vp / admin_vp
bash aws/rearch-down.sh   # ~25 min, deletes everything and prints a leftovers check
```

Region defaults to `ap-southeast-2`; override with `AWS_REGION=...`.

## What the scripts do

1. Backend security group (self-referencing), later opened **only** to Beanstalk's instance security group.
2. RDS MySQL (private, no public access), ElastiCache Memcached, Amazon MQ RabbitMQ (private, TLS).
3. Load the DB schema **without SSH**: a temporary instance with an IAM role runs the SQL through
   **SSM Run Command**, then terminates itself.
4. Build the WAR with the real endpoints and **passwords generated for this run**; the committed
   `application.properties` keeps only `__PLACEHOLDERS__`.
5. Beanstalk application + environment (ALB, ASG, enhanced health, IMDSv2-only, stickiness).
6. CloudFront distribution in front (HTTPS redirect, caching disabled, all headers/cookies forwarded for login).

## What I changed compared with the course

- **No secrets in Git.** The course's branch has a real RDS endpoint and **password committed in plain text**;
  here they are placeholders, filled at build time with freshly generated passwords that never touch the repo.
- **Infrastructure as code with the AWS CLI** instead of console clicks, with a teardown script and leftovers check.
- **DB initialisation through SSM Run Command** instead of SSH-ing into a bastion with keys.
- **Least-privilege network**: backend services reachable only from the Beanstalk instances' security group.
- **Teardown order solved**: the rule referencing Beanstalk's security group is revoked before terminating
  Beanstalk; otherwise Beanstalk cannot delete its own SG and the teardown hangs.
- Updated for 2026 AWS: `mq.t3.micro` is no longer offered for RabbitMQ (smallest is `mq.m7g.medium`);
  new accounts can't use launch configurations, so Beanstalk is forced onto launch templates (`DisableIMDSv1`).
- Health check on `/` (the app's `/login` is POST-only and returns 405 to a GET).

## Debugging notes (real issues hit while building)

| Symptom | Cause | Fix |
|---|---|---|
| `Could not find or load main class ...plexus...Launcher` | `MSYS_NO_PATHCONV=1` (needed for AWS CLI in Git Bash) breaks Maven's launcher | Run Maven with `env -u MSYS_NO_PATHCONV` |
| RabbitMQ page 500 "User Not Found" | Used the old URL `/user/rabbit`; in this version it's `/rabbit` | Read the controller mappings |
| Logs: `Neither BindingResult nor plain target object for bean 'user'` | Same wrong URL matched `/user/{username}` | as above |

## Production notes

- Custom domain + ACM certificate on CloudFront; restrict the ALB to CloudFront only.
- Secrets Manager (with rotation) instead of build-time injection; RDS Multi-AZ and backups on.
- Private subnets + VPC endpoints; CI/CD pipeline deploying new Beanstalk versions (next projects).

## Tech

Elastic Beanstalk, RDS, ElastiCache, Amazon MQ, CloudFront, IAM roles, SSM Run Command, Security Groups ·
AWS CLI · Bash · Java 17 / Spring 6 · Maven · Tomcat 10
