# NLB Port Operator for EKS (Pod Mode)

A Kubernetes operator that automatically allocates dedicated AWS Network Load Balancer (NLB) ports for individual Pods, creating a 1:1 mapping between Pod names and NLB ports.

## Overview

This operator watches Kubernetes Pods and automatically:
- Allocates a unique NLB port for each Pod from a configurable range
- Creates dedicated NLB listener and target group per Pod
- Registers the Pod IP as the sole target (using IP target type)
- Handles Pod lifecycle events (creation, IP changes, deletion)
- Cleans up NLB resources when Pods are deleted

## Features

- **Per-Pod Port Allocation**: Each Pod gets its own dedicated NLB port
- **Multi-Protocol Support**: TCP, UDP, and TCP_UDP (dual protocol)
- **Flexible Port Configuration**: Specify container port and protocol via annotations
- **Multi-Port Support**: Multiple ports per Pod with different protocols
- **1:1 Pod-to-Port Mapping**: Direct mapping from Pod name to NLB port
- **Automatic IP Management**: Registers and updates Pod IPs automatically
- **Health Monitoring**: Uses NLB health checks to ensure traffic only goes to healthy Pods
- **IRSA Support**: Uses IAM Roles for Service Accounts for secure AWS API access

## Architecture

```
Pod: game-room-1 (80/TCP)   →  NLB Port 30000/TCP  →  Target Group  →  Pod IP:80
Pod: game-room-2 (80/TCP)   →  NLB Port 30001/TCP  →  Target Group  →  Pod IP:80
Pod: udp-server (9999/UDP)  →  NLB Port 30002/UDP  →  Target Group  →  Pod IP:9999
```

## Usage

### Basic TCP Pod

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: game-room-1
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "8080/TCP"  # Container port / Protocol
spec:
  containers:
  - name: game-server
    image: your-game-server:latest
    ports:
    - containerPort: 8080
```

### UDP Pod

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


### Dual Protocol (TCP + UDP on same port)

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: game-server
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "7777/TCPUDP"  # or "7777/TCP_UDP"
spec:
  containers:
  - name: game-server
    image: your-game-server:latest
    ports:
    - containerPort: 7777
      protocol: TCP
    - containerPort: 7777
      protocol: UDP
```

### Multiple Ports

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
      protocol: TCP
    - containerPort: 9999
      protocol: UDP
```

## Port Specification Format

| Format | Description | Example |
|--------|-------------|---------|
| `PORT/TCP` | Single TCP port | `8080/TCP` |
| `PORT/UDP` | Single UDP port | `9999/UDP` |
| `PORT/TCPUDP` | Same port, both protocols | `7777/TCPUDP` |
| `PORT/TCP_UDP` | Same port, both protocols | `7777/TCP_UDP` |
| `PORT1/PROTO1,PORT2/PROTO2` | Multiple ports | `80/TCP,9999/UDP` |

## Annotations

### Input Annotations (User-defined)

| Annotation | Required | Description |
|------------|----------|-------------|
| `nlb.port-manager/auto-assign` | Yes | Set to `"true"` to enable |
| `nlb.port-manager/port` | No | Port spec (default: `80/TCP`) |

### Output Annotations (Added by Operator)

| Annotation | Description |
|------------|-------------|
| `nlb.port-manager/allocated-port` | Allocated NLB port (single port mode) |
| `nlb.port-manager/allocated-ports` | JSON array of allocated ports |
| `nlb.port-manager/resources` | JSON array of all NLB resources |
| `nlb.port-manager/target-group-arn` | Target Group ARN (single port mode) |
| `nlb.port-manager/listener-arn` | Listener ARN (single port mode) |

## Installation

### 1. Setup IRSA

```bash
export CLUSTER_NAME=your-eks-cluster
export AWS_REGION=us-west-2
./setup-irsa.sh
```

### 2. Configure

Edit `k8s/configmap.yaml`:

```yaml
data:
  NLB_ARN: "arn:aws:elasticloadbalancing:..."
  VPC_ID: "vpc-..."
  PORT_RANGE_MIN: "30000"
  PORT_RANGE_MAX: "32767"
  DEFAULT_PORT_SPEC: "80/TCP"  # Default if not specified in annotation
```

### 3. Build and Deploy

```bash
docker build -t your-registry/nlb-port-operator:latest .
docker push your-registry/nlb-port-operator:latest

kubectl apply -f k8s/
```

## Check Allocated Resources

```bash
# Single port mode
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-port}'

# Multi-port mode
kubectl get pod multi-service -o jsonpath='{.metadata.annotations.nlb\.port-manager/allocated-ports}' | jq

# All resources
kubectl get pod game-room-1 -o jsonpath='{.metadata.annotations.nlb\.port-manager/resources}' | jq
```

## Limitations

- Port range limits maximum concurrent Pods (default: ~2768 ports)
- UDP health checks use TCP (NLB limitation)
- Requires VPC CNI (default on EKS)

## License

MIT License
