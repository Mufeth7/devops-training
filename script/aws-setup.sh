#!/bin/bash
set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Using Account ID: ${ACCOUNT_ID}"

###############################################################################
# 1. Create DevOpsAdmin role
###############################################################################

cat > devopsadmin-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name DevOpsAdmin \
  --assume-role-policy-document file://devopsadmin-trust.json

cat > devopsadmin-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DevOpsAdminPermissions",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeVpcs",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "s3:ListAllMyBuckets",
        "s3:ListBucket",
        "cloudwatch:GetMetricStatistics",
        "cloudwatch:ListMetrics",
        "logs:DescribeLogGroups",
        "logs:GetLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name DevOpsAdmin \
  --policy-name DevOpsAdminInlinePolicy \
  --policy-document file://devopsadmin-policy.json

###############################################################################
# 2. Create ReadOnlyAuditor role
###############################################################################

aws iam create-role \
  --role-name ReadOnlyAuditor \
  --assume-role-policy-document file://devopsadmin-trust.json

cat > readonly-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadOnlyAudit",
      "Effect": "Allow",
      "Action": [
        "iam:GetAccountSummary",
        "iam:ListUsers",
        "iam:ListRoles",
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes",
        "ec2:DescribeSecurityGroups",
        "s3:ListAllMyBuckets",
        "s3:GetBucketLocation",
        "cloudtrail:DescribeTrails",
        "cloudtrail:GetTrailStatus"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name ReadOnlyAuditor \
  --policy-name ReadOnlyAuditorInlinePolicy \
  --policy-document file://readonly-policy.json

###############################################################################
# 3. Create CICDDeployer role
###############################################################################

cat > cicd-trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:root"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name CICDDeployer \
  --assume-role-policy-document file://cicd-trust.json

cat > cicd-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DeployPermissions",
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateStack",
        "cloudformation:UpdateStack",
        "cloudformation:DescribeStacks",
        "codebuild:StartBuild",
        "codebuild:BatchGetBuilds",
        "codedeploy:CreateDeployment",
        "codedeploy:GetDeployment",
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name CICDDeployer \
  --policy-name CICDDeployerInlinePolicy \
  --policy-document file://cicd-policy.json

###############################################################################
# 4. Assume ReadOnlyAuditor role and list S3 buckets
###############################################################################

ROLE_CREDS=$(aws sts assume-role \
  --role-arn arn:aws:iam::${ACCOUNT_ID}:role/ReadOnlyAuditor \
  --role-session-name AuditorSession)

export AWS_ACCESS_KEY_ID=$(echo "$ROLE_CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$ROLE_CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$ROLE_CREDS" | jq -r '.Credentials.SessionToken')

echo "Listing S3 buckets using assumed ReadOnlyAuditor role..."
aws s3api list-buckets --query 'Buckets[].Name' --output table

###############################################################################
# 5. Generate IAM credential report and find users without MFA
###############################################################################

unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN

aws iam generate-credential-report

STATE=""
while [[ "$STATE" != "COMPLETE" ]]; do
  sleep 2
  STATE=$(aws iam generate-credential-report \
    --query State \
    --output text)
done

aws iam get-credential-report \
  --query Content \
  --output text \
| base64 -d > credential-report.csv

echo
echo "Users without MFA enabled:"
awk -F',' '
NR==1{
  for(i=1;i<=NF;i++)
    if($i=="mfa_active") mfa=i
  next
}
$mfa=="false" {
  print $1
}
' credential-report.csv
