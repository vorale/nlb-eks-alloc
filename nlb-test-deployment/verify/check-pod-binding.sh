#!/bin/bash

# 检查Pod绑定功能脚本

set -e

echo "=== NLB Port Operator Pod 绑定功能检查 ==="
echo ""

# 检查服务注解
echo "1. 检查指定Pod绑定的服务..."
SERVICES=$(kubectl get svc -A -o json | jq -r '.items[] | select(.metadata.annotations."nlb.port-manager/target-pod" != null) | "\(.metadata.namespace) \(.metadata.name) \(.metadata.annotations."nlb.port-manager/target-pod") \(.metadata.annotations."nlb.port-manager/target-namespace" // .metadata.namespace)"')

if [ -z "$SERVICES" ]; then
    echo "未找到使用Pod绑定功能的服务"
    exit 0
fi

echo "使用Pod绑定功能的服务:"
echo "$SERVICES"
echo ""

# 检查每个服务的绑定情况
echo "2. 检查Pod绑定详情..."
while IFS= read -r line; do
    if [ -n "$line" ]; then
        SERVICE_NAMESPACE=$(echo $line | awk '{print $1}')
        SERVICE_NAME=$(echo $line | awk '{print $2}')
        TARGET_POD=$(echo $line | awk '{print $3}')
        TARGET_NAMESPACE=$(echo $line | awk '{print $4}')
        
        echo "=== 服务: $SERVICE_NAMESPACE/$SERVICE_NAME ==="
        echo "  目标Pod: $TARGET_NAMESPACE/$TARGET_POD"
        
        # 检查目标Pod是否存在
        if kubectl get pod $TARGET_POD -n $TARGET_NAMESPACE >/dev/null 2>&1; then
            POD_STATUS=$(kubectl get pod $TARGET_POD -n $TARGET_NAMESPACE -o jsonpath='{.status.phase}')
            POD_IP=$(kubectl get pod $TARGET_POD -n $TARGET_NAMESPACE -o jsonpath='{.status.podIP}')
            echo "  Pod状态: $POD_STATUS"
            echo "  Pod IP: $POD_IP"
        else
            echo "  Pod状态: 不存在"
            POD_IP=""
        fi
        
        # 获取分配的端口
        ALLOCATED_PORT=$(kubectl get svc $SERVICE_NAME -n $SERVICE_NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}' 2>/dev/null || echo "未分配")
        echo "  分配端口: $ALLOCATED_PORT"
        
        # 获取Target Group ARN
        TG_ARN=$(kubectl get svc $SERVICE_NAME -n $SERVICE_NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}' 2>/dev/null || echo "未创建")
        echo "  Target Group: $TG_ARN"
        
        # 检查Target Group中的目标
        if [ "$TG_ARN" != "未创建" ] && [ -n "$TG_ARN" ]; then
            echo "  Target Group 目标:"
            aws elbv2 describe-target-health --target-group-arn $TG_ARN --query 'TargetHealthDescriptions[].{IP:Target.Id,Port:Target.Port,Health:TargetHealth.State}' --output table
            
            # 验证Pod IP是否正确注册
            if [ -n "$POD_IP" ]; then
                REGISTERED=$(aws elbv2 describe-target-health --target-group-arn $TG_ARN --query "TargetHealthDescriptions[?Target.Id=='$POD_IP'].Target.Id" --output text)
                if [ -n "$REGISTERED" ]; then
                    echo "  ✓ Pod IP 已正确注册到 Target Group"
                else
                    echo "  ✗ Pod IP 未注册到 Target Group"
                fi
            fi
        fi
        
        echo ""
    fi
done <<< "$SERVICES"

echo "=== 检查完成 ==="
