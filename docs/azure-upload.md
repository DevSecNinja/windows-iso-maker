# Azure Blob upload (optional)

A full Windows 11 ISO (~5–7 GB compressed) can strain GitHub Actions artifact size/retention
limits. As an optional, durable alternative, `build-image.yml` can upload the build outputs to
**Azure Blob Storage** using **OIDC federation — no stored secrets** (FR-030, Principle VII).

When Azure is **not** configured, the workflow falls back to a normal per-architecture
`actions/upload-artifact`. Nothing is required to use the default behaviour.

## What gets uploaded

The entire `out/` directory for each architecture — the compressed ISO, `SHA256SUMS`,
`run-report.json`, and the Image BOM — under a per-run prefix:

```
<container>/windows11/<arch>/<run_id>/...
```

## Enabling it

Set these **repository variables** (Settings → Secrets and variables → Actions → *Variables*).
They are non-secret configuration; the actual authentication is done via OIDC.

| Variable | Purpose |
|----------|---------|
| `AZURE_STORAGE_ACCOUNT` | Target storage account name |
| `AZURE_STORAGE_CONTAINER` | Target blob container name |
| `AZURE_CLIENT_ID` | App registration (federated identity) client id |
| `AZURE_TENANT_ID` | Entra tenant id |
| `AZURE_SUBSCRIPTION_ID` | Subscription id |

If `AZURE_STORAGE_ACCOUNT` **and** `AZURE_STORAGE_CONTAINER` are both set, the workflow logs in
with `azure/login` (OIDC) and runs `az storage blob upload-batch --auth-mode login`. Otherwise
it uploads a GitHub Actions artifact instead.

## One-time Azure setup (OIDC, no secrets)

1. Create (or reuse) a storage account + container.
2. Create an Entra app registration and add a **federated credential** for GitHub Actions
   scoped to this repository (subject e.g. `repo:DevSecNinja/windows-iso-maker:ref:refs/heads/main`
   or an environment).
3. Grant the app the **Storage Blob Data Contributor** role on the account/container.
4. Set the repository variables above.

Because authentication is federated, **no client secret or storage key is ever stored** in the
repository. The `id-token: write` permission in the workflow lets GitHub mint the short-lived
OIDC token that `azure/login` exchanges for Azure credentials.
