# 测试指南

## 测试前准备

### 1. 确认环境变量
```bash
export CLUSTER_NAME=your-eks-cluster
export AWS_REGION=us-west-2
export NLB_ARN=arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/net/your-nlb/xxx
export VPC_ID=vpc-0123456789abcdef0
```

### 2. 确认Operator已部署
```bash
kubectl get pods -n kube-system -l app=nlb-port-operator
kubectl logs -n kube-system -l app=nlb-port-operator
```

## 测试场景

### 场景1: 单Pod测试

**目的**: 验证单个Pod的端口分配和NLB配置

```bash
# 部署
kubectl apply -f test/test-single-pod.yaml

# 等待Pod就绪
kubectl wait --for=condition=ready pod/game-room-1 --timeout=120s

# 检查端口分配（等待5-10秒）
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations}' | jq

# 验证注解
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}'
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/listener-arn}'

# 检查Target健康
TG_ARN=$(kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# 测试连通性（等待健康检查通过，约30-90秒）
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --query 'LoadBalancers[0].DNSName' --output text)
PORT=$(kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
curl http://$NLB_DNS:$PORT

# 清理
kubectl delete -f test/test-single-pod.yaml
```

**预期结果**:
- ✓ Pod获得allocated-port注解
- ✓ 创建Target Group和Listener
- ✓ Pod IP注册到Target Group
- ✓ Target状态变为healthy
- ✓ 通过NLB可以访问Pod

### 场景2: 多Pod并发测试

**目的**: 验证多个Pod同时分配不同端口

```bash
# 部署3个Pod
kubectl apply -f test/test-multi-pods.yaml

# 等待所有Pod就绪
kubectl wait --for=condition=ready pod/game-room-1 pod/game-room-2 pod/game-room-3 --timeout=120s

# 查看端口分配
kubectl get pods -o custom-columns=NAME:.metadata.name,PORT:.metadata.annotations.nlb\.port-manager/allocated-port

# 验证端口唯一性
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.annotations.nlb\.port-manager/allocated-port}{"\n"}{end}' | sort | uniq -d

# 使用验证脚本
./verify/check-pod-ports.sh
./verify/check-targets.sh

# 清理
kubectl delete -f test/test-multi-pods.yaml
```

**预期结果**:
- ✓ 3个Pod各自获得不同的端口
- ✓ 端口号连续或在配置范围内
- ✓ 每个Pod有独立的Target Group
- ✓ 所有Target状态healthy

### 场景3: Pod生命周期测试

**目的**: 验证Pod删除时NLB资源自动清理

```bash
# 部署测试Pod
kubectl apply -f test/test-pod-lifecycle.yaml

# 等待Pod就绪和端口分配
kubectl wait --for=condition=ready pod/lifecycle-test --timeout=120s
sleep 10

# 记录分配的资源
PORT=$(kubectl get pod lifecycle-test -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
TG_ARN=$(kubectl get pod lifecycle-test -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
LISTENER_ARN=$(kubectl get pod lifecycle-test -o jsonpath='{.metadata.annotations.nlb\.port-manager/listener-arn}')

echo "分配的端口: $PORT"
echo "Target Group: $TG_ARN"
echo "Listener: $LISTENER_ARN"

# 验证资源存在
aws elbv2 describe-target-groups --target-group-arns $TG_ARN
aws elbv2 describe-listeners --listener-arns $LISTENER_ARN

# 删除Pod
kubectl delete pod lifecycle-test

# 等待清理（5-10秒）
sleep 10

# 验证资源已删除
aws elbv2 describe-target-groups --target-group-arns $TG_ARN 2>&1 | grep -q "TargetGroupNotFound" && echo "✓ Target Group已删除" || echo "✗ Target Group仍存在"
aws elbv2 describe-listeners --listener-arns $LISTENER_ARN 2>&1 | grep -q "ListenerNotFound" && echo "✓ Listener已删除" || echo "✗ Listener仍存在"

# 验证端口可重用
kubectl apply -f test/test-pod-lifecycle.yaml
sleep 10
NEW_PORT=$(kubectl get pod lifecycle-test -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
echo "新分配的端口: $NEW_PORT"

# 清理
kubectl delete -f test/test-pod-lifecycle.yaml
```

**预期结果**:
- ✓ Pod删除后Listener自动删除
- ✓ Pod删除后Target Group自动删除
- ✓ 端口可以被新Pod重用

### 场景4: 快速集成测试

**目的**: 一键运行所有基础测试

```bash
./quick-test.sh
```

**预期结果**:
- ✓ 部署3个测试Pod
- ✓ 所有Pod获得端口
- ✓ Target状态healthy
- ✓ 连通性测试通过

## 故障排查

### Pod未获得端口

1. 检查Pod注解
```bash
kubectl get pod <pod-name> -o yaml | grep -A2 annotations
```

2. 检查Pod IP
```bash
kubectl get pod <pod-name> -o wide
```

3. 检查Operator日志
```bash
kubectl logs -n kube-system -l app=nlb-port-operator | grep <pod-name>
```

4. 检查端口池
```bash
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].Port'
```

### Target不健康

1. 检查Pod状态
```bash
kubectl get pod <pod-name> -o wide
```

2. 检查安全组
```bash
# 确保NLB可以访问Pod IP的TARGET_PORT
```

3. 检查健康检查配置
```bash
TG_ARN=$(kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
aws elbv2 describe-target-groups --target-group-arns $TG_ARN --query 'TargetGroups[0].HealthCheckProtocol'
```

### 连接失败

1. 等待健康检查（30-90秒）
2. 检查NLB安全组
3. 检查VPC路由表
4. 使用tcpdump调试网络

## 清理所有测试资源

```bash
# 删除所有测试Pods
kubectl delete -f test/

# 验证NLB资源已清理
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN
aws elbv2 describe-target-groups --query 'TargetGroups[?starts_with(TargetGroupName, `tg-default-`)].TargetGroupName'
```
