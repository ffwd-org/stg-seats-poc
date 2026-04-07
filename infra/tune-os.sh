#!/bin/bash
# tune-os.sh — Run on every VM before any POC load test
# Applies OS-level tunings for high-throughput, high-connection scenarios

set -e

echo "[tune-os] Applying OS tunings..."

# Raise file descriptor limit (needed for 250K+ connections)
if ! grep -q "1048576" /etc/security/limits.conf 2>/dev/null; then
  echo "* soft nofile 1048576" >> /etc/security/limits.conf
  echo "* hard nofile 1048576" >> /etc/security/limits.conf
fi
ulimit -n 1048576

# TCP tuning for high-concurrency scenarios
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.core.netdev_max_backlog=65535
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216

# Disable swap for consistent latency
swapoff -a 2>/dev/null || true

echo "[tune-os] Done. Current limits:"
echo "  nofile: $(ulimit -n)"
echo "  somaxconn: $(sysctl -n net.core.somaxconn)"
echo "  tcp_max_syn_backlog: $(sysctl -n net.ipv4.tcp_max_syn_backlog)"
echo "  ip_local_port_range: $(sysctl -n net.ipv4.ip_local_port_range)"
