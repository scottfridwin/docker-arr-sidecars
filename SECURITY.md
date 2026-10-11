# Security policy

## Supported versions

Only the latest release receives fixes. Images are rebuilt automatically when the base images or dependencies get
security updates.

## Reporting a vulnerability

Please report vulnerabilities privately through
[GitHub's private vulnerability reporting](https://github.com/scottfridwin/docker-arr-sidecars/security/advisories/new)
rather than in a public issue. Include the image and version, how to reproduce the problem and its impact. You should
get a response within a week.

## Verifying images

Every published image has a build provenance attestation signed by GitHub Actions:

```bash
gh attestation verify oci://ghcr.io/scottfridwin/lidarr-sidecar:3 --repo scottfridwin/docker-arr-sidecars
```
