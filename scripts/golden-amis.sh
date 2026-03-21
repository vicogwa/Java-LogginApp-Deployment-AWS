#!/bin/bash
# =================================================================
# PROJECT  : 3-Tier Java Login Application on AWS
# SCRIPT   : 02-golden-amis.sh
# PURPOSE  : Create Global AMI, Nginx Golden AMI,
#            Tomcat Golden AMI, and Maven Golden AMI
# AUTHOR   : vicogwa
# USAGE    : bash scripts/02-golden-amis.sh 2>&1 | tee -a ~/3tier-deploy.log
# REQUIRES : 01-infrastructure.sh must have completed successfully
# NEXT     : bash scripts/03-app-deploy.sh
# =================================================================

set -e

source ~/3tier-resources.env

LOG_FILE=~/3tier-deploy.log

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

save() {
  sed -i "/^export $1=/d" ~/3tier-resources.env 2>/dev/null || true
  echo "export $1=$2" >> ~/3tier-resources.env
}

log "================================================================"
log "3-TIER AWS DEPLOYMENT — PHASE 2: GOLDEN AMIs"
log "================================================================"

# =================================================================
# STEP 1 — Verify Base Instance User Data Completed
# =================================================================
log "--- [1/8] Verifying Global AMI Base Instance ---"

log "Connecting to base instance at $BASE_IP to verify setup..."
ssh -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=30 \
  ec2-user@$BASE_IP << 'VERIFY'
echo "=== AWS CLI Version ==="
aws --version

echo "=== SSM Agent Status ==="
sudo systemctl status amazon-ssm-agent | grep -E "Active|Loaded"

echo "=== CloudWatch Agent ==="
sudo systemctl status amazon-cloudwatch-agent | grep -E "Active|Loaded" || echo "CloudWatch agent installed but not started - normal at this stage"

echo "=== Memory Metric Script ==="
cat /usr/local/bin/memory-metrics.sh

echo "=== Cron Entry ==="
grep memory /etc/crontab

echo "=== User Data Log ==="
tail -5 /var/log/user-data.log

echo "--- Base instance verification PASSED ---"
VERIFY

# =================================================================
# STEP 2 — Create Global AMI
# =================================================================
log "--- [2/8] Creating Global AMI ---"

GLOBAL_AMI=$(aws ec2 create-image \
  --instance-id $BASE_INSTANCE \
  --name "GlobalAMI-Base-$(date +%Y%m%d)" \
  --description "Global base AMI: AWS CLI v2, CloudWatch Agent, SSM Agent, Memory Metrics" \
  --no-reboot \
  --region $REGION \
  --query 'ImageId' \
  --output text)
save "GLOBAL_AMI" "$GLOBAL_AMI"
log "Global AMI: $GLOBAL_AMI — waiting for it to become available..."
aws ec2 wait image-available \
  --image-ids $GLOBAL_AMI --region $REGION
log "Global AMI ready: $GLOBAL_AMI"

# =================================================================
# STEP 3 — Launch Nginx Base Instance
# =================================================================
log "--- [3/8] Launching Nginx AMI Base Instance ---"

NGINX_BASE=$(aws ec2 run-instances \
  --image-id $GLOBAL_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $APP_PUB_SUB_1 \
  --security-group-ids $NGINX_SG \
  --associate-public-ip-address \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Nginx-AMI-Base}]' \
  --user-data '#!/bin/bash
exec > /var/log/user-data.log 2>&1
amazon-linux-extras install nginx1 -y
systemctl enable nginx
systemctl start nginx
echo "Nginx setup complete"' \
  --query 'Instances[0].InstanceId' \
  --output text)
save "NGINX_BASE" "$NGINX_BASE"
log "Nginx Base Instance: $NGINX_BASE"

aws ec2 wait instance-running \
  --instance-ids $NGINX_BASE --region $REGION
log "Nginx base running — waiting 2 minutes for setup to complete..."
sleep 120

NGINX_BASE_IP=$(aws ec2 describe-instances \
  --instance-ids $NGINX_BASE \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
save "NGINX_BASE_IP" "$NGINX_BASE_IP"

# =================================================================
# STEP 4 — Verify Nginx and Create Golden AMI
# =================================================================
log "--- [4/8] Verifying Nginx and Creating Golden AMI ---"

ssh -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=30 \
  ec2-user@$NGINX_BASE_IP << 'VERIFY'
echo "=== Nginx Status ==="
sudo systemctl status nginx | grep -E "Active|Loaded"
echo "=== Memory Metrics Script ==="
ls -la /usr/local/bin/memory-metrics.sh
echo "--- Nginx verification PASSED ---"
VERIFY

NGINX_AMI=$(aws ec2 create-image \
  --instance-id $NGINX_BASE \
  --name "GoldenAMI-Nginx-$(date +%Y%m%d)" \
  --description "Nginx Golden AMI: Nginx 1.x, CloudWatch memory metrics" \
  --no-reboot \
  --region $REGION \
  --query 'ImageId' \
  --output text)
save "NGINX_AMI" "$NGINX_AMI"
log "Nginx AMI: $NGINX_AMI — waiting..."
aws ec2 wait image-available \
  --image-ids $NGINX_AMI --region $REGION
log "Nginx Golden AMI ready: $NGINX_AMI"

# =================================================================
# STEP 5 — Launch Tomcat Base Instance
# =================================================================
log "--- [5/8] Launching Tomcat AMI Base Instance ---"

TOMCAT_BASE=$(aws ec2 run-instances \
  --image-id $GLOBAL_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $APP_PUB_SUB_1 \
  --security-group-ids $TOMCAT_SG \
  --associate-public-ip-address \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Tomcat-AMI-Base}]' \
  --user-data '#!/bin/bash
exec > /var/log/user-data.log 2>&1

# Install JDK 11
sudo yum install -y java-17-amazon-corretto

# Download Tomcat 9
wget https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.85/bin/apache-tomcat-9.0.85.tar.gz \
  -P /tmp/
tar -xzf /tmp/apache-tomcat-9.0.85.tar.gz -C /opt/
mv /opt/apache-tomcat-9.0.85 /opt/tomcat
chmod +x /opt/tomcat/bin/*.sh

# Create dedicated tomcat system user
useradd -r -m -U -d /opt/tomcat -s /bin/false tomcat
chown -R tomcat:tomcat /opt/tomcat

# Create systemd service unit
cat > /etc/systemd/system/tomcat.service << EOF
[Unit]
Description=Apache Tomcat 9 Web Application Server
After=network.target

[Service]
Type=forking
User=tomcat
Group=tomcat
Environment="JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto"
Environment="CATALINA_HOME=/opt/tomcat"
Environment="CATALINA_BASE=/opt/tomcat"
Environment="CATALINA_PID=/opt/tomcat/temp/tomcat.pid"
ExecStart=/opt/tomcat/bin/startup.sh
ExecStop=/opt/tomcat/bin/shutdown.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable tomcat
systemctl start tomcat
echo "Tomcat setup complete"' \
  --query 'Instances[0].InstanceId' \
  --output text)
save "TOMCAT_BASE" "$TOMCAT_BASE"
log "Tomcat Base Instance: $TOMCAT_BASE"

aws ec2 wait instance-running \
  --instance-ids $TOMCAT_BASE --region $REGION
log "Tomcat base running — waiting 3 minutes for setup to complete..."
sleep 180

TOMCAT_BASE_IP=$(aws ec2 describe-instances \
  --instance-ids $TOMCAT_BASE \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
save "TOMCAT_BASE_IP" "$TOMCAT_BASE_IP"

# =================================================================
# STEP 6 — Verify Tomcat and Create Golden AMI
# =================================================================
log "--- [6/8] Verifying Tomcat and Creating Golden AMI ---"

ssh -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=30 \
  ec2-user@$TOMCAT_BASE_IP << 'VERIFY'
echo "=== Java Version ==="
java -version
echo "=== Tomcat Status ==="
sudo systemctl status tomcat | grep -E "Active|Loaded"
echo "=== Tomcat Directory ==="
ls /opt/tomcat/
echo "--- Tomcat verification PASSED ---"
VERIFY

TOMCAT_AMI=$(aws ec2 create-image \
  --instance-id $TOMCAT_BASE \
  --name "GoldenAMI-Tomcat-$(date +%Y%m%d)" \
  --description "Tomcat Golden AMI: Tomcat 9, JDK 11, systemd service, CloudWatch memory metrics" \
  --no-reboot \
  --region $REGION \
  --query 'ImageId' \
  --output text)
save "TOMCAT_AMI" "$TOMCAT_AMI"
log "Tomcat AMI: $TOMCAT_AMI — waiting..."
aws ec2 wait image-available \
  --image-ids $TOMCAT_AMI --region $REGION
log "Tomcat Golden AMI ready: $TOMCAT_AMI"

# =================================================================
# STEP 7 — Launch Maven Base Instance
# =================================================================
log "--- [7/8] Launching Maven AMI Base Instance ---"

MAVEN_BASE=$(aws ec2 run-instances \
  --image-id $GLOBAL_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $APP_PUB_SUB_1 \
  --security-group-ids $NGINX_SG \
  --associate-public-ip-address \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Maven-AMI-Base}]' \
  --user-data '#!/bin/bash
exec > /var/log/user-data.log 2>&1

# Install Git and JDK 11
yum install -y git
sudo yum install -y java-17-amazon-corretto

# Install Maven 3.9.6
wget https://archive.apache.org/dist/maven/maven-3/3.9.6/binaries/apache-maven-3.9.6-bin.tar.gz \
  -P /tmp/
tar -xzf /tmp/apache-maven-3.9.6-bin.tar.gz -C /opt/
ln -s /opt/apache-maven-3.9.6 /opt/maven

# Add Maven to system PATH
cat > /etc/profile.d/maven.sh << EOF
export JAVA_HOME=/usr/lib/jvm/java-17-amazon-corretto
export M2_HOME=/opt/maven
export MAVEN_HOME=/opt/maven
export PATH=\${M2_HOME}/bin:\${PATH}
EOF
chmod +x /etc/profile.d/maven.sh
source /etc/profile.d/maven.sh

echo "Maven setup complete"' \
  --query 'Instances[0].InstanceId' \
  --output text)
save "MAVEN_BASE" "$MAVEN_BASE"
log "Maven Base Instance: $MAVEN_BASE"

aws ec2 wait instance-running \
  --instance-ids $MAVEN_BASE --region $REGION
log "Maven base running — waiting 2 minutes for setup to complete..."
sleep 120

MAVEN_BASE_IP=$(aws ec2 describe-instances \
  --instance-ids $MAVEN_BASE \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
save "MAVEN_BASE_IP" "$MAVEN_BASE_IP"

# =================================================================
# STEP 8 — Verify Maven and Create Golden AMI
# =================================================================
log "--- [8/8] Verifying Maven and Creating Golden AMI ---"

ssh -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  -o ConnectTimeout=30 \
  ec2-user@$MAVEN_BASE_IP << 'VERIFY'
echo "=== Java Version ==="
source /etc/profile.d/maven.sh && java -version
echo "=== Maven Version ==="
source /etc/profile.d/maven.sh && mvn -version
echo "=== Git Version ==="
git --version
echo "--- Maven verification PASSED ---"
VERIFY

MAVEN_AMI=$(aws ec2 create-image \
  --instance-id $MAVEN_BASE \
  --name "GoldenAMI-Maven-$(date +%Y%m%d)" \
  --description "Maven Golden AMI: Maven 3.9.6, JDK 11, Git, CloudWatch memory metrics" \
  --no-reboot \
  --region $REGION \
  --query 'ImageId' \
  --output text)
save "MAVEN_AMI" "$MAVEN_AMI"
log "Maven AMI: $MAVEN_AMI — waiting..."
aws ec2 wait image-available \
  --image-ids $MAVEN_AMI --region $REGION
log "Maven Golden AMI ready: $MAVEN_AMI"

log "================================================================"
log "PHASE 2 COMPLETE — All Golden AMIs Created"
log "================================================================"
log "Global AMI  : $GLOBAL_AMI"
log "Nginx AMI   : $NGINX_AMI"
log "Tomcat AMI  : $TOMCAT_AMI"
log "Maven AMI   : $MAVEN_AMI"
log "================================================================"
log "NEXT STEP: bash scripts/03-app-deploy.sh"
log "================================================================"
