#!/bin/bash

# 清理脚本

set -e

echo "清理 NLB Port Operator 测试环境..."

# 删除测试服务
echo "删除测试服务..."
kubectl delete -f ../test/ --ignore-not-found=true

# 等待服务删除完成
echo "等待服务删除完成..."
sleep 10

# 删除 Operator
echo "删除 Operator..."
kubectl delete -f ../config/deployment.yaml --ignore-not-found=true
kubectl delete -f ../config/configmap.yaml --ignore-not-found=true

# 删除 RBAC (保留 Service Account，因为它可能被 IRSA 使用)
echo "删除 RBAC..."
kubectl delete clusterrolebinding nlb-port-operator --ignore-not-found=true
kubectl delete clusterrole nlb-port-operator --ignore-not-found=true

echo "清理完成!"
echo ""
echo "注意: Service Account 和 IAM Role 未删除，如需完全清理请手动删除:"
echo "kubectl delete serviceaccount nlb-port-operator -n kube-system"
echo "eksctl delete iamserviceaccount --cluster=\$CLUSTER_NAME --name=nlb-port-operator --namespace=kube-system"
