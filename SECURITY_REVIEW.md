# Dependency and security review — October 27, 2026

The changes are local and have not been deployed. Package versions were checked against RubyGems, PyPI, the Ruby/Rails release sites, and the browser-library registries.

## Dependencies

| Component | Updated version |
| --- | --- |
| Ruby / Rails | 4.0.9 / 8.1.4 |
| Puma / Rack | 8.0.2 / 3.2.7 |
| Python | 3.12.16 in the verified Docker build |
| AMIGA / GPy / Paramz | 3.0.4 / 1.15.0 / 0.10.0 |
| NumPy / pandas | 2.3.5 / 2.3.3 |
| SciPy / Matplotlib | 1.18.1 / 3.11.2 |
| PDF previews | pypdfium2 5.14.0; ImageMagick/Ghostscript removed |
| Bootstrap / jQuery | 5.3.8 / 4.0.0, with CDN integrity hashes |

PostgreSQL is pinned to the current supported 16.15 patch release. A change to the newest major requires a separate data migration. Inbucket is updated to 3.2.0; the optional Nginx proxy uses the current stable 1.30.6 release.

The Ruby lockfile updates all resolved gems. `requirements.txt` pins all 31 Python packages with hashes; `requirements.in` is the editable dependency list. The unused Webpacker 5 / Webpack 4 toolchain and tracked `node_modules` were removed; Rails already uses Sprockets and import maps.

AMIGA's latest release still requires Python below 3.13. Real analysis tests demonstrated that NumPy 2.4+ breaks its array-to-integer conversion and pandas 3 breaks its categorical hypothesis-test processing. Those two libraries use the newest verified compatible releases, with explicit bounds in `requirements.in`. Both pass the current advisory audit. These bounds can be reconsidered after AMIGA fixes the incompatibilities.

## Security changes

- Analysis and Python subprocesses receive argument arrays rather than interpolated shell commands, preventing uploaded labels and analysis selections from executing shell syntax.
- Restored CSRF verification on upload, analysis selection, and review. Clearing uploads requires DELETE; GET/HEAD review requests cannot change analysis selections.
- Result downloads require the submitting session or an existing administrator. An email address alone grants no access to another session's previous jobs. Traversal and symlink escapes are rejected.
- Admin login rotates the session; logout clears it. Stale administrator IDs no longer authorize requests. Login has a per-process IP limit of 10 requests per three minutes.
- Initial admin creation requires an explicitly supplied password of at least 12 characters. Re-seeding preserves existing administrators. The reset task no longer prints passwords.
- Production enforces HTTPS and secure, HTTP-only, SameSite=Lax session cookies; the HTTP health check remains available.
- PDF previews use a dedicated PDFium subprocess in place of ImageMagick/Ghostscript, removing unused image/XML codec libraries and their OS advisories. Single-page and multi-page rendering are tested.
- Docker excludes local secrets, upload data, debugger history, and generated dependencies. The production image runs as UID 1001 and uses current Debian security updates. Setuid/setgid helper permissions, compiler tools/headers, the superseded vulnerable default JSON implementation, and unused bundled Python packaging tools are removed. Development web/database ports bind only to localhost.
- The previously tracked Rails master key and debugger history are removed from Git tracking, while their local files are preserved. Their history is not rewritten.

## Validation

- Rails: 93 tests, 634 assertions, no failures/errors/skips.
- Python: six tests, including actual unpooled/pooled fitting, posterior sampling, parameter comparison, hypothesis testing, heatmaps, raw-data plotting, and PDF-to-PNG rendering.
- Ruby advisory audit: no known vulnerabilities.
- Python advisory audit: no known vulnerabilities across the 31 locked packages.
- Brakeman: no unreviewed warnings. Four bounded filesystem-path warnings are individually documented in `config/brakeman.ignore`; they are reviewed findings, not scanner-proven absence of risk.
- An isolated headless Chrome run passes the real CSRF-protected upload, selection, and review forms with jQuery 4 and no JavaScript errors.
- Container scan: zero critical findings and no high/critical Ruby, Python, or Node package findings. Eight high-severity Debian advisories remain across 43 package entries, with no vendor fix listed by the scanner. Details are in [security/container-advisories.json](security/container-advisories.json). These are package advisories, not confirmed exploitable HTTP paths; they have not been suppressed.
- Rails autoload check and production asset compilation pass. The production image boots as UID 1001, serves the homepage and health check, and redirects HTTP to HTTPS.

Run the checks again using the current built image:

```sh
docker compose run --rm web bin/security
docker compose run --rm test
docker compose run --rm web python -m unittest discover -s test/scripts -p '*_test.py'
```

## Deployment actions still required

Track the eight remaining Debian advisories and rebuild when vendor fixes become available. The production image is not a zero-finding image; no claim of complete safety is made.

1. Rotate the previously committed Rails master key and any credentials it protected if that key was shared or used in a deployment. Removing it now does not remove historical copies. Supply the new key/credentials or `SECRET_KEY_BASE` through the deployment's secret store; expect session invalidation when rotating session secrets.
2. Change any existing admin password that still uses the former default. The new seed behavior intentionally does not overwrite existing passwords.
3. Verify HTTPS forwarding and storage permissions in the actual OpenShift deployment. The local non-root image has been tested, but the deployed configuration has not.
4. Apply shared ingress limits and upload/compute quotas for public or multi-replica deployments. The login backstop is local to each process, and an unverified email is not proof of identity. The existing per-email job limit is not a substitute for these controls.

Advisory checks cannot guarantee absence of unknown vulnerabilities. No live-site exploitation, deployment, or live credential rotation was performed.

## Sources

- [Ruby releases](https://www.ruby-lang.org/en/downloads/) and [Rails releases](https://rubyonrails.org/category/releases)
- [RubyGems package registry](https://rubygems.org/) and [PyPI package registry](https://pypi.org/)
- [PostgreSQL versioning and upgrade policy](https://www.postgresql.org/support/versioning/)
- [pypdfium2 API and bundled PDFium version](https://pypdfium2.readthedocs.io/en/stable/python_api.html)

- [Nginx stable releases](https://nginx.org/en/download.html) and [Inbucket releases](https://github.com/inbucket/inbucket/releases/latest)
