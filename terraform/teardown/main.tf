terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# =================================================================
# VARIABLES
# Auto-populated by 03-app-deploy.sh into terraform.tfvars
# =================================================================
variable "bastion_vpc_id"     { default = "" }
variable "app_vpc_id"         { default = "" }
variable "bastion_pub_sub"    { default = "" }
variable "app_pub_sub_1"      { default = "" }
variable "app_pub_sub_2"      { default = "" }
variable "app_priv_sub_1"     { default = "" }
variable "app_priv_sub_2"     { default = "" }
variable "bastion_igw"        { default = "" }
variable "app_igw"            { default = "" }
variable "bastion_rt"         { default = "" }
variable "app_pub_rt"         { default = "" }
variable "app_priv_rt"        { default = "" }
variable "nat_eip"            { default = "" }
variable "nat_gw"             { default = "" }
variable "tgw"                { default = "" }
variable "tgw_attach_bastion" { default = "" }
variable "tgw_attach_app"     { default = "" }
variable "bastion_sg"         { default = "" }
variable "nginx_sg"           { default = "" }
variable "tomcat_sg"          { default = "" }
variable "rds_sg"             { default = "" }
variable "bastion_instance"   { default = "" }
variable "bastion_eip"        { default = "" }
variable "base_instance"      { default = "" }
variable "nginx_base"         { default = "" }
variable "tomcat_base"        { default = "" }
variable "maven_base"         { default = "" }
variable "maven_instance"     { default = "" }
variable "global_ami"         { default = "" }
variable "nginx_ami"          { default = "" }
variable "tomcat_ami"         { default = "" }
variable "maven_ami"          { default = "" }
variable "nginx_asg"          { default = "" }
variable "tomcat_asg"         { default = "" }
variable "pub_nlb_arn"        { default = "" }
variable "priv_nlb_arn"       { default = "" }
variable "pub_tg_arn"         { default = "" }
variable "priv_tg_arn"        { default = "" }
variable "rds_instance"       { default = "3tier-mysql" }
variable "db_subnet_group"    { default = "3tier-db-subnet-group" }
variable "sns_arn"            { default = "" }
variable "log_bucket"         { default = "" }

# =================================================================
# TEARDOWN SEQUENCE
# Order matters — dependencies must be removed before their parents
#
# 1.  Auto Scaling Groups
# 2.  Load Balancers
# 3.  Target Groups
# 4.  EC2 Instances
# 5.  RDS Instance + Subnet Group
# 6.  Deregister AMIs
# 7.  NAT Gateway
# 8.  Transit Gateway Attachments
# 9.  Transit Gateway
# 10. Security Groups
# 11. Subnets
# 12. Route Tables
# 13. Internet Gateways
# 14. Elastic IPs
# 15. VPCs
# 16. SNS Topic + CloudWatch Alarm
# 17. S3 Bucket
# =================================================================

# -----------------------------------------------------------------
# 1. Auto Scaling Groups
# -----------------------------------------------------------------
resource "null_resource" "delete_asgs" {
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Auto Scaling Groups..."
      [ -n "${var.nginx_asg}" ] && \
        aws autoscaling delete-auto-scaling-group \
          --auto-scaling-group-name ${var.nginx_asg} \
          --force-delete --region us-east-1 && \
        echo "Nginx ASG deleted" || true
      [ -n "${var.tomcat_asg}" ] && \
        aws autoscaling delete-auto-scaling-group \
          --auto-scaling-group-name ${var.tomcat_asg} \
          --force-delete --region us-east-1 && \
        echo "Tomcat ASG deleted" || true
      echo "Waiting 60 seconds for ASG instances to terminate..."
      sleep 60
    CMD
  }
}

# -----------------------------------------------------------------
# 2. Load Balancers
# -----------------------------------------------------------------
resource "null_resource" "delete_nlbs" {
  depends_on = [null_resource.delete_asgs]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Network Load Balancers..."
      [ -n "${var.pub_nlb_arn}" ] && \
        aws elbv2 delete-load-balancer \
          --load-balancer-arn ${var.pub_nlb_arn} \
          --region us-east-1 && \
        echo "Public NLB deleted" || true
      [ -n "${var.priv_nlb_arn}" ] && \
        aws elbv2 delete-load-balancer \
          --load-balancer-arn ${var.priv_nlb_arn} \
          --region us-east-1 && \
        echo "Internal NLB deleted" || true
      echo "Waiting 30 seconds..."
      sleep 30
    CMD
  }
}

# -----------------------------------------------------------------
# 3. Target Groups
# -----------------------------------------------------------------
resource "null_resource" "delete_target_groups" {
  depends_on = [null_resource.delete_nlbs]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Target Groups..."
      [ -n "${var.pub_tg_arn}" ] && \
        aws elbv2 delete-target-group \
          --target-group-arn ${var.pub_tg_arn} \
          --region us-east-1 && \
        echo "Nginx TG deleted" || true
      [ -n "${var.priv_tg_arn}" ] && \
        aws elbv2 delete-target-group \
          --target-group-arn ${var.priv_tg_arn} \
          --region us-east-1 && \
        echo "Tomcat TG deleted" || true
    CMD
  }
}

# -----------------------------------------------------------------
# 4. EC2 Instances
# -----------------------------------------------------------------
resource "null_resource" "terminate_instances" {
  depends_on = [null_resource.delete_target_groups]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Terminating EC2 instances..."
      INSTANCES=""
      [ -n "${var.bastion_instance}" ] && INSTANCES="$INSTANCES ${var.bastion_instance}"
      [ -n "${var.base_instance}" ]    && INSTANCES="$INSTANCES ${var.base_instance}"
      [ -n "${var.nginx_base}" ]       && INSTANCES="$INSTANCES ${var.nginx_base}"
      [ -n "${var.tomcat_base}" ]      && INSTANCES="$INSTANCES ${var.tomcat_base}"
      [ -n "${var.maven_base}" ]       && INSTANCES="$INSTANCES ${var.maven_base}"
      [ -n "${var.maven_instance}" ]   && INSTANCES="$INSTANCES ${var.maven_instance}"
      if [ -n "$INSTANCES" ]; then
        aws ec2 terminate-instances \
          --instance-ids $INSTANCES \
          --region us-east-1
        echo "Waiting for all instances to terminate..."
        aws ec2 wait instance-terminated \
          --instance-ids $INSTANCES \
          --region us-east-1
        echo "All EC2 instances terminated"
      fi
    CMD
  }
}

# -----------------------------------------------------------------
# 5. RDS Instance and Subnet Group
# -----------------------------------------------------------------
resource "null_resource" "delete_rds" {
  depends_on = [null_resource.terminate_instances]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting RDS instance..."
      aws rds delete-db-instance \
        --db-instance-identifier ${var.rds_instance} \
        --skip-final-snapshot \
        --region us-east-1 || true
      echo "Waiting for RDS deletion (this takes several minutes)..."
      aws rds wait db-instance-deleted \
        --db-instance-identifier ${var.rds_instance} \
        --region us-east-1 || true
      aws rds delete-db-subnet-group \
        --db-subnet-group-name ${var.db_subnet_group} \
        --region us-east-1 || true
      echo "RDS and subnet group deleted"
    CMD
  }
}

# -----------------------------------------------------------------
# 6. Deregister AMIs
# -----------------------------------------------------------------
resource "null_resource" "deregister_amis" {
  depends_on = [null_resource.terminate_instances]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deregistering AMIs..."
      for AMI in ${var.global_ami} ${var.nginx_ami} ${var.tomcat_ami} ${var.maven_ami}; do
        [ -n "$AMI" ] && \
          aws ec2 deregister-image \
            --image-id $AMI \
            --region us-east-1 && \
          echo "Deregistered: $AMI" || true
      done
    CMD
  }
}

# -----------------------------------------------------------------
# 7. NAT Gateway
# -----------------------------------------------------------------
resource "null_resource" "delete_nat_gw" {
  depends_on = [null_resource.delete_rds]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting NAT Gateway..."
      [ -n "${var.nat_gw}" ] && \
        aws ec2 delete-nat-gateway \
          --nat-gateway-id ${var.nat_gw} \
          --region us-east-1 || true
      echo "Waiting 60 seconds for NAT Gateway to delete..."
      sleep 60
      echo "NAT Gateway deleted"
    CMD
  }
}

# -----------------------------------------------------------------
# 8. Transit Gateway Attachments
# -----------------------------------------------------------------
resource "null_resource" "delete_tgw_attachments" {
  depends_on = [null_resource.delete_nat_gw]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Transit Gateway attachments..."
      [ -n "${var.tgw_attach_bastion}" ] && \
        aws ec2 delete-transit-gateway-vpc-attachment \
          --transit-gateway-attachment-id ${var.tgw_attach_bastion} \
          --region us-east-1 || true
      [ -n "${var.tgw_attach_app}" ] && \
        aws ec2 delete-transit-gateway-vpc-attachment \
          --transit-gateway-attachment-id ${var.tgw_attach_app} \
          --region us-east-1 || true
      echo "Waiting 90 seconds for attachments to delete..."
      sleep 90
      echo "TGW attachments deleted"
    CMD
  }
}

# -----------------------------------------------------------------
# 9. Transit Gateway
# -----------------------------------------------------------------
resource "null_resource" "delete_tgw" {
  depends_on = [null_resource.delete_tgw_attachments]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Transit Gateway..."
      [ -n "${var.tgw}" ] && \
        aws ec2 delete-transit-gateway \
          --transit-gateway-id ${var.tgw} \
          --region us-east-1 || true
      sleep 30
      echo "Transit Gateway deleted"
    CMD
  }
}

# -----------------------------------------------------------------
# 10. Security Groups
# -----------------------------------------------------------------
resource "null_resource" "delete_security_groups" {
  depends_on = [null_resource.delete_tgw]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Security Groups..."
      for SG in ${var.rds_sg} ${var.tomcat_sg} ${var.nginx_sg} ${var.bastion_sg}; do
        [ -n "$SG" ] && \
          aws ec2 delete-security-group \
            --group-id $SG \
            --region us-east-1 && \
          echo "Deleted SG: $SG" || true
      done
    CMD
  }
}

# -----------------------------------------------------------------
# 11. Subnets
# -----------------------------------------------------------------
resource "null_resource" "delete_subnets" {
  depends_on = [null_resource.delete_security_groups]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Subnets..."
      for SUBNET in \
        ${var.bastion_pub_sub} \
        ${var.app_pub_sub_1} \
        ${var.app_pub_sub_2} \
        ${var.app_priv_sub_1} \
        ${var.app_priv_sub_2}; do
        [ -n "$SUBNET" ] && \
          aws ec2 delete-subnet \
            --subnet-id $SUBNET \
            --region us-east-1 && \
          echo "Deleted subnet: $SUBNET" || true
      done
    CMD
  }
}

# -----------------------------------------------------------------
# 12. Route Tables
# -----------------------------------------------------------------
resource "null_resource" "delete_route_tables" {
  depends_on = [null_resource.delete_subnets]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Route Tables..."
      for RT in ${var.bastion_rt} ${var.app_pub_rt} ${var.app_priv_rt}; do
        [ -n "$RT" ] && \
          aws ec2 delete-route-table \
            --route-table-id $RT \
            --region us-east-1 && \
          echo "Deleted RT: $RT" || true
      done
    CMD
  }
}

# -----------------------------------------------------------------
# 13. Internet Gateways
# -----------------------------------------------------------------
resource "null_resource" "delete_igws" {
  depends_on = [null_resource.delete_route_tables]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting Internet Gateways..."
      [ -n "${var.bastion_igw}" ] && [ -n "${var.bastion_vpc_id}" ] && \
        aws ec2 detach-internet-gateway \
          --internet-gateway-id ${var.bastion_igw} \
          --vpc-id ${var.bastion_vpc_id} \
          --region us-east-1 && \
        aws ec2 delete-internet-gateway \
          --internet-gateway-id ${var.bastion_igw} \
          --region us-east-1 && \
        echo "Bastion IGW deleted" || true
      [ -n "${var.app_igw}" ] && [ -n "${var.app_vpc_id}" ] && \
        aws ec2 detach-internet-gateway \
          --internet-gateway-id ${var.app_igw} \
          --vpc-id ${var.app_vpc_id} \
          --region us-east-1 && \
        aws ec2 delete-internet-gateway \
          --internet-gateway-id ${var.app_igw} \
          --region us-east-1 && \
        echo "App IGW deleted" || true
    CMD
  }
}

# -----------------------------------------------------------------
# 14. Elastic IPs
# -----------------------------------------------------------------
resource "null_resource" "release_eips" {
  depends_on = [null_resource.delete_igws]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Releasing Elastic IPs..."
      [ -n "${var.nat_eip}" ] && \
        aws ec2 release-address \
          --allocation-id ${var.nat_eip} \
          --region us-east-1 && \
        echo "NAT EIP released" || true
      [ -n "${var.bastion_eip}" ] && \
        aws ec2 release-address \
          --allocation-id ${var.bastion_eip} \
          --region us-east-1 && \
        echo "Bastion EIP released" || true
    CMD
  }
}

# -----------------------------------------------------------------
# 15. VPCs
# -----------------------------------------------------------------
resource "null_resource" "delete_vpcs" {
  depends_on = [null_resource.release_eips]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting VPCs..."
      [ -n "${var.bastion_vpc_id}" ] && \
        aws ec2 delete-vpc \
          --vpc-id ${var.bastion_vpc_id} \
          --region us-east-1 && \
        echo "Bastion VPC deleted" || true
      [ -n "${var.app_vpc_id}" ] && \
        aws ec2 delete-vpc \
          --vpc-id ${var.app_vpc_id} \
          --region us-east-1 && \
        echo "App VPC deleted" || true
    CMD
  }
}

# -----------------------------------------------------------------
# 16. SNS Topic and CloudWatch Alarm
# -----------------------------------------------------------------
resource "null_resource" "delete_monitoring" {
  depends_on = [null_resource.delete_vpcs]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Deleting CloudWatch alarm..."
      aws cloudwatch delete-alarms \
        --alarm-names "RDS-HighConnectionCount-3Tier" \
        --region us-east-1 || true
      echo "[TEARDOWN] Deleting SNS topic..."
      [ -n "${var.sns_arn}" ] && \
        aws sns delete-topic \
          --topic-arn ${var.sns_arn} \
          --region us-east-1 && \
        echo "SNS topic deleted" || true
    CMD
  }
}

# -----------------------------------------------------------------
# 17. S3 Bucket (empty first then delete)
# -----------------------------------------------------------------
resource "null_resource" "delete_s3" {
  depends_on = [null_resource.delete_monitoring]
  provisioner "local-exec" {
    command = <<-CMD
      echo "[TEARDOWN] Emptying and deleting S3 log bucket..."
      [ -n "${var.log_bucket}" ] && \
        aws s3 rm s3://${var.log_bucket} --recursive \
          --region us-east-1 && \
        aws s3 rb s3://${var.log_bucket} \
          --region us-east-1 && \
        echo "S3 bucket deleted: ${var.log_bucket}" || true
    CMD
  }
}

# -----------------------------------------------------------------
# OUTPUT
# -----------------------------------------------------------------
output "teardown_complete" {
  depends_on = [null_resource.delete_s3]
  value      = "All 3-tier AWS resources destroyed successfully. No further charges will accrue."
}
