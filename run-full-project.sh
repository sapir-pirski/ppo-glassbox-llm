#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

load_env_defaults() {
  [[ -f .env ]] || return

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "${line:0:1}" == "#" || "$line" != *"="* ]] && continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue

    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < .env
}

load_env_defaults

NOTEBOOK="${NOTEBOOK:-ppo_glassbox_llm.ipynb}"
VENV_DIR="${VENV_DIR:-.venv}"
PYTHON_BIN="$VENV_DIR/bin/python"
JUPYTER_BIN="$VENV_DIR/bin/jupyter"
TIMEOUT_SECONDS="${NOTEBOOK_TIMEOUT:-3600}"
JUPYTER_PORT="${JUPYTER_PORT:-8888}"
EXECUTE_ONLY="${EXECUTE_ONLY:-0}"

RUN_ON_NEBIUS_VM="${RUN_ON_NEBIUS_VM:-0}"
NEBIUS_CLI="${NEBIUS_CLI:-/Users/sapirpirski/.nebius/bin/nebius}"
NEBIUS_INSTANCE_ID="${NEBIUS_INSTANCE_ID:-}"
VM_SSH_HOST="${VM_SSH_HOST:-}"
VM_SSH_USER="${VM_SSH_USER:-$USER}"
VM_SSH_PORT="${VM_SSH_PORT:-22}"
VM_WORKDIR="${VM_WORKDIR:-ppo-glassbox-llm}"
VM_STOP_AFTER="${VM_STOP_AFTER:-1}"
VM_COPY_BACK="${VM_COPY_BACK:-1}"
VM_SSH_ATTEMPTS="${VM_SSH_ATTEMPTS:-60}"
VM_SSH_SLEEP_SECONDS="${VM_SSH_SLEEP_SECONDS:-10}"
VM_NOTEBOOK_POLL_SECONDS="${VM_NOTEBOOK_POLL_SECONDS:-60}"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

require_project_files() {
  if [[ ! -f "$NOTEBOOK" ]]; then
    echo "Notebook not found: $NOTEBOOK" >&2
    exit 1
  fi

  if [[ ! -f requirements.txt ]]; then
    echo "requirements.txt not found" >&2
    exit 1
  fi
}

load_env_file() {
  if [[ ! -f .env ]]; then
    log "Creating .env from .env.example"
    cp .env.example .env
    chmod 600 .env
    echo "Edit .env and set HF_TOKEN before relying on higher Hugging Face rate limits." >&2
  fi

  if [[ -f .env ]]; then
    log "Loading local environment defaults from .env"
    load_env_defaults
  fi
}

install_requirements() {
  if command -v uv >/dev/null 2>&1; then
    log "Creating virtual environment with uv"
    uv venv "$VENV_DIR"
    log "Installing requirements with uv"
    uv pip install --python "$PYTHON_BIN" -r requirements.txt
  else
    log "Creating virtual environment with python3"
    python3 -m venv "$VENV_DIR"
    log "Installing requirements with pip"
    "$PYTHON_BIN" -m pip install --upgrade pip
    "$PYTHON_BIN" -m pip install -r requirements.txt
  fi
}

execute_notebook() {
  if [[ ! -x "$JUPYTER_BIN" ]]; then
    echo "Jupyter executable not found at $JUPYTER_BIN" >&2
    exit 1
  fi

  if [[ -z "${HF_TOKEN:-}" ]]; then
    echo "HF_TOKEN is not set. The notebook can still run, but Hugging Face downloads may be rate-limited." >&2
  fi

  log "Executing notebook end to end"
  "$JUPYTER_BIN" nbconvert \
    --to notebook \
    --execute \
    --inplace \
    --ExecutePreprocessor.timeout="$TIMEOUT_SECONDS" \
    --ExecutePreprocessor.kernel_name=python3 \
    "$NOTEBOOK"
}

run_local_project() {
  require_project_files
  load_env_file
  install_requirements
  execute_notebook

  if [[ "$EXECUTE_ONLY" == "1" ]]; then
    log "Notebook execution complete; skipping Jupyter launch because EXECUTE_ONLY=1"
    return
  fi

  log "Launching Jupyter Notebook in the browser"
  exec "$JUPYTER_BIN" notebook "$NOTEBOOK" \
    --ip=127.0.0.1 \
    --port="$JUPYTER_PORT" \
    --port-retries=50
}

ssh_target() {
  printf '%s@%s' "$VM_SSH_USER" "$VM_SSH_HOST"
}

refresh_vm_public_ip() {
  local instance_json
  local detected_host

  instance_json="$("$NEBIUS_CLI" compute instance get "$NEBIUS_INSTANCE_ID" --format=json --timeout=2m --no-progress)"
  detected_host="$(
    INSTANCE_JSON="$instance_json" python3 -c '
import json
import os

data = json.loads(os.environ["INSTANCE_JSON"])
for iface in data.get("status", {}).get("network_interfaces", []):
    public_ip = iface.get("public_ip_address") or {}
    address = public_ip.get("address") or public_ip.get("ip_address") or ""
    if address:
        print(address.split("/")[0])
        break
'
  )"

  if [[ -n "$detected_host" ]]; then
    VM_SSH_HOST="$detected_host"
    log "Using VM public IP $VM_SSH_HOST"
    return
  fi

  if [[ -n "$VM_SSH_HOST" ]]; then
    log "Could not detect a VM public IP; falling back to VM_SSH_HOST=$VM_SSH_HOST"
    return
  fi

  echo "Could not detect VM public IP. Set VM_SSH_HOST manually." >&2
  exit 1
}

wait_for_vm_ssh() {
  local target
  target="$(ssh_target)"
  local ssh_opts=(
    -p "$VM_SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=120
    -o ConnectTimeout=10
  )

  log "Waiting for SSH on $target:$VM_SSH_PORT"
  for attempt in $(seq 1 "$VM_SSH_ATTEMPTS"); do
    if ssh "${ssh_opts[@]}" "$target" "echo ready" >/dev/null 2>&1; then
      log "SSH is ready"
      return 0
    fi
    log "SSH not ready yet ($attempt/$VM_SSH_ATTEMPTS)"
    sleep "$VM_SSH_SLEEP_SECONDS"
  done

  echo "Timed out waiting for SSH on $target:$VM_SSH_PORT" >&2
  exit 1
}

install_vm_os_prereqs() {
  local target
  target="$(ssh_target)"
  local ssh_opts=(
    -p "$VM_SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=120
    -o ConnectTimeout=10
  )

  log "Installing VM OS prerequisites if needed"
  ssh "${ssh_opts[@]}" "$target" \
    "if command -v apt-get >/dev/null 2>&1; then sudo env DEBIAN_FRONTEND=noninteractive apt-get update && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y rsync python3-venv python3-pip; fi"
}

sync_project_to_vm() {
  local target
  target="$(ssh_target)"
  local ssh_opts=(
    -p "$VM_SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=120
    -o ConnectTimeout=10
  )
  local rsync_ssh
  rsync_ssh="ssh -p $VM_SSH_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -o ConnectTimeout=10"

  log "Creating remote workdir $VM_WORKDIR"
  ssh "${ssh_opts[@]}" "$target" "mkdir -p '$VM_WORKDIR'"

  log "Syncing project to $target:$VM_WORKDIR"
  rsync -az \
    --exclude ".venv/" \
    --exclude ".ipynb_checkpoints/" \
    --exclude "__pycache__/" \
    --exclude ".git/" \
    -e "$rsync_ssh" \
    ./ "$target:$VM_WORKDIR/"
}

run_project_on_vm() {
  local target
  target="$(ssh_target)"
  local ssh_opts=(
    -p "$VM_SSH_PORT"
    -o BatchMode=yes
    -o StrictHostKeyChecking=accept-new
    -o ServerAliveInterval=30
    -o ServerAliveCountMax=120
    -o ConnectTimeout=10
  )
  local remote_status="run-full-project.status"
  local remote_done="run-full-project.done"
  local remote_log="run-full-project.log"
  local status

  log "Running notebook end to end on the VM"
  ssh "${ssh_opts[@]}" "$target" \
    "cd '$VM_WORKDIR' && rm -f '$remote_status' '$remote_done' '$remote_log' && chmod +x run-full-project.sh && setsid -f env RUN_ON_NEBIUS_VM=0 EXECUTE_ONLY=1 NOTEBOOK_TIMEOUT='$TIMEOUT_SECONDS' NOTEBOOK='$NOTEBOOK' bash -lc './run-full-project.sh; rc=\$?; echo \$rc > $remote_status; touch $remote_done; exit \$rc' > '$remote_log' 2>&1 < /dev/null"

  while true; do
    if ! status="$(ssh "${ssh_opts[@]}" "$target" "cd '$VM_WORKDIR' && if [ -f '$remote_done' ]; then cat '$remote_status'; else echo RUNNING; fi" 2>/dev/null)"; then
      log "Remote notebook status check failed; retrying"
      sleep "$VM_NOTEBOOK_POLL_SECONDS"
      continue
    fi
    if [[ "$status" != "RUNNING" ]]; then
      if [[ "$status" != "0" ]]; then
        ssh "${ssh_opts[@]}" "$target" "cd '$VM_WORKDIR' && tail -n 80 '$remote_log'" >&2 || true
        echo "Remote notebook run failed with status $status" >&2
        exit "$status"
      fi
      log "Remote notebook execution finished successfully"
      ssh "${ssh_opts[@]}" "$target" "cd '$VM_WORKDIR' && tail -n 20 '$remote_log'" || true
      return
    fi

    log "Remote notebook still running; recent VM log:"
    ssh "${ssh_opts[@]}" "$target" "cd '$VM_WORKDIR' && tail -n 8 '$remote_log'" || true
    sleep "$VM_NOTEBOOK_POLL_SECONDS"
  done
}

copy_notebook_back() {
  if [[ "$VM_COPY_BACK" != "1" ]]; then
    log "Skipping notebook copy-back because VM_COPY_BACK=$VM_COPY_BACK"
    return
  fi

  local target
  target="$(ssh_target)"
  local rsync_ssh
  rsync_ssh="ssh -p $VM_SSH_PORT -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=120 -o ConnectTimeout=10"

  log "Copying executed notebook back from the VM"
  rsync -az -e "$rsync_ssh" "$target:$VM_WORKDIR/$NOTEBOOK" "$NOTEBOOK"
}

stop_vm() {
  if [[ "$VM_STOP_AFTER" != "1" ]]; then
    log "Leaving Nebius VM running because VM_STOP_AFTER=$VM_STOP_AFTER"
    return
  fi

  log "Stopping Nebius VM $NEBIUS_INSTANCE_ID"
  "$NEBIUS_CLI" compute instance stop "$NEBIUS_INSTANCE_ID" --timeout=20m --no-progress || true
}

run_on_nebius_vm() {
  require_project_files

  if [[ -z "$NEBIUS_INSTANCE_ID" ]]; then
    echo "Set NEBIUS_INSTANCE_ID before RUN_ON_NEBIUS_VM=1" >&2
    exit 1
  fi
  if ! command -v "$NEBIUS_CLI" >/dev/null 2>&1; then
    echo "Nebius CLI not found: $NEBIUS_CLI" >&2
    exit 1
  fi
  if ! command -v rsync >/dev/null 2>&1; then
    echo "rsync is required for VM sync/copy-back" >&2
    exit 1
  fi
  if [[ "$VM_WORKDIR" == *"'"* || "$NOTEBOOK" == *"'"* ]]; then
    echo "VM_WORKDIR and NOTEBOOK must not contain single quotes" >&2
    exit 1
  fi

  trap stop_vm EXIT

  log "Starting Nebius VM $NEBIUS_INSTANCE_ID"
  if ! "$NEBIUS_CLI" compute instance start "$NEBIUS_INSTANCE_ID" --timeout=20m --no-progress; then
    log "Start returned non-zero; continuing in case the VM is already running"
  fi

  refresh_vm_public_ip
  wait_for_vm_ssh
  install_vm_os_prereqs
  sync_project_to_vm
  run_project_on_vm
  copy_notebook_back
}

if [[ "$RUN_ON_NEBIUS_VM" == "1" ]]; then
  run_on_nebius_vm
else
  run_local_project
fi
