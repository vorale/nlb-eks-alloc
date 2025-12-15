#!/bin/bash

# 检查端口分配脚本

set -e

echo "=== NLB Port Operator 端口分配检查 ==="
echo ""

# 检查服务注解
echo "1. 检查服务注解..."
SERVICES=$(kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.metadata.annotations.nlb\.port-manager/auto-assign}{"\n"}{end}' | grep "true")

if [ -z "$SERVICES" ]; then
    echo "未找到启用自动端口分配的服务"
    exit 0
fi

echo "启用自动端口分配的服务:"
echo "$SERVICES"
echo ""

# 检查每个服务的分配情况
echo "2. 检查端口分配详情..."
while IFS= read -r line; do
    if [ -n "$line" ]; then
        NAMESPACE=$(echo $line | awk '{print $1}')
        SERVICE=$(echo $line | awk '{print $2}')
        
        echo "服务: $NAMESPACE/$SERVICE"
        
        # 获取分配的端口
        ALLOCATED_PORT=$(kubectl get svc $SERVICE -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}' 2>/dev/null || echo "未分配")
        echo "  分配端口: $ALLOCATED_PORT"
        
        # 获取目标端口
        TARGET_PORT=$(kubectl get svc $SERVICE -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-port}' 2>/dev/null || echo "未设置")
        echo "  目标端口: $TARGET_PORT"
        
        # 获取 Target Group ARN
        TG_ARN=$(kubectl get svc $SERVICE -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}' 2>/dev/null || echo "未创建")
        echo "  Target Group: $TG_ARN"
        
        # 获取 Listener ARN
        LISTENER_ARN=$(kubectl get svc $SERVICE -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/listener-arn}' 2>/dev/null || echo "未创建")
        echo "  Listener: $LISTENER_ARN"
        
        echo ""
    fi
done <<< "$SERVICES"

# 检查 NLB 监听器
echo "3. 检查 NLB 监听器..."
if [ -n "$NLB_ARN" ]; then
    echo "NLB ARN: $NLB_ARN"
    aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[].{Port:Port,Protocol:Protocol,TargetGroup:DefaultActions[0].TargetGroupArn}' --output table
else
    echo "请设置环境变量 NLB_ARN"
fi

echo ""
echo "=== 检查完成 ==="
