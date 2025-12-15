#!/bin/bash

# NLB Port Operator 部署脚本

set -e

echo "部署 NLB Port Operator..."

# 检查必需的环境变量
if [ -z "$NLB_ARN" ] || [ -z "$VPC_ID" ]; then
    echo "错误: 请设置环境变量 NLB_ARN 和 VPC_ID"
    echo "export NLB_ARN=arn:aws:elasticloadbalancing:region:account:loadbalancer/net/your-nlb/xxx"
    echo "export VPC_ID=vpc-0123456789abcdef0"
    exit 1
fi

# 获取当前目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/../config"

# 更新配置文件中的实际值
echo "更新配置文件..."
sed -i.bak "s|arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/net/your-nlb/abc123|$NLB_ARN|g" "$CONFIG_DIR/configmap.yaml"
sed -i.bak "s|vpc-0123456789abcdef0|$VPC_ID|g" "$CONFIG_DIR/configmap.yaml"

if [ -n "$AWS_REGION" ]; then
    sed -i.bak "s|us-west-2|$AWS_REGION|g" "$CONFIG_DIR/configmap.yaml"
fi

# 获取 IAM Role ARN
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_ARN="arn:aws:iam::$ACCOUNT_ID:role/nlb-port-operator-role"
sed -i.bak "s|arn:aws:iam::123456789012:role/nlb-port-operator-role|$ROLE_ARN|g" "$CONFIG_DIR/rbac.yaml"

echo "应用配置文件..."

# 应用 RBAC
kubectl apply -f "$CONFIG_DIR/rbac.yaml"

# 应用 ConfigMap
kubectl apply -f "$CONFIG_DIR/configmap.yaml"

# 应用 Deployment
kubectl apply -f "$CONFIG_DIR/deployment.yaml"

echo "等待 Operator 启动..."
kubectl rollout status deployment/nlb-port-operator -n kube-system --timeout=300s

echo "检查 Operator 状态..."
kubectl get pods -n kube-system -l app=nlb-port-operator

echo "查看 Operator 日志..."
kubectl logs -n kube-system -l app=nlb-port-operator --tail=20

echo "NLB Port Operator 部署完成!"
echo ""
echo "使用以下命令查看日志:"
echo "kubectl logs -n kube-system -l app=nlb-port-operator -f"
