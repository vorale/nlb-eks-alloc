#!/bin/bash

# Pod绑定功能测试脚本

set -e

echo "=== NLB Port Operator Pod 绑定功能测试 ==="
echo ""

# 检查环境变量
REQUIRED_VARS=("CLUSTER_NAME" "AWS_REGION" "NLB_ARN" "VPC_ID")
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "错误: 环境变量 $var 未设置"
        exit 1
    fi
done

echo "1. 部署Pod绑定测试用例..."
kubectl apply -f test/test-pod-binding.yaml
echo "  已部署指定Pod绑定测试"

echo ""
echo "2. 等待Pod就绪..."
kubectl wait --for=condition=ready pod gateway-pod-12345 --timeout=120s
kubectl wait --for=condition=ready pod gateway-pod-67890 --timeout=120s
echo "  Pod已就绪"

echo ""
echo "3. 等待端口分配..."
for service in "gateway-service-12345" "gateway-service-67890"; do
    echo "  等待服务 $service 端口分配..."
    for i in {1..12}; do
        ALLOCATED_PORT=$(kubectl get svc $service -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}' 2>/dev/null || echo "")
        if [ -n "$ALLOCATED_PORT" ] && [ "$ALLOCATED_PORT" != "null" ]; then
            echo "    $service: 端口 $ALLOCATED_PORT"
            break
        fi
        echo "    等待中... ($i/12)"
        sleep 5
    done
    
    if [ -z "$ALLOCATED_PORT" ] || [ "$ALLOCATED_PORT" = "null" ]; then
        echo "    错误: $service 端口分配超时"
        exit 1
    fi
done

echo ""
echo "4. 验证Pod绑定..."
./verify/check-pod-binding.sh

echo ""
echo "5. 测试连通性..."
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --query 'LoadBalancers[0].DNSName' --output text)

for service in "gateway-service-12345" "gateway-service-67890"; do
    ALLOCATED_PORT=$(kubectl get svc $service -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
    echo "  测试服务 $service (端口: $ALLOCATED_PORT)"
    
    if curl -s --connect-timeout 10 --max-time 15 "http://$NLB_DNS:$ALLOCATED_PORT" > /dev/null; then
        echo "    ✓ 连通性测试成功"
        echo "    响应内容:"
        curl -s --connect-timeout 10 --max-time 15 "http://$NLB_DNS:$ALLOCATED_PORT" | head -3 | sed 's/^/      /'
    else
        echo "    ✗ 连通性测试失败"
    fi
    echo ""
done

echo "6. 测试跨命名空间绑定..."
kubectl apply -f test/test-cross-namespace.yaml
echo "  已部署跨命名空间测试"

echo ""
echo "  等待跨命名空间Pod就绪..."
kubectl wait --for=condition=ready pod game-server-room-1 -n game-ns --timeout=120s

echo ""
echo "  等待跨命名空间服务端口分配..."
for i in {1..12}; do
    ALLOCATED_PORT=$(kubectl get svc game-room-1-service -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}' 2>/dev/null || echo "")
    if [ -n "$ALLOCATED_PORT" ] && [ "$ALLOCATED_PORT" != "null" ]; then
        echo "    跨命名空间服务: 端口 $ALLOCATED_PORT"
        break
    fi
    echo "    等待中... ($i/12)"
    sleep 5
done

if [ -n "$ALLOCATED_PORT" ] && [ "$ALLOCATED_PORT" != "null" ]; then
    echo ""
    echo "  测试跨命名空间连通性..."
    if curl -s --connect-timeout 10 --max-time 15 "http://$NLB_DNS:$ALLOCATED_PORT" > /dev/null; then
        echo "    ✓ 跨命名空间连通性测试成功"
        curl -s --connect-timeout 10 --max-time 15 "http://$NLB_DNS:$ALLOCATED_PORT" | head -3 | sed 's/^/      /'
    else
        echo "    ✗ 跨命名空间连通性测试失败"
    fi
fi

echo ""
echo "=== Pod 绑定功能测试完成 ==="
echo ""
echo "清理测试资源:"
echo "kubectl delete -f test/test-pod-binding.yaml"
echo "kubectl delete -f test/test-cross-namespace.yaml"
