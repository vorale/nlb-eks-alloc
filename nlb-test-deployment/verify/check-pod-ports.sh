#!/bin/bash
set -e

echo "=== 检查Pod端口分配 ==="
echo ""

# 获取所有带auto-assign注解的Pods
PODS=$(kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.annotations."nlb.port-manager/auto-assign" == "true") | "\(.metadata.namespace)/\(.metadata.name)"')

if [ -z "$PODS" ]; then
    echo "未找到带 nlb.port-manager/auto-assign 注解的Pod"
    exit 0
fi

echo "找到以下管理的Pods:"
echo "$PODS"
echo ""

# 检查每个Pod
for POD_PATH in $PODS; do
    NAMESPACE=$(echo $POD_PATH | cut -d'/' -f1)
    POD_NAME=$(echo $POD_PATH | cut -d'/' -f2)
    
    echo "Pod: $NAMESPACE/$POD_NAME"
    
    # 获取Pod IP
    POD_IP=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.podIP}')
    echo "  Pod IP: $POD_IP"
    
    # 获取分配的端口
    ALLOCATED_PORT=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
    if [ -n "$ALLOCATED_PORT" ] && [ "$ALLOCATED_PORT" != "null" ]; then
        echo "  ✓ 分配端口: $ALLOCATED_PORT"
    else
        echo "  ✗ 未分配端口"
    fi
    
    # 获取Target Group ARN
    TG_ARN=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
    if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "null" ]; then
        echo "  ✓ Target Group: ${TG_ARN##*/}"
    else
        echo "  ✗ 未创建Target Group"
    fi
    
    # 获取Listener ARN
    LISTENER_ARN=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/listener-arn}')
    if [ -n "$LISTENER_ARN" ] && [ "$LISTENER_ARN" != "null" ]; then
        echo "  ✓ Listener: ${LISTENER_ARN##*/}"
    else
        echo "  ✗ 未创建Listener"
    fi
    
    echo ""
done

echo "=== 检查完成 ==="
