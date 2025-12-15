#!/bin/bash

# NLB Port Operator IRSA 设置脚本

set -e

# 检查必需的环境变量
if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ]; then
    echo "错误: 请设置环境变量 CLUSTER_NAME 和 AWS_REGION"
    echo "export CLUSTER_NAME=your-eks-cluster"
    echo "export AWS_REGION=us-west-2"
    exit 1
fi

echo "设置 NLB Port Operator IRSA..."
echo "集群: $CLUSTER_NAME"
echo "区域: $AWS_REGION"

# 创建 IAM 策略
POLICY_NAME="NLBPortOperatorPolicy"
POLICY_ARN="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/$POLICY_NAME"

echo "创建 IAM 策略: $POLICY_NAME"
cat > /tmp/nlb-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:DescribeLoadBalancers"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
    --policy-name $POLICY_NAME \
    --policy-document file:///tmp/nlb-policy.json \
    --region $AWS_REGION || echo "策略可能已存在"

# 创建 Service Account 和 IAM Role
ROLE_NAME="nlb-port-operator-role"
NAMESPACE="kube-system"
SERVICE_ACCOUNT="nlb-port-operator"

echo "创建 IRSA 角色: $ROLE_NAME"
eksctl create iamserviceaccount \
    --cluster=$CLUSTER_NAME \
    --namespace=$NAMESPACE \
    --name=$SERVICE_ACCOUNT \
    --role-name=$ROLE_NAME \
    --attach-policy-arn=$POLICY_ARN \
    --region=$AWS_REGION \
    --approve \
    --override-existing-serviceaccounts

echo "IRSA 设置完成!"
echo "Service Account: $NAMESPACE/$SERVICE_ACCOUNT"
echo "IAM Role: $ROLE_NAME"

# 清理临时文件
rm -f /tmp/nlb-policy.json
