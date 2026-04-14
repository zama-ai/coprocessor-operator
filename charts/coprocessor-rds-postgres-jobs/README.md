# coprocessor-rds-postgres-jobs

A generic Helm chart for running one-off PostgreSQL administration Jobs against the coprocessor RDS instance.

## Overview

This chart renders a single Kubernetes Job gated by `job.enabled`. It is designed to be instantiated multiple times via helmfile — each release supplies its own values file with the specific command, image, and configuration for that operation.

Current operations:

* **coprocessor-db-user-setup** — creates/updates the `coprocessor_user` and `postgres_exporter` roles with correct grants

Planned operations (disabled, for future releases):

* **coprocessor-ciphertext-restore** — seeds ciphertext data as a one-time operation

## Prerequisites

* `db-admin` ServiceAccount with an IRSA role that can:
    * `secretsmanager:GetSecretValue` on the RDS master credentials secret
* An ExternalName service `coprocessor-database` in the `coproc` namespace pointing to the RDS endpoint
* Required Kubernetes secrets provisioned by `secrets-bootstrap.sh`

## Usage

To inspect logs after a run:

```bash
kubectl logs -n coproc-admin -l app.kubernetes.io/instance=coprocessor-db-user-setup --all-containers --tail=-1
```

## Configuration

### Key Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `job.enabled` | Must be `true` to render any resources | `false` |
| `job.ttlSecondsAfterFinished` | Seconds before the completed Job is deleted | _(keep indefinitely)_ |
| `job.backoffLimit` | Retries before the Job is marked failed | _(unset)_ |
| `job.restartPolicy` | Pod restart policy | `Never` |
| `job.command` / `job.args` | Entrypoint and arguments for the job container | `[]` |
| `image.repository` / `image.tag` | Default image used by the job container | `""` |
| `serviceAccountName` | Existing ServiceAccount to run the job as (e.g. with IRSA) | `""` |
| `imagePullSecrets` | Secrets for pulling images from the private registry | `[]` |

### Per-Job Image Override

Each job can override the chart-level image:

```yaml
job:
  enabled: true
  image:
    repository: hub.zama.org/zama-protocol/zama.ai/postgres
    tag: "17-dev"
```

If `job.image.repository` is unset, the chart falls back to `image.repository`.

### Init Containers

Use `initContainers` to run steps before the main job container. Images are specified as `repository` + `tag` — the template constructs `repository:tag`:

```yaml
initContainers:
  - name: fetch-rds-secret
    image:
      repository: hub.zama.org/zama-protocol/zama.ai/aws-cli
      tag: "2.30-dev"
    command: ["/bin/sh", "-c"]
    args:
      - aws secretsmanager get-secret-value --secret-id "$RDS_SECRET_ARN" ...
    env:
      - name: RDS_SECRET_ARN
        value: "arn:aws:secretsmanager:..."
    volumeMounts:
      - name: shared-creds
        mountPath: /shared
```

### Shared Volumes

Volumes and mounts defined at the top level are available to both init containers and the job container:

```yaml
volumes:
  - name: shared-creds
    emptyDir:
      medium: Memory

volumeMounts:
  - name: shared-creds
    mountPath: /shared
```

## Security Considerations

* `job.enabled` defaults to `false` — no resources are rendered unless explicitly enabled, preventing accidental execution
* Sensitive credentials fetched at runtime should use `emptyDir.medium: Memory` volumes to avoid writing to disk
* The chart does not create a ServiceAccount; bind an existing IRSA-annotated account via `serviceAccountName`

## Values

See [values.yaml](values.yaml) for the complete list of configurable parameters.
