#!/bin/bash
set -e

echo "=== 检查Target Group注册状态 ==="
echo ""

# 获取所有带auto-assign注解的Pods
PODS=$(kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.annotations."nlb.port-manager/auto-assign" == "true") | "\(.metadata.namespace)/\(.metadata.name)"')

if [ -z "$PODS" ]; then
    echo "未找到带 nlb.port-manager/auto-assign 注解的Pod"
    exit 0
fi

for POD_PATH in $PODS; do
    NAMESPACE=$(echo $POD_PATH | cut -d'/' -f1)
    POD_NAME=$(echo $POD_PATH | cut -d'/' -f2)
    
    echo "Pod: $NAMESPACE/$POD_NAME"
    
    # 获取Pod IP
    POD_IP=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.podIP}')
    echo "  Pod IP: $POD_IP"
    
    # 获取Target Group ARN
    TG_ARN=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
    
    if [ -z "$TG_ARN" ] || [ "$TG_ARN" = "null" ]; then
        echo "  ✗ 未找到Target Group"
        echo ""
        continue
    fi
    
    echo "  Target Group: ${TG_ARN##*/}"
    
    # 检查Target健康状态
    TARGETS=$(aws elbv2 describe-target-health --target-group-arn "$TG_ARN" --output json 2>/dev/null || echo '{"TargetHealthDescriptions":[]}')
    
    TARGET_COUNT=$(echo "$TARGETS" | jq '.TargetHealthDescriptions | length')
    echo "  注册Target数量: $TARGET_COUNT"
    
    if [ "$TARGET_COUNT" -eq 0 ]; then
        echo "  ✗ 未注册任何Target"
    else
        echo "$TARGETS" | jq -r '.TargetHealthDescriptions[] | "  Target: \(.Target.Id):\(.Target.Port) - \(.TargetHealth.State)"'
        
        # 验证Pod IP是否匹配
        REGISTERED_IP=$(echo "$TARGETS" | jq -r '.TargetHealthDescriptions[0].Target.Id')
        if [ "$REGISTERED_IP" = "$POD_IP" ]; then
            echo "  ✓ Pod IP匹配"
        else
            echo "  ✗ Pod IP不匹配 (注册: $REGISTERED_IP, 实际: $POD_IP)"
        fi
    fi
    
    echo ""
done

echo "=== 检查完成 ==="
