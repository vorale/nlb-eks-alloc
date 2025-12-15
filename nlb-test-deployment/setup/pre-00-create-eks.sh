#!/bin/bash

# EKS 集群创建脚本 - 使用默认 VPC

set -e

echo "=== 创建 EKS 集群（使用默认 VPC） ==="
echo ""

# 默认配置
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-nlb-operator-test}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODE_COUNT="${NODE_COUNT:-2}"

echo "集群配置:"
echo "  名称: $CLUSTER_NAME"
echo "  区域: $AWS_REGION"
echo "  节点类型: $NODE_TYPE"
echo "  节点数量: $NODE_COUNT"
echo ""

# 检查 eksctl
if ! command -v eksctl &> /dev/null; then
    echo "错误: eksctl 未安装"
    echo "macOS: brew tap weaveworks/tap && brew install weaveworks/tap/eksctl"
    exit 1
fi

# 检查集群是否已存在
EXISTING=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.name' --output text 2>/dev/null || echo "")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
    echo "集群 $CLUSTER_NAME 已存在"
    echo ""
    echo "配置 kubectl..."
    aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
    echo "✓ kubectl 已配置"
    exit 0
fi

# 获取默认 VPC ID
echo "获取默认 VPC 信息..."
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region $AWS_REGION \
    --query 'Vpcs[0].VpcId' \
    --output text)

if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "错误: 未找到默认 VPC"
    exit 1
fi
echo "✓ 默认 VPC: $VPC_ID"

# 获取公有子网（MapPublicIpOnLaunch=true 的子网）
echo "获取公有子网..."
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
    --region $AWS_REGION \
    --query 'Subnets[*].SubnetId' \
    --output text)

# 转换为逗号分隔
PUBLIC_SUBNET_LIST=$(echo $PUBLIC_SUBNETS | tr '\t' ',' | tr ' ' ',')

if [ -z "$PUBLIC_SUBNET_LIST" ]; then
    echo "错误: 未找到公有子网"
    exit 1
fi
echo "✓ 公有子网: $PUBLIC_SUBNET_LIST"

# 获取私有子网（MapPublicIpOnLaunch=false 的子网）
echo "获取私有子网..."
PRIVATE_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=false" \
    --region $AWS_REGION \
    --query 'Subnets[*].SubnetId' \
    --output text)

PRIVATE_SUBNET_LIST=$(echo $PRIVATE_SUBNETS | tr '\t' ',' | tr ' ' ',')
echo "✓ 私有子网: $PRIVATE_SUBNET_LIST"

echo ""
echo "开始创建 EKS 集群（预计需要 15-20 分钟）..."
echo ""

# 使用 eksctl 命令行参数指定现有 VPC 和子网
eksctl create cluster \
    --name $CLUSTER_NAME \
    --region $AWS_REGION \
    --version 1.30 \
    --vpc-public-subnets $PUBLIC_SUBNET_LIST \
    --node-type $NODE_TYPE \
    --nodes $NODE_COUNT \
    --nodes-min 1 \
    --nodes-max 4 \
    --managed \
    --with-oidc \
    --node-volume-size 30

# 验证集群
echo ""
echo "验证集群..."
kubectl cluster-info
kubectl get nodes

# 保存配置
cat > /tmp/eks-config.env <<EOF
export CLUSTER_NAME="$CLUSTER_NAME"
export AWS_REGION="$AWS_REGION"
export VPC_ID="$VPC_ID"
EOF

echo ""
echo "==================================="
echo "✓ EKS 集群创建完成！"
echo "==================================="
echo ""
echo "集群信息:"
echo "  名称: $CLUSTER_NAME"
echo "  区域: $AWS_REGION"
echo "  VPC:  $VPC_ID"
echo ""
echo "配置已保存到 /tmp/eks-config.env"
echo "使用: source /tmp/eks-config.env"
echo ""
echo "下一步: 运行 ./00-create-nlb.sh"
