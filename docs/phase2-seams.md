# Phase-2 seams

Where the remaining stages attach to the Phase-1 MVP. Not built yet — this maps
the insertion points so Phase 2 is additive, not a rewrite.

## Stage 4 — Automated testing / scanners
Add scanner Tasks to `ci/tekton/pipeline.yaml` with `runAfter: ["build-image"]`
(parallel to `sbom-attest`). Industry slots mirror the Konflux pipeline:
- container scan (Clair / RH ACS `roxctl image scan`)
- SAST (Snyk / Sonatype / Veracode / Contrast — your call)
- SBOM policy (consume the CycloneDX attestation)

Each emits results; aggregate them for Stage 5.

## Stage 5 — Risk-based change management + policy gating  ← the key seam
This is where the **Lightwell risk/remediation engine** lands. Today the gate is a
single cosign check (`gitops/base/petclinic/verify-gate-job.yaml` +
`ci/tekton/tasks/cosign-verify.yaml`). Evolve it in place:

1. Replace/augment the PreSync gate with an **Enterprise Contract / Conforma**
   `verify-enterprise-contract` step whose policy consumes the SLSA provenance +
   SBOM + scanner results.
2. The risk engine reads those attestations, computes a contextual score (see the
   `scoring-approaches-analysis.md` tiered model: gates → exploitation → impact),
   and returns pass / gate / remediate.
3. On "gate": fail the PreSync Job (blocks deploy) and optionally open a Jira ticket.

Keep it a **discrete Tekton task + ArgoCD PreSync hook** so the engine is swappable
without touching the build or deploy manifests.

## Stage 6 — (done) release orchestration
GitOps/ArgoCD is in place. AAP/Ansible is an alternative orchestrator if desired;
`~/dcm/osac/osac-aap/` is a style reference.

## Stage 7 — Runtime monitoring + rollback
Add a `ServiceMonitor` for the petclinic Deployment/Route; wire OpenShift
monitoring (or Dynatrace). Rollback = ArgoCD revert to the previous pinned digest.

## Stage 8 — Agentic vulnerability remediation
Consumes Stage-5 output. Most reproducible remediation path on this architecture:
a **GitOps PR** that bumps the pinned image digest (and/or the `pom.xml` dependency
version) after a verified rebuild — Renovate/Dependabot for the version bump,
your engine for the "is this change safe to auto-merge" decision.
