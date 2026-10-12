# End-to-end verification

Three things to prove: (1) the app is deployed and working, (2) the image is
signed + attested and the gate enforces it, (3) `aspectjweaver` really came from
the Red Hat Lightwell repo.

## 1. App deployed and healthy

```bash
# ArgoCD shows both apps Synced/Healthy
oc get applications -n openshift-gitops
argocd app get petclinic            # if argocd CLI is logged in

# Route is up; UI loads; DB is wired (owners list renders)
oc get route petclinic -n petclinic
curl -sk https://petclinic.apps-crc.testing/actuator/health   # {"status":"UP"}
xdg-open https://petclinic.apps-crc.testing                    # browse the UI
```

## 2. Image signed + verified

```bash
# Pull the built digest from the PipelineRun results
DIGEST=$(oc -n petclinic get pipelinerun --sort-by=.metadata.creationTimestamp \
  -o jsonpath='{.items[-1:].status.results}' | tr ',' '\n' | grep -A1 IMAGE_DIGEST)
echo "$DIGEST"

REG=$(oc get route default-route -n openshift-image-registry -o jsonpath='{.spec.host}')
IMAGE="$REG/petclinic/petclinic@sha256:<digest>"

# Signature + SBOM attestation verify against the public key
cosign verify --insecure-ignore-tlog=true --allow-insecure-registry \
  --key cosign.pub "$IMAGE"
cosign verify-attestation --insecure-ignore-tlog=true --allow-insecure-registry \
  --key cosign.pub --type cyclonedx "$IMAGE"

# See the whole supply-chain tree (.sig / .att provenance / sbom)
cosign tree --allow-insecure-registry "$IMAGE"

# The gate enforced this at deploy time:
oc logs -n petclinic job/petclinic-verify-gate   # "GATE PASSED: ..."
```

**Negative test (prove the gate bites):** point the overlay `images[].digest` at an
unsigned image and re-sync — the `petclinic-verify-gate` PreSync Job should fail and
the Deployment should NOT roll out.

## 3. aspectjweaver provenance

```bash
# In the maven-build task logs, the "Proof" section prints _remote.repositories:
tkn taskrun logs -n petclinic -f $(oc get taskrun -n petclinic \
  -o name | grep maven-build | tail -1)
# expect a line recording: aspectjweaver-1.9.25.1.jar>redhat-lightwell=

# Locally, reproduce with a clean repo:
cd spring-petclinic
./mvnw -s ~/.m2/settings.xml -Dmaven.repo.local=$(mktemp -d) -DskipTests clean package
# then inspect org/aspectj/aspectjweaver/1.9.25.1/_remote.repositories in that dir

# Confirm it's pinned in the SBOM too:
grep -o 'aspectjweaver@[0-9.]*' spring-petclinic/target/bom.json | head
```

## 4. Java artifact SLSA provenance (Lightwell)

Each RHLN artifact ships a sibling SLSA provenance attestation signed by "PNC
Provenance Signing Key 1". The bundle
`<artifactId>-<version>.provenance.sigstore.json` lives in the SAME Maven
coordinate directory on the validated-tier server as the `.jar`.

### Manual verification

```bash
# 0. Save the PNC public key (from the Red Hat Lightwell Network docs) to
#    pnc-provenance-signing-key-1.pub (a PEM beginning with -----BEGIN PUBLIC KEY-----).

# 1. Pick an artifact and download the jar + its provenance bundle from the SAME
#    coordinate directory, using your Basic creds.
BASE=https://packages.redhat.com/lightwell/java/validated
G=org/aspectj A=aspectjweaver V=1.9.25.1
curl -fSL -u "$RH_LIGHTWELL_USER:$RH_LIGHTWELL_TOKEN" \
  -O "$BASE/$G/$A/$V/$A-$V.jar"
curl -fSL -u "$RH_LIGHTWELL_USER:$RH_LIGHTWELL_TOKEN" \
  -O "$BASE/$G/$A/$V/$A-$V.provenance.sigstore.json"

# 2. Verify the SLSA provenance attestation against the PNC public key.
cosign verify-blob-attestation \
  --type https://slsa.dev/provenance/v1 \
  --key pnc-provenance-signing-key-1.pub \
  --bundle "$A-$V.provenance.sigstore.json" \
  "$A-$V.jar"
# expect: "Verified OK"
```

### Enforced automatically in the pipeline

The `provenance-verify` Tekton task (`ci/tekton/tasks/provenance-verify.yaml`)
runs AFTER `maven-build` has resolved the artifacts into the shared `.m2` cache and
BEFORE `build-image` (which `runAfter: ["provenance-verify"]`). For each target GAV
it downloads the provenance bundle and runs the `cosign verify-blob-attestation`
command above; if any bundle is missing or fails to verify, the task exits
non-zero and the image is never built — a hard supply-chain gate.

```bash
# Watch the gate in a run:
tkn taskrun logs -n petclinic -f $(oc get taskrun -n petclinic \
  -o name | grep provenance-verify | tail -1)
# expect: "GATE PASSED: all target artifacts have verified SLSA provenance."
```

Prereqs: the PNC public key must be installed as a ConfigMap in the namespace:

```bash
oc create configmap pnc-provenance-key -n petclinic \
  --from-file=pnc-provenance-signing-key-1.pub=ci/tekton/keys/pnc-provenance-signing-key-1.pub
```

**Negative test (prove the gate bites):** install a wrong/placeholder key (the
checked-in `ci/tekton/keys/pnc-provenance-signing-key-1.pub` is a placeholder), or
point `artifacts` at a GAV with no published provenance — `provenance-verify` fails
and `build-image` never runs.
