#!/bin/bash
# =============================================================================
# Kubernetes Gateway API Lab - Automated Setup Script
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
# 1. Creates a 3-node Kubernetes cluster using KIND (Docker containers)
# 2. Installs Cilium as the network fabric (CNI)
# 3. Installs MetalLB to provide external IPs (like a cloud provider would)
# 4. Installs Gateway API CRDs (the standard definitions)
# 5. Installs Envoy Gateway (the actual load balancer implementation)
# 6. Creates a TLS certificate and Gateway resource
# 7. Deploys a sample web application
# 8. Configures routing (HTTPRoute)
#
# PREREQUISITES:
# - Docker Desktop or Docker Engine (running)
# - kubectl (Kubernetes CLI)
# - kind (Kubernetes IN Docker)
# - helm (Package manager for K8s)
# - cilium CLI
#
# Works on: macOS (Intel/Apple Silicon) and Linux
#
# =============================================================================

set -e  # Exit on any error

# Colors for output (makes logs easier to read)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Version Configuration
# These are pinned to known-working versions for reproducibility
CLUSTER_NAME="gateway-api-lab"
CILIUM_VERSION="1.16.5"
METALLB_VERSION="v0.14.9"
GATEWAY_API_VERSION="v1.2.1"
ENVOY_GATEWAY_VERSION="v1.2.6"

# Helper functions for formatted output
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# =============================================================================
# Step 1: Check Prerequisites
# =============================================================================
check_prerequisites() {
    info "Checking prerequisites..."

    # Verify all required tools are installed
    command -v docker >/dev/null 2>&1 || error "Docker is required but not installed."
    command -v kubectl >/dev/null 2>&1 || error "kubectl is required but not installed."
    command -v kind >/dev/null 2>&1 || error "kind is required but not installed."
    command -v helm >/dev/null 2>&1 || error "helm is required but not installed."
    command -v cilium >/dev/null 2>&1 || error "cilium CLI is required but not installed."

    # Check Docker daemon is running
    docker info >/dev/null 2>&1 || error "Docker is not running. Please start Docker."

    success "All prerequisites met!"
}

# =============================================================================
# Step 2: Create KIND Cluster
# Creates a 3-node cluster (1 control-plane + 2 workers) in Docker
# Think of this as provisioning 3 virtual servers
# =============================================================================
create_cluster() {
    info "Creating KIND cluster: $CLUSTER_NAME"
    info "This creates 3 Docker containers that act as Kubernetes nodes"

    # Remove existing cluster if present (clean slate)
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "Cluster $CLUSTER_NAME already exists. Deleting..."
        kind delete cluster --name $CLUSTER_NAME
    fi

    # Create cluster from config file
    kind create cluster --config=01-kind-config.yaml
    success "KIND cluster created!"
}

# =============================================================================
# Step 3: Install Cilium CNI
# Cilium provides pod networking using eBPF (faster than iptables)
# Think of it as the "network switches" connecting your pods
# =============================================================================
install_cilium() {
    info "Installing Cilium CNI v$CILIUM_VERSION..."
    info "Cilium will handle all networking between pods (containers)"

    cilium install \
        --version $CILIUM_VERSION \
        --set kubeProxyReplacement=true \
        --set k8sServiceHost=${CLUSTER_NAME}-control-plane \
        --set k8sServicePort=6443

    info "Waiting for Cilium to be ready (this may take 1-2 minutes)..."
    cilium status --wait

    success "Cilium installed!"
}

# =============================================================================
# Step 4: Install MetalLB
# MetalLB provides LoadBalancer IPs in environments without cloud provider
# Think of it as your "IP address pool" for virtual IPs
# =============================================================================
install_metallb() {
    info "Installing MetalLB $METALLB_VERSION..."
    info "MetalLB will assign external IPs to LoadBalancer services"

    # Install MetalLB components
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml

    info "Waiting for MetalLB pods to be ready..."
    kubectl wait --namespace metallb-system \
        --for=condition=ready pod \
        --selector=app=metallb \
        --timeout=120s

    # Auto-detect KIND network and configure IP pool
    info "Configuring MetalLB IP pool based on Docker network..."

    # Get the Docker network subnet used by KIND
    KIND_NET_CIDR=$(docker network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' | head -1)
    KIND_NET_PREFIX=$(echo $KIND_NET_CIDR | cut -d. -f1-2)

    info "Detected KIND network: $KIND_NET_CIDR"
    info "Using IP range: ${KIND_NET_PREFIX}.255.200-${KIND_NET_PREFIX}.255.250"

    # Create MetalLB config with dynamic IP range
    cat > /tmp/metallb-config.yaml <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
    - ${KIND_NET_PREFIX}.255.200-${KIND_NET_PREFIX}.255.250
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - kind-pool
EOF

    kubectl apply -f /tmp/metallb-config.yaml
    rm /tmp/metallb-config.yaml

    success "MetalLB installed and configured!"
}

# =============================================================================
# Step 5: Install Gateway API CRDs
# CRDs = Custom Resource Definitions (new types of K8s objects)
# This adds GatewayClass, Gateway, HTTPRoute, etc. to your cluster
# =============================================================================
install_gateway_api_crds() {
    info "Installing Gateway API CRDs $GATEWAY_API_VERSION..."
    info "This adds the standard Gateway API resource types to Kubernetes"

    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml

    success "Gateway API CRDs installed!"
}

# =============================================================================
# Step 6: Install Envoy Gateway
# Envoy Gateway is the controller that implements the Gateway API
# It watches for Gateway/HTTPRoute resources and configures Envoy proxies
# =============================================================================
install_envoy_gateway() {
    info "Installing Envoy Gateway $ENVOY_GATEWAY_VERSION..."
    info "Envoy Gateway watches your configs and manages Envoy proxies"

    # Install via Helm, skip CRDs since we installed them in Step 5
    helm install eg oci://docker.io/envoyproxy/gateway-helm \
        --version $ENVOY_GATEWAY_VERSION \
        -n envoy-gateway-system \
        --create-namespace \
        --skip-crds

    info "Waiting for Envoy Gateway controller to be ready..."
    kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

    # Create GatewayClass (required when using --skip-crds)
    # GatewayClass = "which vendor's load balancer to use"
    info "Creating GatewayClass 'eg' for Envoy Gateway..."
    kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
EOF

    # Wait for GatewayClass to be accepted by the controller
    sleep 2
    kubectl wait --timeout=60s gatewayclass/eg --for=condition=Accepted

    success "Envoy Gateway installed!"
}

# =============================================================================
# Step 7: Deploy Gateway Resource
# The Gateway is your "load balancer VIP" - it listens on ports 80 and 443
# IMPORTANT: We create the TLS certificate FIRST, then the Gateway
# =============================================================================
deploy_gateway() {
    info "Creating TLS certificate for HTTPS..."
    info "This is a self-signed cert for local testing"

    # Generate self-signed certificate
    # -x509: Create self-signed cert (no CA needed)
    # -nodes: No password on the private key
    # -days 365: Valid for 1 year
    # -subj: Certificate subject (CN = Common Name)
    # -addext: Add Subject Alternative Names (SANs) for multiple domains
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /tmp/tls.key -out /tmp/tls.crt \
        -subj "/CN=*.local.dev" \
        -addext "subjectAltName=DNS:*.local.dev,DNS:localhost" 2>/dev/null

    # Create Kubernetes Secret from the certificate
    # The Gateway will reference this secret for TLS termination
    kubectl create secret tls eg-tls-cert \
        --cert=/tmp/tls.crt \
        --key=/tmp/tls.key \
        -n envoy-gateway-system 2>/dev/null || true

    # Clean up temp files
    rm -f /tmp/tls.key /tmp/tls.crt

    info "Deploying Gateway resource (ports 80 and 443)..."
    kubectl apply -f 03-gateway.yaml

    info "Waiting for Gateway to get an external IP and be ready..."
    kubectl wait --timeout=5m -n envoy-gateway-system gateway/eg-gateway --for=condition=Programmed

    success "Gateway deployed!"
}

# =============================================================================
# Step 8: Deploy Sample Application
# Deploys two versions of a simple web app:
# - Stable (3 replicas): Returns "Hello from Gateway API!"
# - Canary (1 replica): Returns "CANARY VERSION!"
# =============================================================================
deploy_app() {
    info "Deploying sample web application..."
    info "Creating 'demo-app' namespace with stable and canary versions"

    kubectl apply -f 04-webapp.yaml
    kubectl apply -f 05-webapp-canary.yaml

    info "Waiting for application pods to be ready..."
    kubectl wait --timeout=120s -n demo-app deployment/webapp --for=condition=Available
    kubectl wait --timeout=120s -n demo-app deployment/webapp-canary --for=condition=Available

    success "Sample application deployed!"
}

# =============================================================================
# Step 9: Deploy HTTPRoute
# HTTPRoute connects the Gateway to the application
# It defines: "requests to webapp.local.dev go to webapp-service"
# =============================================================================
deploy_httproute() {
    info "Deploying HTTPRoute (routing rules)..."
    info "This tells the Gateway where to send incoming requests"

    kubectl apply -f 06-httproute-basic.yaml

    success "HTTPRoute deployed!"
}

# =============================================================================
# Step 10: Configure /etc/hosts
# Maps the Gateway IP to human-readable hostnames
# This lets you use: curl http://webapp.local.dev/
# =============================================================================
configure_hosts() {
    info "Configuring /etc/hosts for local testing..."

    # Get the Gateway's external IP (assigned by MetalLB)
    GATEWAY_IP=$(kubectl get gateway/eg-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}')

    if [ -z "$GATEWAY_IP" ]; then
        warn "Could not get Gateway IP. You may need to configure /etc/hosts manually."
        return
    fi

    # Check if entries already exist
    if grep -q "webapp.local.dev" /etc/hosts; then
        warn "Host entries already exist. Skipping..."
    else
        echo "Adding entries to /etc/hosts (requires sudo)..."
        echo "$GATEWAY_IP webapp.local.dev api.local.dev" | sudo tee -a /etc/hosts
    fi

    success "Hosts configured!"
}

# =============================================================================
# Final Status Output
# Shows what was created and how to test it
# =============================================================================
print_status() {
    echo ""
    echo "=============================================="
    echo -e "${GREEN}Gateway API Lab Setup Complete!${NC}"
    echo "=============================================="
    echo ""

    GATEWAY_IP=$(kubectl get gateway/eg-gateway -n envoy-gateway-system -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)

    echo "Gateway IP: $GATEWAY_IP"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test Commands:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  # HTTP test (if /etc/hosts configured):"
    echo "  curl http://webapp.local.dev/"
    echo ""
    echo "  # HTTP test (using Host header):"
    echo "  curl -H 'Host: webapp.local.dev' http://$GATEWAY_IP/"
    echo ""
    echo "  # HTTPS test (self-signed cert, use -k to skip verification):"
    echo "  curl -k https://webapp.local.dev/"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "View Resources:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  kubectl get gatewayclass,gateway,httproute -A"
    echo "  kubectl get pods -n envoy-gateway-system"
    echo "  kubectl get pods -n demo-app"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Advanced Routing Examples:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  # Traffic splitting (90% stable, 10% canary):"
    echo "  kubectl apply -f 07-httproute-canary.yaml"
    echo ""
    echo "  # Header-based routing (X-Canary: true → canary):"
    echo "  kubectl apply -f 08-httproute-header.yaml"
    echo ""
}

# =============================================================================
# Main Execution
# Runs all steps in order
# =============================================================================
main() {
    echo "=============================================="
    echo "Kubernetes Gateway API Lab Setup"
    echo "=============================================="
    echo ""
    echo "This script will create a complete Gateway API lab environment."
    echo "Estimated time: 5-10 minutes"
    echo ""

    check_prerequisites
    create_cluster
    install_cilium
    install_metallb
    install_gateway_api_crds
    install_envoy_gateway
    deploy_gateway
    deploy_app
    deploy_httproute
    configure_hosts
    print_status
}

# Run main function
main "$@"
