# Agent notes — lighttable-plugin-focus-check

- This is a Light Table plugin repo. Read `README.md` first; it has the build, test, and release steps.
- Build with `scripts/build.sh [release|debug]`; it writes the package, zip and checksum into the Light Table checkout (`LIGHTTABLE_ROOT`, default `../lighttable`). Report a build as done only after checking those three artifacts exist.
- Test with `scripts/test.sh`. Every fix needs a regression test. Do not build against a Light Table checkout with uncommitted changes you did not make.
- Version, build number, capabilities and description live in `lighttable-plugin.json`. API 1 capability names are frozen (`codes`, `ingest`, `transfer`, `editing`, `culling`); add new integrations as optional manifest fields.
- Never write reverse-domain ids into artifact filenames; the packager derives names from the display name and version.
