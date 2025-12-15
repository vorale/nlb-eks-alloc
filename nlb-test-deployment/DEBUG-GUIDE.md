# NLB Port Operator 调试指南

## 1. 检查 Operator 状态

### 查看 Pod 状态
```bash
kubectl get pods -n kube-system -l app=nlb-port-operator
```
期望状态：`Running` 且 `READY: 1/1`

### 查看 Operator 日志
```bash
kubectl logs -n kube-system -l app=nlb-port-operator --tail=50
```

### 实时跟踪日志
```bash
kubectl logs -n kube-system -l app=nlb-port-operator -f
```

### 查看包含 game-room 的日志
```bash
kubectl logs -n kube-system -l app=nlb-port-operator | grep -E "(game-room|Error|error|failed)"
```

---

## 2. 常见问题及解决方案

| 状态/错误 | 原因 | 解决方案 |
|-----------|------|----------|
| `ImagePullBackOff` | 镜像不存在或无权限拉取 | 检查 ECR 镜像是否推送成功 |
| `CrashLoopBackOff` | 代码错误导致崩溃 | 查看日志找出错误原因 |
| `exec format error` | 镜像架构不匹配 (ARM vs AMD64) | 使用 `--platform linux/amd64` 重新构建 |
| `APIForbiddenError - pods/status` | RBAC 缺少 pods/status 权限 | 添加 pods/status 权限到 ClusterRole |
| `APIForbiddenError - CRD` | RBAC 缺少 CRD 权限 | 添加 customresourcedefinitions 权限 |
| `TypeError: '>=' not supported` | `settings.posting.level` 使用字符串 | 改为 `logging.INFO` (整数) |
| `DuplicateListener` | 端口冲突 | 删除旧的 Listener 或使用不同端口 |

---

## 3. 检查镜像配置

### 查看当前使用的镜像
```bash
kubectl get deployment nlb-port-operator -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'
```

### 查看配置文件中的镜像
```bash
cat config/deployment.yaml | grep image
```

### 重新构建正确架构的镜像
```bash
# Mac M1/M2 需要指定平台为 linux/amd64
docker build --platform linux/amd64 -t nlb-port-operator:latest .
```

---

## 4. 重新部署 Operator

### 方法1：滚动重启
```bash
kubectl rollout restart deployment/nlb-port-operator -n kube-system
```

### 方法2：删除并重建
```bash
kubectl delete deployment nlb-port-operator -n kube-system
kubectl apply -f config/deployment.yaml
```

### 强制删除卡住的 Pod
```bash
kubectl delete pods -n kube-system -l app=nlb-port-operator \
  --force --grace-period=0
```

---

## 5. 检查测试 Pod 端口分配

### 查看 Pod 分配的端口
```bash
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations}' | jq
```

### 查看所有管理的 Pod 端口
```bash
kubectl get pods -o custom-columns=\
NAME:.metadata.name,\
PORT:.metadata.annotations.'nlb\.port-manager/allocated-port',\
TG:.metadata.annotations.'nlb\.port-manager/target-group-arn' | grep game-room
```

---

## 6. 检查 AWS 资源

### 查看 NLB Listeners
```bash
aws elbv2 describe-listeners --load-balancer-arn $NLB_ARN
```

### 查看 Target Group 健康状态
```bash
TG_ARN=$(kubectl get pod game-room-1 \
  -o jsonpath='{.metadata.annotations.nlb\.port-manager/target-group-arn}')
aws elbv2 describe-target-health --target-group-arn $TG_ARN
```

### 测试连通性
```bash
NLB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns $NLB_ARN \
  --query 'LoadBalancers[0].DNSName' --output text)
PORT=$(kubectl get pod game-room-1 \
  -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}')
curl http://$NLB_DNS:$PORT
```

---

## 7. 检查 RBAC 权限

### 查看 ClusterRole 权限
```bash
kubectl describe clusterrole nlb-port-operator
```

### 测试 ServiceAccount 权限
```bash
# 测试是否可以 list pods
kubectl auth can-i list pods \
  --as=system:serviceaccount:kube-system:nlb-port-operator

# 测试是否可以 patch pods/status
kubectl auth can-i patch pods/status \
  --as=system:serviceaccount:kube-system:nlb-port-operator
```

### 必需的 RBAC 权限
```yaml
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["pods/status"]  # kopf 必需
  verbs: ["get", "patch", "update"]
- apiGroups: ["apiextensions.k8s.io"]
  resources: ["customresourcedefinitions"]  # kopf 必需
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["configmaps"]  # kopf 状态存储
  verbs: ["get", "list", "watch", "create", "update", "patch"]
```

---

## 8. 检查 ConfigMap 配置

### 查看当前配置
```bash
kubectl get configmap nlb-port-operator-config -n kube-system -o yaml
```

### 验证环境变量
```bash
kubectl exec -n kube-system -l app=nlb-port-operator -- env | grep -E "(NLB|VPC|PORT)"
```

---

## 9. 完整重建流程

```bash
# 1. 构建并推送镜像（指定 linux/amd64）
./setup/build-and-push-image.sh

# 2. 重新应用所有配置
kubectl apply -f config/rbac.yaml
kubectl apply -f config/configmap.yaml

# 3. 删除旧部署并重建
kubectl delete deployment nlb-port-operator -n kube-system
kubectl apply -f config/deployment.yaml

# 4. 等待并检查
sleep 30
kubectl get pods -n kube-system -l app=nlb-port-operator
kubectl logs -n kube-system -l app=nlb-port-operator --tail=30
```

---

## 10. 今日修复的问题记录

| 问题 | 原因 | 修复 |
|------|------|------|
| EKS 创建失败 | 版本 1.28 不再支持 | 改为 1.30 |
| VPC 限制 | 无法创建新 VPC | 使用默认 VPC |
| NLB 创建失败 | 名称超过 32 字符 | 缩短名称 |
| Pod 启动失败 | 镜像架构不匹配 | 使用 `--platform linux/amd64` |
| Pod 崩溃 | `settings.posting.level` 类型错误 | 使用 `logging.INFO` |
| 端口不分配 | 缺少 pods/status 权限 | 添加 RBAC 权限 |
