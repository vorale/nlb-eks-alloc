# NLB Port Operator - Pod Mode

## 概述

此operator为**每个Pod**自动分配独立的NLB端口，实现Pod名称到NLB端口的1对1映射。

## 特性

- **多协议支持**: TCP、UDP、TCP_UDP（双协议）
- **灵活端口配置**: 通过注解指定容器端口和协议
- **多端口支持**: 单个Pod可配置多个端口/协议组合
- **自动资源管理**: Pod删除时自动清理NLB资源

## 工作原理

```
Pod: game-room-1 (8080/TCP)    →  NLB Port: 30000/TCP     →  Pod IP: 10.0.1.5:8080
Pod: voice-server (9999/UDP)   →  NLB Port: 30001/UDP     →  Pod IP: 10.0.1.6:9999
Pod: dual-server (7777/TCPUDP) →  NLB Port: 30002/TCP_UDP →  Pod IP: 10.0.1.7:7777
```

每个Pod获得：
- 独立的NLB端口（从配置的范围自动分配）
- 独立的Target Group（只包含该Pod的IP）
- 独立的NLB Listener（支持TCP/UDP/TCP_UDP协议）

## 配置

### ConfigMap (k8s/configmap.yaml)

```yaml
data:
  NLB_ARN: "arn:aws:elasticloadbalancing:..."
  VPC_ID: "vpc-xxxxx"
  PORT_RANGE_MIN: "30000"
  PORT_RANGE_MAX: "32767"
  DEFAULT_PORT_SPEC: "80/TCP"  # 默认端口规格
```

## 使用方法

### 1. TCP Pod（基本用法）

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: game-room-1
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "8080/TCP"  # 容器端口/协议
spec:
  containers:
  - name: game-server
    image: your-game-server:latest
    ports:
    - containerPort: 8080
```

### 2. UDP Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: voice-server
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "9999/UDP"
spec:
  containers:
  - name: voice-server
    image: your-voice-server:latest
    ports:
    - containerPort: 9999
      protocol: UDP
```

### 3. 双协议 Pod（TCP + UDP 同端口）

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dual-server
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "7777/TCPUDP"  # 或 "7777/TCP_UDP"
spec:
  containers:
  - name: server
    image: your-server:latest
    ports:
    - containerPort: 7777
      protocol: TCP
    - containerPort: 7777
      protocol: UDP
```

### 4. 多端口 Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: multi-service
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "80/TCP,9999/UDP"  # HTTP + Voice
spec:
  containers:
  - name: server
    image: your-server:latest
    ports:
    - containerPort: 80
    - containerPort: 9999
      protocol: UDP
```

## 端口规格格式

| 格式 | 说明 | 示例 |
|------|------|------|
| `PORT/TCP` | 单端口 TCP | `8080/TCP` |
| `PORT/UDP` | 单端口 UDP | `9999/UDP` |
| `PORT/TCPUDP` | 同端口双协议 | `7777/TCPUDP` |
| `PORT/TCP_UDP` | 同端口双协议 | `7777/TCP_UDP` |
| `PORT1/PROTO1,PORT2/PROTO2` | 多端口 | `80/TCP,9999/UDP` |

## 查看分配的端口

```bash
# 单端口模式
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'

# 多端口模式
kubectl get pod multi-service -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-ports}' | jq

# 查看所有资源
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/resources}' | jq
```

## 测试连接

```bash
# 获取NLB DNS
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --query 'LoadBalancers[0].DNSName' --output text)

# 获取分配的端口
PORT=$(kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')

# TCP 测试
nc -zv $NLB_DNS $PORT

# UDP 测试
echo "test" | nc -u $NLB_DNS $PORT
```

## Pod注解说明

### 输入注解（用户添加）

| 注解 | 必需 | 说明 |
|------|------|------|
| `nlb.port-manager/auto-assign` | 是 | 设为 `"true"` 启用 |
| `nlb.port-manager/port` | 否 | 端口规格（默认: `80/TCP`） |

### 输出注解（Operator添加）

| 注解 | 说明 |
|------|------|
| `nlb.port-manager/allocated-port` | 分配的NLB端口（单端口模式） |
| `nlb.port-manager/allocated-ports` | JSON数组，所有分配的端口 |
| `nlb.port-manager/resources` | JSON数组，所有NLB资源详情 |
| `nlb.port-manager/target-group-arn` | Target Group ARN（单端口模式） |
| `nlb.port-manager/listener-arn` | Listener ARN（单端口模式） |

## 测试步骤

```bash
# 1. 部署 TCP 测试 Pod
kubectl apply -f test/test-multi-pods.yaml

# 2. 部署 UDP 测试 Pod
kubectl apply -f test/test-udp-pod.yaml

# 3. 部署双协议测试 Pod
kubectl apply -f test/test-dual-protocol-pod.yaml

# 4. 查看Pod状态
kubectl get pods

# 5. 查看分配的端口
kubectl get pods -o custom-columns=NAME:.metadata.name,PORT:.metadata.annotations.nlb\.port-manager/allocated-port

# 6. 检查NLB监听器
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].[Port,Protocol]' --output table

# 7. 检查Target Group健康状态
TG_ARN=$(kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# 8. 清理
kubectl delete -f test/
```

## 与Service模式的区别

| 特性 | Service模式（旧） | Pod模式（新） |
|------|------------------|--------------|
| 分配对象 | Service | Pod |
| 端口映射 | 1个端口 → 多个Pod | 1个端口 → 1个Pod |
| Target Group | 包含多个Pod IP | 只包含1个Pod IP |
| 协议支持 | 仅TCP | TCP/UDP/TCP_UDP |
| 使用场景 | 负载均衡 | 游戏房间、独立会话 |

## 限制

- 端口范围有限（默认30000-32767，约2768个端口）
- 每个Pod需要独立的Target Group和Listener
- Pod必须先获得IP才能分配端口
- UDP健康检查使用TCP（NLB限制）
