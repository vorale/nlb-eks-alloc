"""NLB Port Operator - 自动为 Pod 分配 NLB 端口

支持的注解:
- nlb.port-manager/auto-assign: "true"  # 启用自动分配
- nlb.port-manager/port: "8080/TCP"     # 容器端口/协议

端口规格格式:
- "8080/TCP"           - 单端口 TCP
- "8080/UDP"           - 单端口 UDP
- "8080/TCPUDP"        - 同端口 TCP+UDP
- "8080/TCP,9090/UDP"  - 多端口多协议
"""
import hashlib
import json
import logging
import os
import time

import boto3
import kopf
from kubernetes import client, config

from port_manager import PortManager, parse_port_spec

# 配置
NLB_ARN = os.getenv('NLB_ARN')
VPC_ID = os.getenv('VPC_ID')
PORT_RANGE_MIN = int(os.getenv('PORT_RANGE_MIN', '30000'))
PORT_RANGE_MAX = int(os.getenv('PORT_RANGE_MAX', '32767'))
DEFAULT_PORT_SPEC = os.getenv('DEFAULT_PORT_SPEC', '80/TCP')  # 默认端口规格

# 初始化
config.load_incluster_config()
k8s_core_api = client.CoreV1Api()
port_manager = PortManager(NLB_ARN, VPC_ID, (PORT_RANGE_MIN, PORT_RANGE_MAX))
logger = logging.getLogger(__name__)


@kopf.on.create('v1', 'pods')
def create_pod(meta, namespace, status, **_):
    """处理 Pod 创建 - 为每个 Pod 分配独立的 NLB 端口"""
    annotations = meta.get('annotations', {})

    # 检查是否需要自动分配端口
    if annotations.get('nlb.port-manager/auto-assign') != 'true':
        return None

    pod_name = meta['name']
    pod_ip = status.get('podIP') if status else None

    # 等待 Pod 获取 IP
    if not pod_ip:
        raise kopf.TemporaryError(f"Pod {pod_name} has no IP yet", delay=5)

    # 解析端口规格
    port_spec_str = annotations.get('nlb.port-manager/port', DEFAULT_PORT_SPEC)
    try:
        port_specs = parse_port_spec(port_spec_str)
    except ValueError as e:
        raise kopf.PermanentError(f"Invalid port spec '{port_spec_str}': {e}")

    logger.info(f"Processing pod {pod_name} with port specs: {port_specs}")

    try:
        allocated_resources = []

        for spec in port_specs:
            container_port = spec['port']
            protocol = spec['protocol']

            # 分配 NLB 端口
            nlb_port = port_manager.allocate_port(protocol)
            if not nlb_port:
                raise kopf.PermanentError(f"No available ports for protocol {protocol}")

            # 创建目标组 (包含协议以支持多协议)
            tg_name = f"{namespace}-{pod_name}"
            tg_arn = port_manager.create_target_group(tg_name, container_port, protocol)
            logger.info(f"Created target group for {pod_name}: {tg_arn}")

            time.sleep(1)

            # 注册 Pod IP 到目标组
            port_manager.register_targets(tg_arn, [pod_ip], container_port)
            logger.info(f"Registered {pod_name} ({pod_ip}:{container_port}) to target group")

            # 创建监听器
            listener_arn = port_manager.create_listener(nlb_port, tg_arn, protocol)
            logger.info(f"Created {protocol} listener on port {nlb_port} for {pod_name}")

            allocated_resources.append({
                'nlb_port': nlb_port,
                'container_port': container_port,
                'protocol': protocol,
                'target_group_arn': tg_arn,
                'listener_arn': listener_arn
            })

        # 更新 Pod 注解
        patch_annotations = {
            'nlb.port-manager/allocated-ports': json.dumps([
                {'nlb_port': r['nlb_port'], 'protocol': r['protocol']}
                for r in allocated_resources
            ]),
            'nlb.port-manager/resources': json.dumps(allocated_resources)
        }

        # 兼容单端口场景，保留旧注解格式
        if len(allocated_resources) == 1:
            r = allocated_resources[0]
            patch_annotations['nlb.port-manager/allocated-port'] = str(r['nlb_port'])
            patch_annotations['nlb.port-manager/target-group-arn'] = r['target_group_arn']
            patch_annotations['nlb.port-manager/listener-arn'] = r['listener_arn']

        k8s_core_api.patch_namespaced_pod(
            pod_name, namespace,
            {'metadata': {'annotations': patch_annotations}}
        )

        return {
            'pod': pod_name,
            'resources': allocated_resources
        }

    except Exception as e:
        logger.error(f"Error creating NLB resources for pod {pod_name}: {e}")
        raise kopf.TemporaryError(f"Failed to create NLB resources: {e}", delay=30)


def find_target_groups_by_name(namespace: str, pod_name: str) -> list:
    """通过命名规则查找所有相关的 Target Group ARN"""
    elbv2 = boto3.client('elbv2')
    results = []

    # 尝试查找各种协议的 Target Group
    for protocol in ['tcp', 'udp', 'tcp_udp']:
        name = f"{namespace}-{pod_name}"
        name_with_proto = f"{name}-{protocol}"
        name_hash = hashlib.md5(name_with_proto.encode()).hexdigest()[:8]
        short_name = name[:16] if len(name) > 16 else name
        tg_name = f"tg-{short_name}-{name_hash}"[:32]

        try:
            response = elbv2.describe_target_groups(Names=[tg_name])
            if response['TargetGroups']:
                results.append(response['TargetGroups'][0]['TargetGroupArn'])
        except Exception:
            pass

    return results


def find_listeners_by_target_groups(tg_arns: list) -> list:
    """通过 Target Group ARN 列表查找关联的 Listener ARN"""
    if not tg_arns:
        return []

    elbv2 = boto3.client('elbv2')
    results = []

    try:
        listeners = elbv2.describe_listeners(LoadBalancerArn=NLB_ARN)
        for listener in listeners['Listeners']:
            for action in listener.get('DefaultActions', []):
                if action.get('TargetGroupArn') in tg_arns:
                    results.append(listener['ListenerArn'])
    except Exception as e:
        logger.error(f"Error finding listeners: {e}")

    return results


@kopf.on.delete('v1', 'pods')
def delete_pod(meta, namespace, **_):
    """处理 Pod 删除 - 清理 NLB 资源"""
    annotations = meta.get('annotations', {})
    pod_name = meta['name']

    logger.info(f"DELETE event for pod {pod_name}")

    # 尝试从新格式注解获取资源列表
    resources_json = annotations.get('nlb.port-manager/resources')
    if resources_json:
        try:
            resources = json.loads(resources_json)
            logger.info(f"Found {len(resources)} resources from annotations")
        except json.JSONDecodeError:
            resources = []
    else:
        # 兼容旧格式
        listener_arn = annotations.get('nlb.port-manager/listener-arn')
        tg_arn = annotations.get('nlb.port-manager/target-group-arn')
        if listener_arn or tg_arn:
            resources = [{'listener_arn': listener_arn, 'target_group_arn': tg_arn}]
        else:
            resources = []

    # 如果注解中没有，尝试通过命名规则查找
    if not resources:
        logger.info("Trying to find resources by naming convention...")
        tg_arns = find_target_groups_by_name(namespace, pod_name)
        if tg_arns:
            listener_arns = find_listeners_by_target_groups(tg_arns)
            resources = [
                {'listener_arn': l, 'target_group_arn': None}
                for l in listener_arns
            ] + [
                {'listener_arn': None, 'target_group_arn': t}
                for t in tg_arns
            ]
            logger.info(f"Found {len(tg_arns)} target groups, {len(listener_arns)} listeners")

    if not resources:
        logger.info(f"No NLB resources found for pod {pod_name}, skipping cleanup")
        return

    logger.info(f"Cleaning up {len(resources)} NLB resources for pod {pod_name}")

    # 先删除所有 Listener
    for r in resources:
        listener_arn = r.get('listener_arn')
        if listener_arn:
            try:
                logger.info(f"Deleting listener: {listener_arn}")
                port_manager.delete_listener(listener_arn)
            except Exception as e:
                logger.error(f"Error deleting listener: {e}")

    time.sleep(2)

    # 再删除所有 Target Group
    for r in resources:
        tg_arn = r.get('target_group_arn')
        if tg_arn:
            try:
                logger.info(f"Deleting target group: {tg_arn}")
                port_manager.delete_target_group(tg_arn)
            except Exception as e:
                logger.error(f"Error deleting target group: {e}")


@kopf.on.update('v1', 'pods')
def update_pod(meta, namespace, old, status, **_):
    """处理 Pod 更新 - 更新目标组中的 IP"""
    annotations = meta.get('annotations', {})

    if annotations.get('nlb.port-manager/auto-assign') != 'true':
        return

    pod_name = meta['name']
    old_ip = old.get('status', {}).get('podIP')
    new_ip = status.get('podIP') if status else None

    # IP 变化时更新目标组
    if old_ip != new_ip and new_ip:
        # 尝试从新格式获取资源
        resources_json = annotations.get('nlb.port-manager/resources')
        if resources_json:
            try:
                resources = json.loads(resources_json)
                for r in resources:
                    tg_arn = r.get('target_group_arn')
                    container_port = r.get('container_port')
                    if tg_arn and container_port:
                        if old_ip:
                            port_manager.deregister_targets(tg_arn, [old_ip], container_port)
                        port_manager.register_targets(tg_arn, [new_ip], container_port)
                        logger.info(f"Updated {pod_name} IP: {old_ip} -> {new_ip}")
            except Exception as e:
                logger.error(f"Error updating pod IP: {e}")
        else:
            # 兼容旧格式
            tg_arn = annotations.get('nlb.port-manager/target-group-arn')
            port_spec_str = annotations.get('nlb.port-manager/port', DEFAULT_PORT_SPEC)
            try:
                port_specs = parse_port_spec(port_spec_str)
                container_port = port_specs[0]['port'] if port_specs else 80
            except ValueError:
                container_port = 80

            if tg_arn:
                try:
                    if old_ip:
                        port_manager.deregister_targets(tg_arn, [old_ip], container_port)
                    port_manager.register_targets(tg_arn, [new_ip], container_port)
                    logger.info(f"Updated {pod_name} IP: {old_ip} -> {new_ip}")
                except Exception as e:
                    logger.error(f"Error updating pod IP: {e}")


@kopf.on.startup()
def configure(settings: kopf.OperatorSettings, **_):
    """配置 Operator"""
    settings.posting.level = logging.INFO
    settings.watching.connect_timeout = 1 * 60
    settings.watching.server_timeout = 10 * 60
