# Terraform backend identity fixture harness

**Manual, init + plan only. Never apply or import.** This isolated harness tests
separate backend/provider identities in default and strict environment-variable modes.
The CI examples do not provision infrastructure. The separate `infra` bootstrap
creates only the isolated test resources recorded in `.azure\deployment-plan.md`.

## Pinned sources

- Core: [`jaredfholgate/terraform@e8195f605d24299788cdf36738915d84563e4c58`](https://github.com/jaredfholgate/terraform/commit/e8195f605d24299788cdf36738915d84563e4c58),
  upstream [hashicorp/terraform#36922](https://github.com/hashicorp/terraform/pull/36922).
- Docs: [`d55950c86e2dc3757df3b7bd2279b0cf96fe1679`](https://github.com/hashicorp/web-unified-docs/pull/3332),
  `content/terraform/v1.16.x/docs/language/backend/azurerm.mdx`.
- `scripts\Build-Terraform.ps1` fetches/checks out that exact fork commit and runs
  `go build -trimpath -buildvcs=true`. Go **1.26.4** is checked against both
  `.go-version` and `go.mod`. The build records source revision, clean VCS metadata,
  Terraform version and executable SHA-256. No released Terraform executable is used.
  Only Go module/build caches are shared; the CLI is built on every invocation.

## Entry points and prerequisites

| Mode | Manual entry point | Precreated provider resource group |
| --- | --- | --- |
| GitHub default | `.github\workflows\gh-default.yml` | `rg-tf36922-e8195f-gh-default` |
| GitHub strict | `.github\workflows\gh-strict.yml` | `rg-tf36922-e8195f-gh-strict` |
| Azure Pipelines default | `.ado\ado-default.yml` | `rg-tf36922-e8195f-ado-default` |
| Azure Pipelines strict | `.ado\ado-strict.yml` | `rg-tf36922-e8195f-ado-strict` |

All use Windows hosted agents and PowerShell 7. GitHub exposes only
`workflow_dispatch`; ADO has `trigger: none` and `pr: none` (also disable any
UI-configured schedules/triggers). Use workload identity federation. Authorize both
GitHub identities for the dispatched branch and both ADO service connections for
each pipeline. The fixed ADO connection names are **sc-tf36922-state** and
**sc-tf36922-provider**. No Terraform marketplace installer extension is needed.

Set these **non-secret** GitHub repository variables / ADO pipeline variables:

| Variables | Meaning |
| --- | --- |
| `AZAPI_CLIENT_ID`, `AZAPI_TENANT_ID`, `AZAPI_SUBSCRIPTION_ID` | Expected provider identity and subscription |
| `STATE_CLIENT_ID`, `STATE_TENANT_ID`, `STATE_SUBSCRIPTION_ID` | Expected backend identity and subscription |
| `STATE_STORAGE_ACCOUNT_NAME`, `STATE_CONTAINER_NAME` | Existing state storage |
| `STATE_KEY` | Non-secret blob name/prefix, not a storage key |

Backend and provider client IDs **must differ**. Backend access needs Storage Blob
Data Contributor scoped to the state container; provider access is scoped to the
mode's precreated resource group. The HCL previews a create for that group because
each backend key is empty and unique; it is deliberately never imported or applied.
No subscription-wide Contributor grant is required. Direct Entra storage access
does not perform a management-plane endpoint lookup. In non-strict mode the
expected state subscription is a harness assertion input, **not** an
`ARM_BACKEND_SUBSCRIPTION_ID` override.

## Faithfulness and limits

`examples\source\<mode>` retains both original fenced HCL and YAML, unchanged.
`examples\source\provenance.json` records exact headings, source commit/Git blob,
LF-normalized document SHA-256, and individual snippet SHA-256 hashes.
Runnable HCL lives in `examples\<mode>`. Edit the generator, not generated files.

Allowed adaptations: replace release installers with the pinned source build;
use Windows instead of Ubuntu (source scripts already use `pwsh`/`pscore`); allow
`>= 1.17.0-dev` for the prerelease CLI; substitute the four scoped group names;
disable ADO PR triggers; add isolated directories/unique keys, assertions,
sanitized evidence, caches and cleanup. HCL authentication is otherwise unchanged.

The exact ordered authentication assignments are checked against the source:
GitHub default overrides **only backend client/tenant**, sharing OIDC/AzureAD
flags and the native GitHub broker. GitHub strict copies the current step's
`ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN` to `ARM_BACKEND_OIDC_REQUEST_URL/TOKEN`
in **both** init and plan. ADO initializes in the state connection, carries only
non-secret identity/connection metadata forward, and plans in the provider
connection. Each task maps its own `System.AccessToken`; `SYSTEM_OIDCREQUESTURI`
remains native. Backend/provider service connection selectors and strict-mode
flags are preserved. No fixed assertion token or broker rewrite is introduced.

**Single-tenant limitation:** with both supplied identities in one tenant, these
runs establish identity isolation and init-to-plan behavior, not the documentation's
cross-tenant claims. They also do not prove apply, import, cross-job handoff,
long-running token refresh or management-plane endpoint lookup. Plan JSON proves
the provider identity; successful state access plus deliberately scoped RBAC and
runtime environment checks are the backend evidence, not a decoded-token identity
attestation.

## Local validation and evidence

```powershell
.\scripts\Test-Fixtures.ps1
# Re-extract only from the authorized read-only checkout at the pinned docs commit:
.\scripts\Export-Fixtures.ps1 -DocsPath '<absolute-path-to-azurerm.mdx>'
.\scripts\Test-Fixtures.ps1 -DocsPath '<absolute-path-to-azurerm.mdx>'
```

Validation is offline: compare generated fixtures/source hashes and exact auth
sequence, parse scripts and embedded PowerShell, and test accepted/rejected
synthetic plan identities/resources. It does not start CI or access Azure.

Each invocation appends **mode + run ID + attempt** to `STATE_KEY`. Init and plan
use the same `.runs\<mode>-<run>-<attempt>` directory in one job. Saved `tfplan`
is inspected with `terraform show -json` **in memory**: assert the
`data.azapi_client_config.current` client/tenant/subscription and the sole planned
resource group's name/type/location/parent subscription/create action.
Only allow-listed non-secret JSON in `evidence\` is published. Never publish raw
plan/state or enable Terraform debug logging. A `finally` block and an always-run
cleanup step remove the entire local run directory, including plan, state metadata
and provider cache. Hosted-runner disposal covers abrupt job termination. Remote
state blobs are not deleted by this harness; the provisioning owner handles them.
