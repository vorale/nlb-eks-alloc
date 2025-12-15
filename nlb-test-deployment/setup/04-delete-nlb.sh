#!/bin/bash

# 删除 NLB 和相关资源

set -e

echo "=== 删除 Network Load Balancer ==="
echo ""

# 检查必需的环境变量
if [ -z "$AWS_REGION" ]; then
    AWS_REGION="us-west-2"
    echo "使用默认区域: $AWS_REGION"
fi

# 获取 NLB ARN
if [ -z "$NLB_ARN" ]; then
    if [ -z "$CLUSTER_NAME" ]; then
        echo "错误: 请设置 NLB_ARN 或 CLUSTER_NAME"
        exit 1
    fi
    NLB_NAME="${CLUSTER_NAME}-nlb-port-operator"
    NLB_ARN=$(aws elbv2 describe-load-balancers \
        --names $NLB_NAME \
        --region $AWS_REGION \
        --query 'LoadBalancers[0].LoadBalancerArn' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$NLB_ARN" ] || [ "$NLB_ARN" == "None" ]; then
        echo "未找到 NLB: $NLB_NAME"
        exit 0
    fi
fi

echo "删除 NLB: $NLB_ARN"

# 1. 删除所有 Listeners
echo "删除 Listeners..."
LISTENERS=$(aws elbv2 describe-listeners \
    --load-balancer-arn $NLB_ARN \
    --region $AWS_REGION \
    --query 'Listeners[*].ListenerArn' \
    --output text 2>/dev/null || echo "")

for LISTENER in $LISTENERS; do
    if [ -n "$LISTENER" ] && [ "$LISTENER" != "None" ]; then
        echo "  删除 Listener: ${LISTENER##*/}"
        aws elbv2 delete-listener --listener-arn $LISTENER --region $AWS_REGION || true
    fi
done

# 2. 删除所有关联的 Target Groups
echo "删除 Target Groups..."
TARGET_GROUPS=$(aws elbv2 describe-target-groups \
    --load-balancer-arn $NLB_ARN \
    --region $AWS_REGION \
    --query 'TargetGroups[*].TargetGroupArn' \
    --output text 2>/dev/null || echo "")

for TG in $TARGET_GROUPS; do
    if [ -n "$TG" ] && [ "$TG" != "None" ]; then
        echo "  删除 Target Group: ${TG##*/}"
        aws elbv2 delete-target-group --target-group-arn $TG --region $AWS_REGION || true
    fi
done

# 等待资源删除
sleep 5

# 3. 删除 NLB
echo "删除 NLB..."
aws elbv2 delete-load-balancer --load-balancer-arn $NLB_ARN --region $AWS_REGION

echo ""
echo "=== NLB 删除完成 ==="
echo ""
echo "清理环境变量:"
echo "  unset NLB_ARN VPC_ID NLB_DNS"
