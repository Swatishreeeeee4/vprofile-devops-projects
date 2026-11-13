# DevOps Projects: one Java app, taken from VMs to the cloud to Kubernetes

The same multi-tier Java web app (Nginx → Tomcat → MySQL, Memcached, RabbitMQ) built and operated with a
different DevOps toolset in each project. Every project has its own branch with code, a README, and the real
problems I hit and how I fixed them.

> Built while following the *Decoding DevOps* course (Udemy), then automated and improved. Each README has a
> **"What I changed"** section.

## Projects

| # | Project | Tools | Code |
|---|---|---|---|
| 1 | **GitOps CI/CD on Amazon EKS** ⭐ | GitHub Actions, Docker, GHCR, Trivy, Helm, Argo CD, Terraform, EKS | [vprofile-gitops](https://github.com/Swatishreeeeee4/vprofile-gitops) |
| 2 | **AWS Lift & Shift** | EC2, ALB, Auto Scaling, Route 53, S3, IAM, AWS CLI | [aws-liftandshift](https://github.com/Swatishreeeeee4/vprofile-devops-projects/tree/aws-liftandshift) |
| 3 | **AWS Re-architecture** | Elastic Beanstalk, RDS, ElastiCache, Amazon MQ, CloudFront | [aws-rearch](https://github.com/Swatishreeeeee4/vprofile-devops-projects/tree/aws-rearch) |
| 4 | **Jenkins CI** (as code) | Jenkins JCasC, Maven, SonarQube, Nexus | [jenkins-ci](https://github.com/Swatishreeeeee4/vprofile-devops-projects/tree/jenkins-ci) |
| 5 | **Observability** | Prometheus, Alertmanager, Grafana, Loki, Alloy | [monitoring-observability](https://github.com/Swatishreeeeee4/vprofile-devops-projects/tree/monitoring-observability) |
| 6 | **Configuration management** | Ansible roles, Ubuntu + Rocky Linux | [ansible-config](https://github.com/Swatishreeeeee4/vprofile-devops-projects/tree/ansible-config) |
| 7 | **Containerization** | Dockerfiles (multi-stage), Docker Compose | [docker-containers](https://github.com/Swatishreeeeee4/vprofile-devops-projects/tree/docker-containers) |
| 8 | **Python automation** | boto3, pytest, moto, GitHub Actions | [devops-python-toolkit](https://github.com/Swatishreeeeee4/devops-python-toolkit) |

## How to read a project

1. Open the branch link above.
2. Read its **README**: architecture diagram, how to run it, **What I changed**, **Debugging notes**.
3. The commit history shows each fix with an explanation.
