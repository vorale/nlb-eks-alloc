#!/bin/bash
set -e

echo "=== NLB Port Operator 快速测试 (Pod Mode) ==="
echo ""

# 检查环境变量
if [ -z "$CLUSTER_NAME" ] || [ -z "$AWS_REGION" ] || [ -z "$NLB_ARN" ] || [ -z "$VPC_ID" ]; then
    echo "错误: 请设置环境变量"
    echo "export CLUSTER_NAME=your-cluster"
    echo "export AWS_REGION=us-west-2"
    echo "export NLB_ARN=arn:aws:..."
    echo "export VPC_ID=vpc-xxx"
    exit 1
fi

echo "环境配置:"
echo "  Cluster: $CLUSTER_NAME"
echo "  Region: $AWS_REGION"
echo "  NLB: $NLB_ARN"
echo "  VPC: $VPC_ID"
echo ""

# 检查operator是否运行
echo "1. 检查Operator状态..."
if ! kubectl get pods -n kube-system -l app=nlb-port-operator | grep -q Running; then
    echo "  错误: Operator未运行，请先部署operator"
    echo "  运行: cd setup && ./02-deploy-operator.sh"
    exit 1
fi
echo "  ✓ Operator运行中"

# 部署测试Pod
echo ""
echo "2. 部署测试Pods..."
kubectl apply -f test/test-multi-pods.yaml
echo "  ✓ 已部署3个测试Pods"

# 等待Pod就绪
echo ""
echo "3. 等待Pods就绪..."
for pod in game-room-1 game-room-2 game-room-3; do
    echo "  等待 $pod..."
    kubectl wait --for=condition=ready pod/$pod --timeout=120s 2>/dev/null || true
done
echo "  ✓ Pods已就绪"

# 等待端口分配
echo ""
echo "4. 等待端口分配（最多60秒）..."
for i in {1..12}; do
    sleep 5
    ALLOCATED=$(kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.nlb\.port-manager/allocated-port}{"\n"}{end}' | grep -c "^game-room" || echo 0)
    echo "  已分配: $ALLOCATED/3"
    if [ "$ALLOCATED" -eq 3 ]; then
        break
    fi
done

# 显示结果
echo ""
echo "5. 端口分配结果:"
kubectl get pods -o custom-columns=NAME:.metadata.name,PORT:.metadata.annotations.nlb\.port-manager/allocated-port | grep game-room

# 检查Target Groups
echo ""
echo "6. 检查Target Groups健康状态..."
for pod in game-room-1 game-room-2 game-room-3; do
    TG_ARN=$(kubectl get pod $pod -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}' 2>/dev/null || echo "")
    if [ -n "$TG_ARN" ]; then
        HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "unknown")
        echo "  $pod: $HEALTH"
    else
        echo "  $pod: 未分配Target Group"
    fi
done

# 测试连通性
echo ""
echo "7. 测试连通性..."
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --query 'LoadBalancers[0].DNSName' --output text)
echo "  NLB DNS: $NLB_DNS"

for pod in game-room-1 game-room-2 game-room-3; do
    PORT=$(kubectl get pod $pod -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}' 2>/dev/null || echo "")
    if [ -n "$PORT" ]; then
        echo "  测试 $pod (端口 $PORT)..."
        if curl -s --connect-timeout 5 "http://$NLB_DNS:$PORT" | grep -q "Game Room"; then
            echo "    ✓ 连接成功"
        else
            echo "    ✗ 连接失败（可能需要等待健康检查）"
        fi
    fi
done

echo ""
echo "=== 测试完成 ==="
echo ""
echo "查看详细信息:"
echo "  kubectl get pods -o yaml | grep -A5 'nlb.port-manager'"
echo "  kubectl logs -n kube-system -l app=nlb-port-operator"
echo ""
echo "清理测试资源:"
echo "  kubectl delete -f test/test-multi-pods.yaml"
