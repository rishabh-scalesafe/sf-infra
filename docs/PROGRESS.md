# Overnight build progress (2026-11-16)

- 00:17 Started. Azure CLI logged in (Azure subscription 1). Quota: 4 cores centralindia.
- 00:25 Pinned versions: k3s v1.36.5+k3s1, Argo CD v3.5.7, Tekton Pipelines v1.17.1, Triggers v0.37.2, Dashboard v0.73.0 (all >= 2 weeks old).
- 00:40 Terraform modules written: k3s-cloudinit, azure-k3s, aws-k3s, gcp-k3s.
- 00:47 Azure quicktest cluster up (B2s capacity-restricted -> B2as_v2). 2 nodes Ready, k3s v1.36.5+k3s1.
- 00:58 Platform bootstrap OK (Tekton + Argo CD). Added retries: local internet drops API connections intermittently.
- 01:22 Smoke test 12/12 PASS (nodes, Tekton build, Argo CD sync, restricted app HTTP 200, secrets encryption, ssh hardening, audit log).
- 01:25 GitHub webhook trigger verified: bad HMAC rejected ("payload signature check failed"), good HMAC -> PipelineRun with lowercased repo name.
- 01:30 Running full GitOps e2e (Gitea + registry as stand-ins for GitHub/GHCR): tests/e2e/run-e2e.sh
- 01:35 6443 drops from local ISP -> SSH tunnel access (kubeconfig-tunnel). Argo CD OutOfSync on Tekton -> ServerSideDiff fix.
- 01:50 Full GitOps e2e 9/9 PASS (webhook -> Tekton build/push -> GitOps bump -> Argo CD rollout -> HTTP 200).
- 01:55 Secret scan clean, terraform validate x4 OK, fmt clean. docs/MORNING-REPORT.md written. Cluster left running (auto-shutdown 09:00 IST).
- check-in OK 01:54 (2/2 nodes Ready, 7/7 Argo apps Synced+Healthy, 0 unhealthy pods)
- 02:44 ScaleSafe: manifests (own, generated), secrets, sources in Gitea. Building HEAD 7dc0462 (9 images).
- 03:12 ScaleSafe HEAD 7dc0462 deployed via Tekton+Argo CD (9 images, 8.5 min). App e2e: client saga 47/47, investor 125/125.
  Issues fixed on the way: CRLF in OIDC client secret (secrets.sh), NetworkPolicy blocked tunnel to cross-node pods
  (-> node-side port-forward), tunnel port collision, Windows curl temp path, investor-suite test users.
- 03:14 DOWNGRADE started: platform 7dc0462 -> 273b1a2 (Boot 4.1.2 -> 3.5.16, esign schema already at V2), site 2a31c94 -> 9498408
- 03:36 Guard deployed. Re-running downgrade (re-pin 273b1a2) to prove the guard.
- 03:37 Guarded downgrade: esign 273b1a2 blocked by Flyway ("applied migration not resolved locally: 2"), 7dc0462 kept serving; others downgraded.
- 03:44 Rolled forward by re-pin (79s). Final: 7dc0462 healthy, e2e 47/47 + 125/125. Orphan check finds 1 pre-guard request. Report: docs/SCALESAFE-DEPLOY-REPORT.md
- 03:49 Deck published (12 slides): https://claude.ai/artifact/DYygBhKqTMxktKH94boauB . MORNING-REPORT updated.
- check-in OK 03:49 (2/2 nodes Ready, 8/8 Argo apps Synced+Healthy incl. scalesafe, 0 unhealthy pods)
- check-in OK 04:33 (2/2 nodes Ready, 8/8 Argo apps Synced+Healthy, 0 unhealthy pods)
- 05:43 Morning handoff: 2/2 nodes Ready, 8/8 Argo apps Synced+Healthy, 0 unhealthy pods, scalesafe 10/10 deployments up.
- 05:55 Smoke re-run: the build was stuck in PipelineRunPending because the ci PVC quota (20) was full of finished-run PVCs. Freed it by deleting 11 old runs. Fix: tekton/pruner.yaml (CronJob, keeps 10), shipped via GitOps 68c0f39/80e5a9c. The first image, rancher/kubectl, has no /bin/sh; switched to alpine/k8s:1.36.5. Manual prune OK.
- 06:05 Smoke 12/12. The 3 node checks were re-run by hand because the first SMOKE_SSH key path broke on the space in the folder name. MORNING-REPORT finalized.
- check-in OK 06:00 (2/2 nodes Ready, 8/8 Argo apps Synced+Healthy, 0 unhealthy pods, ci PVCs 10/20)
- 06:20 Domain set to indiescale.in (all __DOMAIN__ placeholders: argocd/tekton/hooks/app hosts, argocd-cm url, oauth2-proxy redirect). Cloudflare tfvars written (gitignored) with origin_ips = both quick-test nodes; zone_id still needed. indiescale.in DNS is currently on Hostinger parking nameservers (dns-parking.com), not Cloudflare. Not deployed yet: platform/ui needs the zone, an origin cert and the GitHub OAuth apps.
