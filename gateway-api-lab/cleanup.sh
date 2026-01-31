#!/bin/bash
# =============================================================================
# Kubernetes Gateway API Lab - Cleanup Script
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
# 1. Deletes the KIND cluster (removes all Docker containers)
# 2. Removes /etc/hosts entries for local.dev
#
# This completely removes the lab environment from your machine.
#
# =============================================================================

set -e

CLUSTER_NAME="gateway-api-lab"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }

echo "=============================================="
echo "Kubernetes Gateway API Lab Cleanup"
echo "=============================================="
echo ""

# Delete KIND cluster
info "Deleting KIND cluster: $CLUSTER_NAME"
info "This removes all Kubernetes resources and Docker containers"
kind delete cluster --name $CLUSTER_NAME 2>/dev/null || true
success "KIND cluster deleted!"

# Remove /etc/hosts entries
info "Removing /etc/hosts entries..."
if grep -q "local.dev" /etc/hosts; then
    # macOS and Linux have different sed syntax
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS requires '' after -i
        sudo sed -i '' '/local.dev/d' /etc/hosts
    else
        # Linux
        sudo sed -i '/local.dev/d' /etc/hosts
    fi
    success "Host entries removed!"
else
    info "No host entries found."
fi

echo ""
success "Cleanup complete!"
echo ""
echo "To start fresh, run: ./setup.sh"
