#!/bin/bash
# =================================================================
# PROJECT  : 3-Tier Java Login Application on AWS
# SCRIPT   : 03-app-deploy.sh
# PURPOSE  : Maven build, JFrog deploy, SonarCloud analysis,
#            NLBs, ASGs, DB schema, S3 logs, CloudWatch alarms
# AUTHOR   : vicogwa
# USAGE    : bash scripts/03-app-deploy.sh 2>&1 | tee -a ~/3tier-deploy.log
# REQUIRES : 01-infrastructure.sh and 02-golden-amis.sh complete
# =================================================================

set -e

source ~/3tier-resources.env

LOG_FILE=~/3tier-deploy.log

# -----------------------------------------------------------------
# PROJECT-SPECIFIC CONFIGURATION
# -----------------------------------------------------------------
JFROG_USER="vicogwa"
JFROG_TOKEN="${JFROG_TOKEN}"
JFROG_BASE_URL="https://vicogwa.jfrog.io/artifactory"
JFROG_REPO="my-libs-release"
ARTIFACT_PATH="com/devopsrealtime/dptweb/1.0/dptweb-1.0.war"
SONAR_TOKEN="aef1ae20d7ea3bfa78224d01005ef889d7522c2e"
GITHUB_REPO="https://github.com/vicogwa/Java-LogginApp-Deployment-AWS.git"
SETTINGS_XML=~/Java-LogginApp-Deployment-AWS/Java-Login-App/settings.xml
APP_PROPERTIES=~/Java-LogginApp-Deployment-AWS/Java-Login-App/src/main/resources/application.properties
ALERT_EMAIL="vicogwa@gmail.com"
LOG_BUCKET="3tier-tomcat-logs-$(date +%Y%m%d)"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

save() {
  sed -i "/^export $1=/d" ~/3tier-resources.env 2>/dev/null || true
  echo "export $1=$2" >> ~/3tier-resources.env
}

log "================================================================"
log "3-TIER AWS DEPLOYMENT — PHASE 3: APPLICATION"
log "================================================================"

# =================================================================
# STEP 1 — Wait for RDS
# =================================================================
log "--- [1/10] Waiting for RDS to be Available ---"

aws rds wait db-instance-available \
  --db-instance-identifier 3tier-mysql \
  --region $REGION
log "RDS is available"

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier 3tier-mysql \
  --region $REGION \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text)
save "RDS_ENDPOINT" "$RDS_ENDPOINT"
log "RDS Endpoint: $RDS_ENDPOINT"

# =================================================================
# STEP 2 — Update application.properties with RDS Endpoint
# =================================================================
log "--- [2/10] Updating application.properties ---"

cat > $APP_PROPERTIES << EOF
spring.mvc.view.prefix=/pages/
spring.mvc.view.suffix=.jsp
spring.datasource.url=jdbc:mysql://${RDS_ENDPOINT}:3306/java3tier_db
spring.datasource.username=appuser
spring.datasource.password=StrongPassword123!
spring.datasource.driver-class-name=com.mysql.cj.jdbc.Driver
EOF

cd ~/Java-LogginApp-Deployment-AWS/Java-Login-App
git add src/main/resources/application.properties
git commit -m "AWS deployment: update RDS endpoint to $RDS_ENDPOINT"
git push origin master
log "application.properties updated and pushed to GitHub"

# =================================================================
# STEP 3 — Launch Maven Build Server
# =================================================================
log "--- [3/10] Launching Maven Build Server ---"

MAVEN_INSTANCE=$(aws ec2 run-instances \
  --image-id $MAVEN_AMI \
  --instance-type t2.micro \
  --key-name $KEY_NAME \
  --subnet-id $APP_PUB_SUB_1 \
  --security-group-ids $NGINX_SG \
  --associate-public-ip-address \
  --region $REGION \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=Maven-Build-Server}]' \
  --query 'Instances[0].InstanceId' \
  --output text)
save "MAVEN_INSTANCE" "$MAVEN_INSTANCE"
log "Maven Instance: $MAVEN_INSTANCE"

aws ec2 wait instance-running \
  --instance-ids $MAVEN_INSTANCE --region $REGION

MAVEN_IP=$(aws ec2 describe-instances \
  --instance-ids $MAVEN_INSTANCE \
  --region $REGION \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text)
save "MAVEN_IP" "$MAVEN_IP"
log "Maven Server IP: $MAVEN_IP — waiting 60 seconds before connecting..."
sleep 60

# =================================================================
# STEP 4 — Copy Credentials and Run Build
# =================================================================
log "--- [4/10] Running Maven Build, JFrog Deploy, SonarCloud ---"

scp -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  $SETTINGS_XML \
  ec2-user@$MAVEN_IP:~/settings.xml
log "settings.xml copied to Maven server"

ssh -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  ec2-user@$MAVEN_IP << SSHEOF
set -e
source /etc/profile.d/maven.sh

echo "=== Cloning repository ==="
git clone $GITHUB_REPO
cd Java-LogginApp-Deployment-AWS/Java-Login-App

echo "=== Running Maven build and deploying to JFrog ==="
mvn clean deploy -s ~/settings.xml

echo "=== Running SonarCloud analysis ==="
export SONAR_TOKEN=$SONAR_TOKEN
mvn verify org.sonarsource.scanner.maven:sonar-maven-plugin:sonar \
  -Dsonar.projectKey=vicogwa_Java-LogginApp-Deployment-AWS \
  -s ~/settings.xml

echo "=== Build and analysis complete ==="
SSHEOF
log "Maven build, JFrog deploy, and SonarCloud analysis completed"

# =================================================================
# STEP 5 — Internal NLB for Tomcat Backend
# =================================================================
log "--- [5/10] Creating Internal Network Load Balancer ---"

PRIV_NLB_ARN=$(aws elbv2 create-load-balancer \
  --name 3tier-internal-nlb \
  --type network \
  --scheme internal \
  --subnets $APP_PRIV_SUB_1 $APP_PRIV_SUB_2 \
  --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
save "PRIV_NLB_ARN" "$PRIV_NLB_ARN"

PRIV_NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $PRIV_NLB_ARN \
  --region $REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)
save "PRIV_NLB_DNS" "$PRIV_NLB_DNS"
log "Internal NLB DNS: $PRIV_NLB_DNS"

PRIV_TG_ARN=$(aws elbv2 create-target-group \
  --name 3tier-tomcat-tg \
  --protocol TCP \
  --port 8080 \
  --vpc-id $APP_VPC \
  --target-type instance \
  --health-check-protocol TCP \
  --health-check-port 8080 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --region $REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
save "PRIV_TG_ARN" "$PRIV_TG_ARN"

aws elbv2 create-listener \
  --load-balancer-arn $PRIV_NLB_ARN \
  --protocol TCP --port 8080 \
  --default-actions Type=forward,TargetGroupArn=$PRIV_TG_ARN \
  --region $REGION
log "Internal NLB and Tomcat Target Group created"

# =================================================================
# STEP 6 — Tomcat Launch Template and Auto Scaling Group
# =================================================================
log "--- [6/10] Creating Tomcat Launch Template and ASG ---"

TOMCAT_USERDATA=$(cat << USERDATA | base64 -w 0
#!/bin/bash
exec > /var/log/user-data.log 2>&1

# Pull WAR artifact from JFrog
ARTIFACT_URL="${JFROG_BASE_URL}/${JFROG_REPO}/${ARTIFACT_PATH}"
curl -u ${JFROG_USER}:${JFROG_TOKEN} \
  -o /tmp/ROOT.war \
  "\$ARTIFACT_URL"

# Remove existing ROOT and deploy new WAR
rm -rf /opt/tomcat/webapps/ROOT
cp /tmp/ROOT.war /opt/tomcat/webapps/ROOT.war
chown tomcat:tomcat /opt/tomcat/webapps/ROOT.war

# Restart Tomcat
systemctl restart tomcat

# Create S3 log rotation cron
S3_BUCKET="${LOG_BUCKET}"
echo "0 * * * * root aws s3 cp /opt/tomcat/logs/catalina.out s3://\${S3_BUCKET}/\$(hostname)-\$(date +\%Y\%m\%d\%H).log && truncate -s 0 /opt/tomcat/logs/catalina.out" >> /etc/crontab

echo "Tomcat app deployment complete"
USERDATA
)

TOMCAT_LT=$(aws ec2 create-launch-template \
  --launch-template-name Tomcat-LT \
  --version-description "Tomcat backend - dptweb WAR from JFrog" \
  --launch-template-data "{
    \"ImageId\": \"$TOMCAT_AMI\",
    \"InstanceType\": \"t2.micro\",
    \"KeyName\": \"$KEY_NAME\",
    \"SecurityGroupIds\": [\"$TOMCAT_SG\"],
    \"UserData\": \"$TOMCAT_USERDATA\"
  }" \
  --region $REGION \
  --query 'LaunchTemplate.LaunchTemplateId' \
  --output text)
save "TOMCAT_LT" "$TOMCAT_LT"
log "Tomcat Launch Template: $TOMCAT_LT"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name Tomcat-ASG \
  --launch-template LaunchTemplateId=$TOMCAT_LT,Version='$Latest' \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "$APP_PRIV_SUB_1,$APP_PRIV_SUB_2" \
  --target-group-arns $PRIV_TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --region $REGION
save "TOMCAT_ASG" "Tomcat-ASG"
log "Tomcat ASG created"

# =================================================================
# STEP 7 — Public NLB for Nginx Frontend
# =================================================================
log "--- [7/10] Creating Public Network Load Balancer ---"

PUB_NLB_ARN=$(aws elbv2 create-load-balancer \
  --name 3tier-public-nlb \
  --type network \
  --scheme internet-facing \
  --subnets $APP_PUB_SUB_1 $APP_PUB_SUB_2 \
  --region $REGION \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text)
save "PUB_NLB_ARN" "$PUB_NLB_ARN"

PUB_NLB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $PUB_NLB_ARN \
  --region $REGION \
  --query 'LoadBalancers[0].DNSName' \
  --output text)
save "PUB_NLB_DNS" "$PUB_NLB_DNS"
log "Public NLB DNS: $PUB_NLB_DNS"

PUB_TG_ARN=$(aws elbv2 create-target-group \
  --name 3tier-nginx-tg \
  --protocol TCP \
  --port 80 \
  --vpc-id $APP_VPC \
  --target-type instance \
  --health-check-protocol TCP \
  --health-check-port 80 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --region $REGION \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text)
save "PUB_TG_ARN" "$PUB_TG_ARN"

aws elbv2 create-listener \
  --load-balancer-arn $PUB_NLB_ARN \
  --protocol TCP --port 80 \
  --default-actions Type=forward,TargetGroupArn=$PUB_TG_ARN \
  --region $REGION
log "Public NLB and Nginx Target Group created"

# =================================================================
# STEP 8 — Nginx Launch Template and Auto Scaling Group
# =================================================================
log "--- [8/10] Creating Nginx Launch Template and ASG ---"

NGINX_USERDATA=$(cat << USERDATA | base64 -w 0
#!/bin/bash
exec > /var/log/user-data.log 2>&1

# Remove default Nginx config
rm -f /etc/nginx/conf.d/default.conf

# Create reverse proxy config pointing to internal NLB
cat > /etc/nginx/conf.d/app.conf << NGINXCONF
server {
    listen 80;
    location / {
        proxy_pass http://${PRIV_NLB_DNS}:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
    }
}
NGINXCONF

nginx -t && systemctl reload nginx
echo "Nginx proxy configured to: ${PRIV_NLB_DNS}"
USERDATA
)

NGINX_LT=$(aws ec2 create-launch-template \
  --launch-template-name Nginx-LT \
  --version-description "Nginx frontend - proxy to internal NLB" \
  --launch-template-data "{
    \"ImageId\": \"$NGINX_AMI\",
    \"InstanceType\": \"t2.micro\",
    \"KeyName\": \"$KEY_NAME\",
    \"SecurityGroupIds\": [\"$NGINX_SG\"],
    \"UserData\": \"$NGINX_USERDATA\"
  }" \
  --region $REGION \
  --query 'LaunchTemplate.LaunchTemplateId' \
  --output text)
save "NGINX_LT" "$NGINX_LT"
log "Nginx Launch Template: $NGINX_LT"

aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name Nginx-ASG \
  --launch-template LaunchTemplateId=$NGINX_LT,Version='$Latest' \
  --min-size 1 \
  --max-size 2 \
  --desired-capacity 1 \
  --vpc-zone-identifier "$APP_PUB_SUB_1,$APP_PUB_SUB_2" \
  --target-group-arns $PUB_TG_ARN \
  --health-check-type ELB \
  --health-check-grace-period 300 \
  --region $REGION
save "NGINX_ASG" "Nginx-ASG"
log "Nginx ASG created"

# =================================================================
# STEP 9 — Create Employee Table Schema via Bastion
# =================================================================
log "--- [9/10] Creating Database Schema ---"
log "Waiting 3 minutes for ASG instances to launch and register..."
sleep 180

TOMCAT_PRIVATE_IP=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names Tomcat-ASG \
  --region $REGION \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text | xargs -I{} aws ec2 describe-instances \
  --instance-ids {} --region $REGION \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text)
save "TOMCAT_PRIVATE_IP" "$TOMCAT_PRIVATE_IP"
log "Tomcat Private IP: $TOMCAT_PRIVATE_IP"

ssh -i ~/3tier-key.pem \
  -o StrictHostKeyChecking=no \
  -o ProxyJump=ec2-user@$BASTION_PUBLIC_IP \
  ec2-user@$TOMCAT_PRIVATE_IP << SSHEOF
mysql -h $RDS_ENDPOINT -u admin -pAdmin123! java3tier_db << SQLEOF
-- Create scoped application user
CREATE USER IF NOT EXISTS 'appuser'@'%' IDENTIFIED BY 'StrongPassword123!';
GRANT ALL PRIVILEGES ON java3tier_db.* TO 'appuser'@'%';
FLUSH PRIVILEGES;

-- Create Employee table (matches Java entity in login.java and register.java)
CREATE TABLE IF NOT EXISTS Employee (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    first_name VARCHAR(100) NOT NULL,
    last_name  VARCHAR(100) NOT NULL,
    email      VARCHAR(150),
    username   VARCHAR(100) NOT NULL UNIQUE,
    password   VARCHAR(255) NOT NULL,
    regdate    DATE
);

SHOW TABLES;
DESCRIBE Employee;
SELECT 'Schema created successfully' AS Status;
SQLEOF
SSHEOF
log "Database schema created successfully"

# =================================================================
# STEP 10 — S3 Log Bucket + CloudWatch Alarm + SNS
# =================================================================
log "--- [10/10] Creating S3 Bucket, CloudWatch Alarm, SNS Topic ---"

# S3 bucket for Tomcat logs
aws s3 mb s3://$LOG_BUCKET --region $REGION
save "LOG_BUCKET" "$LOG_BUCKET"
log "S3 log bucket created: $LOG_BUCKET"

# SNS Topic for email alerts
SNS_ARN=$(aws sns create-topic \
  --name 3tier-rds-alerts \
  --region $REGION \
  --query 'TopicArn' \
  --output text)
save "SNS_ARN" "$SNS_ARN"

aws sns subscribe \
  --topic-arn $SNS_ARN \
  --protocol email \
  --notification-endpoint $ALERT_EMAIL \
  --region $REGION
log "SNS email subscription sent to $ALERT_EMAIL — confirm the email before alarms fire"

# CloudWatch alarm — RDS connections > 100
aws cloudwatch put-metric-alarm \
  --alarm-name "RDS-HighConnectionCount-3Tier" \
  --alarm-description "Alert when RDS connections exceed 100" \
  --metric-name DatabaseConnections \
  --namespace AWS/RDS \
  --statistic Average \
  --period 60 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold \
  --dimensions Name=DBInstanceIdentifier,Value=3tier-mysql \
  --evaluation-periods 2 \
  --alarm-actions $SNS_ARN \
  --ok-actions $SNS_ARN \
  --region $REGION
log "CloudWatch alarm created for RDS connection threshold"

# =================================================================
# Auto-populate Terraform teardown variables
# =================================================================
log "Populating Terraform teardown variables..."

source ~/3tier-resources.env

cat > ~/Java-LogginApp-Deployment-AWS/terraform/teardown/terraform.tfvars << TFVARS
bastion_vpc_id     = "$BASTION_VPC"
app_vpc_id         = "$APP_VPC"
bastion_pub_sub    = "$BASTION_PUB_SUB"
app_pub_sub_1      = "$APP_PUB_SUB_1"
app_pub_sub_2      = "$APP_PUB_SUB_2"
app_priv_sub_1     = "$APP_PRIV_SUB_1"
app_priv_sub_2     = "$APP_PRIV_SUB_2"
bastion_igw        = "$BASTION_IGW"
app_igw            = "$APP_IGW"
bastion_rt         = "$BASTION_RT"
app_pub_rt         = "$APP_PUB_RT"
app_priv_rt        = "$APP_PRIV_RT"
nat_eip            = "$NAT_EIP"
nat_gw             = "$NAT_GW"
tgw                = "$TGW"
tgw_attach_bastion = "$TGW_ATTACH_BASTION"
tgw_attach_app     = "$TGW_ATTACH_APP"
bastion_sg         = "$BASTION_SG"
nginx_sg           = "$NGINX_SG"
tomcat_sg          = "$TOMCAT_SG"
rds_sg             = "$RDS_SG"
bastion_instance   = "$BASTION_INSTANCE"
bastion_eip        = "$BASTION_EIP"
base_instance      = "$BASE_INSTANCE"
nginx_base         = "$NGINX_BASE"
tomcat_base        = "$TOMCAT_BASE"
maven_base         = "$MAVEN_BASE"
maven_instance     = "$MAVEN_INSTANCE"
global_ami         = "$GLOBAL_AMI"
nginx_ami          = "$NGINX_AMI"
tomcat_ami         = "$TOMCAT_AMI"
maven_ami          = "$MAVEN_AMI"
nginx_asg          = "$NGINX_ASG"
tomcat_asg         = "$TOMCAT_ASG"
pub_nlb_arn        = "$PUB_NLB_ARN"
priv_nlb_arn       = "$PRIV_NLB_ARN"
pub_tg_arn         = "$PUB_TG_ARN"
priv_tg_arn        = "$PRIV_TG_ARN"
rds_instance       = "3tier-mysql"
db_subnet_group    = "3tier-db-subnet-group"
sns_arn            = "$SNS_ARN"
log_bucket         = "$LOG_BUCKET"
TFVARS
log "Terraform tfvars populated at terraform/teardown/terraform.tfvars"

log "================================================================"
log "FULL DEPLOYMENT COMPLETE"
log "================================================================"
log "Public URL  : http://$PUB_NLB_DNS/login"
log "Bastion IP  : ssh -i ~/3tier-key.pem ec2-user@$BASTION_PUBLIC_IP"
log "RDS         : $RDS_ENDPOINT"
log "SonarCloud  : https://sonarcloud.io/project/overview?id=vicogwa_Java-LogginApp-Deployment-AWS"
log "JFrog       : https://vicogwa.jfrog.io/artifactory/$JFROG_REPO"
log "================================================================"
log "ACTION REQUIRED: Confirm SNS email subscription in your inbox"
log "================================================================"
log "TEARDOWN: cd terraform/teardown && terraform init && terraform apply -auto-approve"
log "================================================================"
