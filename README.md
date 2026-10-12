# sdlc-playground

A small, reproducible **software delivery + release pipeline** on local
OpenShift (CRC / SNO), built to experiment with secure supply-chain practices.

It builds
[spring-petclinic](https://github.com/spring-projects/spring-petclinic), pulls a
dependency (`org.aspectj:aspectjweaver`) from Red Hat's **Lightwell** validated
Maven repository, signs + attests the image, and deploys it via GitOps with a
signature-verification gate.

## Two-repo layout

| Repo                            | Role         | What it holds                                                                                  |
| ------------------------------- | ------------ | ---------------------------------------------------------------------------------------------- |
| **spring-petclinic** (fork)     | app          | vanilla `pom.xml` (Lightwell repo is declared in `settings.xml`, not the pom), `Containerfile` |
| **sdlc-playground** (this repo) | infra/config | Tekton pipeline, ArgoCD GitOps, overlays, bootstrap, docs                                      |

## Pipeline stages (Phase 1)

```
 git  ─►  mvn verify            ─►  buildah            ─►  cosign attest (SBOM)
(fork)    (aspectjweaver from       (image + push)         + Tekton Chains signs
          Red Hat Lightwell;                               image & SLSA provenance
          CycloneDX SBOM)                                  out-of-band)
                                                               │
                                        GitOps (ArgoCD)  ◄──────┘
                                        PreSync cosign-verify GATE ─► Deploy + Route + DB
```

- **Stage 1** (artifact ingestion): `org.aspectj:*` resolves from the Lightwell
  **validated** tier via a self-contained `<repositories>` profile + matching
  `<server>` (id `lightwell-validated`) in `settings.xml`
  (`ci/maven/settings.xml.template`, `dev/settings.xml.template`); Maven Central
  still follows as the fallback. The provenance of resolved artifacts is then
  enforced by a Cosign SLSA-provenance gate (`provenance-verify`) before the
  image is built.
- **Stage 2** (SCM): your petclinic fork; Tekton clones it.
- **Stage 3** (CI): `ci/tekton/` — build, SBOM attest, Chains signing.
- **Stage 6** (release): `gitops/` + `overlays/` — ArgoCD app-of-apps, image
  pinned by digest, PreSync signature gate, OpenShift Route.

Stages 4 (scanners), 5 (risk gating + remediation engine), 7 (runtime
monitoring), 8 (agentic remediation) are Phase 2 — see
[`docs/phase2-seams.md`](docs/phase2-seams.md).

## Prerequisites

### Lightwell credentials

Create a service account on
[https://access.redhat.com/terms-based-registry/](https://access.redhat.com/terms-based-registry/)
to use as `RH_LIGHTWELL_USER` `RH_LIGHTWELL_TOKEN` environment
variables.

### Tekton CLI

```
# Get the tar.xz
curl -LO https://github.com/tektoncd/cli/releases/download/v0.46.0/tkn_0.46.0_Darwin_all.tar.gz
# Extract tkn to your PATH (e.g. /usr/local/bin)
sudo tar xvzf tkn_0.46.0_Darwin_all.tar.gz -C /usr/local/bin tkn
```

### CRC setup

1. Install the crc binary (onto your PATH at ~/go/bin)

```
cd /tmp
curl -L -o crc.tar.xz "https://mirror.openshift.com/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz"
tar -xf crc.tar.xz
install -m 0755 crc-linux-*-amd64/crc ~/go/bin/crc
hash -r && crc version
```

2. Get the pull secret

Download from https://console.redhat.com/openshift/create/local and save it as
~/pull-secret.json

3. Configure CRC (generous, since your host can take it)

```
crc config set cpus 6
crc config set memory 20480          # 20 GB; bump to 24576 if you want headroom
crc config set disk-size 80          # default 31 GB is too tight for Pipelines+GitOps+Maven+registry
crc config set pull-secret-file ~/pull-secret.json
```

4. One-time host setup, then start (first start ~15–20 min)

```
crc setup        # prepares libvirt/networking; may prompt for sudo
crc start        # prints the kubeadmin login command + password at the end
```

5. Point oc at CRC and log in as cluster-admin

```
eval "$(crc oc-env)"                          # adds the 'crc' context to ~/.kube/config
crc console --credentials                     # shows the exact kubeadmin login line
oc login -u kubeadmin -p <password-from-above> https://api.crc.testing:6443
oc whoami                                      # should print kube:admin
```

## Quick start

```bash
# prereqs on PATH: crc, oc, cosign  (and a running/startable CRC)
export RH_LIGHTWELL_USER=... RH_LIGHTWELL_TOKEN=...
./bootstrap/bootstrap.sh
```

Then follow the "Next" steps printed by the script (fill in your fork URLs, run
a PipelineRun, paste the built digest into the overlay). Full proof procedure:
[`docs/verification.md`](docs/verification.md).

## Security model (from day one)

- **Signed:** image (cosign) + SLSA provenance (Tekton Chains) + CycloneDX SBOM
  attestation.
- **Verified:** ArgoCD **PreSync gate** runs `cosign verify` +
  `verify-attestation` against the pinned **digest**; failure blocks the
  rollout.
- **Logged:** Chains records attestations in the registry (OCI). Public Rekor is
  off by default (no egress needed on CRC); flip `transparency.enabled` to use
  it.

## Known open items

See the Risks section of the plan and `docs/`. Biggest: the auth scheme for the
Red Hat Lightwell repo (token vs basic) — modeled here as a username/token
Secret.
