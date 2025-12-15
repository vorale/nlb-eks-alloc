#!/bin/bash

# 配置 kubectl 连接到 EKS 集群

set -e

echo "=== 配置 kubectl ==="
echo ""

# 默认配置
AWS_REGION="${AWS_REGION:-us-west-2}"

# 检查 CLUSTER_NAME
if [ -z "$CLUSTER_NAME" ]; then
    echo "未设置 CLUSTER_NAME，列出可用集群..."
    echo ""
    
    CLUSTERS=$(aws eks list-clusters --region $AWS_REGION --query 'clusters[]' --output text 2>/dev/null || echo "")
    
    if [ -z "$CLUSTERS" ]; then
        echo "错误: 区域 $AWS_REGION 中没有 EKS 集群"
        echo "运行 ./pre-00-create-eks.sh 创建集群"
        exit 1
    fi
    
    echo "可用集群:"
    i=1
    for cluster in $CLUSTERS; do
        echo "  $i) $cluster"
        CLUSTER_ARRAY[$i]=$cluster
        i=$((i + 1))
    done
    
    if [ ${#CLUSTER_ARRAY[@]} -eq 1 ]; then
        CLUSTER_NAME=${CLUSTER_ARRAY[1]}
        echo ""
        echo "自动选择唯一集群: $CLUSTER_NAME"
    else
        echo ""
        read -p "选择集群 (1-$((i-1))): " choice
        CLUSTER_NAME=${CLUSTER_ARRAY[$choice]}
    fi
fi

if [ -z "$CLUSTER_NAME" ]; then
    echo "错误: 未选择集群"
    exit 1
fi

echo ""
echo "配置 kubectl 连接到集群: $CLUSTER_NAME"

# 更新 kubeconfig
aws eks update-kubeconfig \
    --name $CLUSTER_NAME \
    --region $AWS_REGION

echo ""
echo "验证连接..."

# 显示当前上下文
echo "当前上下文: $(kubectl config current-context)"

# 验证集群连接
echo ""
echo "集群信息:"
kubectl cluster-info

echo ""
echo "节点列表:"
kubectl get nodes

echo ""
echo "==================================="
echo "✓ kubectl 配置完成！"
echo "==================================="
echo ""
echo "设置环境变量:"
echo "  export CLUSTER_NAME=\"$CLUSTER_NAME\""
echo "  export AWS_REGION=\"$AWS_REGION\""
echo ""
echo "下一步: 运行 ./00-create-nlb.sh"
