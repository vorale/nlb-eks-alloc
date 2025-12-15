#!/bin/bash

# 删除 EKS 集群

set -e

echo "=== 删除 EKS 集群 ==="
echo ""

# 默认配置
AWS_REGION="${AWS_REGION:-us-west-2}"
CLUSTER_NAME="${CLUSTER_NAME:-nlb-operator-test}"

echo "警告: 即将删除 EKS 集群!"
echo "  集群: $CLUSTER_NAME"
echo "  区域: $AWS_REGION"
echo ""
read -p "确认删除? (输入 'yes' 继续): " confirm

if [ "$confirm" != "yes" ]; then
    echo "取消删除"
    exit 0
fi

# 检查 eksctl
if ! command -v eksctl &> /dev/null; then
    echo "错误: eksctl 未安装"
    exit 1
fi

echo ""
echo "删除集群（可能需要 10-15 分钟）..."

eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION

echo ""
echo "==================================="
echo "✓ EKS 集群已删除"
echo "==================================="
