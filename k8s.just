# Standalone justfile - intended to be invoked via:
#   just --justfile k8s.just --set cluster_name=my-app-test cluster-init
#
# Upstream repos should use a thin dispatcher pattern (see chart.just):
#   k8s *args:
#     @curl -sS https://raw.githubusercontent.com/hotosm/justfiles/main/k8s.just \
#       -o {{justfile_directory()}}/tasks/k8s.just;
#     @just --justfile {{justfile_directory()}}/tasks/k8s.just \
#       --set cluster_name my-app-test \
#       --set namespace argo \
#       {{args}}
#
# Provisions a local Talos-in-Docker Kubernetes cluster with Argo Workflows
# installed, for running end-to-end tests of tools that dispatch processing as
# Argo workflows (e.g. ScaleODM, OpenAerialMap). The module is self-contained:
# it installs its own tool prerequisites (curl, jq, talosctl, kubectl) so it can
# be curl-downloaded and run without any recipes from the calling Justfile.

# --- Configurable variables (override via `--set name value` or env) --------

# Talos cluster name (also the docker network name).
cluster_name := env("TALOS_CLUSTER_NAME", "local-test")
# Namespace Argo Workflows (and the workflow S3 secret) are installed into.
namespace := env("K8S_NAMESPACE", "argo")
# Argo Workflows release to install.
argo_version := env("ARGO_WORKFLOWS_VERSION", "v3.7.3")
# Argo install scope:
#   cluster   - cluster-wide install.yaml + a dedicated ServiceAccount bound to
#               the built-in `admin` ClusterRole (workflows may run in any ns).
#   namespace - namespace-install.yaml + a namespaced RoleBinding to `admin`
#               (workflows confined to {{namespace}}, no cluster-scoped RBAC).
argo_scope := "cluster"
# ServiceAccount created for workflow pods, and granted admin (see argo_scope).
service_account := "argo-odm"
# Comma-separated key=value labels applied to worker nodes so workflow pods that
# pin themselves to these labels (e.g. Karpenter node-type / capacity-type) can
# schedule on the single Docker-mode worker. Empty string disables labelling.
node_labels := "node-type=cpu,karpenter.sh/capacity-type=spot"
# Configure Argo to archive workflow pod logs to S3 ("true" | "false"). Requires
# the archive bucket to exist in the target S3. See archive_* variables below.
archive_logs := "true"

# Talos node sizing (Docker provider).
control_plane_memory := env("TALOS_CONTROL_PLANE_MEMORY", "2.0GiB")
worker_memory := env("TALOS_WORKER_MEMORY", "5.0GiB")
control_plane_cpus := env("TALOS_CONTROL_PLANE_CPUS", "1.0")
worker_cpus := env("TALOS_WORKER_CPUS", "2.0")

# Workflow S3 credentials secret. Name and values are overridable; the value
# defaults read the standard AWS_* env vars (defaults suit local RustFS/MinIO
# test stacks). The archived-logs feature also authenticates with this secret,
# so it must match the target S3's credentials.
secret_name := env("AWS_S3_SECRET_NAME", "workflow-s3-secrets")
s3_access_key := env("AWS_ACCESS_KEY_ID", "admin")
s3_secret_key := env("AWS_SECRET_ACCESS_KEY", "somelongpassword")
s3_region := env("AWS_DEFAULT_REGION", "us-east-1")

# Argo archived-logs S3 target. When archive_s3_endpoint is empty it is derived
# from the Talos docker network gateway IP + archive_s3_port (so in-cluster pods
# can reach a host-published S3 service).
archive_log_bucket := env("ARGO_ARCHIVE_LOG_BUCKET", "argo-logs")
archive_s3_endpoint := env("ARGO_ARCHIVE_S3_ENDPOINT", "")
archive_s3_port := env("ARGO_ARCHIVE_S3_PORT", "31102")
archive_s3_insecure := env("ARGO_ARCHIVE_S3_INSECURE", "true")

# Talos control-plane node IP in the Docker provider (stable default).
control_plane_ip := env("TALOS_CONTROL_PLANE_IP", "10.5.0.2")

_self := justfile()

# List available recipes. Kept as the first recipe so `just k8s` (no args, which
# passes no recipe through the dispatcher) lists rather than running the first
# recipe it finds - just uses the first recipe as the default, not the name.
[private]
default:
  @just --justfile {{_self}} --list

# --- Tool installers (self-contained, no parent Justfile needed) ------------

[private]
[no-cd]
_install-curl:
  #!/usr/bin/env bash
  set -e
  command -v curl &> /dev/null && exit 0
  echo "📦 Installing curl..."
  if command -v apt-get &> /dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y curl
  elif command -v yum &> /dev/null; then
      sudo yum install -y curl
  elif command -v apk &> /dev/null; then
      sudo apk add --no-cache curl
  else
      echo "❌ curl is not installed and no supported package manager found"; exit 1
  fi

[private]
[no-cd]
_install-jq:
  #!/usr/bin/env bash
  set -e
  command -v jq &> /dev/null && exit 0
  echo "📦 Installing jq..."
  if command -v apt-get &> /dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y jq
  elif command -v yum &> /dev/null; then
      sudo yum install -y jq
  elif command -v apk &> /dev/null; then
      sudo apk add --no-cache jq
  else
      echo "❌ jq is not installed and no supported package manager found"; exit 1
  fi

[private]
[no-cd]
_install-talosctl:
  #!/usr/bin/env bash
  set -e
  command -v talosctl &> /dev/null && exit 0
  echo "📦 Installing talosctl..."
  curl -sL https://talos.dev/install | sh
  [ -f "$HOME/.local/bin/talosctl" ] && export PATH="$HOME/.local/bin:$PATH"
  command -v talosctl &> /dev/null || { echo "❌ Failed to install talosctl"; exit 1; }

[private]
[no-cd]
_install-kubectl:
  #!/usr/bin/env bash
  set -e
  command -v kubectl &> /dev/null && exit 0
  echo "📦 Installing kubectl..."
  KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64/kubectl"
  chmod +x kubectl
  if sudo mv kubectl /usr/local/bin/kubectl 2>/dev/null; then
      echo "✓ kubectl installed to /usr/local/bin"
  else
      mkdir -p "$HOME/.local/bin"; mv kubectl "$HOME/.local/bin/kubectl"
      export PATH="$HOME/.local/bin:$PATH"
      echo "✓ kubectl installed to ~/.local/bin"
  fi
  command -v kubectl &> /dev/null || { echo "❌ Failed to install kubectl"; exit 1; }

[private]
[no-cd]
_install-tools: _install-curl _install-jq _install-talosctl _install-kubectl

# --- Cluster reachability ---------------------------------------------------

# Check whether a Kubernetes cluster is reachable (exit 0 if so). Private.
[private]
[no-cd]
_check-cluster:
  #!/usr/bin/env bash
  set +e
  T="${KUBECTL_TIMEOUT:-5s}"
  command -v kubectl &> /dev/null || exit 1
  kubectl --request-timeout="$T" cluster-info &> /dev/null || exit 1
  kubectl --request-timeout="$T" get nodes &> /dev/null || exit 1
  exit 0

# Print the Talos docker network gateway IP (host address reachable from pods).
[no-cd]
gateway-ip:
  #!/usr/bin/env bash
  set -euo pipefail
  just --justfile {{_self}} _install-jq >/dev/null 2>&1 || true
  docker network inspect "{{cluster_name}}" 2>/dev/null \
    | jq -r '.[0].IPAM.Config[0].Gateway // ""' 2>/dev/null || true

# Runs as ordered dependencies (status report, then the idempotent init) rather
# than a nested `just --justfile` call, so the caller's `--set` overrides
# propagate to cluster-init - a fresh nested invocation would reset them to
# their defaults.
# Ensure a cluster is available, initialising/reconciling one if needed.
[no-cd]
cluster-available: _report-cluster-status cluster-init

# Report current cluster reachability (informational; never fails the build).
[private]
[no-cd]
_report-cluster-status:
  #!/usr/bin/env bash
  set +e
  echo "Checking for Kubernetes cluster..."
  if KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-5s}" just --justfile {{_self}} _check-cluster; then
      echo "✓ Kubernetes cluster is available; reconciling prerequisites..."
  else
      echo "⚠️  Kubernetes cluster not available; initialising (this may take a few minutes)..."
  fi

# --- Cluster provisioning ---------------------------------------------------

# _install-tools runs first (same invocation) to ensure curl/jq/talosctl/kubectl.
# Setup Talos Kubernetes cluster + Argo Workflows for testing (idempotent).
[no-cd]
cluster-init: _install-tools
  #!/usr/bin/env bash
  set -e

  CLUSTER_NAME="{{cluster_name}}"
  NAMESPACE="{{namespace}}"
  ARGO_VERSION="{{argo_version}}"
  ARGO_SCOPE="{{argo_scope}}"
  SERVICE_ACCOUNT="{{service_account}}"
  NODE_LABELS="{{node_labels}}"
  ARCHIVE_LOGS="{{archive_logs}}"
  WORKER_MEMORY="{{worker_memory}}"
  CONTROL_PLANE_MEMORY="{{control_plane_memory}}"
  WORKER_CPUS="{{worker_cpus}}"
  CONTROL_PLANE_CPUS="{{control_plane_cpus}}"
  CP_IP="{{control_plane_ip}}"

  WORKFLOW_S3_SECRET_NAME="{{secret_name}}"
  WORKFLOW_S3_ACCESS_KEY="{{s3_access_key}}"
  WORKFLOW_S3_SECRET_KEY="{{s3_secret_key}}"
  WORKFLOW_S3_REGION="{{s3_region}}"

  ARGO_ARCHIVE_LOG_BUCKET="{{archive_log_bucket}}"
  ARGO_ARCHIVE_S3_ENDPOINT="{{archive_s3_endpoint}}"
  ARGO_ARCHIVE_S3_PORT="{{archive_s3_port}}"
  ARGO_ARCHIVE_S3_INSECURE="{{archive_s3_insecure}}"

  # Resolve the Argo install manifest for the requested scope.
  case "$ARGO_SCOPE" in
      cluster)   ARGO_MANIFEST="install.yaml" ;;
      namespace) ARGO_MANIFEST="namespace-install.yaml" ;;
      *) echo "❌ argo_scope must be 'cluster' or 'namespace', got '$ARGO_SCOPE'"; exit 1 ;;
  esac
  ARGO_URL="https://github.com/argoproj/argo-workflows/releases/download/${ARGO_VERSION}/${ARGO_MANIFEST}"

  # Bind the workflow ServiceAccount to the built-in `admin` role. Cluster scope
  # uses a ClusterRoleBinding (workflows may run in any namespace); namespace
  # scope uses a namespaced RoleBinding (no cluster-scoped RBAC granted).
  bind_service_account() {
      kubectl create serviceaccount "$SERVICE_ACCOUNT" -n "$NAMESPACE" \
          --dry-run=client -o yaml | kubectl apply -f - &> /dev/null
      if [ "$ARGO_SCOPE" = "cluster" ]; then
          kubectl create clusterrolebinding "${SERVICE_ACCOUNT}-admin" \
              --clusterrole=admin --serviceaccount="$NAMESPACE:$SERVICE_ACCOUNT" \
              --dry-run=client -o yaml | kubectl apply -f - &> /dev/null
      else
          kubectl create rolebinding "${SERVICE_ACCOUNT}-admin" -n "$NAMESPACE" \
              --clusterrole=admin --serviceaccount="$NAMESPACE:$SERVICE_ACCOUNT" \
              --dry-run=client -o yaml | kubectl apply -f - &> /dev/null
      fi
  }

  # (Re)create the workflow S3 credentials secret read by workflow pods.
  apply_s3_secret() {
      kubectl create secret generic "$WORKFLOW_S3_SECRET_NAME" -n "$NAMESPACE" \
          --from-literal=AWS_ACCESS_KEY_ID="$WORKFLOW_S3_ACCESS_KEY" \
          --from-literal=AWS_SECRET_ACCESS_KEY="$WORKFLOW_S3_SECRET_KEY" \
          --from-literal=AWS_DEFAULT_REGION="$WORKFLOW_S3_REGION" \
          --dry-run=client -o yaml | kubectl apply -f - &> /dev/null
  }

  # Label worker nodes so pods pinned to these labels can schedule on the single
  # Docker-mode worker (which otherwise has no Karpenter-style labels, leaving
  # such pods Pending with "didn't match Pod's node affinity/selector").
  label_workflow_nodes() {
      [ -z "$NODE_LABELS" ] && return 0
      local workers
      workers=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name 2>/dev/null || true)
      if [ -z "$workers" ]; then
          echo "⚠️  No worker nodes found to label; skipping workflow node labels"; return 0
      fi
      echo "📦 Labeling worker nodes for workflow scheduling ($NODE_LABELS)..."
      local labels_spaced="${NODE_LABELS//,/ }"
      while IFS= read -r node; do
          [ -z "$node" ] && continue
          kubectl label "$node" $labels_spaced --overwrite >/dev/null
      done <<< "$workers"
      echo "✓ Worker nodes labeled"
  }

  # Point Argo's workflow-controller at an S3 bucket for archived pod logs.
  configure_argo_archive_logs() {
      [ "$ARCHIVE_LOGS" = "true" ] || return 0
      local endpoint="$ARGO_ARCHIVE_S3_ENDPOINT"
      if [ -z "$endpoint" ]; then
          local gw
          gw=$(docker network inspect "$CLUSTER_NAME" 2>/dev/null | jq -r '.[0].IPAM.Config[0].Gateway // ""' 2>/dev/null || true)
          [ -z "$gw" ] && gw="host.docker.internal"
          endpoint="http://${gw}:${ARGO_ARCHIVE_S3_PORT}"
      fi
      local hostport="${endpoint#http://}"; hostport="${hostport#https://}"
      echo "📦 Configuring Argo archived logs (s3://${ARGO_ARCHIVE_LOG_BUCKET} @ ${hostport})..."
      kubectl apply -n "$NAMESPACE" -f - <<EOF
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: workflow-controller-configmap
  data:
    config: |
      artifactRepository:
        archiveLogs: true
        s3:
          bucket: ${ARGO_ARCHIVE_LOG_BUCKET}
          endpoint: ${hostport}
          insecure: ${ARGO_ARCHIVE_S3_INSECURE}
          keyFormat: "{{ "{{" }}workflow.namespace{{ "}}" }}/{{ "{{" }}workflow.name{{ "}}" }}/{{ "{{" }}pod.name{{ "}}" }}"
          accessKeySecret:
            name: ${WORKFLOW_S3_SECRET_NAME}
            key: AWS_ACCESS_KEY_ID
          secretKeySecret:
            name: ${WORKFLOW_S3_SECRET_NAME}
            key: AWS_SECRET_ACCESS_KEY
      workflowDefaults:
        spec:
          archiveLogs: true
  EOF
      kubectl rollout restart deployment/workflow-controller -n "$NAMESPACE" >/dev/null 2>&1 || true
      echo "✓ Argo archived logs configured"
  }

  echo "🚀 Setting up Talos cluster '$CLUSTER_NAME' (namespace: $NAMESPACE, argo scope: $ARGO_SCOPE)"
  echo "   Control plane: ${CONTROL_PLANE_CPUS} CPU / ${CONTROL_PLANE_MEMORY}, worker: ${WORKER_CPUS} CPU / ${WORKER_MEMORY}"
  echo ""

  # br_netfilter is required for Flannel networking in the Docker provider.
  if ! lsmod | grep -q "^br_netfilter"; then
      echo "📦 Loading br_netfilter kernel module..."
      sudo modprobe br_netfilter 2>/dev/null \
          && echo "✓ br_netfilter loaded" \
          || echo "⚠️  Could not load br_netfilter; k8s networking in Docker may fail"
  else
      echo "✓ br_netfilter already loaded"
  fi

  # Fast path: detect an already-provisioned, accessible cluster and only
  # reconcile the prerequisites (idempotent), avoiding a needless recreate.
  CLUSTER_SHOW_OUTPUT=$(talosctl cluster show --name "$CLUSTER_NAME" 2>/dev/null || echo "")
  if [ -n "$CLUSTER_SHOW_OUTPUT" ]; then
      CURRENT_CLUSTER=$(echo "$CLUSTER_SHOW_OUTPUT" | grep "^NAME" | awk '{print $2}' | head -1 | tr -d '\n\r' || echo "")
      NODE_COUNT=$(echo "$CLUSTER_SHOW_OUTPUT" | grep -E "^[a-z].*-.*(controlplane|worker)" | wc -l | tr -d '[:space:]')
      if [ -z "$NODE_COUNT" ] || ! [ "$NODE_COUNT" -ge 0 ] 2>/dev/null; then
          NODE_COUNT=0
      fi

      # A different cluster is running - refuse rather than clobber it.
      if [ -n "$CURRENT_CLUSTER" ] && [ "$NODE_COUNT" -gt 0 ] && [ "$CURRENT_CLUSTER" != "$CLUSTER_NAME" ]; then
          echo "❌ A different cluster '$CURRENT_CLUSTER' is running (expected '$CLUSTER_NAME')"
          echo "   Destroy it or set TALOS_CLUSTER_NAME=$CURRENT_CLUSTER"
          exit 1
      fi

      if [ -n "$CURRENT_CLUSTER" ] && [ "$CURRENT_CLUSTER" = "$CLUSTER_NAME" ] && [ "$NODE_COUNT" -gt 0 ]; then
          if ! kubectl cluster-info &> /dev/null || ! kubectl get nodes &> /dev/null; then
              echo "❌ Cluster '$CLUSTER_NAME' exists but is not accessible via kubectl"
              exit 1
          fi
          echo "✓ Cluster '$CLUSTER_NAME' found and accessible"
          kubectl get namespace "$NAMESPACE" &> /dev/null \
              && echo "✓ Namespace '$NAMESPACE' exists" \
              || echo "⚠️  Namespace '$NAMESPACE' missing, will create"

          if kubectl get crd workflows.argoproj.io &> /dev/null && kubectl get namespace "$NAMESPACE" &> /dev/null; then
              echo "✓ Argo Workflows CRD exists"
              echo ""
              echo "✅ Cluster already configured - reconciling prerequisites..."
              echo "📦 Verifying service account and RBAC..."
              bind_service_account
              echo "✓ Service account and RBAC verified"
              echo "📦 Verifying workflow S3 credentials secret..."
              apply_s3_secret
              echo "✓ Workflow S3 credentials secret verified"
              label_workflow_nodes
              configure_argo_archive_logs
              echo ""
              exit 0
          fi
          echo "⚠️  Argo Workflows not fully installed, continuing setup..."
      fi
  fi

  echo "📦 Creating Talos cluster '$CLUSTER_NAME'..."
  # Lower kubelet eviction thresholds so the Docker provider does not
  # false-positive disk-pressure taints (containers inherit host disk but may
  # report limited space). Strategic merge patch - JSON6902 is unsupported for
  # Talos multi-document machine config.
  KUBELET_PATCH=$'machine:\n  kubelet:\n    extraConfig:\n      evictionHard:\n        nodefs.available: "5%"\n        imagefs.available: "5%"'

  talosctl cluster create docker \
    --name "$CLUSTER_NAME" \
    --workers 1 \
    --memory-controlplanes "${CONTROL_PLANE_MEMORY}" \
    --memory-workers "${WORKER_MEMORY}" \
    --cpus-controlplanes "${CONTROL_PLANE_CPUS}" \
    --cpus-workers "${WORKER_CPUS}" \
    --config-patch "$KUBELET_PATCH"

  echo "📦 Merging kubeconfig from cluster..."
  talosctl kubeconfig --nodes "$CP_IP" --force

  echo "⏳ Waiting for nodes to be ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=5m || echo "⚠️  Some nodes may not be ready yet"
  echo "⏳ Waiting for CoreDNS to be ready..."
  kubectl wait --for=condition=Ready pod -l k8s-app=kube-dns -n kube-system --timeout=10m || echo "⚠️  CoreDNS may not be ready yet"

  echo ""
  echo "✓ Talos cluster created (context: $(kubectl config current-context))"
  echo ""

  kubectl get namespace "$NAMESPACE" &> /dev/null || {
      echo "📦 Creating namespace: $NAMESPACE"; kubectl create namespace "$NAMESPACE"; }

  if ! kubectl get crd workflows.argoproj.io &> /dev/null; then
      echo "📦 Installing Argo Workflows $ARGO_VERSION ($ARGO_SCOPE scope)..."
      kubectl apply -n "$NAMESPACE" -f "$ARGO_URL"
      echo "⏳ Waiting for Argo Workflows to be ready..."
      kubectl wait --for=condition=ready pod -l app=workflow-controller -n "$NAMESPACE" --timeout=5m || true
      kubectl wait --for=condition=ready pod -l app=argo-server -n "$NAMESPACE" --timeout=5m || true
  else
      echo "✓ Argo Workflows already installed"
  fi

  echo "📦 Setting up workflow service account and RBAC..."
  bind_service_account
  echo "📦 Setting up workflow S3 credentials secret..."
  apply_s3_secret
  label_workflow_nodes
  configure_argo_archive_logs

  echo ""
  echo "✅ Talos cluster setup complete!"
  echo "   Nodes:  kubectl get nodes"
  echo "   Argo:   kubectl get pods -n $NAMESPACE"
  echo "   Destroy: just k8s cluster-destroy"

# Destroy the Talos test cluster and clean up docker/talos/kube state.
[no-cd]
cluster-destroy:
  #!/usr/bin/env bash
  set -e
  CLUSTER_NAME="{{cluster_name}}"

  echo "Destroying Talos cluster: $CLUSTER_NAME"
  talosctl cluster destroy --name "$CLUSTER_NAME" || true

  echo "Cleaning up leftover Docker resources..."
  LEFTOVER=$(docker ps -a --filter "name=${CLUSTER_NAME}" -q 2>/dev/null || true)
  if [ -n "$LEFTOVER" ]; then
      docker rm -f $LEFTOVER && echo "  Removed leftover containers"
  fi
  docker network rm "$CLUSTER_NAME" 2>/dev/null && echo "  Removed leftover network" || true

  TALOS_STATE_DIR="${HOME}/.talos/clusters/${CLUSTER_NAME}"
  if [ -d "$TALOS_STATE_DIR" ]; then
      rm -rf "$TALOS_STATE_DIR" && echo "  Removed state directory: $TALOS_STATE_DIR"
  fi

  talosctl config remove "$CLUSTER_NAME" 2>/dev/null || true
  kubectl config delete-context "admin@$CLUSTER_NAME" 2>/dev/null || true
  kubectl config delete-cluster "$CLUSTER_NAME" 2>/dev/null || true
  kubectl config delete-user "admin@$CLUSTER_NAME" 2>/dev/null || true
  # Clean up any renamed contexts (e.g. my-app-test-2, my-app-test-3).
  for ctx in $(talosctl config contexts 2>/dev/null | grep "^${CLUSTER_NAME}-[0-9]" || true); do
      talosctl config remove "$ctx" 2>/dev/null || true
  done

  echo "Cluster destroyed"
