#!/bin/bash
# =================================================================
# PROJECT  : 3-Tier Java Login Application on AWS
# SCRIPT   : 01-infrastructure.sh
# PURPOSE  : Deploy VPCs, Subnets, IGWs, NAT, TGW, SGs,
#            Bastion Host, RDS, and Global AMI Base Instance
# AUTHOR   : vicogwa
# USAGE    : bash scripts/01-infrastructure.sh 2>&1 | tee ~/3tier-deploy.log
# NEXT     : bash scripts/02-golden-amis.sh
# =================================================================

set -e

# -----------------------------------------------------------------
# CONFIGURATION — Update before running
# -----------------------------------------------------------------
REGION="us-east-1"
KEY_NAME="3tier-key"
RESOURCES_FILE=~/3tier-resources.env
LOG_FILE=~/3tier-deploy.log

# -----------------------------------------------------------------
# HELPERS
# -----------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

save() {
  # Remove existing entry then append fresh value
  sed -i "/^export $1=/d" $RESOURCES_FILE 2>/dev/null || true
  echo "export $1=$2" >> $RESOURCES_FILE
}

# -----------------------------------------------------------------
# INIT
# -----------------------------------------------------------------
> $RESOURCES_FILE
log "================================================================"
log "3-TIER AWS DEPLOYMENT — PHASE 1: INFRASTRUCTURE"
log "Region: $REGION"
log "================================================================"

# =================================================================
# SECTION 1 — VPCs
# =================================================================
log "--- [1/11] Creating VPCs ---"

BASTION_VPC=$(aws ec2 create-vpc \
  --cidr-block 192.168.0.0/16 \
  --region $REGION \
  --query 'Vpc.VpcId' \
  --output text)
aws ec2 create-tags --resources $BASTION_VPC \
  --tags Key=Name,Value=Bastion-VPC --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $BASTION_VPC \
  --enable-dns-hostnames --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $BASTION_VPC \
  --enable-dns-support --region $REGION
save "BASTION_VPC" "$BASTION_VPC"
log "Bastion VPC created: $BASTION_VPC"

APP_VPC=$(aws ec2 create-vpc \
  --cidr-block 172.32.0.0/16 \
  --region $REGION \
  --query 'Vpc.VpcId' \
  --output text)
aws ec2 create-tags --resources $APP_VPC \
  --tags Key=Name,Value=App-VPC --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $APP_VPC \
  --enable-dns-hostnames --region $REGION
aws ec2 modify-vpc-attribute --vpc-id $APP_VPC \
  --enable-dns-support --region $REGION
save "APP_VPC" "$APP_VPC"
log "App VPC created: $APP_VPC"

# =================================================================
# SECTION 2 — Subnets
# =================================================================
log "--- [2/11] Creating Subnets ---"

BASTION_PUB_SUB=$(aws ec2 create-subnet \
  --vpc-id $BASTION_VPC \
  --cidr-block 192.168.1.0/24 \
  --availability-zone ${REGION}a \
  --region $REGION \
  --query 'Subnet.SubnetId' \
  --output text)
aws ec2 create-tags --resources $BASTION_PUB_SUB \
  --tags Key=Name,Value=Bastion-Public-Subnet --region $REGION
aws ec2 modify-subnet-attribute \
  --subnet-id $BASTION_PUB_SUB \
  --map-public-ip-on-launch --region $REGION
save "BASTION_PUB_SUB" "$BASTION_PUB_SUB"
log "Bastion Public Subnet: $BASTION_PUB_SUB"

APP_PUB_SUB_1=$(aws ec2 create-subnet \
  --vpc-id $APP_VPC \
  --cidr-block 172.32.1.0/24 \
  --availability-zone ${REGION}a \
  --region $REGION \
  --query 'Subnet.SubnetId' \
  --output text)
aws ec2 create-tags --resources $APP_PUB_SUB_1 \
  --tags Key=Name,Value=App-Public-Subnet-1 --region $REGION
aws ec2 modify-subnet-attribute \
  --subnet-id $APP_PUB_SUB_1 \
  --map-public-ip-on-launch --region $REGION
save "APP_PUB_SUB_1" "$APP_PUB_SUB_1"
log "App Public Subnet 1: $APP_PUB_SUB_1"

APP_PUB_SUB_2=$(aws ec2 create-subnet \
  --vpc-id $APP_VPC \
  --cidr-block 172.32.2.0/24 \
  --availability-zone ${REGION}b \
  --region $REGION \
  --query 'Subnet.SubnetId' \
  --output text)
aws ec2 create-tags --resources $APP_PUB_SUB_2 \
  --tags Key=Name,Value=App-Public-Subnet-2 --region $REGION
aws ec2 modify-subnet-attribute \
  --subnet-id $APP_PUB_SUB_2 \
  --map-public-ip-on-launch --region $REGION
save "APP_PUB_SUB_2" "$APP_PUB_SUB_2"
log "App Public Subnet 2: $APP_PUB_SUB_2"

APP_PRIV_SUB_1=$(aws ec2 create-subnet \
  --vpc-id $APP_VPC \
  --cidr-block 172.32.3.0/24 \
  --availability-zone ${REGION}a \
  --region $REGION \
  --query 'Subnet.SubnetId' \
  --output text)
aws ec2 create-tags --resources $APP_PRIV_SUB_1 \
  --tags Key=Name,Value=App-Private-Subnet-1 --region $REGION
save "APP_PRIV_SUB_1" "$APP_PRIV_SUB_1"
log "App Private Subnet 1: $APP_PRIV_SUB_1"

APP_PRIV_SUB_2=$(aws ec2 create-subnet \
  --vpc-id $APP_VPC \
  --cidr-block 172.32.4.0/24 \
  --availability-zone ${REGION}b \
  --region $REGION \
  --query 'Subnet.SubnetId' \
  --output text)
aws ec2 create-tags --resources $APP_PRIV_SUB_2 \
  --tags Key=Name,Value=App-Private-Subnet-2 --region $REGION
save "APP_PRIV_SUB_2" "$APP_PRIV_SUB_2"
log "App Private Subnet 2: $APP_PRIV_SUB_2"

# =================================================================
# SECTION 3 — Internet Gateways
# =================================================================
log "--- [3/11] Creating Internet Gateways ---"

BASTION_IGW=$(aws ec2 create-internet-gateway \
  --region $REGION \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)
aws ec2 create-tags --resources $BASTION_IGW \
  --tags Key=Name,Value=Bastion-IGW --region $REGION
aws ec2 attach-internet-gateway \
  --internet-gateway-id $BASTION_IGW \
  --vpc-id $BASTION_VPC --region $REGION
save "BASTION_IGW" "$BASTION_IGW"
log "Bastion IGW: $BASTION_IGW"

APP_IGW=$(aws ec2 create-internet-gateway \
  --region $REGION \
  --query 'InternetGateway.InternetGatewayId' \
  --output text)
aws ec2 create-tags --resources $APP_IGW \
  --tags Key=Name,Value=App-IGW --region $REGION
aws ec2 attach-internet-gateway \
  --internet-gateway-id $APP_IGW \
  --vpc-id $APP_VPC --region $REGION
save "APP_IGW" "$APP_IGW"
log "App IGW: $APP_IGW"

# =================================================================
# SECTION 4 — Public Route Tables
# =================================================================
log "--- [4/11] Creating Public Route Tables ---"

BASTION_RT=$(aws ec2 create-route-table \
  --vpc-id $BASTION_VPC --region $REGION \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $BASTION_RT \
  --tags Key=Name,Value=Bastion-Public-RT --region $REGION
aws ec2 create-route --route-table-id $BASTION_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $BASTION_IGW --region $REGION
aws ec2 associate-route-table \
  --route-table-id $BASTION_RT \
  --subnet-id $BASTION_PUB_SUB --region $REGION
save "BASTION_RT" "$BASTION_RT"
log "Bastion Route Table: $BASTION_RT"

APP_PUB_RT=$(aws ec2 create-route-table \
  --vpc-id $APP_VPC --region $REGION \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $APP_PUB_RT \
  --tags Key=Name,Value=App-Public-RT --region $REGION
aws ec2 create-route --route-table-id $APP_PUB_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $APP_IGW --region $REGION
aws ec2 associate-route-table \
  --route-table-id $APP_PUB_RT \
  --subnet-id $APP_PUB_SUB_1 --region $REGION
aws ec2 associate-route-table \
  --route-table-id $APP_PUB_RT \
  --subnet-id $APP_PUB_SUB_2 --region $REGION
save "APP_PUB_RT" "$APP_PUB_RT"
log "App Public Route Table: $APP_PUB_RT"

# =================================================================
# SECTION 5 — NAT Gateway
# =================================================================
log "--- [5/11] Creating NAT Gateway ---"

NAT_EIP=$(aws ec2 allocate-address \
  --domain vpc --region $REGION \
  --query 'AllocationId' --output text)
save "NAT_EIP" "$NAT_EIP"
log "NAT Elastic IP allocated: $NAT_EIP"

NAT_GW=$(aws ec2 create-nat-gateway \
  --subnet-id $APP_PUB_SUB_1 \
  --allocation-id $NAT_EIP \
  --region $REGION \
  --query 'NatGateway.NatGatewayId' \
  --output text)
aws ec2 create-tags --resources $NAT_GW \
  --tags Key=Name,Value=App-NAT-GW --region $REGION
save "NAT_GW" "$NAT_GW"
log "NAT Gateway created: $NAT_GW — waiting to become available..."
aws ec2 wait nat-gateway-available \
  --nat-gateway-ids $NAT_GW --region $REGION
log "NAT Gateway is ready"

# =================================================================
# SECTION 6 — Private Route Table
# =================================================================
log "--- [6/11] Creating Private Route Table ---"

APP_PRIV_RT=$(aws ec2 create-route-table \
  --vpc-id $APP_VPC --region $REGION \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $APP_PRIV_RT \
  --tags Key=Name,Value=App-Private-RT --region $REGION
aws ec2 create-route --route-table-id $APP_PRIV_RT \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id $NAT_GW --region $REGION
aws ec2 associate-route-table \
  --route-table-id $APP_PRIV_RT \
  --subnet-id $APP_PRIV_SUB_1 --region $REGION
aws ec2 associate-route-table \
  --route-table-id $APP_PRIV_RT \
  --subnet-id $APP_PRIV_SUB_2 --region $REGION
save "APP_PRIV_RT" "$APP_PRIV_RT"
log "App Private Route Table: $APP_PRIV_RT"

# =================================================================
# SECTION 7 — Transit Gateway
# =================================================================
log "--- [7/11] Creating Transit Gateway ---"

TGW=$(aws ec2 create-transit-gateway \
  --description "3Tier-Project-TGW" \
  --region $REGION \
  --query 'TransitGateway.TransitGatewayId' \
  --output text)
aws ec2 create-tags --resources $TGW \
  --tags Key=Name,Value=3Tier-TGW --region $REGION
save "TGW" "$TGW"
log "Transit Gateway: $TGW — waiting 60 seconds for it to become available..."
sleep 60

TGW_ATTACH_BASTION=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id $TGW \
  --vpc-id $BASTION_VPC \
  --subnet-ids $BASTION_PUB_SUB \
  --region $REGION \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' \
  --output text)
save "TGW_ATTACH_BASTION" "$TGW_ATTACH_BASTION"
log "TGW Bastion Attachment: $TGW_ATTACH_BASTION"

TGW_ATTACH_APP=$(aws ec2 create-transit-gateway-vpc-attachment \
  --transit-gateway-id $TGW \
  --vpc-id $APP_VPC \
  --subnet-ids $APP_PUB_SUB_1 \
  --region $REGION \
  --query 'TransitGatewayVpcAttachment.TransitGatewayAttachmentId' \
  --output text)
save "TGW_ATTACH_APP" "$TGW_ATTACH_APP"
log "TGW App Attachment: $TGW_ATTACH_APP"

log "Waiting 90 seconds for TGW attachments to become available..."
sleep 90

aws ec2 create-route --route-table-id $BASTION_RT \
  --destination-cidr-block 172.32.0.0/16 \
  --transit-gateway-id $TGW --region $REGION
aws ec2 create-route --route-table-id $APP_PUB_RT \
  --destination-cidr-block 192.168.0.0/16 \
  --transit-gateway-id $TGW --region $REGION
aws ec2 create-route --route-table-id $APP_PRIV_RT \
  --destination-cidr-block 192.168.0.0/16 \
  --transit-gateway-id $TGW --region $REGION
log "Cross-VPC routes added to all route tables"

# =================================================================
# SECTION 8 — Security Groups
# =================================================================
log "--- [8/11] Creating Security Groups ---"

BASTION_SG=$(aws ec2 create-security-group \
  --group-name Bastion-SG \
  --description "Bastion Host Security Group" \
  --vpc-id $BASTION_VPC --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $BASTION_SG --protocol tcp \
  --port 22 --cidr 0.0.0.0/0 --region $REGION
aws ec2 create-tags --resources $BASTION_SG \
  --tags Key=Name,Value=Bastion-SG --region $REGION
save "BASTION_SG" "$BASTION_SG"
log "Bastion SG: $BASTION_SG"

NGINX_SG=$(aws ec2 create-security-group \
  --group-name Nginx-SG \
  --description "Nginx Frontend Security Group" \
  --vpc-id $APP_VPC --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $NGINX_SG --protocol tcp \
  --port 80 --cidr 0.0.0.0/0 --region $REGION
aws ec2 authorize-security-group-ingress \
  --group-id $NGINX_SG --protocol tcp \
  --port 22 --cidr 192.168.0.0/16 --region $REGION
aws ec2 create-tags --resources $NGINX_SG \
  --tags Key=Name,Value=Nginx-SG --region $REGION
save "NGINX_SG" "$NGINX_SG"
log "Nginx SG: $NGINX_SG"

TOMCAT_SG=$(aws ec2 create-security-group \
  --group-name Tomcat-SG \
  --description "Tomcat Backend Security Group" \
  --vpc-id $APP_VPC --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $TOMCAT_SG --protocol tcp \
  --port 8080 --cidr 172.32.0.0/16 --region $REGION
aws ec2 authorize-security-group-ingress \
  --group-id $TOMCAT_SG --protocol tcp \
  --port 22 --cidr 192.168.0.0/16 --region $REGION
aws ec2 create-tags --resources $TOMCAT_SG \
  --tags Key=Name,Value=Tomcat-SG --region $REGION
save "TOMCAT_SG" "$TOMCAT_SG"
log "Tomcat SG: $TOMCAT_SG"

RDS_SG=$(aws ec2 create-security-group \
  --group-name RDS-SG \
  --description "RDS MySQL Security Group" \
  --vpc-id $APP_VPC --region $REGION \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG --protocol tcp \
  --port 3306 --cidr 172.32.0.0/16 --region $REGION
aws ec2 authorize-security-group-ingress \
  --group-id $RDS_SG --protocol tcp \
  --port 3306 --cidr 192.168.0.0/16 --region $REGION
aws ec2 create-tags --resources $RDS_SG \
  --tags Key=Name,Value=RDS-SG --region $REGION
save "RDS_SG" "$RDS_SG"
log "RDS SG: $RDS_SG"

# =================================================================
# SECTION 9 — Bastion Host
# =================================================================
log "--- [9/11] Launching Bastion Host ---"

AMZN2_AMI=$(aws ec2 describe-images \
  --owners amazon \
  --filters \
    "Name=name,Values=amzn2-ami-hvm-2.0.*-x86_64-gp2" \
    "Name=state,Values=available" \
  --region $REGION \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text)
save "AMZN2_AMI" "$AMZN2_AMI"
log "Amazon Linux 2 AMI: $AMZN2_AMI"

BASTION_INSTANCE=$(aws ec2 run-instances \
  --image-id $AMZN2_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $BASTION_PUB_SUB \
  --security-group-ids $BASTION_SG \
  --associate-public-ip-address \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Bastion-Host}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
save "BASTION_INSTANCE" "$BASTION_INSTANCE"
log "Bastion Instance: $BASTION_INSTANCE"

BASTION_EIP=$(aws ec2 allocate-address \
  --domain vpc --region $REGION \
  --query 'AllocationId' --output text)
save "BASTION_EIP" "$BASTION_EIP"

log "Waiting for Bastion to be running..."
aws ec2 wait instance-running \
  --instance-ids $BASTION_INSTANCE --region $REGION

aws ec2 associate-address \
  --instance-id $BASTION_INSTANCE \
  --allocation-id $BASTION_EIP --region $REGION

BASTION_PUBLIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids $BASTION_EIP --region $REGION \
  --query 'Addresses[0].PublicIp' --output text)
save "BASTION_PUBLIC_IP" "$BASTION_PUBLIC_IP"
log "Bastion Public IP: $BASTION_PUBLIC_IP"

# =================================================================
# SECTION 10 — RDS MySQL (Multi-AZ)
# =================================================================
log "--- [10/11] Creating RDS MySQL Multi-AZ Instance ---"

aws rds create-db-subnet-group \
  --db-subnet-group-name rds-subnet-group \
  --db-subnet-group-description "3-Tier Project RDS Subnet Group" \
  --subnet-ids $APP_PRIV_SUB_1 $APP_PRIV_SUB_2 \
  --region $REGION

aws rds create-db-instance \
  --db-instance-identifier threetier-mysql \
  --db-instance-class db.t3.micro \
  --engine mysql \
  --engine-version 8.0 \
  --master-username admin \
  --master-user-password Admin123! \
  --db-name java3tier_db \
  --vpc-security-group-ids $RDS_SG \
  --db-subnet-group-name rds-subnet-group \
  --multi-az \
  --allocated-storage 20 \
  --storage-type gp2 \
  --no-publicly-accessible \
  --region $REGION

log "RDS creation started — takes 10-15 minutes. Continuing with AMI base..."

# =================================================================
# SECTION 11 — Global AMI Base Instance
# =================================================================
log "--- [11/11] Launching Global AMI Base Instance ---"

BASE_INSTANCE=$(aws ec2 run-instances \
  --image-id $AMZN2_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $APP_PUB_SUB_1 \
  --security-group-ids $NGINX_SG \
  --associate-public-ip-address \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Global-AMI-Base}]' \
  --user-data '#!/bin/bash
set -e
exec > /var/log/user-data.log 2>&1

yum update -y

# ── AWS CLI v2 ──────────────────────────────────────────────
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip /tmp/awscliv2.zip -d /tmp/
sudo /tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws/

# ── CloudWatch Agent ────────────────────────────────────────
yum install -y amazon-cloudwatch-agent

# ── Custom Memory Metric Script ─────────────────────────────
cat > /usr/local/bin/memory-metrics.sh << METRICS
#!/bin/bash
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
MEMORY_TOTAL=$(free -m | awk "/^Mem:/{print \$2}")
MEMORY_USED=$(free -m | awk "/^Mem:/{print \$3}")
MEMORY_PERCENT=$(echo "scale=2; $MEMORY_USED / $MEMORY_TOTAL * 100" | bc)
/usr/local/aws-cli/v2/current/bin/aws cloudwatch put-metric-data \
  --namespace CWAgent \
  --metric-name MemoryUtilization \
  --value $MEMORY_PERCENT \
  --unit Percent \
  --dimensions InstanceId=$INSTANCE_ID \
  --region us-east-1
METRICS
chmod +x /usr/local/bin/memory-metrics.sh

# Schedule memory metrics every minute via cron
echo "* * * * * root /usr/local/bin/memory-metrics.sh" >> /etc/crontab

# ── SSM Agent ───────────────────────────────────────────────
systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

echo "Global AMI base setup complete" >> /var/log/user-data.log' \
  --query 'Instances[0].InstanceId' \
  --output text)

save "BASE_INSTANCE" "$BASE_INSTANCE"
log "Base Instance: $BASE_INSTANCE"

log "Waiting for base instance to be running..."
aws ec2 wait instance-running \
  --instance-ids $BASE_INSTANCE --region $REGION
log "Base instance running — waiting 3 minutes for user data to complete..."
sleep 180

BASE_IP=$(aws ec2 describe-instances \
  --instance-ids $BASE_INSTANCE \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
save "BASE_IP" "$BASE_IP"
save "REGION" "$REGION"
save "KEY_NAME" "$KEY_NAME"

log "================================================================"
log "PHASE 1 COMPLETE — All resource IDs saved to: $RESOURCES_FILE"
log "================================================================"
log "Bastion Host IP  : $BASTION_PUBLIC_IP"
log "Base Instance IP : $BASE_IP"
log "RDS              : Still provisioning in background"
log "================================================================"
log "NEXT STEP: bash scripts/02-golden-amis.sh"
log "================================================================"
