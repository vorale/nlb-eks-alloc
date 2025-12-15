#!/bin/bash

# 构建并推送 Operator Docker 镜像到 ECR

set -e

echo "=== 构建并推送 NLB Port Operator 镜像 ==="
echo ""

# 配置
AWS_REGION="${AWS_REGION:-us-west-2}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="nlb-port-operator"
IMAGE_TAG="${IMAGE_TAG:-latest}"

ECR_URI="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$REPO_NAME"

echo "配置:"
echo "  区域: $AWS_REGION"
echo "  账号: $ACCOUNT_ID"
echo "  镜像: $ECR_URI:$IMAGE_TAG"
echo ""

# 获取 Operator 源码目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPERATOR_DIR="$SCRIPT_DIR/../../nlb-port-alloc"

if [ ! -f "$OPERATOR_DIR/Dockerfile" ]; then
    echo "错误: 未找到 Operator 源码目录"
    echo "期望路径: $OPERATOR_DIR"
    exit 1
fi

echo "源码目录: $OPERATOR_DIR"
echo ""

# 1. 创建 ECR 仓库（如果不存在）
echo "1. 检查/创建 ECR 仓库..."
aws ecr describe-repositories --repository-names $REPO_NAME --region $AWS_REGION &>/dev/null || \
aws ecr create-repository --repository-name $REPO_NAME --region $AWS_REGION

echo "   ✓ ECR 仓库就绪"

# 2. 登录 ECR
echo ""
echo "2. 登录 ECR..."
aws ecr get-login-password --region $AWS_REGION | \
    docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
echo "   ✓ ECR 登录成功"

# 3. 构建 Docker 镜像（为 linux/amd64 架构）
echo ""
echo "3. 构建 Docker 镜像 (linux/amd64)..."
cd "$OPERATOR_DIR"
docker build --platform linux/amd64 -t $REPO_NAME:$IMAGE_TAG .
echo "   ✓ 镜像构建成功"

# 4. 标记镜像
echo ""
echo "4. 标记镜像..."
docker tag $REPO_NAME:$IMAGE_TAG $ECR_URI:$IMAGE_TAG
echo "   ✓ 镜像标记成功"

# 5. 推送镜像
echo ""
echo "5. 推送镜像到 ECR..."
docker push $ECR_URI:$IMAGE_TAG
echo "   ✓ 镜像推送成功"

# 6. 更新部署配置
echo ""
echo "6. 更新部署配置..."
DEPLOY_FILE="$SCRIPT_DIR/../config/deployment.yaml"
sed -i.bak "s|your-registry/nlb-port-operator:latest|$ECR_URI:$IMAGE_TAG|g" "$DEPLOY_FILE"
sed -i.bak "s|image:.*nlb-port-operator.*|image: $ECR_URI:$IMAGE_TAG|g" "$DEPLOY_FILE"
rm -f "$DEPLOY_FILE.bak"
echo "   ✓ 部署配置已更新"

echo ""
echo "==================================="
echo "✓ 镜像构建并推送成功！"
echo "==================================="
echo ""
echo "镜像 URI: $ECR_URI:$IMAGE_TAG"
echo ""
echo "下一步: 重新部署 Operator"
echo "  kubectl rollout restart deployment/nlb-port-operator -n kube-system"
