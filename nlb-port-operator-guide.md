# NLB端口自动分配Operator完整方案

## 概述

实现类似Tencent CLB端口池的AWS EKS解决方案，通过Kubernetes Operator自动管理NLB端口分配。

## 1. 项目结构

```bash
nlb-port-operator/
├── operator.py          # 主程序
├── port_manager.py      # 端口管理逻辑
├── Dockerfile
├── requirements.txt
├── deploy/
│   ├── rbac.yaml
│   ├── deployment.yaml
│   └── configmap.yaml
└── README.md
```

## 2. 核心代码

### requirements.txt

```txt
kopf==1.37.2
kubernetes==28.1.0
boto3==1.34.0
```

### port_manager.py

```python
import boto3
from typing import Set, Optional

class PortManager:
    def __init__(self, nlb_arn: str, vpc_id: str, port_range=(30000, 32767)):
        self.nlb_arn = nlb_arn
        self.vpc_id = vpc_id
        self.elbv2 = boto3.client('elbv2')
        self.min_port, self.max_port = port_range
        
    def get_used_ports(self) -> Set[int]:
        """获取NLB已使用端口"""
        listeners = self.elbv2.describe_listeners(LoadBalancerArn=self.nlb_arn)
        return {l['Port'] for l in listeners['Listeners']}
    
    def allocate_port(self) -> Optional[int]:
        """分配可用端口"""
        used = self.get_used_ports()
        for port in range(self.min_port, self.max_port + 1):
            if port not in used:
                return port
        return None
    
    def create_target_group(self, name: str, port: int) -> str:
        """创建目标组"""
        response = self.elbv2.create_target_group(
            Name=f"tg-{name}"[:32],
            Protocol='TCP',
            Port=port,
            VpcId=self.vpc_id,
            TargetType='ip',
            HealthCheckProtocol='TCP',
            HealthCheckPort=str(port)
        )
        return response['TargetGroups'][0]['TargetGroupArn']
    
    def create_listener(self, port: int, target_group_arn: str) -> str:
        """创建监听器"""
        response = self.elbv2.create_listener(
            LoadBalancerArn=self.nlb_arn,
            Protocol='TCP',
            Port=port,
            DefaultActions=[{
                'Type': 'forward',
                'TargetGroupArn': target_group_arn
            }]
        )
        return response['Listeners'][0]['ListenerArn']
    
    def delete_listener(self, port: int):
        """删除监听器"""
        listeners = self.elbv2.describe_listeners(LoadBalancerArn=self.nlb_arn)
        for listener in listeners['Listeners']:
            if listener['Port'] == port:
                self.elbv2.delete_listener(ListenerArn=listener['ListenerArn'])
                break
    
    def delete_target_group(self, name: str):
        """删除目标组"""
        try:
            tgs = self.elbv2.describe_target_groups(Names=[f"tg-{name}"[:32]])
            for tg in tgs['TargetGroups']:
                self.elbv2.delete_target_group(TargetGroupArn=tg['TargetGroupArn'])
        except:
            pass
```

### operator.py

```python
import kopf
import os
from kubernetes import client, config
from port_manager import PortManager

# 配置
NLB_ARN = os.getenv('NLB_ARN')
VPC_ID = os.getenv('VPC_ID')
PORT_RANGE_MIN = int(os.getenv('PORT_RANGE_MIN', '30000'))
PORT_RANGE_MAX = int(os.getenv('PORT_RANGE_MAX', '32767'))

# 初始化
config.load_incluster_config()
k8s_api = client.CoreV1Api()
port_manager = PortManager(NLB_ARN, VPC_ID, (PORT_RANGE_MIN, PORT_RANGE_MAX))

@kopf.on.create('v1', 'services')
def create_service(spec, meta, namespace, **kwargs):
    """处理Service创建"""
    annotations = meta.get('annotations', {})
    
    # 检查是否需要自动分配端口
    if annotations.get('nlb.port-manager/auto-assign') != 'true':
        return
    
    service_name = meta['name']
    
    # 分配端口
    port = port_manager.allocate_port()
    if not port:
        raise kopf.PermanentError("No available ports")
    
    # 获取目标端口
    target_port = spec['ports'][0]['targetPort']
    
    # 创建目标组
    tg_arn = port_manager.create_target_group(service_name, target_port)
    
    # 创建监听器
    listener_arn = port_manager.create_listener(port, tg_arn)
    
    # 更新Service注解
    service = k8s_api.read_namespaced_service(service_name, namespace)
    if not service.metadata.annotations:
        service.metadata.annotations = {}
    
    service.metadata.annotations['nlb.port-manager/allocated-port'] = str(port)
    service.metadata.annotations['nlb.port-manager/target-group-arn'] = tg_arn
    service.metadata.annotations['nlb.port-manager/listener-arn'] = listener_arn
    
    k8s_api.patch_namespaced_service(service_name, namespace, service)
    
    return {'port': port, 'target_group': tg_arn}

@kopf.on.delete('v1', 'services')
def delete_service(meta, **kwargs):
    """处理Service删除"""
    annotations = meta.get('annotations', {})
    
    if annotations.get('nlb.port-manager/auto-assign') != 'true':
        return
    
    # 删除监听器
    port = int(annotations.get('nlb.port-manager/allocated-port', 0))
    if port:
        port_manager.delete_listener(port)
    
    # 删除目标组
    port_manager.delete_target_group(meta['name'])
```

### Dockerfile

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY operator.py port_manager.py ./

CMD ["kopf", "run", "--standalone", "operator.py"]
```

## 3. Kubernetes部署文件

### deploy/rbac.yaml

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nlb-port-operator
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nlb-port-operator
rules:
- apiGroups: [""]
  resources: ["services"]
  verbs: ["get", "list", "watch", "patch", "update"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nlb-port-operator
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nlb-port-operator
subjects:
- kind: ServiceAccount
  name: nlb-port-operator
  namespace: kube-system
```

### deploy/configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nlb-port-operator-config
  namespace: kube-system
data:
  NLB_ARN: "arn:aws:elasticloadbalancing:us-west-2:123456789012:loadbalancer/net/my-nlb/xxxxx"
  VPC_ID: "vpc-xxxxxx"
  PORT_RANGE_MIN: "30000"
  PORT_RANGE_MAX: "32767"
```

### deploy/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nlb-port-operator
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nlb-port-operator
  template:
    metadata:
      labels:
        app: nlb-port-operator
    spec:
      serviceAccountName: nlb-port-operator
      containers:
      - name: operator
        image: your-registry/nlb-port-operator:latest
        envFrom:
        - configMapRef:
            name: nlb-port-operator-config
        env:
        - name: AWS_REGION
          value: us-west-2
```

## 4. 安装步骤

### 步骤1: 构建镜像

```bash
cd nlb-port-operator

# 构建镜像
docker build -t your-registry/nlb-port-operator:latest .

# 推送到ECR
aws ecr get-login-password --region us-west-2 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-west-2.amazonaws.com
docker tag nlb-port-operator:latest 123456789012.dkr.ecr.us-west-2.amazonaws.com/nlb-port-operator:latest
docker push 123456789012.dkr.ecr.us-west-2.amazonaws.com/nlb-port-operator:latest
```

### 步骤2: 配置参数

```bash
# 编辑deploy/configmap.yaml，填入实际值
# - NLB_ARN: 你的NLB ARN
# - VPC_ID: 你的VPC ID
```

### 步骤3: 部署Operator

```bash
# 部署RBAC
kubectl apply -f deploy/rbac.yaml

# 部署ConfigMap
kubectl apply -f deploy/configmap.yaml

# 部署Operator
kubectl apply -f deploy/deployment.yaml

# 检查状态
kubectl get pods -n kube-system -l app=nlb-port-operator
kubectl logs -n kube-system -l app=nlb-port-operator -f
```

## 5. 使用示例

### 创建游戏服务

```yaml
apiVersion: v1
kind: Service
metadata:
  name: game-room-1
  annotations:
    nlb.port-manager/auto-assign: "true"
spec:
  selector:
    app: game-room-1
  ports:
  - protocol: TCP
    port: 80
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: game-room-1
spec:
  replicas: 2
  selector:
    matchLabels:
      app: game-room-1
  template:
    metadata:
      labels:
        app: game-room-1
    spec:
      containers:
      - name: game-server
        image: your-game-server:latest
        ports:
        - containerPort: 8080
```

### 查看分配的端口

```bash
kubectl get svc game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'
```

## 6. IAM权限

### Operator需要的IAM权限

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:CreateListener",
        "elasticloadbalancing:DeleteListener",
        "elasticloadbalancing:DescribeListeners",
        "elasticloadbalancing:CreateTargetGroup",
        "elasticloadbalancing:DeleteTargetGroup",
        "elasticloadbalancing:DescribeTargetGroups"
      ],
      "Resource": "*"
    }
  ]
}
```

使用IRSA (IAM Roles for Service Accounts)绑定权限到ServiceAccount。

## 7. 工作流程

1. **游戏房间启动** → 创建带有 `nlb.port-manager/auto-assign: "true"` 注解的Service
2. **Operator监听** → 检测到新Service创建事件
3. **端口分配** → 从端口池(30000-32767)中分配可用端口
4. **创建目标组** → 在NLB中创建指向Pod IP的目标组
5. **创建监听器** → 在NLB上创建监听指定端口的监听器
6. **更新注解** → 将分配的端口写入Service注解
7. **客户端连接** → 游戏客户端通过 `NLB_IP:分配的端口` 连接

## 8. 优势

- **成本优化**: 单个NLB处理多个游戏服务
- **自动化**: 无需手动管理端口分配
- **无冲突**: 系统保证端口唯一性
- **可扩展**: 支持大量游戏房间
- **高性能**: IP模式直连Pod，低延迟

## 9. 注意事项

- NLB监听器数量限制: 默认50个，可申请提升到500
- 端口范围可根据需求调整
- 建议配置监控告警端口池使用率
- 生产环境建议添加错误重试和日志记录
