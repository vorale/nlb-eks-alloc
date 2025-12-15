#!/bin/bash

# NLB 创建脚本 - 为 NLB Port Operator 创建 Network Load Balancer

set -e

echo "=== 创建 Network Load Balancer ==="
echo ""

# 检查必需的环境变量
if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
    echo "错误: 请设置环境变量"
    echo "export CLUSTER_NAME=your-eks-cluster"
    echo "export AWS_REGION=us-west-2"
    exit 1
fi

# 获取 VPC ID
echo "获取 VPC 信息..."

# 优先使用环境变量中的 VPC_ID
if [ -n "$VPC_ID" ]; then
    echo "使用环境变量中的 VPC ID: $VPC_ID"
# 如果有 CLUSTER_NAME，尝试从 EKS 集群获取 VPC
elif [ -n "$CLUSTER_NAME" ]; then
    VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo "")
    if [ -n "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
        echo "使用 EKS 集群 VPC: $VPC_ID"
    fi
fi

# 如果仍然没有 VPC_ID，使用默认 VPC
if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
    echo "未找到 EKS VPC，使用默认 VPC..."
    VPC_ID=$(aws ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --region $AWS_REGION \
        --query 'Vpcs[0].VpcId' \
        --output text)
    
    if [ -z "$VPC_ID" ] || [ "$VPC_ID" == "None" ]; then
        echo "错误: 无法找到默认 VPC"
        exit 1
    fi
    echo "使用默认 VPC: $VPC_ID"
fi
echo "✓ VPC ID: $VPC_ID"

# 获取公有子网（用于 internet-facing NLB）
echo "获取公有子网..."
PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:kubernetes.io/role/elb,Values=1" \
    --query 'Subnets[*].SubnetId' \
    --output text \
    --region $AWS_REGION)

# 如果没有找到带标签的子网，尝试获取所有公有子网
if [ -z "$PUBLIC_SUBNETS" ]; then
    echo "未找到带 kubernetes.io/role/elb 标签的子网，尝试查找公有子网..."
    PUBLIC_SUBNETS=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[*].SubnetId' \
        --output text \
        --region $AWS_REGION)
fi

if [ -z "$PUBLIC_SUBNETS" ]; then
    echo "错误: 未找到公有子网"
    echo "请确保 VPC 中有公有子网，或手动指定子网 ID"
    echo ""
    echo "手动指定示例:"
    echo "  export SUBNET_IDS=\"subnet-xxx subnet-yyy\""
    exit 1
fi

# 将子网列表转换为空格分隔格式
SUBNET_LIST=$(echo $PUBLIC_SUBNETS | tr '\t' ' ')
echo "✓ 子网: $SUBNET_LIST"

# NLB 名称（限制32字符）
NLB_NAME="${CLUSTER_NAME}-nlb"
# 确保名称不超过32字符
NLB_NAME="${NLB_NAME:0:32}"
echo ""
echo "创建 NLB: $NLB_NAME"

# 检查 NLB 是否已存在
EXISTING_NLB=$(aws elbv2 describe-load-balancers \
    --names $NLB_NAME \
    --region $AWS_REGION \
    --query 'LoadBalancers[0].LoadBalancerArn' \
    --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_NLB" ] && [ "$EXISTING_NLB" != "None" ]; then
    echo "NLB 已存在: $NLB_NAME"
    NLB_ARN=$EXISTING_NLB
else
    # 创建 NLB
    NLB_ARN=$(aws elbv2 create-load-balancer \
        --name $NLB_NAME \
        --type network \
        --scheme internet-facing \
        --subnets $SUBNET_LIST \
        --region $AWS_REGION \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text)
    
    echo "✓ NLB 创建成功"
fi

# 获取 NLB DNS
NLB_DNS=$(aws elbv2 describe-load-balancers \
    --load-balancer-arns $NLB_ARN \
    --region $AWS_REGION \
    --query 'LoadBalancers[0].DNSName' \
    --output text)

echo ""
echo "==================================="
echo "NLB 创建完成！"
echo "==================================="
echo ""
echo "NLB 信息:"
echo "  名称: $NLB_NAME"
echo "  ARN:  $NLB_ARN"
echo "  DNS:  $NLB_DNS"
echo "  VPC:  $VPC_ID"
echo ""
echo "请设置以下环境变量用于后续部署:"
echo ""
echo "  export NLB_ARN=\"$NLB_ARN\""
echo "  export VPC_ID=\"$VPC_ID\""
echo "  export NLB_DNS=\"$NLB_DNS\""
echo ""
echo "下一步: 运行 ./01-setup-irsa.sh"

# 保存配置到文件
cat > /tmp/nlb-config.env <<EOF
export NLB_ARN="$NLB_ARN"
export VPC_ID="$VPC_ID"
export NLB_DNS="$NLB_DNS"
export NLB_NAME="$NLB_NAME"
EOF

echo ""
echo "配置已保存到 /tmp/nlb-config.env"
echo "使用: source /tmp/nlb-config.env"
