# Client API fixtures

`api-version.json` is a checked fixture for release-managed Parle API version drift. It is intentionally static in this repo: CI catches adapter-package drift against the recorded API contract, while live server drift is handled at runtime by the unsupported-version diagnostic that names the sent version, source, adapter default, and server-supported values when the API returns them.

Refresh this fixture in the same change that bumps the adapter `DEFAULT_VERSION`.
