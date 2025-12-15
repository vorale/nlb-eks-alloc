# NLB Port Operator Project

A Kubernetes operator solution for automatically allocating dedicated AWS Network Load Balancer (NLB) ports for individual Pods in EKS clusters.

## Project Structure

```
.
├── nlb-port-alloc/          # Core operator implementation
└── nlb-test-deployment/     # Test deployment and verification
```

## Overview

This project provides a complete solution for managing NLB port allocation in Kubernetes environments. It enables 1:1 mapping between Pod names and NLB ports, supporting TCP, UDP, and dual-protocol (TCP_UDP) configurations.

### Key Features

- Per-Pod dedicated NLB port allocation
- Multi-protocol support: TCP, UDP, TCP_UDP
- Automatic Pod lifecycle management (create, update, delete)
- IRSA (IAM Roles for Service Accounts) integration
- Configurable port ranges (default: 30000-32767)

## Components

### nlb-port-alloc

The core Kubernetes operator that:
- Watches Pods with specific annotations
- Allocates unique NLB ports from a configurable range
- Creates dedicated NLB listeners and target groups per Pod
- Registers Pod IPs as targets
- Cleans up NLB resources when Pods are deleted

Architecture:
```
Pod: game-room-1 (80/TCP)   →  NLB Port 30000/TCP  →  Target Group  →  Pod IP:80
Pod: game-room-2 (80/TCP)   →  NLB Port 30001/TCP  →  Target Group  →  Pod IP:80
Pod: udp-server (9999/UDP)  →  NLB Port 30002/UDP  →  Target Group  →  Pod IP:9999
```

See [nlb-port-alloc/README.md](nlb-port-alloc/README.md) for detailed usage and configuration.

### nlb-test-deployment

Complete test deployment environment including:
- Setup scripts for EKS cluster, NLB, and IRSA
- Kubernetes manifests (ConfigMap, RBAC, Deployment)
- Test cases for TCP, UDP, and dual-protocol scenarios
- Verification scripts for connectivity and resource validation

Quick start:
```bash
cd nlb-test-deployment/setup/
./pre-check.sh              # Check prerequisites
./00-create-nlb.sh          # Create NLB
./01-setup-irsa.sh          # Configure IRSA
./02-deploy-operator.sh     # Deploy operator

cd ..
./quick-test.sh             # Run tests
```

See [nlb-test-deployment/README.md](nlb-test-deployment/README.md) for complete deployment guide.

## Quick Usage

Add annotations to your Pod:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: game-server
  annotations:
    nlb.port-manager/auto-assign: "true"
    nlb.port-manager/port: "8080/TCP"
spec:
  containers:
  - name: server
    image: your-image:latest
    ports:
    - containerPort: 8080
```

## Requirements

- AWS EKS cluster with OIDC enabled
- AWS CLI, kubectl, eksctl
- VPC CNI (default on EKS)
- Appropriate IAM permissions for NLB management

## License

MIT License
