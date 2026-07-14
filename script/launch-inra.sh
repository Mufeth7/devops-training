#!/bin/bash

set -euo pipefail

REGION="ap-south-1"
APP_NAME="test-app"
INSTANCE_TYPE="t3.micro"
AMI_ID="$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameter.Value' \
  --output text)"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

ECR_REPO="day6-app"
IMAGE_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${ECR_REPO}:latest"

INSTANCE_PROFILE="EC2-SSM-ECR-Role"

MY_IP="$(curl -s https://checkip.amazonaws.com)/32"

VPC_ID="$(aws ec2 describe-vpcs \
  --filters Name=isDefault,Values=true \
  --query 'Vpcs[0].VpcId' \
  --output text)"

SUBNETS="$(aws ec2 describe-subnets \
  --filters Name=vpc-id,Values=${VPC_ID} \
  --query 'Subnets[*].SubnetId' \
  --output text)"

SUBNET1=$(echo $SUBNETS | awk '{print $1}')
SUBNET2=$(echo $SUBNETS | awk '{print $2}')

echo "Creating ALB security group..."

ALB_SG=$(aws ec2 create-security-group \
  --group-name "${APP_NAME}-alb-sg" \
  --description "ALB SG" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG" \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0

echo "Creating EC2 security group..."

EC2_SG=$(aws ec2 create-security-group \
  --group-name "${APP_NAME}-ec2-sg" \
  --description "EC2 SG" \
  --vpc-id "$VPC_ID" \
  --query GroupId \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG" \
  --protocol tcp \
  --port 22 \
  --cidr "$MY_IP"

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG" \
  --protocol tcp \
  --port 80 \
  --source-group "$ALB_SG"

cat > userdata.sh <<EOF
#!/bin/bash
yum update -y

dnf install -y docker

systemctl enable docker
systemctl start docker

aws ecr get-login-password --region ${REGION} | \
docker login --username AWS --password-stdin \
${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com

docker pull ${IMAGE_URI}

docker rm -f day6-app || true

cat >/etc/systemd/system/day6-app.service <<SERVICE
[Unit]
Description=Day6 Docker Application
After=docker.service

[Service]
Restart=always
ExecStart=/usr/bin/docker run --name day6-app -p 80:80 ${IMAGE_URI}
ExecStop=/usr/bin/docker stop day6-app

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable day6-app
systemctl start day6-app
EOF

USER_DATA=$(base64 -w0 userdata.sh)

echo "Creating launch template..."

aws ec2 create-launch-template \
  --launch-template-name "${APP_NAME}-lt" \
  --launch-template-data "{
    \"ImageId\":\"${AMI_ID}\",
    \"InstanceType\":\"${INSTANCE_TYPE}\",
    \"IamInstanceProfile\":{\"Name\":\"${INSTANCE_PROFILE}\"},
    \"SecurityGroupIds\":[\"${EC2_SG}\"],
    \"UserData\":\"${USER_DATA}\",
    \"MetadataOptions\":{
      \"HttpTokens\":\"required\"
    }
}" >/dev/null

echo "Creating target group..."

TG_ARN=$(aws elbv2 create-target-group \
  --name "${APP_NAME}-tg" \
  --protocol HTTP \
  --port 80 \
  --target-type instance \
  --vpc-id "$VPC_ID" \
  --health-check-path "/health" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)

echo "Creating ALB..."

ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${APP_NAME}-alb" \
  --subnets "$SUBNET1" "$SUBNET2" \
  --security-groups "$ALB_SG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text)

aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  >/dev/null

echo "Creating ASG..."

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "${APP_NAME}-asg" \
  --launch-template LaunchTemplateName="${APP_NAME}-lt",Version='$Latest' \
  --min-size 2 \
  --max-size 5 \
  --desired-capacity 2 \
  --vpc-zone-identifier "${SUBNET1},${SUBNET2}" \
  --target-group-arns "$TG_ARN"

cat > target-tracking.json <<EOF
{
  "TargetValue": 60.0,
  "PredefinedMetricSpecification": {
    "PredefinedMetricType": "ASGAverageCPUUtilization"
  }
}
EOF

aws autoscaling put-scaling-policy \
  --auto-scaling-group-name "${APP_NAME}-asg" \
  --policy-name cpu60-target \
  --policy-type TargetTrackingScaling \
  --target-tracking-configuration file://target-tracking.json

echo
echo "ALB DNS: http://${ALB_DNS}"
echo "Deployment complete."
