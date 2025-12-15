"""NLB Port Manager - 管理 NLB 端口、Target Group 和 Listener"""
import hashlib
from typing import Dict, List, Optional, Set, Tuple

import boto3


class PortManager:
    """管理 NLB 端口分配和资源生命周期"""

    # 支持的协议
    VALID_PROTOCOLS = {'TCP', 'UDP', 'TCP_UDP'}

    def __init__(self, nlb_arn: str, vpc_id: str, port_range: Tuple[int, int] = (30000, 32767)):
        self.nlb_arn = nlb_arn
        self.vpc_id = vpc_id
        self.elbv2 = boto3.client('elbv2')
        self.min_port, self.max_port = port_range

    def get_used_ports(self, protocol: str = None) -> Set[int]:
        """获取 NLB 已使用端口
        
        Args:
            protocol: 可选，指定协议过滤 (TCP/UDP/TCP_UDP)
        
        Returns:
            已使用的端口集合
        """
        listeners = self.elbv2.describe_listeners(LoadBalancerArn=self.nlb_arn)
        if protocol:
            return {l['Port'] for l in listeners['Listeners'] if l['Protocol'] == protocol}
        return {l['Port'] for l in listeners['Listeners']}

    def get_used_port_protocols(self) -> Set[Tuple[int, str]]:
        """获取 NLB 已使用的 (端口, 协议) 组合"""
        listeners = self.elbv2.describe_listeners(LoadBalancerArn=self.nlb_arn)
        return {(l['Port'], l['Protocol']) for l in listeners['Listeners']}

    def allocate_port(self, protocol: str = 'TCP') -> Optional[int]:
        """分配可用端口
        
        Args:
            protocol: 协议类型 (TCP/UDP/TCP_UDP)
        
        Returns:
            可用端口号，如果没有可用端口返回 None
        """
        used = self.get_used_port_protocols()
        for port in range(self.min_port, self.max_port + 1):
            # 检查该端口+协议组合是否已被使用
            if (port, protocol) not in used:
                # 对于 TCP_UDP，还需要检查 TCP 和 UDP 是否单独占用
                if protocol == 'TCP_UDP':
                    if (port, 'TCP') in used or (port, 'UDP') in used:
                        continue
                # 对于单协议，检查 TCP_UDP 是否已占用该端口
                elif (port, 'TCP_UDP') in used:
                    continue
                return port
        return None

    def create_target_group(self, name: str, port: int, protocol: str = 'TCP') -> str:
        """创建目标组
        
        Args:
            name: 目标组名称前缀
            port: 目标端口
            protocol: 协议 (TCP/UDP/TCP_UDP)
        
        Returns:
            Target Group ARN
        """
        # 验证协议
        if protocol not in self.VALID_PROTOCOLS:
            raise ValueError(f"Invalid protocol: {protocol}. Must be one of {self.VALID_PROTOCOLS}")

        # 使用 hash 确保名称唯一且不超过32字符
        # 包含协议以区分同一 Pod 的不同协议 Target Group
        name_with_proto = f"{name}-{protocol.lower()}"
        name_hash = hashlib.md5(name_with_proto.encode()).hexdigest()[:8]
        short_name = name[:16] if len(name) > 16 else name
        tg_name = f"tg-{short_name}-{name_hash}"[:32]

        # UDP 健康检查必须用 TCP 或 HTTP
        health_check_protocol = 'TCP' if protocol in ('UDP', 'TCP_UDP') else protocol

        response = self.elbv2.create_target_group(
            Name=tg_name,
            Protocol=protocol,
            Port=port,
            VpcId=self.vpc_id,
            TargetType='ip',
            HealthCheckProtocol=health_check_protocol,
            HealthCheckPort=str(port),
            HealthCheckIntervalSeconds=30,
            HealthyThresholdCount=3,
            UnhealthyThresholdCount=3
        )
        return response['TargetGroups'][0]['TargetGroupArn']

    def register_targets(self, target_group_arn: str, pod_ips: List[str], port: int):
        """注册 Pod IP 到目标组"""
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
        """从目标组注销 Pod IP"""
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

    def create_listener(self, port: int, target_group_arn: str, protocol: str = 'TCP') -> str:
        """创建监听器
        
        Args:
            port: 监听端口
            target_group_arn: 目标组 ARN
            protocol: 协议 (TCP/UDP/TCP_UDP)
        
        Returns:
            Listener ARN
        """
        if protocol not in self.VALID_PROTOCOLS:
            raise ValueError(f"Invalid protocol: {protocol}. Must be one of {self.VALID_PROTOCOLS}")

        response = self.elbv2.create_listener(
            LoadBalancerArn=self.nlb_arn,
            Protocol=protocol,
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
        except self.elbv2.exceptions.ListenerNotFoundException:
            print(f"Listener {listener_arn} not found, skipping deletion")
        except Exception as e:
            print(f"Error deleting listener: {e}")
            raise

    def delete_target_group(self, target_group_arn: str):
        """删除目标组"""
        try:
            self.elbv2.delete_target_group(TargetGroupArn=target_group_arn)
        except self.elbv2.exceptions.TargetGroupNotFoundException:
            print(f"Target group {target_group_arn} not found, skipping deletion")
        except Exception as e:
            print(f"Error deleting target group: {e}")
            raise


def parse_port_spec(port_spec: str) -> List[Dict[str, any]]:
    """解析端口规格字符串
    
    支持格式:
    - "8080/TCP" - 单端口单协议
    - "8080/UDP" - UDP 协议
    - "8080/TCPUDP" 或 "8080/TCP_UDP" - 同端口双协议
    - "8080/TCP,9090/UDP" - 多端口多协议
    
    Args:
        port_spec: 端口规格字符串
    
    Returns:
        解析后的端口配置列表，每项包含 {'port': int, 'protocol': str}
    
    Examples:
        >>> parse_port_spec("8080/TCP")
        [{'port': 8080, 'protocol': 'TCP'}]
        
        >>> parse_port_spec("8080/TCPUDP")
        [{'port': 8080, 'protocol': 'TCP_UDP'}]
        
        >>> parse_port_spec("8080/TCP,9090/UDP")
        [{'port': 8080, 'protocol': 'TCP'}, {'port': 9090, 'protocol': 'UDP'}]
    """
    if not port_spec:
        raise ValueError("Port specification cannot be empty")

    results = []
    # 分割多个端口配置
    specs = [s.strip() for s in port_spec.split(',')]

    for spec in specs:
        if '/' not in spec:
            raise ValueError(f"Invalid port spec '{spec}': must be in format 'PORT/PROTOCOL'")

        port_str, protocol = spec.split('/', 1)

        # 解析端口
        try:
            port = int(port_str.strip())
            if port < 1 or port > 65535:
                raise ValueError(f"Port {port} out of range (1-65535)")
        except ValueError as e:
            raise ValueError(f"Invalid port number '{port_str}': {e}")

        # 标准化协议
        protocol = protocol.strip().upper()
        if protocol == 'TCPUDP':
            protocol = 'TCP_UDP'

        if protocol not in PortManager.VALID_PROTOCOLS:
            raise ValueError(f"Invalid protocol '{protocol}': must be TCP, UDP, or TCP_UDP/TCPUDP")

        results.append({'port': port, 'protocol': protocol})

    return results
