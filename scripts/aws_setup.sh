#!/usr/bin/env bash
# Provisioning Track A (EC2 + RDS MySQL) di AWS Learner Lab / Sandbox (us-east-1)
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
DB_USER="${DB_USER:-admin}"
DB_PASS="${DB_PASS:-}"
DB_NAME="${DB_NAME:-merch_preorder}"
SSH_CIDR="${SSH_CIDR:-0.0.0.0/0}"
KEY_NAME="${KEY_NAME:-merch-preorder-key}"

if [[ -z "$DB_PASS" ]]; then
  echo "Error: set DB_PASS terlebih dahulu (contoh: DB_PASS='Rahasia123!' ./scripts/aws_setup.sh)" >&2
  exit 1
fi

echo "==> Menggunakan region: $REGION"
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text --region "$REGION")
if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  echo "Error: Default VPC tidak ditemukan di $REGION" >&2
  exit 1
fi
echo "==> Default VPC: $VPC_ID"

# 1. Security Group untuk EC2 (22, 80, 443)
SG_EC2=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-ec2" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")
if [[ "$SG_EC2" == "None" || -z "$SG_EC2" ]]; then
  SG_EC2=$(aws ec2 create-security-group --group-name sg-ec2 --description "EC2 API Server (SSH, HTTP, HTTPS)" --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" --protocol tcp --port 22 --cidr "$SSH_CIDR" --region "$REGION" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" --protocol tcp --port 443 --cidr 0.0.0.0/0 --region "$REGION" >/dev/null
fi
echo "==> sg-ec2: $SG_EC2"

# 2. Security Group untuk RDS (3306 hanya dari sg-ec2)
SG_RDS=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=sg-rds" --query 'SecurityGroups[0].GroupId' --output text --region "$REGION")
if [[ "$SG_RDS" == "None" || -z "$SG_RDS" ]]; then
  SG_RDS=$(aws ec2 create-security-group --group-name sg-rds --description "RDS MySQL (only from sg-ec2)" --vpc-id "$VPC_ID" --query 'GroupId' --output text --region "$REGION")
  aws ec2 authorize-security-group-ingress --group-id "$SG_RDS" --protocol tcp --port 3306 --source-group "$SG_EC2" --region "$REGION" >/dev/null
fi
echo "==> sg-rds: $SG_RDS"

# 3. DB Subnet Group (minimal 2 AZ)
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query 'Subnets[0:2].SubnetId' --output text --region "$REGION")
FIRST_SUBNET=$(echo "$SUBNET_IDS" | awk '{print $1}')
if ! aws rds describe-db-subnet-groups --db-subnet-group-name merch-preorder-sng --region "$REGION" >/dev/null 2>&1; then
  aws rds create-db-subnet-group \
    --db-subnet-group-name merch-preorder-sng \
    --db-subnet-group-description "Subnet group for merch-preorder RDS" \
    --subnet-ids $SUBNET_IDS \
    --region "$REGION" >/dev/null
fi
echo "==> DB Subnet Group: merch-preorder-sng"

# 4. RDS MySQL (db.t3.micro, non-public)
if ! aws rds describe-db-instances --db-instance-identifier merch-preorder-db --region "$REGION" >/dev/null 2>&1; then
  echo "==> Membuat RDS MySQL merch-preorder-db (butuh ~5-10 menit)..."
  aws rds create-db-instance \
    --db-instance-identifier merch-preorder-db \
    --db-instance-class db.t3.micro \
    --engine mysql \
    --allocated-storage 20 \
    --master-username "$DB_USER" \
    --master-user-password "$DB_PASS" \
    --db-name "$DB_NAME" \
    --vpc-security-group-ids "$SG_RDS" \
    --db-subnet-group-name merch-preorder-sng \
    --no-publicly-accessible \
    --backup-retention-period 0 \
    --region "$REGION" >/dev/null
fi

# 5. Key Pair untuk SSH
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" >/dev/null 2>&1; then
  rm -f "${KEY_NAME}.pem"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query 'KeyMaterial' --output text --region "$REGION" > "${KEY_NAME}.pem"
  chmod 400 "${KEY_NAME}.pem"
  echo "==> Key pair disimpan ke ${KEY_NAME}.pem"
fi

# 6. EC2 Instance (Ubuntu 24.04 LTS, t3.micro)
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=merch-api-server" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text --region "$REGION")

if [[ "$INSTANCE_ID" == "None" || -z "$INSTANCE_ID" ]]; then
  AMI_ID=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query 'Parameter.Value' --output text --region "$REGION")
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type t3.micro \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_EC2" \
    --subnet-id "$FIRST_SUBNET" \
    --associate-public-ip-address \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=merch-api-server}]' \
    --query 'Instances[0].InstanceId' --output text --region "$REGION")
  echo "==> Menunggu EC2 running ($INSTANCE_ID)..."
  aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"
fi

EC2_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text --region "$REGION")
echo "==> EC2 Public IP: $EC2_IP"

echo "==> Menunggu RDS merch-preorder-db available..."
aws rds wait db-instance-available --db-instance-identifier merch-preorder-db --region "$REGION"
RDS_ENDPOINT=$(aws rds describe-db-instances --db-instance-identifier merch-preorder-db --query 'DBInstances[0].Endpoint.Address' --output text --region "$REGION")

echo ""
echo "=========================================="
echo "PROVISIONING SELESAI"
echo "EC2 Public IP : $EC2_IP"
echo "RDS Endpoint  : $RDS_ENDPOINT"
echo "SSH Command   : ssh -i ${KEY_NAME}.pem ubuntu@${EC2_IP}"
echo "=========================================="

