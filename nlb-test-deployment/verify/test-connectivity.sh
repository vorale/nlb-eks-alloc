#!/bin/bash
set -e

echo "=== 测试NLB连通性 ==="
echo ""

if [ -z "$NLB_ARN" ]; then
    echo "错误: 请设置环境变量 NLB_ARN"
    exit 1
fi

# 获取NLB DNS
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$NLB_ARN" --query 'LoadBalancers[0].DNSName' --output text)
echo "NLB DNS: $NLB_DNS"
echo ""

# 获取所有带auto-assign注解的Pods
PODS=$(kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.annotations."nlb.port-manager/auto-assign" == "true") | "\(.metadata.namespace)/\(.metadata.name)"')

if [ -z "$PODS" ]; then
    echo "未找到带 nlb.port-manager/auto-assign 注解的Pod"
    exit 0
fi

SUCCESS=0
FAILED=0

for POD_PATH in $PODS; do
    NAMESPACE=$(echo $POD_PATH | cut -d'/' -f1)
    POD_NAME=$(echo $POD_PATH | cut -d'/' -f2)
    
    # 获取分配的端口
    PORT=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
    
    if [ -z "$PORT" ] || [ "$PORT" = "null" ]; then
        echo "✗ $NAMESPACE/$POD_NAME: 未分配端口"
        FAILED=$((FAILED + 1))
        continue
    fi
    
    echo "测试 $NAMESPACE/$POD_NAME (端口 $PORT)..."
    
    # 测试连接
    RESPONSE=$(curl -s --connect-timeout 5 --max-time 10 "http://$NLB_DNS:$PORT" 2>/dev/null || echo "")
    
    if [ -n "$RESPONSE" ]; then
        echo "  ✓ 连接成功"
        echo "  响应: $(echo "$RESPONSE" | head -n 1)"
        SUCCESS=$((SUCCESS + 1))
    else
        echo "  ✗ 连接失败"
        
        # 检查Target健康状态
        TG_ARN=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
        if [ -n "$TG_ARN" ]; then
            HEALTH=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --query 'TargetHealthDescriptions[0].TargetHealth.State' --output text 2>/dev/null || echo "unknown")
            echo "  Target状态: $HEALTH"
            if [ "$HEALTH" != "healthy" ]; then
                echo "  提示: 等待健康检查通过（可能需要30-90秒）"
            fi
        fi
        FAILED=$((FAILED + 1))
    fi
    echo ""
done

echo "=== 测试结果 ==="
echo "成功: $SUCCESS"
echo "失败: $FAILED"
echo ""

if [ $FAILED -gt 0 ]; then
    echo "提示: 如果Target状态为initial，请等待健康检查完成后重试"
    exit 1
fi
