# Terraform backend live test deployment plan

Status: Deployed

CSUTF extension status: Approved; live access validation blocked on MFA.

## Scope and approval

Create only new isolated development/test assets. Delegated approval: user
requested a new repository, project, and resource groups and instructed autonomous
context selection. No production changes, shared pools, or existing assets.

Build Terraform source `0c5e9bef8b6d76866b0f0ddedab5b72af51bcc27` in both CI
platforms. Extract the four separate-identity examples from documentation commit
`1281ae9db0b308bf26c12d157b105f189e6681db`. Execute init and plan, not apply.
Eight final runs are required: four same-tenant multi-identity cases and four
cross-tenant cases. All require distinct identities; cross-tenant cases additionally
require distinct tenant and subscription IDs.

## Azure context and architecture

Tenant: `azureverifiedmodules.onmicrosoft.com`
(`13b2a159-de04-4835-a3ad-fd814c6adb4f`).
Subscription: `sub-avm-tf-testing-021`
(`121e2ce8-c399-4fea-958a-09d15ed949c4`). Region: `westeurope`.
Recipe: Azure CLI + Bicep; no Azure compute.

For the four additional cross-tenant cases, the user authorized provider subscription
`66bd4c09-0b95-49f7-9db1-a8f69c54e827` (`alz-plz-bootstrap-001`) in CSUTF tenant
`dac8feee-8768-4fbd-9cf9-9d96d4718018`. Keep state infrastructure above unchanged.
Create a new provider identity group `rg-tf36922-csutf-provider`, a new identity
`id-tf36922-csutf-provider`, and four new target groups in that subscription with
the same case names listed below. Confirm names are absent before deployment.
The new provider gets only four target-group Contributor assignments and
GitHub-main/ADO-connection federation. Create `sc-tf36922-csutf-provider`; retain
the original provider assets/connection for the four same-tenant cases. No subscription-wide grants.

CSUTF extension limits/policy checks remain pending live ARM access. Cached
subscription metadata confirms tenant and Enabled state, but ARM returned
AADSTS50076 (MFA required) on 2026-09-08 at 11:33 UTC. No CSUTF resource operation
has been performed. Validate inventory, permissions, limits, policies and what-if
before deploying the extension.

- New state group: `rg-tf36922-e8195f-state`.
- New Standard_LRS StorageV2 account: `sttf36922e8195f`; container: `tfstate`.
- New identities: `id-tf36922-state`, `id-tf36922-provider`.
- New target groups: `rg-tf36922-e8195f-gh-default`,
  `rg-tf36922-e8195f-gh-strict`, `rg-tf36922-e8195f-ado-default`,
  `rg-tf36922-e8195f-ado-strict`.
- New GitHub repository and private ADO project/repository:
  `microsoft-avm-end-to-end-tests/terraform-backend-env-e2e-36922`.

State identity: Storage Blob Data Contributor only at the new container.
Provider identity: Contributor only at the four target groups.
No subscription-wide grants. GitHub main-branch-bound federation and two new ADO
workload-federated service connections, with issuer/subject read from ADO.
Shared keys and anonymous blob access disabled; TLS 1.2 and HTTPS required.

## Limits

Prior authorized inventory/quotas: resource groups 1+5=6/980; storage accounts
0+1=1/250; identities 2 in new group (<800 ARM type bound); federation 2/20 per
identity; role assignments 234+5=239/4000. Storage quota endpoint succeeded;
Resources, ManagedIdentity and Authorization used inventory plus official
limits because their quota endpoints are unsupported. Only subscription policy
observed was SecurityCenterBuiltIn.

## Adaptations and evidence

Replace released CLI installers with pinned source builds; parameterize target
group names and unique run-specific blob keys; add sanitized assertions. Preserve
the documented version constraint, auth logic and init/plan steps.
Precreated resource groups provide scoped RBAC; plan-only examples do not
require imports. Do not publish tokens, plans, or state.

Creator owns upstream comments and screenshots. Return durable run URLs/job IDs.
Keep test infrastructure for review. No automatic resource-group cleanup.

## Progress

- [x] New repositories/project and approved context.
- [x] Generate bootstrap IaC and eight CI entry points from four source examples.
- [x] Validate Bicep and what-if.
- [x] Deploy new infrastructure and federation.
- [x] Run all four same-tenant cases successfully.
- [ ] Validate and deploy the additional CSUTF provider resources after MFA.
- [ ] Run all four cross-tenant cases successfully.
- [ ] Return sanitized evidence.

## 7. Validation proof

Azure CLI confirmed the target subscription/tenant, all five group names absent
(only NetworkWatcherRG exists), and storage account name available. Bicep
0.44.1 is installed. Latest resource schemas were confirmed during preparation.
`az bicep build --file .\infra\main.bicep` succeeded.
`.\infra\Bootstrap.ps1 -Operation Validate` succeeded, correlation ID
`00535890-89a6-4d00-ac34-834af1ccd3b5`.
`az deployment sub what-if` with the same explicit subscription/location and
template succeeded: 13 Create changes, zero Modify/Delete changes. Four provider
role modules report Unsupported/NestedDeploymentShortCircuited because their
principal ID is an output of a newly-created identity. Static inspection confirms
each is a Contributor assignment scoped to its new target group; live assignment
verification will follow deployment. The container-scoped state data role is
included in the preview.

- [x] Azure CLI installation and authentication.
- [x] Bicep compilation and template validation.
- [x] What-if preview and static role verification.
- [x] Azure Policy validation (only SecurityCenterBuiltIn).
- [x] Docker build: not applicable, no containers.

Raw validation and what-if JSON are retained in session artifacts, not published
as CI evidence. Federation validation follows issuer/subject discovery from the
two new connections.

## Deployment evidence

Bootstrap deployment `tf36922-e8195f-bootstrap` succeeded on 2026-09-08,
correlation ID `e44d122c-030c-4856-b7e8-d51c1b633796`.
ADO federation validation succeeded; preview contained two Create changes and
no modifications/deletions. Deployment `tf36922-ado-federation` succeeded,
correlation ID `8c4db30c-7e77-4f7b-a56b-f2625395f125`.

Live role queries confirmed exactly the intended five assignments, with no
subscription-wide roles. Storage endpoint:
https://sttf36922e8195f.blob.core.windows.net/
Shared keys and anonymous access are disabled; TLS 1.2 and HTTPS are enforced.

| Identity | Client ID | ADO connection ID |
| --- | --- | --- |
| State | 4387b74e-0954-4630-a230-4c3a766c2b34 | a772cbab-ead7-4c84-93bf-24a22ec6ab3c |
| Provider | b1c4b1f6-46bc-43ff-8109-55f4d2b6cc33 | bbfc21fb-7bc1-47b2-9578-89a4445edb31 |

The connections returned issuer
`https://login.microsoftonline.com/13b2a159-de04-4835-a3ad-fd814c6adb4f/v2.0`;
their exact returned subjects were used, not constructed.

GitHub's repository OIDC configuration returns subject prefix
`repo:microsoft-avm-end-to-end-tests@177230035/terraform-backend-env-e2e-36922@1361231930`.
The new GitHub credentials use this exact prefix plus `:ref:refs/heads/main`.
The initial name-only subject was rejected with AADSTS700213; no repository/org
OIDC configuration or RBAC was changed to correct it.

## Same-tenant live results

All four runs succeeded on 2026-09-08 using harness
`da708b332389cd72f62dee532dd728198b4a313e`. Their sanitized build/identity/resource
evidence and run URLs are preserved in `results/same-tenant/manifest.json`.
GitHub runs: `34222433385` (default), `34222437502` (strict).
ADO builds: `138` (default), `139` (strict).

Each built core `0c5e9bef8b6d76866b0f0ddedab5b72af51bcc27` with Go 1.26.4 and
reported Terraform 1.17.0-dev. All four binary SHA-256 values are
`6256a318b480ad095855740dfcfde6cd940d8c585ab92e5688cc23090822702e`.
Init, plan, identity/resource assertions and cleanup succeeded. No apply occurred.
Cross-tenant execution is still blocked on the separate CSUTF MFA sign-in.
