# CyberDrain Azure SWA Deploy

[![CI](https://github.com/CyberDrain/swa-deploy-action/actions/workflows/ci.yml/badge.svg)](https://github.com/CyberDrain/swa-deploy-action/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A drop-in replacement for [`Azure/static-web-apps-deploy`](https://github.com/Azure/static-web-apps-deploy). It talks to the same Azure content distribution API, but **starts working immediately instead of building a container first**, and **tells you why a deployment failed** instead of returning a dead-end string.

```diff
- uses: Azure/static-web-apps-deploy@v1
+ uses: CyberDrain/swa-deploy-action@v1
  with:
    azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
    action: upload
    app_location: "/"
    output_location: "dist"
```

---

## 1. Speed: no per-run container build

The official action is a Docker action built from a `Dockerfile`, so **every job starts with a `Build <action>` step** — the runner pulls a 1.58 GB base image and builds a container before touching your site. From a real run:

```
1. Set up job                              2s
2. Build Azure/static-web-apps-deploy@v1  21s   ← pure overhead
3. Run actions/checkout@v6                 2s
4. Build And Deploy                       21s
                                    total 46s
```

Step 2 doesn't exist for a composite action, and it's paid **per job** — a matrix across N sites pays it N times.

The upload itself is *not* faster. It's server-bound and identical for both clients: same 1,232-file / 59 MB site, 27s for the official action against 35s here, within run-to-run variance. The win is the container build you stop paying, plus failing in ~2s when the deploy was never going to succeed.

This is a composite action, so it also runs on Windows and macOS runners — Docker actions are Linux-only.

---

## 2. Error handling: it names the actual cause

The official client understates the payload it uploads, so quota breaches pass validation and resurface minutes later as:

```
Deployment failed: Failure during content distribution.
```

Neither the API nor ARM returns anything more, and the upload is already spent. This action reports the payload's **true file count and uncompressed size** in the upload request, so the server rejects it up front, by name — in ~2s, before uploading a byte:

```
The content server rejected /api/upload/request with 400.
Reason: The number of static files was too large.
```

Other failures get the same treatment:

- **Nested and array error payloads are flattened**, so you get `DistributionFailed: Failure during content distribution.: blob upload denied` instead of `System.Object[]`.
- **Failure envelopes are checked on every call.** The content server returns *HTTP 200* wrapping `isSuccessStatusCode: false` — miss that and the real reason is silently discarded.
- **`unhealthyRegions` is surfaced**, since regional distribution failures name regions there rather than in the error field.
- **Unrecognized fields fall back to raw JSON** rather than being dropped, so a payload shape we've never seen still reaches you.
- **Failures carry context** — content host and correlation ID, which is what Azure support asks for first.

Failures land as `::error::` annotations and a job-summary table, not a PowerShell stack trace.

---

## Preview environments

`deployment_environment` deploys to a named environment instead of production; `production_branch` sends every other branch to one named after the branch. Verified against a live app — the preview gets its own hostname (`<app>-<environment>.<region>.azurestaticapps.net`) and production is untouched.

One Azure constraint worth knowing: **environment names may only contain letters and digits.** A branch called `feature/new-ui` is folded to `featurenewui` and the substitution is logged, because passing it through verbatim gets the deployment rejected outright.

Teardown (`action: close`) isn't implemented — see [Not supported](#not-supported).

## Deploying from a URL

Beyond the official input set: point at a prebuilt artifact and skip the checkout and build entirely.

```yaml
- uses: CyberDrain/swa-deploy-action@v1
  with:
    azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
    zip_url: https://releases.example.com/latest.zip
    zip_subdirectory: out          # deploy only out/ from inside the zip
```

Useful for fanning one release out across many Static Web Apps: build once, then deploy the same artifact N times without N checkouts. Downloads stream to disk with a size cap (`max_download_mb`, default 1024), and a zip is refused before expansion if it declares more uncompressed content than the platform allows.

## Building

Replicates what Oryx does for Node projects, using the runner's toolchain instead of bundled runtimes:

| Detected | Install | Build |
|---|---|---|
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` | `pnpm run build` |
| `yarn.lock` | `yarn install --frozen-lockfile` | `yarn run build` |
| `package-lock.json` | `npm ci` | `npm run build` |
| `package.json` only | `npm install` | `npm run build` |
| no `package.json` | — | — (deployed as-is) |

`build` runs only if `package.json` declares it. Commands run through the platform shell (`bash` on Linux/macOS, `pwsh` on Windows), so shell syntax works as written. Use `app_build_command` to override detection, or `skip_app_build: true` to deploy prebuilt output untouched.

### Node version

`engines.node` (or `.nvmrc`) is resolved against **nodejs.org's live release index**, so a range keeps selecting current releases — unlike Oryx, whose runtimes are frozen into its image:

```
Node 24.11.1 (project asks for '20.x' via package.json engines.node)
Resolved '20.x' to Node 20.20.2 (LTS Iron)
Installing Node 20.20.2 (darwin-arm64)...
Building with Node 20.20.2
```

How it resolves, cheapest first:

1. **Runner's Node already satisfies the range** → nothing happens. This is the common case and costs zero.
2. **Version is in the runner tool cache** (e.g. `setup-node` put it there) → reused, no download.
3. **Otherwise** → download from nodejs.org, **verify SHA256 against the release's published `SHASUMS256.txt`**, extract, and prepend to `PATH` for this action and later steps.

Ranges support `>=`, `>`, `<=`, `<`, `^`, `~`, `=`, bare and X-ranges, space-separated AND, and `||`, compared on major, minor and patch. Unparseable ranges are left alone.

A failed download warns and builds with the runner's Node rather than failing the deploy. Set `install_node: false` to always warn instead:

```yaml
- uses: CyberDrain/swa-deploy-action@v1
  with:
    azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
    output_location: "dist"
    install_node: false     # warn on mismatch; don't fetch anything
```

You can still use `actions/setup-node` — this action will find and reuse whatever it installed. Just don't restate the version in the workflow; point it at the file that already declares it:

```yaml
- uses: actions/setup-node@v7
  with:
    node-version-file: package.json   # reads engines.node (or use .nvmrc)
    cache: npm
```

## Input compatibility

Every input of the official action is accepted, so the swap is a one-line change.

| Input | Status |
|---|---|
| `azure_static_web_apps_api_token` | ✅ |
| `action` | ✅ `upload` — ❌ `close` fails (see below) |
| `app_location`, `output_location`, `app_artifact_location` | ✅ |
| `app_build_command` | ✅ overrides detection |
| `skip_app_build` | ✅ |
| `config_file_location` | ✅ `staticwebapp.config.json` injected at payload root |
| `deployment_environment`, `production_branch` | ✅ verified against a real preview deployment |
| `skip_api_build`, `is_static_export` | ⚠️ accepted, no effect (Oryx-only hints) |
| `repo_token`, `github_id_token` | ⚠️ accepted, unused — no PR commenting |
| `api_location`, `api_build_command`, `data_api_location` | ❌ **fails** — managed Functions / Data API |
| `routes_location` | ❌ **fails** — `routes.json` is deprecated |

Unsupported inputs fail loudly rather than being silently ignored, so a half-migrated workflow can't quietly deploy something wrong.

**Additional inputs:** `install_node`, `zip_url`, `zip_subdirectory`, `max_download_mb`, `verbose`.

**Output:** `static_web_app_url`.

### Not supported

- **Managed Azure Functions and the Data API.** Static content only. Keep the official action for those, or use a [linked backend](https://learn.microsoft.com/azure/static-web-apps/apis-overview).
- **`action: close`.** Preview-environment teardown needs an API this action doesn't implement:

  ```yaml
  - if: github.event.action == 'closed'
    uses: Azure/static-web-apps-deploy@v1
    with:
      azure_static_web_apps_api_token: ${{ secrets.AZURE_STATIC_WEB_APPS_API_TOKEN }}
      action: close
  ```

## Input handling

Location inputs decide what gets zipped and uploaded to a public URL, so they're validated rather than trusted:

- **`app_location`, `output_location`, `config_file_location`** are normalized and rejected if they resolve outside `GITHUB_WORKSPACE` — `../../.ssh` fails instead of packaging runner state. A leading `/` means workspace-relative, matching the official action.
- **`zip_subdirectory`** is rejected if it contains a `..` segment.
- **`zip_url`** must be `http`/`https`, streams to disk under a byte cap enforced during transfer (not from `Content-Length`, which a server can understate), and is never logged with its query string — SAS tokens live there.
- **The deployment token is registered with `::add-mask::`.** No code path logs it; verbose logging prints request paths only.
- **Values written to `GITHUB_OUTPUT` are stripped of newlines**, so a value can't inject extra step outputs.

Not defended against, and neither does the official action: a symlink committed inside the workspace pointing outside it is followed when packaging. Don't run deployments against untrusted pull requests.

## Platform quotas

[Azure limits](https://learn.microsoft.com/azure/static-web-apps/quotas) every plan to **15,000 files**, and a single environment to **500 MB** (250 MB on Free). Both are measured before upload and reported in the request — breaching either is what produces "Failure during content distribution." from the official client.

## Using the module directly

The action is a thin wrapper over a PowerShell module that works outside CI:

```powershell
Import-Module ./src/SwaDeploy.psd1

Invoke-SwaDeployment -DeploymentToken $token -Path ./dist
Invoke-SwaDeployment -DeploymentToken $token -Path ./release.zip -ZipSubdirectory out
Invoke-SwaDeployment -DeploymentToken $token -ZipUrl https://releases.example.com/latest.zip -ZipSubdirectory out

# Check quotas without deploying
Test-SwaQuota -Payload (New-SwaPayload -Path ./dist)
```

| Function | Purpose |
|---|---|
| `Invoke-SwaDeployment` | Full deploy: package, validate, upload, poll |
| `New-SwaPayload` | Build the zip and measure it |
| `Test-SwaQuota` | Report file-count / size breaches |
| `Get-SwaRemoteZip` | Download a zip under a size cap |
| `Resolve-SwaWorkspacePath` | Resolve a path input, rejecting workspace escapes |
| `Resolve-SwaContentHost` | Derive the content host from a deployment token |
| `Get-SwaBuildPlan` / `Invoke-SwaBuild` | Detect and run the project build |
| `Resolve-SwaNodeVersion` / `Install-SwaNode` | Resolve a range against nodejs.org and install it |
| `Test-SwaVersionRange` | npm-style semver range matching |
| `ConvertTo-SwaErrorText` / `Get-SwaStatusError` | Flatten API error payloads |

## Development

```bash
pwsh -c "Invoke-Pester ./tests"
pwsh -c "Invoke-ScriptAnalyzer -Path ./src -Recurse -Severity Error,Warning"
```

## Credits

Extracted from CyberDrain's CIPP hosted-deployment tooling.

## License

[Apache License 2.0](LICENSE)
