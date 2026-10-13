#!/usr/bin/env bash
#
# bootstrap.sh — stand up the SDLC playground on a local OpenShift (CRC / SNO).
#
# Idempotent-ish: safe to re-run. It installs the operators, wires secrets, and
# points ArgoCD at your fork. The parts that NEED your input (Red Hat Lightwell
# credentials, your fork URLs) are read from env vars / flags and validated.
#
# Prereqs on your PATH: crc, oc, cosign.
#
# Usage:
#   export RH_LIGHTWELL_USER=... RH_LIGHTWELL_TOKEN=...
#   ./bootstrap/bootstrap.sh
#
set -euo pipefail

# --- config (override via env) ------------------------------------------------
APP_NS="${APP_NS:-petclinic}"
PIPELINES_NS="openshift-pipelines"
GITOPS_NS="openshift-gitops"
CRC_MEMORY="${CRC_MEMORY:-20480}"
CRC_CPUS="${CRC_CPUS:-6}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERNAL_REGISTRY="image-registry.openshift-image-registry.svc:5000"

log() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. preflight -------------------------------------------------------------
for bin in oc cosign curl; do command -v "$bin" >/dev/null || die "missing required binary: $bin"; done
: "${RH_LIGHTWELL_USER:?set RH_LIGHTWELL_USER}"
: "${RH_LIGHTWELL_TOKEN:?set RH_LIGHTWELL_TOKEN}"

# Validate the Lightwell token NOW (fail early, clear message). A bad/expired
# token does not error the build — Maven silently falls back to Maven Central —
# so catch it here before standing anything up.
log "Validating Red Hat Lightwell credentials"
_lw_probe="https://packages.redhat.com/lightwell/java/validated/org/springframework/spring-aop/7.0.8/spring-aop-7.0.8.pom"
_lw_code="$(curl -s -o /dev/null -w '%{http_code}' -u "${RH_LIGHTWELL_USER}:${RH_LIGHTWELL_TOKEN}" "${_lw_probe}" || echo 000)"
[ "${_lw_code}" = "200" ] || die "Lightwell auth check failed (HTTP ${_lw_code}) as '${RH_LIGHTWELL_USER}'. Check RH_LIGHTWELL_USER/RH_LIGHTWELL_TOKEN (unset? expired? wrong account?)."
printf '  OK (HTTP 200)\n'

# --- 1. CRC (optional; skip if already logged in) -----------------------------
if ! oc whoami >/dev/null 2>&1; then
  command -v crc >/dev/null || die "not logged in and crc not found"
  log "Configuring and starting CRC (${CRC_CPUS} vCPU / ${CRC_MEMORY} MB)"
  crc config set memory "${CRC_MEMORY}"
  crc config set cpus "${CRC_CPUS}"
  crc start
  eval "$(crc oc-env)"
  die "Run 'oc login' as kubeadmin, then re-run this script."
fi
log "Logged in to: $(oc whoami --show-server)"

# --- 2. operators -------------------------------------------------------------
log "Installing OpenShift Pipelines + OpenShift GitOps operators"
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-gitops-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-gitops-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

log "Waiting for operator-provided CRDs (this can take a few minutes)"
for crd in pipelines.tekton.dev applications.argoproj.io tektonconfigs.operator.tekton.dev; do
  until oc get crd "$crd" >/dev/null 2>&1; do sleep 5; printf '.'; done
done
echo
oc rollout status deployment/openshift-gitops-server -n "${GITOPS_NS}" --timeout=300s || true

# CRDs appear BEFORE the Tekton webhook pods are serving. Creating a Task/Pipeline
# invokes the defaulting admission webhook, so applying ci/tekton/* too early fails
# with "no endpoints available for service tekton-pipelines-webhook". Wait for the
# webhook deployment to exist, roll out, and have live endpoints before step 4.
log "Waiting for the Tekton pipelines webhook to be ready"
until oc get deploy tekton-pipelines-webhook -n "${PIPELINES_NS}" >/dev/null 2>&1; do sleep 5; printf '.'; done
oc rollout status deploy/tekton-pipelines-webhook -n "${PIPELINES_NS}" --timeout=300s
until [ -n "$(oc get endpoints tekton-pipelines-webhook -n "${PIPELINES_NS}" \
        -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null)" ]; do sleep 5; printf '.'; done
echo

# --- 3. expose internal registry ---------------------------------------------
log "Exposing the internal image registry (defaultRoute)"
oc patch configs.imageregistry.operator.openshift.io/cluster --type merge \
  -p '{"spec":{"defaultRoute":true}}'

# --- 4. namespace + RBAC + tekton resources -----------------------------------
log "Creating namespace ${APP_NS} and applying Tekton RBAC/tasks/pipeline"
oc create namespace "${APP_NS}" --dry-run=client -o yaml | oc apply -f -
oc apply -f "${REPO_ROOT}/ci/tekton/rbac.yaml" -n "${APP_NS}"
oc apply -f "${REPO_ROOT}/ci/tekton/workspace-pvc.yaml" -n "${APP_NS}"
oc apply -f "${REPO_ROOT}/ci/tekton/tasks/" -n "${APP_NS}"
oc apply -f "${REPO_ROOT}/ci/tekton/pipeline.yaml" -n "${APP_NS}"

# --- 5. Red Hat Lightwell credentials + maven settings ------------------------
log "Creating Red Hat Lightwell credentials secret + maven-settings ConfigMap"
oc create secret generic redhat-lightwell-creds -n "${APP_NS}" \
  --from-literal=username="${RH_LIGHTWELL_USER}" \
  --from-literal=token="${RH_LIGHTWELL_TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -
oc create configmap maven-settings -n "${APP_NS}" \
  --from-file=settings.xml="${REPO_ROOT}/ci/maven/settings.xml.template" \
  --dry-run=client -o yaml | oc apply -f -
# PNC provenance public key — mounted by the provenance-verify task. Without this
# ConfigMap that task's pod hangs in Pending (missing volume) until the pipeline
# times out.
oc create configmap pnc-provenance-key -n "${APP_NS}" \
  --from-file=pnc-provenance-signing-key-1.pub="${REPO_ROOT}/ci/tekton/keys/pnc-provenance-signing-key-1.pub" \
  --dry-run=client -o yaml | oc apply -f -

# --- 6. cosign keypair -> signing-secrets (Chains + app ns) -------------------
log "Generating cosign keypair and installing signing-secrets"
WORKDIR="$(mktemp -d)"; trap 'rm -rf "${WORKDIR}"' EXIT
( cd "${WORKDIR}" && COSIGN_PASSWORD="" cosign generate-key-pair )
for ns in "${PIPELINES_NS}" "${APP_NS}"; do
  oc create secret generic signing-secrets -n "$ns" \
    --from-file=cosign.key="${WORKDIR}/cosign.key" \
    --from-file=cosign.pub="${WORKDIR}/cosign.pub" \
    --from-literal=cosign.password="" \
    --dry-run=client -o yaml | oc apply -f -
done

# --- 7. registry-auth for the deploy gate (SA token -> dockerconfigjson) -------
log "Creating registry-auth secret for the PreSync verify gate"
SA_TOKEN="$(oc create token pipeline-sa -n "${APP_NS}" --duration=8760h 2>/dev/null \
  || oc create token pipeline-sa -n "${APP_NS}")"
oc create secret docker-registry registry-auth -n "${APP_NS}" \
  --docker-server="${INTERNAL_REGISTRY}" \
  --docker-username="pipeline-sa" \
  --docker-password="${SA_TOKEN}" \
  --dry-run=client -o yaml | oc apply -f -

# --- 8. configure Tekton Chains ----------------------------------------------
log "Configuring Tekton Chains (OCI storage, simplesigning, no external Rekor)"
oc patch TektonConfig config --type merge -p '{
  "spec": {"chain": {
    "artifacts.oci.storage": "oci",
    "artifacts.oci.format": "simplesigning",
    "artifacts.taskrun.format": "slsa/v2alpha3",
    "artifacts.taskrun.storage": "oci",
    "transparency.enabled": "false"
  }}}'
# Chains picks up the signing key from signing-secrets in openshift-pipelines.
oc delete pod -n "${PIPELINES_NS}" -l app=tekton-chains-controller >/dev/null 2>&1 || true

# --- 9. ArgoCD app-of-apps ----------------------------------------------------
log "Granting ArgoCD access to ${APP_NS} and applying the root Application"
oc adm policy add-role-to-user admin \
  system:serviceaccount:${GITOPS_NS}:openshift-gitops-argocd-application-controller \
  -n "${APP_NS}" || true
oc apply -f "${REPO_ROOT}/gitops/bootstrap/root-application.yaml"

cat <<EOF

$(log "Bootstrap complete")
Next:
  1. Edit repoURL/git-url placeholders (<your-user>) in:
       ci/tekton/pipelinerun.yaml
       gitops/bootstrap/root-application.yaml
       gitops/applications/*/application.yaml
     and push this repo + your spring-petclinic fork to GitHub.
  2. Run a build:
       oc create -f ci/tekton/pipelinerun.yaml -n ${APP_NS}
       tkn pipelinerun logs -f -n ${APP_NS} --last
  3. Grab IMAGE_DIGEST from the finished run and paste it into
       overlays/openshift-local/kustomization.yaml (images[].digest), commit/push.
  4. Watch ArgoCD deploy it (PreSync gate verifies the signature first):
       argocd app get petclinic   # or the OpenShift GitOps console
  5. Open https://petclinic.apps-crc.testing
See docs/verification.md for the full end-to-end proof.
EOF
