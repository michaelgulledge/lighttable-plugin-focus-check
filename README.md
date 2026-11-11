# lighttable-plugin-focus-check

Focus Check — a plugin for [Light Table](https://github.com/michaelgulledge/lighttable). Plugin ids: com.idlewild.lighttable.focus-check.

This repository builds on its own but **ships inside Light Table**: `scripts/build.sh` compiles the plugin and writes the packaged result into the Light Table checkout's `build/` and `dist/` folders, which is where Light Table's release tooling picks plugins up. Do not commit build output here.

## Layout

| Path | Purpose |
| --- | --- |
| `Sources/` | The plugin's Swift targets. |
| `Tests/PluginTests/` | Unit tests (run by `scripts/test.sh` and by Light Table's `verify.py`). |
| `lighttable-plugin.json` | Packaging config: id, display name, **version and build number**, capabilities, network access, description, variables, extra manifest fields and resources to copy into the package. The packager turns it into `plugin.json` and `Info.plist`. |
| `INSTALL.md` | User-facing text. It is copied into the package as `README.md`. |
| `scripts/build.sh`, `scripts/test.sh` | Build/package and test entry points. |

## Prerequisites

- macOS 14+, Xcode with Swift 6.1 or later.
- A Light Table checkout next to this repository (`../lighttable`), or any checkout named by `LIGHTTABLE_ROOT`. The plugin compiles against that checkout's `LightTablePluginKit` / `LightTableCore` libraries, so build against the Light Table version you intend to ship with. The packaging script, plugin icon and signing steps come from the same checkout (`scripts/package-plugin.py`).

## Build into Light Table

```sh
scripts/build.sh            # release (default)
scripts/build.sh debug      # debug build for UI/integration checks
LIGHTTABLE_ROOT=/path/to/lighttable scripts/build.sh   # a different Light Table checkout or worktree
```

Output, under `$LIGHTTABLE_ROOT`:

- `build/plugins/Focus-Check-1.0.0.ltplugin` — the runnable, ad-hoc-signed package
- `dist/plugins/Focus-Check-1.0.0.zip` — the distribution archive (older zips move to `dist/archive/plugins/`)
- `dist/checksums/plugins/<name>.zip.sha256` — its checksum

Confirm all three exist before calling a build done. To try it, install the `.ltplugin` from **Settings → Plugins → Install or update plugin…** in Light Table.

## Test

```sh
scripts/test.sh                       # swift test against the Light Table checkout
scripts/test.sh --filter SomeTests    # one suite
```

Every fix needs a regression test that fails without the fix.

## Releasing a new version

1. Bump `version` (and `build`) for the plugin in `lighttable-plugin.json`. The version appears in the artifact filename.
2. `scripts/test.sh` and `scripts/build.sh release`; check the package, zip and checksum.
3. Commit and push this repository, and tag it `v<version>`.
4. Light Table releases are built from the Light Table repo: `python3 scripts/verify.py release` there rebuilds every plugin repo it finds (see below), and the plugin zip is attached to the GitHub release (releases are immutable, so attach it before publishing).

## How Light Table finds this repo

Light Table's `scripts/build-plugins.sh`, `scripts/test-plugins.sh` and its verification ledger look for sibling folders named `lighttable-plugin-*` next to the main Light Table checkout (override with `LIGHTTABLE_PLUGINS_DIR`). Keep this folder name and a clean, committed working tree when running a release: the ledger keys plugin checks on each repository's committed tree and refuses to reuse results from a dirty one.
