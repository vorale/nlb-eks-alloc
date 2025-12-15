#!/bin/bash

# 前置条件检查脚本

set -e

echo "=== NLB Port Operator 前置条件检查 ==="
echo ""

# 默认区域
AWS_REGION="${AWS_REGION:-us-west-2}"

ERRORS=0

# 1. 检查 AWS CLI
echo "1. 检查 AWS CLI..."
if command -v aws &> /dev/null; then
    AWS_VERSION=$(aws --version 2>&1 | head -1)
    echo "   ✓ AWS CLI 已安装: $AWS_VERSION"
else
    echo "   ✗ AWS CLI 未安装"
    echo "     安装方法: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    ERRORS=$((ERRORS + 1))
fi

# 2. 检查 AWS 凭证
echo ""
echo "2. 检查 AWS 凭证..."
if aws sts get-caller-identity &> /dev/null; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    USER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    echo "   ✓ AWS 凭证有效"
    echo "     账号: $ACCOUNT_ID"
    echo "     身份: $USER_ARN"
else
    echo "   ✗ AWS 凭证无效或未配置"
    echo "     运行: aws configure"
    ERRORS=$((ERRORS + 1))
fi

# 3. 检查 kubectl
echo ""
echo "3. 检查 kubectl..."
if command -v kubectl &> /dev/null; then
    KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null || kubectl version --client -o yaml 2>/dev/null | grep gitVersion | head -1)
    echo "   ✓ kubectl 已安装: $KUBECTL_VERSION"
else
    echo "   ✗ kubectl 未安装"
    echo "     安装方法: https://kubernetes.io/docs/tasks/tools/"
    ERRORS=$((ERRORS + 1))
fi

# 4. 检查 eksctl
echo ""
echo "4. 检查 eksctl..."
if command -v eksctl &> /dev/null; then
    EKSCTL_VERSION=$(eksctl version 2>&1)
    echo "   ✓ eksctl 已安装: $EKSCTL_VERSION"
else
    echo "   ✗ eksctl 未安装"
    echo "     安装方法:"
    echo "     macOS: brew tap weaveworks/tap && brew install weaveworks/tap/eksctl"
    echo "     Linux: curl -sLO \"https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz\""
    ERRORS=$((ERRORS + 1))
fi

# 5. 检查 Docker（用于构建 Operator 镜像）
echo ""
echo "5. 检查 Docker..."
if command -v docker &> /dev/null; then
    if docker info &> /dev/null; then
        DOCKER_VERSION=$(docker --version)
        echo "   ✓ Docker 已安装且运行中: $DOCKER_VERSION"
    else
        echo "   ⚠ Docker 已安装但未运行"
        echo "     请启动 Docker Desktop"
    fi
else
    echo "   ⚠ Docker 未安装（可选，用于构建镜像）"
    echo "     安装方法: https://docs.docker.com/get-docker/"
fi

# 6. 检查默认 VPC
echo ""
echo "6. 检查默认 VPC (区域: $AWS_REGION)..."
DEFAULT_VPC=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region $AWS_REGION \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "None")

if [ -n "$DEFAULT_VPC" ] && [ "$DEFAULT_VPC" != "None" ]; then
    echo "   ✓ 默认 VPC: $DEFAULT_VPC"
else
    echo "   ⚠ 未找到默认 VPC"
    echo "     可能需要手动创建或使用自定义 VPC"
fi

# 7. 检查现有 EKS 集群
echo ""
echo "7. 检查现有 EKS 集群 (区域: $AWS_REGION)..."
CLUSTERS=$(aws eks list-clusters --region $AWS_REGION --query 'clusters[]' --output text 2>/dev/null || echo "")
if [ -n "$CLUSTERS" ]; then
    echo "   现有集群:"
    for cluster in $CLUSTERS; do
        echo "     - $cluster"
    done
else
    echo "   未找到 EKS 集群"
    echo "   运行 ./setup/pre-00-create-eks.sh 创建集群"
fi

# 8. 检查 kubectl 配置
echo ""
echo "8. 检查 kubectl 配置..."
if kubectl config current-context &> /dev/null; then
    CURRENT_CONTEXT=$(kubectl config current-context)
    echo "   ✓ 当前上下文: $CURRENT_CONTEXT"
    
    # 尝试连接集群
    if kubectl cluster-info &> /dev/null 2>&1; then
        echo "   ✓ 集群连接正常"
    else
        echo "   ⚠ 无法连接到集群"
        echo "     运行: aws eks update-kubeconfig --name <cluster-name> --region $AWS_REGION"
    fi
else
    echo "   ⚠ kubectl 未配置上下文"
    echo "     创建集群后运行: aws eks update-kubeconfig --name <cluster-name> --region $AWS_REGION"
fi

echo ""
echo "==================================="
if [ $ERRORS -eq 0 ]; then
    echo "✓ 所有必需工具已安装"
else
    echo "✗ 发现 $ERRORS 个问题，请先解决再继续"
fi
echo "==================================="

exit $ERRORS
