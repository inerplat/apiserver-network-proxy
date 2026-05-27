#!/usr/bin/env bash

# Reproduces pending backend dials with real konnectivity components in a
# kubeadm cluster built from kindest/node containers. This intentionally uses
# only the kind node image, not `kind create cluster`.
#
#   1. Bootstrap one control-plane and two workers with kubeadm.
#   2. Start host-networked proxy-server/proxy-agents in http-connect mode.
#   3. Verify an HTTP CONNECT request can reach a host-networked test server.
#   4. Drop only proxy-agent <-> proxy-server TCP packets on the established
#      server-agent path, leaving the proxy-agent processes running.
#   5. Send many large HTTP CONNECT dial requests through the proxy UDS.
#   6. Stop the clients and assert pending backend dials drain back to zero.
#
# Unpatched code fails step 5 because backend dial requests have no bounded
# lifetime when the backend stream stops making forward progress.

set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-${KIND_CLUSTER_NAME:-pending-dial-kubeadm}}"
NODE_IMAGE="${NODE_IMAGE:-${KIND_IMAGE:-kindest/node:v1.34.3}}"
CLUSTER_NETWORK="${CLUSTER_NETWORK:-${CLUSTER_NAME}-net}"
CLUSTER_SUBNET="${CLUSTER_SUBNET:-172.30.50.0/24}"
CONTROL_PLANE_NODE="${CONTROL_PLANE_NODE:-${CLUSTER_NAME}-cp}"
WORKER1_NODE="${WORKER1_NODE:-${CLUSTER_NAME}-w1}"
WORKER2_NODE="${WORKER2_NODE:-${CLUSTER_NAME}-w2}"
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-172.30.50.2}"
WORKER1_IP="${WORKER1_IP:-172.30.50.3}"
WORKER2_IP="${WORKER2_IP:-172.30.50.4}"
API_HOST_PORT="${API_HOST_PORT:-16443}"
ADMIN_HOST_PORT="${ADMIN_HOST_PORT:-18093}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/tmp/${CLUSTER_NAME}-kubeconfig}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/16}"
SERVER_IMAGE="${SERVER_IMAGE:-gcr.io/k8s-staging-kas-network-proxy/proxy-server:pending-dial}"
AGENT_IMAGE="${AGENT_IMAGE:-gcr.io/k8s-staging-kas-network-proxy/proxy-agent:pending-dial}"
TEST_CLIENT_IMAGE="${TEST_CLIENT_IMAGE:-gcr.io/k8s-staging-kas-network-proxy/proxy-test-client:pending-dial}"
TEST_SERVER_IMAGE="${TEST_SERVER_IMAGE:-gcr.io/k8s-staging-kas-network-proxy/http-test-server:pending-dial}"
BACKEND_DIAL_TIMEOUT="${BACKEND_DIAL_TIMEOUT:-}"
LOAD_REQUESTS="${LOAD_REQUESTS:-6000}"
CONNECT_HOST_BYTES="${CONNECT_HOST_BYTES:-6000}"
MIN_PENDING_DIALS="${MIN_PENDING_DIALS:-10}"
CLIENT_ACTIVE_DEADLINE_SECONDS="${CLIENT_ACTIVE_DEADLINE_SECONDS:-20}"
PENDING_RISE_TIMEOUT_SECONDS="${PENDING_RISE_TIMEOUT_SECONDS:-60}"
DRAIN_TIMEOUT_SECONDS="${DRAIN_TIMEOUT_SECONDS:-10}"
METRICS_URL="${METRICS_URL:-http://127.0.0.1:${ADMIN_HOST_PORT}/metrics}"

dropped_agent_rules=()
dropped_server_rules=()
NODE_NAMES=("${CONTROL_PLANE_NODE}" "${WORKER1_NODE}" "${WORKER2_NODE}")

log() {
  printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "${GITHUB_STEP_SUMMARY}"
  fi
}

cleanup() {
  set +e
  for node_ip in "${dropped_agent_rules[@]}"; do
    node="${node_ip%%:*}"
    agent_ip="${node_ip##*:}"
    docker exec "${node}" iptables -D OUTPUT -s "${agent_ip}/32" -d "${CONTROL_PLANE_IP}/32" -p tcp --dport 8091 -j DROP >/dev/null 2>&1
  done
  for node_ip in "${dropped_server_rules[@]}"; do
    node="${node_ip%%:*}"
    agent_ip="${node_ip##*:}"
    docker exec "${node}" iptables -D OUTPUT -s "${CONTROL_PLANE_IP}/32" -d "${agent_ip}/32" -p tcp --sport 8091 -j DROP >/dev/null 2>&1
  done
}
trap cleanup EXIT

node_ip() {
  case "$1" in
    "${CONTROL_PLANE_NODE}") printf '%s\n' "${CONTROL_PLANE_IP}" ;;
    "${WORKER1_NODE}") printf '%s\n' "${WORKER1_IP}" ;;
    "${WORKER2_NODE}") printf '%s\n' "${WORKER2_IP}" ;;
    *) return 1 ;;
  esac
}

k8s_version_from_image() {
  local tag="${NODE_IMAGE##*:}"
  if [[ "${tag}" == "${NODE_IMAGE}" || -z "${tag}" ]]; then
    tag="v1.34.3"
  fi
  printf '%s\n' "${tag}"
}

write_to_node() {
  local node="$1"
  local path="$2"
  local content="$3"
  printf '%s' "${content}" | docker exec -i "${node}" tee "${path}" >/dev/null
}

create_node_network() {
  if docker network inspect "${CLUSTER_NETWORK}" >/dev/null 2>&1; then
    log "Docker network ${CLUSTER_NETWORK} already exists"
    return
  fi
  docker network create --subnet "${CLUSTER_SUBNET}" "${CLUSTER_NETWORK}" >/dev/null
  log "Created Docker network ${CLUSTER_NETWORK} (${CLUSTER_SUBNET})"
}

create_node_container() {
  local node="$1"
  local ip="$2"
  docker rm -f "${node}" >/dev/null 2>&1 || true

  local args=(
    run -d --privileged
    "--name=${node}"
    "--hostname=${node}"
    --tmpfs=/tmp
    --tmpfs=/run
    --volume=/var
    --volume=/lib/modules:/lib/modules:ro
    --ulimit=memlock=-1:-1
    --security-opt=seccomp=unconfined
    --cgroupns=private
    --tty
    "--network=${CLUSTER_NETWORK}"
    "--ip=${ip}"
  )
  if [[ "${node}" == "${CONTROL_PLANE_NODE}" ]]; then
    args+=(
      "--publish=127.0.0.1:${API_HOST_PORT}:6443"
      "--publish=127.0.0.1:${ADMIN_HOST_PORT}:8093"
    )
  fi
  args+=("${NODE_IMAGE}")

  docker "${args[@]}" >/dev/null
  log "Started ${node} (${ip}) from ${NODE_IMAGE}"
}

wait_for_containerd() {
  local node="$1"
  local deadline=$((SECONDS + 120))
  while (( SECONDS < deadline )); do
    if docker exec "${node}" crictl info >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  echo "containerd did not become ready on ${node}" >&2
  return 1
}

kubeadm_init() {
  local version
  version="$(k8s_version_from_image)"
  local config
  config=$(cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${CONTROL_PLANE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${CONTROL_PLANE_NODE}
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
  - name: node-ip
    value: "${CONTROL_PLANE_IP}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: ${version}
apiServer:
  certSANs:
  - ${CONTROL_PLANE_IP}
  - 127.0.0.1
  - localhost
  - konnectivity-server.kube-system.svc.cluster.local
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
EOF
)
  write_to_node "${CONTROL_PLANE_NODE}" /tmp/kubeadm-init.yaml "${config}"
  docker exec "${CONTROL_PLANE_NODE}" kubeadm init --config=/tmp/kubeadm-init.yaml --ignore-preflight-errors=all --skip-phases=addon/kube-proxy
}

kubeadm_join() {
  local node="$1"
  local ip="$2"
  local token="$3"
  local config
  config=$(cat <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: ${CONTROL_PLANE_IP}:6443
    token: ${token}
    unsafeSkipCAVerification: true
nodeRegistration:
  name: ${node}
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
  - name: node-ip
    value: "${ip}"
EOF
)
  write_to_node "${node}" /tmp/kubeadm-join.yaml "${config}"
  docker exec "${node}" kubeadm join --config=/tmp/kubeadm-join.yaml --ignore-preflight-errors=all
}

extract_kubeconfig() {
  docker cp "${CONTROL_PLANE_NODE}:/etc/kubernetes/admin.conf" "${KUBECONFIG_PATH}"
  sed "s#https://${CONTROL_PLANE_IP}:6443#https://127.0.0.1:${API_HOST_PORT}#g" "${KUBECONFIG_PATH}" > "${KUBECONFIG_PATH}.tmp"
  mv "${KUBECONFIG_PATH}.tmp" "${KUBECONFIG_PATH}"
  export KUBECONFIG="${KUBECONFIG_PATH}"
  log "Using kubeconfig ${KUBECONFIG_PATH}"
}

wait_for_nodes_registered() {
  local want="$1"
  local deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    local got
    got="$(kubectl get nodes --no-headers 2>/dev/null | awk 'NF { n++ } END { print n + 0 }')"
    log "Registered nodes: ${got}/${want}"
    if (( got >= want )); then
      return 0
    fi
    sleep 5
  done
  kubectl get nodes -o wide || true
  return 1
}

create_kubeadm_cluster() {
  log "Creating kubeadm cluster ${CLUSTER_NAME} with ${NODE_IMAGE}"
  create_node_network
  create_node_container "${CONTROL_PLANE_NODE}" "${CONTROL_PLANE_IP}"
  create_node_container "${WORKER1_NODE}" "${WORKER1_IP}"
  create_node_container "${WORKER2_NODE}" "${WORKER2_IP}"

  for node in "${NODE_NAMES[@]}"; do
    log "Waiting for containerd on ${node}"
    wait_for_containerd "${node}"
  done

  log "Running kubeadm init"
  kubeadm_init
  extract_kubeconfig

  local token
  token="$(docker exec "${CONTROL_PLANE_NODE}" kubeadm token create --ttl=0)"
  log "Joining worker nodes"
  kubeadm_join "${WORKER1_NODE}" "${WORKER1_IP}" "${token}"
  kubeadm_join "${WORKER2_NODE}" "${WORKER2_IP}" "${token}"

  wait_for_nodes_registered 3
  kubectl label node "${WORKER1_NODE}" pending-dial-worker=true --overwrite
  kubectl label node "${WORKER2_NODE}" pending-dial-worker=true --overwrite
  kubectl -n kube-system scale deployment/coredns --replicas=0 || true
}

load_image_to_node() {
  local image="$1"
  local node="$2"
  local safe
  safe="$(printf '%s' "${image}" | tr '/:' '__')"
  local tar_path="/tmp/${CLUSTER_NAME}-${safe}.tar"
  docker save -o "${tar_path}" "${image}"
  docker cp "${tar_path}" "${node}:/var/tmp/image.tar"
  docker exec "${node}" ctr -n=k8s.io images import --all-platforms /var/tmp/image.tar
  docker exec "${node}" rm -f /var/tmp/image.tar
  rm -f "${tar_path}"
}

load_images() {
  log "Loading local images into kubeadm node containerd stores"
  local image
  local node
  for image in "${SERVER_IMAGE}" "${AGENT_IMAGE}" "${TEST_CLIENT_IMAGE}" "${TEST_SERVER_IMAGE}"; do
    for node in "${NODE_NAMES[@]}"; do
      load_image_to_node "${image}" "${node}"
      log "Loaded ${image} into ${node}"
    done
  done
}

server_timeout_arg() {
  if [[ -n "${BACKEND_DIAL_TIMEOUT}" ]]; then
    printf '        - "--backend-dial-timeout=%s"\n' "${BACKEND_DIAL_TIMEOUT}"
  fi
}

install_konnectivity() {
  log "Installing konnectivity server in http-connect mode"
  cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:konnectivity-server
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: system:konnectivity-server
---
apiVersion: v1
kind: Service
metadata:
  name: konnectivity-server
  namespace: kube-system
spec:
  selector:
    k8s-app: konnectivity-server
  ports:
  - protocol: TCP
    port: 8091
    targetPort: 8091
    name: agent
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: konnectivity-server
  namespace: kube-system
  labels:
    k8s-app: konnectivity-server
spec:
  selector:
    matchLabels:
      k8s-app: konnectivity-server
  template:
    metadata:
      labels:
        k8s-app: konnectivity-server
    spec:
      hostNetwork: true
      priorityClassName: system-cluster-critical
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - operator: Exists
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      containers:
      - name: konnectivity-server-container
        image: ${SERVER_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/proxy-server"]
        args:
        - "--logtostderr=true"
        - "--uds-name=/etc/kubernetes/konnectivity-server/konnectivity-server.socket"
        - "--delete-existing-uds-file"
        - "--cluster-cert=/etc/kubernetes/pki/apiserver.crt"
        - "--cluster-key=/etc/kubernetes/pki/apiserver.key"
        - "--server-port=0"
        - "--agent-port=8091"
        - "--health-port=8092"
        - "--admin-port=8093"
        - "--admin-bind-address=0.0.0.0"
        - "--keepalive-time=1h"
        - "--mode=http-connect"
        - "--agent-namespace=kube-system"
        - "--agent-service-account=konnectivity-agent"
        - "--kubeconfig=/etc/kubernetes/admin.conf"
        - "--authentication-audience=system:konnectivity-server"
$(server_timeout_arg)
        ports:
        - name: agent
          containerPort: 8091
          hostPort: 8091
        - name: health
          containerPort: 8092
          hostPort: 8092
        - name: admin
          containerPort: 8093
          hostPort: 8093
        livenessProbe:
          httpGet:
            scheme: HTTP
            host: 127.0.0.1
            port: 8092
            path: /healthz
          initialDelaySeconds: 10
          timeoutSeconds: 60
        volumeMounts:
        - name: kubernetes
          mountPath: /etc/kubernetes
          readOnly: true
        - name: konnectivity-home
          mountPath: /etc/kubernetes/konnectivity-server
      volumes:
      - name: kubernetes
        hostPath:
          path: /etc/kubernetes
      - name: konnectivity-home
        hostPath:
          path: /etc/kubernetes/konnectivity-server
          type: DirectoryOrCreate
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: konnectivity-agent
  namespace: kube-system
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: konnectivity-agent
  namespace: kube-system
  labels:
    k8s-app: konnectivity-agent
spec:
  selector:
    matchLabels:
      k8s-app: konnectivity-agent
  template:
    metadata:
      labels:
        k8s-app: konnectivity-agent
    spec:
      hostNetwork: true
      dnsPolicy: Default
      priorityClassName: system-cluster-critical
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoSchedule
      - operator: Exists
        effect: NoExecute
      nodeSelector:
        kubernetes.io/os: linux
        pending-dial-worker: "true"
      serviceAccountName: konnectivity-agent
      containers:
      - name: konnectivity-agent-container
        image: ${AGENT_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/proxy-agent"]
        args:
        - "--logtostderr=true"
        - "--ca-cert=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        - "--proxy-server-host=${CONTROL_PLANE_IP}"
        - "--proxy-server-port=8091"
        - "--sync-interval=1s"
        - "--sync-interval-cap=5s"
        - "--sync-forever"
        - "--probe-interval=1s"
        - "--service-account-token-path=/var/run/secrets/tokens/konnectivity-agent-token"
        - "--agent-identifiers=ipv4=\$(HOST_IP)"
        env:
        - name: HOST_IP
          valueFrom:
            fieldRef:
              fieldPath: status.hostIP
        readinessProbe:
          httpGet:
            scheme: HTTP
            port: 8093
            path: /readyz
          initialDelaySeconds: 5
          timeoutSeconds: 5
        volumeMounts:
        - mountPath: /var/run/secrets/tokens
          name: konnectivity-agent-token
      volumes:
      - name: konnectivity-agent-token
        projected:
          sources:
          - serviceAccountToken:
              path: konnectivity-agent-token
              audience: system:konnectivity-server
EOF

  kubectl -n kube-system rollout status ds/konnectivity-server --timeout=120s
  kubectl -n kube-system rollout status ds/konnectivity-agent --timeout=120s
}

install_test_server() {
  log "Installing HTTP test server"
  cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pending-dial-http-server
  labels:
    app: pending-dial-http-server
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pending-dial-http-server
  template:
    metadata:
      labels:
        app: pending-dial-http-server
    spec:
      hostNetwork: true
      dnsPolicy: Default
      nodeSelector:
        kubernetes.io/os: linux
        pending-dial-worker: "true"
      tolerations:
      - key: node.kubernetes.io/not-ready
        operator: Exists
        effect: NoSchedule
      - operator: Exists
        effect: NoExecute
      containers:
      - name: http-test-server
        image: ${TEST_SERVER_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/http-test-server"]
        args: ["--server-bind-address=0.0.0.0", "--server-port=8000", "--logtostderr=true"]
        ports:
        - containerPort: 8000
EOF
  kubectl rollout status deployment/pending-dial-http-server --timeout=120s
}

test_server_ip() {
  kubectl get pod -l app=pending-dial-http-server -o jsonpath='{.items[0].status.hostIP}'
}

run_client_job() {
  local name="$1"
  local host="$2"
  local requests="$3"
  local deadline="$4"

  kubectl delete job "${name}" --ignore-not-found --wait=true >/dev/null
  cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
spec:
  backoffLimit: 0
  activeDeadlineSeconds: ${deadline}
  template:
    spec:
      restartPolicy: Never
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - key: CriticalAddonsOnly
        operator: Exists
      - operator: Exists
      containers:
      - name: proxy-test-client
        image: ${TEST_CLIENT_IMAGE}
        imagePullPolicy: IfNotPresent
        command: ["/proxy-test-client"]
        args:
        - "--logtostderr=true"
        - "--proxy-uds=/etc/kubernetes/konnectivity-server/konnectivity-server.socket"
        - "--proxy-host="
        - "--proxy-port=0"
        - "--mode=http-connect"
        - "--request-proto=http"
        - "--request-path=success"
        - "--request-host=${host}"
        - "--request-port=8000"
        - "--test-requests=${requests}"
        - "--test-delay=0"
        - "--close-idle-conn=true"
        volumeMounts:
        - name: konnectivity-home
          mountPath: /etc/kubernetes/konnectivity-server
      volumes:
      - name: konnectivity-home
        hostPath:
          path: /etc/kubernetes/konnectivity-server
          type: DirectoryOrCreate
EOF
}

wait_client_success() {
  local name="$1"
  if ! kubectl wait --for=condition=complete "job/${name}" --timeout=90s; then
    kubectl describe "job/${name}" || true
    kubectl logs "job/${name}" || true
    return 1
  fi
}

metric_value() {
  local metric="$1"
  curl -fsS "${METRICS_URL}" |
    awk -v metric="${metric}" '$1 == metric { value = int($2); found = 1 } END { if (found) print value; else print "0" }'
}

metric_counter_value() {
  local metric="$1"
  local label="$2"
  curl -fsS "${METRICS_URL}" |
    awk -v metric="${metric}" -v label="${label}" '$1 ~ ("^" metric "\\{") && $1 ~ label { value = int($2); found = 1 } END { if (found) print value; else print "0" }'
}

control_plane_node() {
  kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}'
}

drop_server_agent_packets() {
  log "Dropping konnectivity-agent <-> konnectivity-server TCP packets"
  local server_node
  server_node="$(control_plane_node)"
  mapfile -t pods < <(kubectl -n kube-system get pods -l k8s-app=konnectivity-agent -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ "${#pods[@]}" -eq 0 ]]; then
    echo "no konnectivity-agent pods found" >&2
    return 1
  fi

  for pod in "${pods[@]}"; do
    local node
    local agent_ip
    node="$(kubectl -n kube-system get pod "${pod}" -o jsonpath='{.spec.nodeName}')"
    agent_ip="$(kubectl -n kube-system get pod "${pod}" -o jsonpath='{.status.hostIP}')"
    if [[ -z "${agent_ip}" ]]; then
      echo "could not find host IP for ${pod}" >&2
      return 1
    fi
    docker exec "${node}" iptables -I OUTPUT 1 -s "${agent_ip}/32" -d "${CONTROL_PLANE_IP}/32" -p tcp --dport 8091 -j DROP
    dropped_agent_rules+=("${node}:${agent_ip}")
    docker exec "${server_node}" iptables -I OUTPUT 1 -s "${CONTROL_PLANE_IP}/32" -d "${agent_ip}/32" -p tcp --sport 8091 -j DROP
    dropped_server_rules+=("${server_node}:${agent_ip}")
    log "dropped ${pod} (${agent_ip}) <-> tcp/8091 between ${node} and ${server_node}"
  done
}

wait_pending_at_least() {
  local want="$1"
  local deadline=$((SECONDS + PENDING_RISE_TIMEOUT_SECONDS))
  local max_seen=0

  while (( SECONDS < deadline )); do
    local got
    got="$(metric_value konnectivity_network_proxy_server_pending_backend_dials)"
    if (( got > max_seen )); then
      max_seen="${got}"
    fi
    log "pending_backend_dials=${got} max_seen=${max_seen}"
    if (( got >= want )); then
      summary "- Pending backend dials rose to ${got} while server-agent packets were dropped."
      return 0
    fi
    sleep 1
  done

  echo "pending backend dials did not reach ${want}; max_seen=${max_seen}" >&2
  return 1
}

wait_pending_drained() {
  local deadline=$((SECONDS + DRAIN_TIMEOUT_SECONDS))

  while (( SECONDS < deadline )); do
    local got
    got="$(metric_value konnectivity_network_proxy_server_pending_backend_dials)"
    log "pending_backend_dials_after_clients_stopped=${got}"
    if (( got == 0 )); then
      summary "- Pending backend dials drained to 0 after clients stopped."
      return 0
    fi
    sleep 1
  done

  local final
  final="$(metric_value konnectivity_network_proxy_server_pending_backend_dials)"
  summary "- Pending backend dials remained at ${final} after clients stopped."
  echo "pending backend dials did not drain; final=${final}" >&2
  return 1
}

print_debug_state() {
  set +e
  log "Debug state"
  kubectl get pods -A -o wide
  kubectl -n kube-system logs -l k8s-app=konnectivity-server --tail=120
  curl -fsS "${METRICS_URL}" | grep -E 'pending_backend_dials|dial_failure_count' || true
  set -e
}

main() {
  summary "## kubeadm pending dial reproduction"
  summary "- Server mode: http-connect"
  if [[ -n "${BACKEND_DIAL_TIMEOUT}" ]]; then
    summary "- Backend dial timeout: ${BACKEND_DIAL_TIMEOUT}"
  else
    summary "- Backend dial timeout: not configured"
  fi

  create_kubeadm_cluster
  load_images
  install_konnectivity
  install_test_server

  local target_ip
  target_ip="$(test_server_ip)"
  log "Smoke request target pod IP: ${target_ip}"
  run_client_job pending-dial-smoke "${target_ip}" 1 60
  wait_client_success pending-dial-smoke
  summary "- Smoke HTTP CONNECT request succeeded before fault injection."

  drop_server_agent_packets

  local long_host
  printf -v long_host '%*s' "${CONNECT_HOST_BYTES}" ''
  long_host="${long_host// /a}"

  log "Starting ${LOAD_REQUESTS} HTTP CONNECT requests with ${CONNECT_HOST_BYTES}-byte authority"
  run_client_job pending-dial-load "${long_host}" "${LOAD_REQUESTS}" "${CLIENT_ACTIVE_DEADLINE_SECONDS}"
  wait_pending_at_least "${MIN_PENDING_DIALS}"

  log "Stopping client load"
  kubectl delete job pending-dial-load --ignore-not-found --wait=true >/dev/null

  if ! wait_pending_drained; then
    print_debug_state
    return 1
  fi

  if [[ -n "${BACKEND_DIAL_TIMEOUT}" ]]; then
    local timeout_count
    timeout_count="$(metric_counter_value konnectivity_network_proxy_server_dial_failure_count 'reason="backend_dial_timeout"')"
    log "backend_dial_timeout dial failures=${timeout_count}"
    if (( timeout_count == 0 )); then
      echo "expected backend_dial_timeout metric to be observed" >&2
      print_debug_state
      return 1
    fi
    summary "- backend_dial_timeout dial failure metric was observed: ${timeout_count}."
  fi
}

main "$@"
