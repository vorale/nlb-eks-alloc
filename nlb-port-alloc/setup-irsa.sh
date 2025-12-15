#!/bin/bash

# IRSA Setup Script for NLB Port Operator

set -e

CLUSTER_NAME="${CLUSTER_NAME:-your-eks-cluster}"
REGION="${AWS_REGION:-us-west-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="nlb-port-operator-role"
NAMESPACE="kube-system"
SERVICE_ACCOUNT="nlb-port-operator"
POLICY_NAME="NLBPortOperatorPolicy"

echo "=================================="
echo "NLB Port Operator IRSA Setup"
echo "=================================="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Account: $ACCOUNT_ID"
echo "=================================="

# Create IAM OIDC provider for EKS cluster
echo "Creating IAM OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --approve

# Create IAM policy
echo "Creating IAM policy..."
POLICY_ARN=$(aws iam create-policy \
  --policy-name $POLICY_NAME \
  --policy-document file://iam-policy.json \
  --query 'Policy.Arn' \
  --output text 2>/dev/null || \
  aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)

echo "Policy ARN: $POLICY_ARN"

# Create IAM role with trust relationship
echo "Creating IAM service account..."
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=$NAMESPACE \
  --name=$SERVICE_ACCOUNT \
  --role-name=$ROLE_NAME \
  --attach-policy-arn=$POLICY_ARN \
  --region=$REGION \
  --approve \
  --override-existing-serviceaccounts

echo ""
echo "=================================="
echo "IRSA setup complete!"
echo "=================================="
echo "Role ARN: arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"
echo ""
echo "Next steps:"
echo "1. Update k8s/configmap.yaml with your NLB ARN and VPC ID"
echo "2. Update k8s/rbac.yaml with the Role ARN above"
echo "3. Build and push Docker image"
echo "4. Update k8s/deployment.yaml with your image repository"
echo "5. Deploy: kubectl apply -f k8s/"

