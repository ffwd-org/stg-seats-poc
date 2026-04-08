#!/bin/bash
# startup-script for Elixir/BEAM service node (Cluster C)
set -euo pipefail
exec > >(tee /var/log/poc-startup.log) 2>&1

ZONE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone | awk -F/ '{print $NF}')
INSTANCE=$(curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/name)

echo "[$(date)] === Elixir service node startup ==="

# --- OS Tuning ---
echo "* soft nofile 1048576" >> /etc/security/limits.conf
echo "* hard nofile 1048576" >> /etc/security/limits.conf
ulimit -n 1048576 || true
sysctl -w net.core.somaxconn=65535
sysctl -w net.ipv4.tcp_max_syn_backlog=65535
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.core.netdev_max_backlog=65535
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
swapoff -a

# --- Install Erlang/OTP 27 + Elixir 1.17 ---
apt-get update -qq
apt-get install -y -qq git curl unzip

# Install Erlang via ASDF or direct package
curl -fsSL https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc | apt-key add -
echo "deb https://packages.erlang-solutions.com/ubuntu noble contrib" > /etc/apt/sources.list.d/erlang.list
apt-get update -qq
apt-get install -y -qq esl-erlang || {
  # Fallback: install via ASDF
  echo "[$(date)] Erlang package failed, trying direct download..."
  apt-get install -y -qq build-essential autoconf m4 libncurses5-dev libwxgtk3.2-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev xsltproc fop libxml2-utils
  curl -fsSL https://github.com/erlang/otp/releases/download/OTP-27.2/otp_src_27.2.tar.gz | tar -xz -C /tmp
  cd /tmp/otp_src_27.2 && ./configure --without-javac && make -j$(nproc) && make install
  cd /
}

# Install Elixir
curl -fsSL https://github.com/elixir-lang/elixir/releases/download/v1.17.3/elixir-otp-27.zip -o /tmp/elixir.zip
mkdir -p /usr/local/elixir
unzip -q /tmp/elixir.zip -d /usr/local/elixir
export PATH=$PATH:/usr/local/elixir/bin
echo 'export PATH=$PATH:/usr/local/elixir/bin' >> /etc/profile.d/elixir.sh
echo "[$(date)] Elixir $(elixir --version | tail -1) installed"

# --- Clone repo ---
cd /opt
git clone https://github.com/ffwd-org/stg-seats-poc.git
cd stg-seats-poc/poc-6-actor-model

# --- Build and start Elixir app ---
mix local.hex --force
mix local.rebar --force
mix deps.get
MIX_ENV=prod mix compile
echo "[$(date)] Elixir app compiled"

# Start on port 4000 with tuned BEAM
ERL_FLAGS="+S 8:8 +P 1000000" MIX_ENV=prod elixir --no-halt -S mix &
ELIXIR_PID=$!
sleep 5

# Health check
for i in $(seq 1 30); do
  curl -sf http://localhost:4000/health && break
  sleep 1
done
echo "[$(date)] Elixir app running (PID $ELIXIR_PID) on :4000"

# Signal ready
gcloud compute instances add-metadata "$INSTANCE" --zone="$ZONE" --metadata=ready=true
echo "[$(date)] === Elixir service node READY ==="

# Keep alive
wait $ELIXIR_PID
