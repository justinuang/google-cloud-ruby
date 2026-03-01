#!/bin/bash
set -ex
VM_NAME="ju-ruby-sidecar-vm"
VM_ZONE="us-east1-b"
SSH_HOST="nic0.${VM_NAME}.${VM_ZONE}.c.autonomous-mote-782.internal.gcpnode.com"
SSH_USER="justinuang_google_com"
SSH_OPTS="-i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no"

ssh $SSH_OPTS $SSH_USER@$SSH_HOST "bash -s" << 'INNER_EOF'
  set -ex
  if ! command -v rbspy &> /dev/null; then
    wget -qO- https://github.com/rbspy/rbspy/releases/download/v0.42.1/rbspy-x86_64-unknown-linux-musl.tar.gz | tar xz
    sudo mv rbspy-x86_64-unknown-linux-musl /usr/local/bin/rbspy
  fi
  
  echo "Starting Native Ruby benchmark at 1000 QPS..."
  ruby ~/ycsb_benchmark.rb --qps=1000 --app-profile-id=nosidecar --duration=60 > ~/benchmark_profile.log 2>&1 &
  PID=$!
  
  sleep 5
  echo "Recording rbspy on PID $PID for 45 seconds..."
  sudo rbspy record --pid $PID --duration 45 --format flamegraph --file /tmp/ruby_flamegraph.svg
  
  kill $PID || true
INNER_EOF

echo "Fetching flamegraph..."
scp $SSH_OPTS $SSH_USER@$SSH_HOST:/tmp/ruby_flamegraph.svg /usr/local/google/home/justinuang/.gemini/jetski/brain/f7af5d9b-59cb-46a1-876c-a04872902070/ruby_flamegraph.svg
