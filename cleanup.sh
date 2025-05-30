#!/bin/bash
# filepath: /home/nipuna/Personal_Projects/Personal Projects/aws cli create/cleanup.sh

# Exit on error
set -e

# AWS Region - make sure this matches your deployment region
REGION="us-east-2"

# Prompt user for confirmation
echo "WARNING: This will delete ALL resources created by the AWS nginx deployment script!"
echo "Are you sure you want to continue? (yes/no)"
read confirmation

if [[ "$confirmation" != "yes" ]]; then
    echo "Cleanup canceled."
    exit 0
fi

echo "Starting cleanup process..."

# Get the resource IDs - use the AWS CLI to find them by tags or names
echo "Finding deployed resources..."

# Find the load balancer
LB_ARN=$(aws elbv2 describe-load-balancers \
    --names nginx-load-balancer \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [[ -n "$LB_ARN" ]]; then
    echo "Found Load Balancer: $LB_ARN"
    
    # Find listeners and delete them
    LISTENERS=$(aws elbv2 describe-listeners \
        --load-balancer-arn $LB_ARN \
        --query 'Listeners[*].ListenerArn' \
        --output text \
        --region $REGION)
    
    for LISTENER in $LISTENERS; do
        echo "Deleting listener: $LISTENER"
        aws elbv2 delete-listener \
            --listener-arn $LISTENER \
            --region $REGION
    done
    
    # Delete the load balancer
    echo "Deleting load balancer..."
    aws elbv2 delete-load-balancer \
        --load-balancer-arn $LB_ARN \
        --region $REGION
    
    echo "Waiting for load balancer to be deleted..."
    sleep 30  # Give some time for the load balancer to delete
fi

# Find and delete target group
TARGET_GROUP_ARN=$(aws elbv2 describe-target-groups \
    --names nginx-target-group \
    --query 'TargetGroups[0].TargetGroupArn' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [[ -n "$TARGET_GROUP_ARN" ]]; then
    echo "Deleting target group: $TARGET_GROUP_ARN"
    aws elbv2 delete-target-group \
        --target-group-arn $TARGET_GROUP_ARN \
        --region $REGION
fi

# Find and terminate EC2 instances
echo "Finding and terminating EC2 instances..."
INSTANCE_IDS=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=nginx-instance-1,nginx-instance-2" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region $REGION)

if [[ -n "$INSTANCE_IDS" ]]; then
    echo "Terminating instances: $INSTANCE_IDS"
    aws ec2 terminate-instances \
        --instance-ids $INSTANCE_IDS \
        --region $REGION
    
    echo "Waiting for instances to terminate..."
    aws ec2 wait instance-terminated \
        --instance-ids $INSTANCE_IDS \
        --region $REGION
fi

# Find and delete security groups
echo "Finding and deleting security groups..."

# First find the VPC ID to use in security group filters
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=nginx-vpc" \
    --query 'Vpcs[0].VpcId' \
    --output text \
    --region $REGION 2>/dev/null || echo "")

if [[ -n "$VPC_ID" ]]; then
    echo "Found VPC: $VPC_ID"
    
    # Find and delete load balancer security group
    LB_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=nginx-lb-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [[ -n "$LB_SG_ID" && "$LB_SG_ID" != "None" ]]; then
        echo "Deleting load balancer security group: $LB_SG_ID"
        aws ec2 delete-security-group \
            --group-id $LB_SG_ID \
            --region $REGION
    fi
    
    # Find and delete instance security group
    INSTANCE_SG_ID=$(aws ec2 describe-security-groups \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=nginx-instance-sg" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [[ -n "$INSTANCE_SG_ID" && "$INSTANCE_SG_ID" != "None" ]]; then
        echo "Deleting instance security group: $INSTANCE_SG_ID"
        aws ec2 delete-security-group \
            --group-id $INSTANCE_SG_ID \
            --region $REGION
    fi
    
    # Find and delete route table
    RT_ID=$(aws ec2 describe-route-tables \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=nginx-route-table" \
        --query 'RouteTables[0].RouteTableId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [[ -n "$RT_ID" && "$RT_ID" != "None" ]]; then
        echo "Found route table: $RT_ID"
        
        # Find and delete subnet associations
        SUBNET_ASSOCS=$(aws ec2 describe-route-tables \
            --route-table-ids $RT_ID \
            --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
            --output text \
            --region $REGION)
        
        for ASSOC in $SUBNET_ASSOCS; do
            if [[ -n "$ASSOC" && "$ASSOC" != "None" ]]; then
                echo "Deleting route table association: $ASSOC"
                aws ec2 disassociate-route-table \
                    --association-id $ASSOC \
                    --region $REGION
            fi
        done
        
        # Delete route table
        echo "Deleting route table: $RT_ID"
        aws ec2 delete-route-table \
            --route-table-id $RT_ID \
            --region $REGION
    fi
    
    # Find and delete subnets
    SUBNET_IDS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=nginx-subnet-1,nginx-subnet-2" \
        --query 'Subnets[*].SubnetId' \
        --output text \
        --region $REGION)
    
    for SUBNET_ID in $SUBNET_IDS; do
        if [[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]]; then
            echo "Deleting subnet: $SUBNET_ID"
            aws ec2 delete-subnet \
                --subnet-id $SUBNET_ID \
                --region $REGION
        fi
    done
    
    # Find and detach/delete internet gateway
    IGW_ID=$(aws ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$VPC_ID" \
        --query 'InternetGateways[0].InternetGatewayId' \
        --output text \
        --region $REGION 2>/dev/null || echo "")
    
    if [[ -n "$IGW_ID" && "$IGW_ID" != "None" ]]; then
        echo "Detaching internet gateway: $IGW_ID"
        aws ec2 detach-internet-gateway \
            --internet-gateway-id $IGW_ID \
            --vpc-id $VPC_ID \
            --region $REGION
        
        echo "Deleting internet gateway: $IGW_ID"
        aws ec2 delete-internet-gateway \
            --internet-gateway-id $IGW_ID \
            --region $REGION
    fi
    
    # Delete VPC
    echo "Deleting VPC: $VPC_ID"
    aws ec2 delete-vpc \
        --vpc-id $VPC_ID \
        --region $REGION
fi

echo "Cleanup complete! All resources have been deleted."