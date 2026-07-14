## Architecture

Internet
    |
    v
Application Load Balancer
    |
    v
Target Group
    |
    v
Auto Scaling Group (Min 2, Max 5)
    |
    +------------------+
    |                  |
EC2 Instance      EC2 Instance
    |                  |
Docker              Docker
    |                  |
Day6 Container     Day6 Container

## Components

- Application Load Balancer
- Target Group with /health endpoint
- Auto Scaling Group
- Launch Template
- Security Groups
- Amazon ECR image
- EC2 Systemd-managed container
- SSM Session Manager access
- Target Tracking Policy (CPU 60%)

## Security

- HTTP allowed only through ALB
- SSH allowed only from operator public IP
- IMDSv2 enforced
- SSM for administrative access
- ECR authentication via IAM role

## Validation

Run:

```bash
./verify-infra.sh
``
