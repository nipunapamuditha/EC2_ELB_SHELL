#!/bin/bash
# filepath: /home/nipuna/Personal_Projects/Personal Projects/aws cli create/awscli.sh

# Exit on error
set -e

# Function for cleanup on error
cleanup() {
    echo "An error occurred, cleaning up resources..."
    exit 1
}

# Trap errors
trap cleanup ERR

# AWS Region
REGION="us-east-2"

# AMI ID with nginx pre-configured to show instance ID
AMI_ID="ami-0121b9def4c9ff4eb"

# Instance type
INSTANCE_TYPE="t2.micro"

# Key pair name (use existing key pair or create one)
KEY_NAME="xtz"

# Create a user data script to display instance ID on nginx page
USER_DATA=$(cat << 'EOF'
#!/bin/bash
# Install nginx if not already installed
if ! command -v nginx &> /dev/null; then
    apt-get update -y
    apt-get install -y nginx
fi

# Get the instance ID using IMDSv2
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)

# Create a custom HTML file that displays the instance ID
cat > /var/www/html/index.html << HTML
<!DOCTYPE html>
<html>
<head>
    <title>EC2 Instance Information</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 40px;
            text-align: center;
        }
        h1 {
            color: #333;
        }
        .instance-id {
            font-size: 24px;
            color: #0066cc;
            padding: 20px;
            border: 1px solid #ddd;
            border-radius: 5px;
            display: inline-block;
            margin-top: 20px;
        }
    </style>
</head>
<body>
    <h1>EC2 Instance Information</h1>
    <p>You are currently visiting:</p>
    <div class="instance-id">Instance ID: ${INSTANCE_ID}</div>
</body>
</html>
HTML

# Ensure nginx is running
systemctl enable nginx
systemctl restart nginx
EOF
)

# Validate key pair exists
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" --region "$REGION" &>/dev/null; then
    echo "Error: Key pair $KEY_NAME does not exist in region $REGION"
    echo "Please create a key pair first with:"
    echo "aws ec2 create-key-pair --key-name $KEY_NAME --query 'KeyMaterial' --output text > $KEY_NAME.pem"
    exit 1
fi

echo "Creating VPC and network infrastructure..."

# Create VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $VPC_ID \
  --tags Key=Name,Value=nginx-vpc \
  --region $REGION

echo "VPC created: $VPC_ID"

# Enable DNS hostnames for the VPC
aws ec2 modify-vpc-attribute \
  --vpc-id $VPC_ID \
  --enable-dns-hostnames \
  --region $REGION

# Create Internet Gateway
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $IGW_ID \
  --tags Key=Name,Value=nginx-igw \
  --region $REGION

echo "Internet Gateway created: $IGW_ID"

# Attach Internet Gateway to VPC
aws ec2 attach-internet-gateway \
  --internet-gateway-id $IGW_ID \
  --vpc-id $VPC_ID \
  --region $REGION

# Create two subnets in different AZs
SUBNET1_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone ${REGION}a \
  --query 'Subnet.SubnetId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $SUBNET1_ID \
  --tags Key=Name,Value=nginx-subnet-1 \
  --region $REGION

echo "Subnet 1 created: $SUBNET1_ID"

SUBNET2_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone ${REGION}b \
  --query 'Subnet.SubnetId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $SUBNET2_ID \
  --tags Key=Name,Value=nginx-subnet-2 \
  --region $REGION

echo "Subnet 2 created: $SUBNET2_ID"

# Create Route Table
RT_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $RT_ID \
  --tags Key=Name,Value=nginx-route-table \
  --region $REGION

echo "Route Table created: $RT_ID"

# Create route to Internet Gateway
aws ec2 create-route \
  --route-table-id $RT_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID \
  --region $REGION

# Associate Route Table with Subnets
aws ec2 associate-route-table \
  --route-table-id $RT_ID \
  --subnet-id $SUBNET1_ID \
  --region $REGION

aws ec2 associate-route-table \
  --route-table-id $RT_ID \
  --subnet-id $SUBNET2_ID \
  --region $REGION

# Enable auto-assign public IP on subnets
aws ec2 modify-subnet-attribute \
  --subnet-id $SUBNET1_ID \
  --map-public-ip-on-launch \
  --region $REGION

aws ec2 modify-subnet-attribute \
  --subnet-id $SUBNET2_ID \
  --map-public-ip-on-launch \
  --region $REGION

echo "Creating security groups..."

# Create Security Group for instances
INSTANCE_SG_ID=$(aws ec2 create-security-group \
  --group-name nginx-instance-sg \
  --description "Security group for nginx instances" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $INSTANCE_SG_ID \
  --tags Key=Name,Value=nginx-instance-sg \
  --region $REGION

echo "Instance Security Group created: $INSTANCE_SG_ID"

# Allow HTTP from anywhere to instances
aws ec2 authorize-security-group-ingress \
  --group-id $INSTANCE_SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region $REGION

# Allow SSH for management
aws ec2 authorize-security-group-ingress \
  --group-id $INSTANCE_SG_ID \
  --protocol tcp \
  --port 22 \
  --cidr 0.0.0.0/0 \
  --region $REGION

# Create Security Group for Load Balancer
LB_SG_ID=$(aws ec2 create-security-group \
  --group-name nginx-lb-sg \
  --description "Security group for nginx load balancer" \
  --vpc-id $VPC_ID \
  --query 'GroupId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $LB_SG_ID \
  --tags Key=Name,Value=nginx-lb-sg \
  --region $REGION

echo "Load Balancer Security Group created: $LB_SG_ID"

# Allow HTTP from anywhere to Load Balancer
aws ec2 authorize-security-group-ingress \
  --group-id $LB_SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region $REGION

echo "Launching EC2 instances..."

# Launch first instance
INSTANCE1_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --count 1 \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $INSTANCE_SG_ID \
  --subnet-id $SUBNET1_ID \
  --user-data "$USER_DATA" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $INSTANCE1_ID \
  --tags Key=Name,Value=nginx-instance-1 \
  --region $REGION

echo "Instance 1 launched: $INSTANCE1_ID"

# Launch second instance
INSTANCE2_ID=$(aws ec2 run-instances \
  --image-id $AMI_ID \
  --count 1 \
  --instance-type $INSTANCE_TYPE \
  --key-name $KEY_NAME \
  --security-group-ids $INSTANCE_SG_ID \
  --subnet-id $SUBNET2_ID \
  --user-data "$USER_DATA" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region $REGION)

aws ec2 create-tags \
  --resources $INSTANCE2_ID \
  --tags Key=Name,Value=nginx-instance-2 \
  --region $REGION

echo "Instance 2 launched: $INSTANCE2_ID"

echo "Waiting for instances to be in running state..."
aws ec2 wait instance-running \
  --instance-ids $INSTANCE1_ID $INSTANCE2_ID \
  --region $REGION

echo "Creating Load Balancer..."

# Create target group
TARGET_GROUP_ARN=$(aws elbv2 create-target-group \
  --name nginx-target-group \
  --protocol HTTP \
  --port 80 \
  --vpc-id $VPC_ID \
  --health-check-path / \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region $REGION)

echo "Target Group created: $TARGET_GROUP_ARN"

# Register instances with target group
aws elbv2 register-targets \
  --target-group-arn $TARGET_GROUP_ARN \
  --targets Id=$INSTANCE1_ID Id=$INSTANCE2_ID \
  --region $REGION

# Create Load Balancer
LB_ARN=$(aws elbv2 create-load-balancer \
  --name nginx-load-balancer \
  --subnets $SUBNET1_ID $SUBNET2_ID \
  --security-groups $LB_SG_ID \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region $REGION)

echo "Load Balancer created: $LB_ARN"

# Create listener
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $LB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TARGET_GROUP_ARN \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region $REGION)

echo "Listener created: $LISTENER_ARN"

# Wait for LB to be available
echo "Waiting for Load Balancer to become available..."
aws elbv2 wait load-balancer-available \
  --load-balancer-arns $LB_ARN \
  --region $REGION

# Get Load Balancer DNS name
LB_DNS_NAME=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns $LB_ARN \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region $REGION)

# Get instance public IPs for reference
INSTANCE1_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE1_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region $REGION)

INSTANCE2_IP=$(aws ec2 describe-instances \
  --instance-ids $INSTANCE2_ID \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region $REGION)

echo "Setup complete!"
echo "Load Balancer DNS: $LB_DNS_NAME"
echo "Instance 1 IP: $INSTANCE1_IP"
echo "Instance 2 IP: $INSTANCE2_IP"
echo "You can access your load-balanced nginx instances at: http://$LB_DNS_NAME"
echo "You can directly access each instance at:"
echo "http://$INSTANCE1_IP"
echo "http://$INSTANCE2_IP"
echo "It may take a few minutes for the instances to pass health checks."