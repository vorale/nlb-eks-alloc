#!/bin/bash
set -e

echo "=== NLB Port Operator Configuration ==="
echo ""

# 获取AWS账号ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "")
if [ -z "$ACCOUNT_ID" ]; then
    echo "Error: Cannot get AWS Account ID. Please configure AWS CLI first."
    exit 1
fi
echo "✓ AWS Account ID: $ACCOUNT_ID"

# 获取当前region
AWS_REGION=${AWS_REGION:-$(aws configure get region 2>/dev/null || echo "us-west-2")}
echo "✓ AWS Region: $AWS_REGION"

# 获取EKS集群名称
read -p "Enter EKS cluster name: " CLUSTER_NAME
if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: Cluster name is required"
    exit 1
fi

# 获取NLB ARN
echo ""
echo "Listing available NLBs in region $AWS_REGION..."
aws elbv2 describe-load-balancers --query 'LoadBalancers[?Type==`network`].[LoadBalancerName,LoadBalancerArn]' --output table 2>/dev/null || true
echo ""
read -p "Enter NLB ARN (or press Enter to create new): " NLB_ARN

if [ -z "$NLB_ARN" ]; then
    echo "You need to create an NLB first. Exiting..."
    exit 1
fi

# 获取VPC ID (从NLB获取)
VPC_ID=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --query 'LoadBalancers[0].VpcId' --output text 2>/dev/null || echo "")
if [ -z "$VPC_ID" ]; then
    read -p "Enter VPC ID: " VPC_ID
fi
echo "✓ VPC ID: $VPC_ID"

# 获取Docker镜像仓库
read -p "Enter Docker image registry (e.g., 123456789012.dkr.ecr.us-west-2.amazonaws.com): " DOCKER_REGISTRY
if [ -z "$DOCKER_REGISTRY" ]; then
    echo "Error: Docker registry is required"
    exit 1
fi

# 端口配置
read -p "Enter port range min [30000]: " PORT_MIN
PORT_MIN=${PORT_MIN:-30000}
read -p "Enter port range max [32767]: " PORT_MAX
PORT_MAX=${PORT_MAX:-32767}
read -p "Enter target port (Pod listening port) [7777]: " TARGET_PORT
TARGET_PORT=${TARGET_PORT:-7777}

echo ""
echo "=== Configuration Summary ==="
echo "Account ID: $ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo "Cluster: $CLUSTER_NAME"
echo "NLB ARN: $NLB_ARN"
echo "VPC ID: $VPC_ID"
echo "Docker Registry: $DOCKER_REGISTRY"
echo "Port Range: $PORT_MIN-$PORT_MAX"
echo "Target Port: $TARGET_PORT"
echo ""
read -p "Proceed with configuration? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 1
fi

# 备份原始文件
echo ""
echo "Creating backups..."
cp k8s/configmap.yaml k8s/configmap.yaml.bak
cp k8s/rbac.yaml k8s/rbac.yaml.bak
cp k8s/deployment.yaml k8s/deployment.yaml.bak

# 替换ConfigMap
echo "Updating k8s/configmap.yaml..."
sed -i.tmp "s|arn:aws:elasticloadbalancing:us-west-2:ACCOUNT_ID:loadbalancer/net/YOUR-NLB-NAME/XXXXXXXXXXXXXXXX|$NLB_ARN|g" k8s/configmap.yaml
sed -i.tmp "s|vpc-xxxxxxxxxxxxxxxxx|$VPC_ID|g" k8s/configmap.yaml
sed -i.tmp "s|PORT_RANGE_MIN: \"30000\"|PORT_RANGE_MIN: \"$PORT_MIN\"|g" k8s/configmap.yaml
sed -i.tmp "s|PORT_RANGE_MAX: \"32767\"|PORT_RANGE_MAX: \"$PORT_MAX\"|g" k8s/configmap.yaml
sed -i.tmp "s|TARGET_PORT: \"7777\"|TARGET_PORT: \"$TARGET_PORT\"|g" k8s/configmap.yaml
rm k8s/configmap.yaml.tmp

# 替换RBAC (IAM Role ARN)
echo "Updating k8s/rbac.yaml..."
sed -i.tmp "s|arn:aws:iam::ACCOUNT_ID:role/nlb-port-operator-role|arn:aws:iam::$ACCOUNT_ID:role/nlb-port-operator-role|g" k8s/rbac.yaml
rm k8s/rbac.yaml.tmp

# 替换Deployment (Docker image)
echo "Updating k8s/deployment.yaml..."
sed -i.tmp "s|your-registry/nlb-port-operator:latest|$DOCKER_REGISTRY/nlb-port-operator:latest|g" k8s/deployment.yaml
sed -i.tmp "s|value: us-west-2|value: $AWS_REGION|g" k8s/deployment.yaml
rm k8s/deployment.yaml.tmp

echo ""
echo "✓ Configuration completed!"
echo ""
echo "Next steps:"
echo "1. Run ./setup-irsa.sh to create IAM role"
echo "2. Build and push Docker image:"
echo "   docker build -t $DOCKER_REGISTRY/nlb-port-operator:latest ."
echo "   docker push $DOCKER_REGISTRY/nlb-port-operator:latest"
echo "3. Deploy operator:"
echo "   kubectl apply -f k8s/rbac.yaml"
echo "   kubectl apply -f k8s/configmap.yaml"
echo "   kubectl apply -f k8s/deployment.yaml"
echo ""
echo "To restore original files, use the .bak files"
