#!/usr/bin/env bash
# register-editors.sh — register the che-android-studio editors in an Eclipse
# Che / OpenShift Dev Spaces install.
#
# A "selectable editor" is a Devfile stored in a ConfigMap in the Che namespace
# labeled:
#   app.kubernetes.io/part-of=che.eclipse.org
#   app.kubernetes.io/component=editor-definition
# The dashboard reads these and serves them at /dashboard/api/editors, so they
# appear in the editor dropdown on the "Create Workspace" page.
#
# This script wraps each bare editor-definition devfile in deploy/ into such a
# labeled ConfigMap and applies it to your Che namespace. It also applies the
# getting-started sample cards.
#
# Namespace: pass -n <ns>, or let the script auto-detect (CheCluster CR's
# namespace, else the first of eclipse-che / openshift-devspaces / che that
# exists). Works on both upstream Che and OpenShift Dev Spaces.
#
# Idempotent: re-running just re-applies. Requires kubectl with access to the
# target cluster.
#
# Usage:
#   ./hack/register-editors.sh                 # auto-detect namespace
#   ./hack/register-editors.sh -n eclipse-che  # explicit namespace
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="${REPO_ROOT}/deploy"
NAMESPACE=""

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
error() { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [-n <che-namespace>]

  -n   Che namespace to register the editors in. If omitted, the script
       auto-detects it (CheCluster CR namespace, else eclipse-che /
       openshift-devspaces / che, whichever exists).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage; error "Unknown flag: $1" ;;
    esac
done

command -v kubectl >/dev/null 2>&1 || error "kubectl not found in PATH."

# --- Auto-detect the Che namespace ------------------------------------------
detect_namespace() {
    # Prefer the namespace the CheCluster CR lives in (works on any install).
    local ns
    ns="$(kubectl get checluster -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
    if [ -n "${ns}" ]; then echo "${ns}"; return 0; fi
    # Fall back to well-known namespaces.
    for cand in eclipse-che openshift-devspaces che; do
        if kubectl get namespace "${cand}" >/dev/null 2>&1; then echo "${cand}"; return 0; fi
    done
    return 1
}

if [ -z "${NAMESPACE}" ]; then
    if NAMESPACE="$(detect_namespace)"; then
        info "Auto-detected Che namespace: ${NAMESPACE}"
    else
        error "Could not auto-detect the Che namespace. Pass -n <namespace>."
    fi
fi

kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1 \
    || error "Namespace '${NAMESPACE}' not found."

# --- Register each editor definition as a labeled ConfigMap -----------------
register_editor() {
    local name="$1" file="$2"
    [ -r "${file}" ] || error "Editor definition not found: ${file}"
    info "Registering editor '${name}' from ${file##*/}"
    kubectl create configmap "${name}" \
        --namespace "${NAMESPACE}" \
        --from-file="${file}" \
        --dry-run=client -o yaml \
    | kubectl label --local -f - -o yaml \
        app.kubernetes.io/part-of=che.eclipse.org \
        app.kubernetes.io/component=editor-definition \
    | kubectl apply -f -
}

register_editor che-android-studio-asfp-editor   "${DEPLOY_DIR}/asfp-editor-definition.yaml"
register_editor che-android-studio-studio-editor "${DEPLOY_DIR}/studio-editor-definition.yaml"

# --- Getting-started sample cards (already a labeled ConfigMap) -------------
if [ -r "${DEPLOY_DIR}/getting-started-samples.yaml" ]; then
    info "Applying getting-started sample cards"
    kubectl apply -n "${NAMESPACE}" -f "${DEPLOY_DIR}/getting-started-samples.yaml"
fi

ok "Editors registered in namespace '${NAMESPACE}'."
echo
info "They should now appear in the Che dashboard's editor dropdown as"
info "'Android Studio for Platform' and 'Android Studio'. Editor ids:"
info "  che-android-studio/asfp/latest"
info "  che-android-studio/android-studio/latest"
echo
info "Select one when creating a workspace, or reference it from a repo's"
info ".che/che-editor.yaml (id: che-android-studio/asfp/latest), or set it as"
info "the cluster default via spec.devEnvironments.defaultEditor on CheCluster."
