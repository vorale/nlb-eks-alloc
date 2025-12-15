I'll provide you with the complete corrected code that addresses all the critical issues I identified. Let me create the improved version with proper target registration and pod IP management.

# port_manager.py
import boto3
from typing import Set, Optional, List

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
            HealthCheckPort=str(port),
            HealthCheckIntervalSeconds=30,
            HealthyThresholdCount=3,
            UnhealthyThresholdCount=3
        )
        return response['TargetGroups'][0]['TargetGroupArn']
    
    def register_targets(self, target_group_arn: str, pod_ips: List[str], port: int):
        """注册Pod IP到目标组"""
        if not pod_ips:
            return
        
        targets = [{'Id': ip, 'Port': port} for ip in pod_ips]
        try:
            self.elbv2.register_targets(
                TargetGroupArn=target_group_arn,
                Targets=targets
            )
        except Exception as e:
            print(f"Error registering targets: {e}")
            raise
    
    def deregister_targets(self, target_group_arn: str, pod_ips: List[str], port: int):
        """从目标组注销Pod IP"""
        if not pod_ips:
            return
        
        targets = [{'Id': ip, 'Port': port} for ip in pod_ips]
        try:
            self.elbv2.deregister_targets(
                TargetGroupArn=target_group_arn,
                Targets=targets
            )
        except Exception as e:
            print(f"Error deregistering targets: {e}")
    
    def get_target_health(self, target_group_arn: str) -> List[dict]:
        """获取目标组健康状态"""
        try:
            response = self.elbv2.describe_target_health(
                TargetGroupArn=target_group_arn
            )
            return response['TargetHealthDescriptions']
        except Exception as e:
            print(f"Error getting target health: {e}")
            return []
    
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
    
    def delete_listener(self, listener_arn: str):
        """删除监听器"""
        try:
            self.elbv2.delete_listener(ListenerArn=listener_arn)
        except Exception as e:
            print(f"Error deleting listener: {e}")
    
    def delete_target_group(self, target_group_arn: str):
        """删除目标组"""
        try:
            self.elbv2.delete_target_group(TargetGroupArn=target_group_arn)
        except Exception as e:
            print(f"Error deleting target group: {e}")


# operator.py
import kopf
import os
import time
from kubernetes import client, config
from port_manager import PortManager

# 配置
NLB_ARN = os.getenv('NLB_ARN')
VPC_ID = os.getenv('VPC_ID')
PORT_RANGE_MIN = int(os.getenv('PORT_RANGE_MIN', '30000'))
PORT_RANGE_MAX = int(os.getenv('PORT_RANGE_MAX', '32767'))

# 初始化
config.load_incluster_config()
k8s_core_api = client.CoreV1Api()
port_manager = PortManager(NLB_ARN, VPC_ID, (PORT_RANGE_MIN, PORT_RANGE_MAX))

def get_pod_ips_for_service(service_name: str, namespace: str) -> list:
    """获取Service对应的所有Pod IP"""
    try:
        service = k8s_core_api.read_namespaced_service(service_name, namespace)
        selector = service.spec.selector
        
        if not selector:
            return []
        
        # 构建标签选择器
        label_selector = ','.join([f"{k}={v}" for k, v in selector.items()])
        
        # 获取匹配的Pods
        pods = k8s_core_api.list_namespaced_pod(
            namespace=namespace,
            label_selector=label_selector
        )
        
        # 提取运行中的Pod IP
        pod_ips = []
        for pod in pods.items:
            if pod.status.phase == 'Running' and pod.status.pod_ip:
                pod_ips.append(pod.status.pod_ip)
        
        return pod_ips
    except Exception as e:
        print(f"Error getting pod IPs: {e}")
        return []

@kopf.on.create('v1', 'services')
def create_service(spec, meta, namespace, **kwargs):
    """处理Service创建"""
    annotations = meta.get('annotations', {})
    
    # 检查是否需要自动分配端口
    if annotations.get('nlb.port-manager/auto-assign') != 'true':
        return
    
    service_name = meta['name']
    
    try:
        # 分配端口
        nlb_port = port_manager.allocate_port()
        if not nlb_port:
            raise kopf.PermanentError("No available ports in the pool")
        
        # 获取目标端口
        target_port = spec['ports'][0]['targetPort']
        if isinstance(target_port, str):
            # 如果是命名端口，需要解析
            target_port = spec['ports'][0]['port']
        
        # 创建目标组
        tg_arn = port_manager.create_target_group(service_name, target_port)
        print(f"Created target group: {tg_arn}")
        
        # 等待目标组创建完成
        time.sleep(2)
        
        # 获取Pod IPs并注册到目标组
        pod_ips = get_pod_ips_for_service(service_name, namespace)
        if pod_ips:
            port_manager.register_targets(tg_arn, pod_ips, target_port)
            print(f"Registered {len(pod_ips)} pod IPs to target group")
        else:
            print(f"Warning: No pod IPs found for service {service_name}")
        
        # 创建监听器
        listener_arn = port_manager.create_listener(nlb_port, tg_arn)
        print(f"Created listener on port {nlb_port}")
        
        # 更新Service注解
        service = k8s_core_api.read_namespaced_service(service_name, namespace)
        if not service.metadata.annotations:
            service.metadata.annotations = {}
        
        service.metadata.annotations['nlb.port-manager/allocated-port'] = str(nlb_port)
        service.metadata.annotations['nlb.port-manager/target-port'] = str(target_port)
        service.metadata.annotations['nlb.port-manager/target-group-arn'] = tg_arn
        service.metadata.annotations['nlb.port-manager/listener-arn'] = listener_arn
        
        k8s_core_api.patch_namespaced_service(service_name, namespace, service)
        
        return {'nlb_port': nlb_port, 'target_group': tg_arn, 'pod_count': len(pod_ips)}
        
    except Exception as e:
        print(f"Error creating service resources: {e}")
        raise kopf.TemporaryError(f"Failed to create NLB resources: {e}", delay=30)

@kopf.on.delete('v1', 'services')
def delete_service(meta, **kwargs):
    """处理Service删除"""
    annotations = meta.get('annotations', {})
    
    if annotations.get('nlb.port-manager/auto-assign') != 'true':
        return
    
    try:
        # 删除监听器
        listener_arn = annotations.get('nlb.port-manager/listener-arn')
        if listener_arn:
            port_manager.delete_listener(listener_arn)
            print(f"Deleted listener: {listener_arn}")
        
        # 等待监听器删除完成
        time.sleep(2)
        
        # 删除目标组
        tg_arn = annotations.get('nlb.port-manager/target-group-arn')
        if tg_arn:
            port_manager.delete_target_group(tg_arn)
            print(f"Deleted target group: {tg_arn}")
            
    except Exception as e:
        print(f"Error deleting service resources: {e}")

@kopf.on.event('v1', 'pods')
def pod_event(event, spec, meta, namespace, **kwargs):
    """处理Pod变化事件，更新目标组"""
    event_type = event['type']
    pod_name = meta['name']
    pod_ip = spec.get('podIP') if spec else None
    labels = meta.get('labels', {})
    
    # 只处理Running状态的Pod
    if event_type not in ['ADDED', 'MODIFIED', 'DELETED']:
        return
    
    try:
        # 查找匹配的Service
        services = k8s_core_api.list_namespaced_service(namespace=namespace)
        
        for service in services.items:
            annotations = service.metadata.annotations or {}
            
            # 只处理由operator管理的Service
            if annotations.get('nlb.port-manager/auto-assign') != 'true':
                continue
            
            # 检查Pod是否匹配Service的selector
            selector = service.spec.selector or {}
            if not all(labels.get(k) == v for k, v in selector.items()):
                continue
            
            # 获取目标组信息
            tg_arn = annotations.get('nlb.port-manager/target-group-arn')
            target_port = int(annotations.get('nlb.port-manager/target-port', 0))
            
            if not tg_arn or not target_port:
                continue
            
            # 根据事件类型处理
            if event_type == 'DELETED':
                if pod_ip:
                    port_manager.deregister_targets(tg_arn, [pod_ip], target_port)
                    print(f"Deregistered pod {pod_name} ({pod_ip}) from {service.metadata.name}")
            
            elif event_type in ['ADDED', 'MODIFIED']:
                pod_status = kwargs.get('status', {})
                phase = pod_status.get('phase')
                
                if phase == 'Running' and pod_ip:
                    # 检查是否已注册
                    health = port_manager.get_target_health(tg_arn)
                    registered_ips = {t['Target']['Id'] for t in health}
                    
                    if pod_ip not in registered_ips:
                        port_manager.register_targets(tg_arn, [pod_ip], target_port)
                        print(f"Registered pod {pod_name} ({pod_ip}) to {service.metadata.name}")
                
                elif phase in ['Failed', 'Succeeded'] and pod_ip:
                    port_manager.deregister_targets(tg_arn, [pod_ip], target_port)
                    print(f"Deregistered terminated pod {pod_name} ({pod_ip})")
    
    except Exception as e:
        print(f"Error handling pod event: {e}")

@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    """配置Operator"""
    settings.posting.level = 'INFO'
    settings.watching.connect_timeout = 1 * 60
    settings.watching.server_timeout = 10 * 60


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
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes"
      ],
      "Resource": "*"
    }
  ]
}


apiVersion: v1
kind: ServiceAccount
metadata:
  name: nlb-port-operator
  namespace: kube-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/nlb-port-operator-role
---
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
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5


#!/bin/bash

# IRSA Setup Script for NLB Port Operator

CLUSTER_NAME="your-eks-cluster"
REGION="us-west-2"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ROLE_NAME="nlb-port-operator-role"
NAMESPACE="kube-system"
SERVICE_ACCOUNT="nlb-port-operator"

# Create IAM OIDC provider for EKS cluster
eksctl utils associate-iam-oidc-provider \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --approve

# Create IAM policy
cat > nlb-operator-policy.json <<EOF
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
        "elasticloadbalancing:DescribeTargetGroups",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:DescribeTargetHealth",
        "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes"
      ],
      "Resource": "*"
    }
  ]
}
EOF

POLICY_ARN=$(aws iam create-policy \
  --policy-name NLBPortOperatorPolicy \
  --policy-document file://nlb-operator-policy.json \
  --query 'Policy.Arn' \
  --output text)

echo "Created policy: $POLICY_ARN"

# Create IAM role with trust relationship
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=$NAMESPACE \
  --name=$SERVICE_ACCOUNT \
  --role-name=$ROLE_NAME \
  --attach-policy-arn=$POLICY_ARN \
  --region=$REGION \
  --approve \
  --override-existing-serviceaccounts

echo "IRSA setup complete!"
echo "Role ARN: arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME"

Key Improvements Made
1. Target Registration: Added complete pod IP registration and deregistration logic
2. Pod Event Handling: Operator now watches pod events and automatically updates target groups
3. Health Checks: Added target health monitoring to avoid duplicate registrations
4. Error Handling: Improved error handling with retries and better logging
5. IRSA Support: Added proper IAM role annotations for EKS
6. Resource Limits: Added resource requests/limits for production use
Setup Instructions
Create the IAM role using the IRSA setup script
Update the ConfigMap with your NLB ARN and VPC ID
Build and push the Docker image
Deploy using the updated YAML files
Verify the operator is running and watching events
Testing
# Deploy a test service
kubectl apply -f test-game-service.yaml

# Check allocated port
kubectl get svc game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'

# Verify targets are registered
aws elbv2 describe-target-health --target-group-arn <TG_ARN>

# Scale the deployment
kubectl scale deployment game-room-1 --replicas=5

# Verify new pods are automatically registered
Would you like me to explain any specific part in more detail, or help you with the deployment process?