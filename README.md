# Terraform backend identity fixture harness

**Manual, init + plan only. Never apply or import.** This isolated harness tests
separate backend/provider identities in default and strict environment-variable modes.
The CI examples do not provision infrastructure. The separate `infra` bootstrap
creates only the isolated test resources recorded in `.azure\deployment-plan.md`.

## Live results

The four same-tenant cases passed on 2026-09-08. Sanitized evidence is preserved in
[`results/same-tenant`](results/same-tenant); no plans, state or tokens are included.

| Platform | Non-strict | Strict |
| --- | --- | --- |
| GitHub Actions | [Passed](https://github.com/microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922/actions/runs/34222433385) | [Passed](https://github.com/microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922/actions/runs/34222437502) |
| Azure Pipelines | [Passed](https://dev.azure.com/microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922/_build/results?buildId=138) | [Passed](https://dev.azure.com/microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922/_build/results?buildId=139) |

The cross-tenant provider is deployed in a separate tenant/subscription with
four resource-group-scoped Contributor assignments. Both cross-tenant GitHub
cases passed; the Azure Pipelines cases are in progress. Inspected evidence is
preserved separately in [`results/cross-tenant`](results/cross-tenant).

## Pinned sources

- Core: [`jaredfholgate/terraform@0c5e9bef8b6d76866b0f0ddedab5b72af51bcc27`](https://github.com/jaredfholgate/terraform/commit/0c5e9bef8b6d76866b0f0ddedab5b72af51bcc27),
  upstream [hashicorp/terraform#36922](https://github.com/hashicorp/terraform/pull/36922).
- Docs: [`1281ae9db0b308bf26c12d157b105f189e6681db`](https://github.com/hashicorp/web-unified-docs/pull/3332),
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
| GitHub cross-tenant default | `.github\workflows\gh-cross-default.yml` | Same name in CSUTF |
| GitHub cross-tenant strict | `.github\workflows\gh-cross-strict.yml` | Same name in CSUTF |
| Azure Pipelines cross-tenant default | `.ado\ado-cross-default.yml` | Same name in CSUTF |
| Azure Pipelines cross-tenant strict | `.ado\ado-cross-strict.yml` | Same name in CSUTF |

All use Windows hosted agents and PowerShell 7. GitHub exposes only
`workflow_dispatch`; ADO has `trigger: none` and `pr: none` (also disable any
UI-configured schedules/triggers). Use workload identity federation. Authorize both
GitHub identities for the dispatched branch and both ADO service connections for
each pipeline. The fixed ADO connection names are **sc-tf36922-state** and
**sc-tf36922-provider**. No Terraform marketplace installer extension is needed.
Cross-tenant pipelines instead use **sc-tf36922-csutf-provider** for the provider.
Their definition variables must contain `CSUTF_AZAPI_*`, not the original
provider's `AZAPI_*` globals, which shadow task-level environment mappings in ADO.

Set these **non-secret** GitHub repository variables / ADO pipeline variables:

| Variables | Meaning |
| --- | --- |
| `AZAPI_CLIENT_ID`, `AZAPI_TENANT_ID`, `AZAPI_SUBSCRIPTION_ID` | Expected provider identity and subscription |
| `AZAPI_OBJECT_ID` | Provider managed identity principal ID, verified against its client ID during provisioning |
| `STATE_CLIENT_ID`, `STATE_TENANT_ID`, `STATE_SUBSCRIPTION_ID` | Expected backend identity and subscription |
| `STATE_STORAGE_ACCOUNT_NAME`, `STATE_CONTAINER_NAME` | Existing state storage |
| `STATE_KEY` | Non-secret blob name/prefix, not a storage key |
| `CSUTF_AZAPI_CLIENT_ID`, `CSUTF_AZAPI_OBJECT_ID`, `CSUTF_AZAPI_TENANT_ID`, `CSUTF_AZAPI_SUBSCRIPTION_ID` | Provider values for the four additional cross-tenant entry points |

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
use Windows instead of Ubuntu (source scripts already use `pwsh`/`pscore`);
substitute the four scoped group names;
disable ADO PR triggers; add isolated directories/unique keys, assertions,
sanitized evidence, caches and cleanup. HCL authentication is otherwise unchanged.
The documented `>= 1.17.0` constraint is preserved: Terraform compares development
builds using their core version and rejects prerelease suffixes in constraints.

The exact ordered authentication assignments are checked against the source:
GitHub default overrides **only backend client/tenant**, sharing OIDC/AzureAD
flags and the native GitHub broker. GitHub strict also uses the native
`ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN` in **both** init and plan, with no backend
broker overrides. ADO initializes in the state connection, carries only
non-secret identity/connection metadata forward, and plans in the provider
connection. Each task maps its own `System.AccessToken`; `SYSTEM_OIDCREQUESTURI`
remains native. Backend/provider service connection selectors and strict-mode
flags are preserved. No fixed assertion token or broker rewrite is introduced.

The original four cases use separate identities in the state tenant/subscription.
The four cross-tenant entry points keep the same backend but require the provider
client, tenant and subscription IDs all to differ. CSUTF provider resources are
new and isolated; no subscription-wide role is assigned.

The examples do not prove apply, import, cross-job handoff,
long-running token refresh or management-plane endpoint lookup. Plan JSON proves
the provider object ID; provisioning records bind it to the expected client ID.
Successful state access plus deliberately scoped RBAC and
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
`data.azapi_client_config.current` object/tenant/subscription from prior state and the sole planned
resource group's name/type/location/parent subscription/create action.
Only allow-listed non-secret JSON in `evidence\` is published. Never publish raw
plan/state or enable Terraform debug logging. A `finally` block and an always-run
cleanup step remove the entire local run directory, including plan, state metadata
and provider cache. Hosted-runner disposal covers abrupt job termination. Remote
state blobs are not deleted by this harness; the provisioning owner handles them.
