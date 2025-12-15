# 快速配置指南

## 需要替换的配置项

### 1. k8s/configmap.yaml
```yaml
NLB_ARN: "arn:aws:elasticloadbalancing:..."  # 你的NLB ARN
VPC_ID: "vpc-xxxxx"                          # 你的VPC ID
PORT_RANGE_MIN: "30000"                      # 端口范围最小值
PORT_RANGE_MAX: "32767"                      # 端口范围最大值
DEFAULT_PORT_SPEC: "80/TCP"                  # 默认端口规格（端口/协议）
```

### 2. k8s/rbac.yaml
```yaml
eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/nlb-port-operator-role
```
替换 `ACCOUNT_ID` 为你的AWS账号ID

### 3. k8s/deployment.yaml
```yaml
image: your-registry/nlb-port-operator:latest
```
替换为你的ECR或Docker镜像仓库地址

## 方法一：使用自动配置脚本（推荐）

```bash
# 运行配置脚本
./configure.sh
```

脚本会自动：
- 获取AWS账号ID
- 列出可用的NLB
- 从NLB获取VPC ID
- 交互式输入配置
- 自动替换所有YAML文件
- 创建备份文件（.bak）

## 方法二：手动替换

### 步骤1：获取AWS信息

```bash
# 获取账号ID
aws sts get-caller-identity --query Account --output text

# 列出NLB
aws elbv2 describe-load-balancers --query 'LoadBalancers[?Type==`network`].[LoadBalancerName,LoadBalancerArn]' --output table

# 获取VPC ID（从NLB）
aws elbv2 describe-load-balancers --load-balancer-arns <NLB_ARN> --query 'LoadBalancers[0].VpcId' --output text
```

### 步骤2：编辑配置文件

```bash
# 编辑ConfigMap
vi k8s/configmap.yaml

# 编辑RBAC
vi k8s/rbac.yaml

# 编辑Deployment
vi k8s/deployment.yaml
```

### 步骤3：验证配置

```bash
# 检查是否还有占位符
grep -r "ACCOUNT_ID\|YOUR-NLB\|vpc-xxx\|your-registry" k8s/
```

## 完整部署流程

### 1. 配置文件
```bash
./configure.sh
```

### 2. 创建IAM角色（IRSA）
```bash
export CLUSTER_NAME=your-cluster
export AWS_REGION=us-west-2
./setup-irsa.sh
```

### 3. 构建并推送镜像
```bash
# 登录ECR
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com

# 创建ECR仓库（如果不存在）
aws ecr create-repository --repository-name nlb-port-operator --region us-west-2

# 构建镜像
docker build -t <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nlb-port-operator:latest .

# 推送镜像
docker push <ACCOUNT_ID>.dkr.ecr.us-west-2.amazonaws.com/nlb-port-operator:latest
```

### 4. 部署Operator
```bash
kubectl apply -f k8s/rbac.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/deployment.yaml
```

### 5. 验证部署
```bash
# 检查Pod状态
kubectl get pods -n kube-system -l app=nlb-port-operator

# 查看日志
kubectl logs -n kube-system -l app=nlb-port-operator -f
```

### 6. 测试
```bash
# 部署测试Pod
kubectl apply -f k8s/test-pod.yaml

# 查看分配的端口
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'
```

## 恢复原始配置

如果使用了configure.sh脚本，可以恢复备份：

```bash
cp k8s/configmap.yaml.bak k8s/configmap.yaml
cp k8s/rbac.yaml.bak k8s/rbac.yaml
cp k8s/deployment.yaml.bak k8s/deployment.yaml
```

## 常见问题

### Q: 如何获取NLB ARN？
```bash
aws elbv2 describe-load-balancers --query 'LoadBalancers[?Type==`network`]' --output table
```

### Q: 如何创建NLB？
```bash
# 通过AWS Console或CLI创建
aws elbv2 create-load-balancer \
  --name my-nlb \
  --type network \
  --subnets subnet-xxx subnet-yyy \
  --scheme internet-facing
```

### Q: Docker镜像应该推送到哪里？
推荐使用ECR：
- 格式：`<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com/nlb-port-operator:latest`
- 也可以使用Docker Hub或其他镜像仓库

### Q: 端口范围如何选择？
- 默认：30000-32767（Kubernetes NodePort范围）
- 可用端口数 = MAX - MIN + 1
- 每个Pod占用1个或多个端口（取决于协议配置）
- 确保不与现有NLB监听器冲突

### Q: 支持哪些协议？
- TCP: 标准TCP协议
- UDP: UDP协议（健康检查使用TCP）
- TCP_UDP/TCPUDP: 同端口同时支持TCP和UDP

### Q: 如何配置多协议Pod？
```yaml
annotations:
  nlb.port-manager/auto-assign: "true"
  nlb.port-manager/port: "8080/TCP"           # 单端口TCP
  # nlb.port-manager/port: "9999/UDP"         # 单端口UDP
  # nlb.port-manager/port: "7777/TCPUDP"      # 双协议
  # nlb.port-manager/port: "80/TCP,9999/UDP"  # 多端口
```
