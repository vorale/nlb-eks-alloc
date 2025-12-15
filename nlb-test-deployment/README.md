# NLB Port Operator 测试部署方案 (Pod Mode)

## 概述

测试环境用于验证NLB Port Operator的Pod模式功能：
- 每个Pod自动分配独立的NLB端口
- Pod名称到NLB端口的1对1映射
- Pod生命周期管理（创建、更新、删除）

## 目录结构
```
nlb-test-deployment/
├── README.md                     # 本文档
├── quick-test.sh                # 一键快速测试脚本
├── setup/                        # 部署脚本
│   ├── pre-check.sh             # 前置条件检查
│   ├── pre-00-create-eks.sh     # 创建 EKS 集群
│   ├── pre-01-configure-kubectl.sh # 配置 kubectl
│   ├── pre-99-delete-eks.sh     # 删除 EKS 集群
│   ├── 00-create-nlb.sh         # 创建 NLB
│   ├── 01-setup-irsa.sh         # IRSA 配置
│   ├── 02-deploy-operator.sh    # 部署 Operator
│   ├── 03-cleanup.sh            # 清理 Operator
│   └── 04-delete-nlb.sh         # 删除 NLB
├── config/                       # 配置文件
│   ├── configmap.yaml           # Operator 配置
│   ├── rbac.yaml                # 权限配置
│   └── deployment.yaml          # Operator 部署
├── test/                         # 测试用例
│   ├── test-single-pod.yaml     # 单Pod测试 (TCP)
│   ├── test-multi-pods.yaml     # 多Pod并发测试 (TCP)
│   ├── test-udp-pod.yaml        # UDP协议测试
│   └── test-dual-protocol-pod.yaml # TCP_UDP双协议测试
└── verify/                       # 验证脚本
    ├── check-pod-ports.sh       # 检查Pod端口分配
    ├── check-targets.sh         # 检查目标注册
    └── test-connectivity.sh     # 连通性测试
```

---

## 🚀 从零开始完整部署

### 第一步：检查前置条件

```bash
cd setup/
./pre-check.sh
```

检查项目：
- AWS CLI 安装和配置
- kubectl 安装
- eksctl 安装
- Docker 安装（可选）
- 默认 VPC 检查
- 现有 EKS 集群

### 第二步：创建 EKS 集群（如果没有）

```bash
# 设置集群名称和区域
export CLUSTER_NAME=nlb-operator-test
export AWS_REGION=us-west-2

# 创建集群（约15-20分钟）
./pre-00-create-eks.sh
```

集群配置：
- Kubernetes 版本：1.28
- 节点类型：t3.medium
- 节点数量：2
- 启用 OIDC（IRSA 必需）

### 第三步：配置 kubectl（如果已有集群）

```bash
# 自动选择集群并配置
./pre-01-configure-kubectl.sh

# 或手动配置
export CLUSTER_NAME=your-cluster-name
aws eks update-kubeconfig --name $CLUSTER_NAME --region us-west-2
```

### 第四步：创建 NLB

```bash
./00-create-nlb.sh

# 加载配置
source /tmp/nlb-config.env
```

### 第五步：配置 IRSA

```bash
./01-setup-irsa.sh
```

### 第六步：部署 Operator

```bash
./02-deploy-operator.sh
```

### 第七步：运行测试

```bash
cd ..
./quick-test.sh
```

---

## 🧪 完整多协议测试流程

### 测试前准备

```bash
# 确保 Operator 正在运行
kubectl get pods -n kube-system -l app=nlb-port-operator

# 设置 NLB ARN 环境变量
export NLB_ARN="arn:aws:elasticloadbalancing:us-west-2:YOUR_ACCOUNT:loadbalancer/net/YOUR_NLB/XXXXXXXX"

# 或从 ConfigMap 获取
export NLB_ARN=$(kubectl get configmap -n kube-system nlb-port-operator-config -o jsonpath='{.data.NLB_ARN}')

# 获取 NLB DNS
export NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --query 'LoadBalancers[0].DNSName' --output text)
```

### 测试1: TCP 协议

```bash
# 1. 部署 TCP 测试 Pod
kubectl apply -f test/test-multi-pods.yaml

# 2. 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/game-room-1 pod/game-room-2 pod/game-room-3 --timeout=60s

# 3. 查看分配的端口
kubectl get pods -o custom-columns=NAME:.metadata.name,PORT:.metadata.annotations.nlb\.port-manager/allocated-port

# 4. 验证 NLB 监听器
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[?Protocol==`TCP`].[Port,Protocol]' --output table

# 5. 检查 Target Group 健康状态
TG_ARN=$(kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
aws elbv2 describe-target-health --target-group-arn $TG_ARN

# 6. 测试连通性
PORT=$(kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
curl -s http://$NLB_DNS:$PORT
```

### 测试2: UDP 协议

```bash
# 1. 部署 UDP 测试 Pod
kubectl apply -f test/test-udp-pod.yaml

# 2. 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/udp-server-1 --timeout=60s

# 3. 查看分配的端口
kubectl get pod udp-server-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'

# 4. 验证 NLB 监听器为 UDP 协议
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[?Protocol==`UDP`].[Port,Protocol]' --output table

# 5. 查看完整资源信息
kubectl get pod udp-server-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/resources}' | jq
```

### 测试3: TCP_UDP 双协议

```bash
# 1. 部署双协议测试 Pod
kubectl apply -f test/test-dual-protocol-pod.yaml

# 2. 等待 Pod 就绪
kubectl wait --for=condition=Ready pod/dual-proto-server --timeout=60s

# 3. 查看分配的端口
kubectl get pod dual-proto-server -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'

# 4. 验证 NLB 监听器为 TCP_UDP 协议
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[?Protocol==`TCP_UDP`].[Port,Protocol]' --output table

# 5. 查看完整资源信息
kubectl get pod dual-proto-server -o jsonpath='{.metadata.annotations.nlb\.port-manager/resources}' | jq

# 6. 测试 TCP 连通性
PORT=$(kubectl get pod dual-proto-server -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
curl -s http://$NLB_DNS:$PORT
```

### 测试4: Pod 删除清理

```bash
# 1. 记录当前监听器数量
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'length(Listeners)'

# 2. 删除一个 Pod
kubectl delete pod game-room-1

# 3. 等待清理完成
sleep 5

# 4. 验证监听器已删除
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].[Port,Protocol]' --output table

# 5. 查看 Operator 日志确认清理
kubectl logs -n kube-system -l app=nlb-port-operator --tail=20
```

### 测试5: 查看所有资源状态

```bash
# 查看所有测试 Pod 及其端口
echo "=== Pod 端口分配 ==="
kubectl get pods -o custom-columns=NAME:.metadata.name,PORT:.metadata.annotations.nlb\.port-manager/allocated-port,STATUS:.status.phase

# 查看所有 NLB 监听器
echo "=== NLB 监听器 ==="
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].[Port,Protocol]' --output table

# 查看所有 Target Group
echo "=== Target Groups ==="
aws elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName, `tg-default`)].[TargetGroupName,Protocol,Port]' --output table
```

### 清理测试资源

```bash
# 删除所有测试 Pod
kubectl delete -f test/test-multi-pods.yaml
kubectl delete -f test/test-udp-pod.yaml
kubectl delete -f test/test-dual-protocol-pod.yaml

# 等待清理完成
sleep 10

# 验证 NLB 监听器已全部删除
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].[Port,Protocol]' --output table
```

### 预期结果

| 测试 | Pod | 协议 | 预期 NLB 端口 | 预期监听器协议 |
|------|-----|------|--------------|---------------|
| TCP | game-room-1/2/3 | TCP | 30000-30002 | TCP |
| UDP | udp-server-1 | UDP | 30003 | UDP |
| TCP_UDP | dual-proto-server | TCP_UDP | 30004 | TCP_UDP |

---

## 📋 快速命令参考

```bash
# 完整部署流程
cd setup/
./pre-check.sh              # 检查前置条件
./pre-00-create-eks.sh      # 创建 EKS（如需要）
./00-create-nlb.sh          # 创建 NLB
source /tmp/nlb-config.env  # 加载 NLB 配置
./01-setup-irsa.sh          # 配置 IRSA
./02-deploy-operator.sh     # 部署 Operator

# 运行测试
cd ..
./quick-test.sh

# 清理
cd setup/
./03-cleanup.sh             # 清理 Operator 和测试资源
./04-delete-nlb.sh          # 删除 NLB
./pre-99-delete-eks.sh      # 删除 EKS 集群（完全清理）
```

---

## 工作原理

```
Pod: game-room-1 (注解: auto-assign=true, port=8080/TCP)
  ↓
Operator监听Pod创建
  ↓
分配NLB端口: 30000/TCP
  ↓
创建Target Group: tg-default-game-room-1-tcp
  ↓
注册Pod IP: 10.0.1.5:8080
  ↓
创建Listener: 30000/TCP → Target Group
  ↓
更新Pod注解: allocated-port=30000, resources=[...]
```

## 测试场景

### 场景1: TCP Pod端口分配
```bash
kubectl apply -f test/test-multi-pods.yaml
kubectl get pods -o custom-columns=NAME:.metadata.name,PORT:.metadata.annotations.nlb\.port-manager/allocated-port
```

### 场景2: UDP Pod端口分配
```bash
kubectl apply -f test/test-udp-pod.yaml
kubectl get pod udp-server-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'
# 验证监听器协议
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].[Port,Protocol]' --output table
```

### 场景3: 双协议 (TCP_UDP) Pod
```bash
kubectl apply -f test/test-dual-protocol-pod.yaml
kubectl get pod dual-proto-server -o jsonpath='{.metadata.annotations.nlb\.port-manager/resources}' | jq
# 验证监听器为 TCP_UDP 协议
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[?Protocol==`TCP_UDP`].[Port,Protocol]' --output table
```

### 场景4: Pod生命周期
```bash
# 创建Pod
kubectl apply -f test/test-single-pod.yaml

# 查看分配的端口
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations}'

# 删除Pod（自动清理NLB资源）
kubectl delete pod game-room-1

# 验证端口已释放
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN
```

## 验证检查项

### ✓ Pod注解检查
```bash
kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations}' | jq
```
应包含：
- `nlb.port-manager/allocated-port` - 分配的NLB端口
- `nlb.port-manager/allocated-ports` - JSON数组（多端口模式）
- `nlb.port-manager/resources` - 完整资源信息（含协议）
- `nlb.port-manager/target-group-arn` - Target Group ARN
- `nlb.port-manager/listener-arn` - Listener ARN

### ✓ NLB监听器检查
```bash
# 查看所有监听器及协议
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN --query 'Listeners[*].[Port,Protocol]' --output table
```

### ✓ 连通性检查
```bash
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN --query 'LoadBalancers[0].DNSName' --output text)
PORT=$(kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')

# TCP 测试
curl http://$NLB_DNS:$PORT

# UDP 测试
echo "test" | nc -u $NLB_DNS $PORT
```

## 故障排查

### Operator日志
```bash
kubectl logs -n kube-system -l app=nlb-port-operator -f
```

### Pod未分配端口
1. 检查Pod是否有注解 `nlb.port-manager/auto-assign: "true"`
2. 检查Pod是否有 `nlb.port-manager/port` 注解（格式：`PORT/PROTOCOL`）
3. 检查Pod是否有IP地址
4. 检查端口池是否已满
5. 查看operator日志

### 监听器协议错误
1. 确认 `nlb.port-manager/port` 注解格式正确（如 `8080/UDP`、`7777/TCPUDP`）
2. 检查 Operator 镜像是否为最新版本
3. 查看 Operator 日志中的协议信息

### Target不健康
1. 检查Pod是否Running
2. 检查Pod端口是否与注解中的端口一致
3. 检查安全组规则（允许 TCP 和 UDP 端口范围 30000-32767）
4. UDP Target Group 使用 TCP 健康检查，确保容器端口可响应 TCP

### 资源未清理
1. 检查 Operator 日志中的 DELETE 事件
2. 确认 Pod 注解中包含 `nlb.port-manager/resources`
3. 手动清理残留资源：
```bash
# 查找残留监听器
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN

# 手动删除监听器
aws elbv2 delete-listener --listener-arn <LISTENER_ARN>

# 手动删除 Target Group
aws elbv2 delete-target-group --target-group-arn <TG_ARN>
```

## 配置说明

### ConfigMap (config/configmap.yaml)
```yaml
NLB_ARN: "arn:aws:..."      # NLB ARN
VPC_ID: "vpc-xxx"           # VPC ID
PORT_RANGE_MIN: "30000"     # 最小端口
PORT_RANGE_MAX: "32767"     # 最大端口
DEFAULT_PORT_SPEC: "80/TCP" # 默认端口规格
```

### Pod注解
```yaml
metadata:
  annotations:
    nlb.port-manager/auto-assign: "true"      # 必需：启用自动分配
    nlb.port-manager/port: "8080/TCP"         # 可选：端口/协议
```

### 端口规格格式
| 格式 | 说明 | 示例 |
|------|------|------|
| `PORT/TCP` | 单端口 TCP | `8080/TCP` |
| `PORT/UDP` | 单端口 UDP | `9999/UDP` |
| `PORT/TCPUDP` | 同端口双协议 | `7777/TCPUDP` |
| `PORT1/PROTO1,PORT2/PROTO2` | 多端口 | `80/TCP,9999/UDP` |

## 限制

- 端口范围：默认30000-32767（约2768个端口）
- 每个Pod占用1个或多个端口（取决于配置）
- 支持TCP、UDP、TCP_UDP协议
- UDP健康检查使用TCP（NLB限制）
- Pod必须先获得IP才能分配端口
- 需要VPC CNI（EKS默认）

## 安全组配置

确保 EKS 节点安全组允许以下入站规则：
```
协议: TCP
端口范围: 30000-32767
来源: 0.0.0.0/0（或限制为特定 CIDR）

协议: UDP
端口范围: 30000-32767
来源: 0.0.0.0/0（或限制为特定 CIDR）
```
