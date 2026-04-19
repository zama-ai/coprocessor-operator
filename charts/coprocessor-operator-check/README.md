# coprocessor-operator-check

A Helm chart to execute Coprocessor Operator pre-flight check Jobs before install or upgrade.

## Overview

This chart runs a single Kubernetes Job as a `pre-install,pre-upgrade` Helm hook. The job executes three sequential checks via init containers:

1. **k8s-check** — asserts that required namespaces, secrets, and ExternalName services exist in the cluster
2. **aws-check** — verifies the coprocessor S3 bucket is reachable via its Cloudflare custom hostname
3. **fetch-rds-secret** — fetches the RDS master credentials from AWS Secrets Manager into a shared in-memory volume
4. **db-check** (main container) — validates that the `coprocessor_user` and `postgres_exporter` roles exist with the correct permissions

Any failing check exits non-zero and blocks the Helm release from proceeding.

## Prerequisites

* `db-admin` ServiceAccount with an IRSA role that can:
    * `secretsmanager:GetSecretValue` on the RDS master credentials secret
* Terraform provisioned infrastructure (namespaces, RDS, S3 bucket, Cloudflare hostname, `rds-admin-secret-id` ConfigMap)
* `secrets-bootstrap.sh` executed (populates `coprocessor-user-rds-credentials`, `registry-credentials`, etc.)

The `rds-admin-secret-id` ConfigMap is expected in the release namespace (`coproc-admin`) with key `RDS_ADMIN_SECRET_ID` holding the ID of the RDS master credentials secret in AWS Secrets Manager.

## Usage

To inspect job logs after a run (available for `ttlSecondsAfterFinished` seconds):

```bash
kubectl logs -n coproc-admin -l app=coprocessor-operator-check --all-containers --tail=-1
```

## Configuration

### Required Parameters

| Parameter | Description |
|-----------|-------------|
| `checks.aws.storageHostname` | Cloudflare custom hostname fronting the coprocessor S3 bucket |

These must be set in your environment values file (e.g. `testnet/helm-values/coprocessor-operator-check.yaml`).

The RDS master secret ID is sourced from the existing `rds-admin-secret-id` ConfigMap (key `RDS_ADMIN_SECRET_ID`) rather than chart values — see [Prerequisites](#prerequisites).

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `job.ttlSecondsAfterFinished` | Seconds before the completed Job is deleted | `300` |
| `serviceAccount.name` | ServiceAccount to run the job as | `db-admin` |
| `securityContext` | Container-level security context applied to all containers | `capabilities.drop: [ALL]` |
| `podSecurityContext` | Pod-level security context | `{}` |
| `imagePullSecrets` | Secrets for pulling images from the private registry | `[registry-credentials]` |

### Check Scripts

The shell scripts executed by each check are fully configurable in values:

```yaml
checks:
  k8s:
    script: |
      # ...
  aws:
    storageHostname: "my-bucket.example.com"
    script: |
      # ...
  db:
    script: |
      # ...
```

## Security Considerations

* The Job runs with `capabilities.drop: [ALL]` on all containers by default
* RDS credentials fetched from Secrets Manager are written to an `emptyDir` volume backed by memory (`medium: Memory`), never touching disk
* The ClusterRole is scoped to only `get`/`list` on `namespaces`, `secrets`, `services`, and `configmaps` — no wildcard access
* RBAC resources are deleted on hook success (`hook-delete-policy: before-hook-creation,hook-succeeded`)

## Values

See [values.yaml](values.yaml) for the complete list of configurable parameters.
