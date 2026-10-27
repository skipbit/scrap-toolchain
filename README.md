# scrap-toolchain

Toolchain registry for [scrap](https://github.com/skipbit/scrap) — a C/C++ build system.

This repository defines **molds** (toolchain recipes) and the CI/CD pipeline that validates and distributes them as **ingots** (prebuilt toolchain packages).

## Directory Structure

```
scrap-toolchain/
├── molds/                          # Toolchain recipes
│   └── {family}/{version}/
│       ├── mold.toml               # Recipe definition
│       └── patches/                # Optional patches (build type only)
├── schema/
│   └── mold-v1.schema.json         # JSON Schema for mold.toml validation
├── scripts/                        # CI/CD helper scripts
├── .github/workflows/              # GitHub Actions workflows
├── platforms.toml                   # Platform matrix (Tier 1/2)
├── index.toml                      # Auto-generated toolchain index
└── README.md
```

## Pipeline Overview

1. A contributor submits a PR adding or updating a `molds/{family}/{version}/mold.toml`
2. **PR Validation** — the mold is validated against `schema/mold-v1.schema.json`, and **fetch-type** molds are verified on Tier 1 platforms where binaries are defined (Linux platforms are mandatory; macOS is verified when a binary is available)
3. On merge, **Ingot Cast** — CI processes the mold:
   - **fetch** molds: no artifacts produced (validation already done in step 2)
   - **build** molds: CI builds the toolchain and pushes ingots to `ghcr.io` as OCI artifacts
4. **Index Update** — `index.toml` is regenerated from mold definitions and build artifacts, then committed to the repository

## Mold Types

- **fetch** — References prebuilt binaries from upstream (e.g., LLVM official releases). CI validates the recipe but does not produce artifacts; users download directly from upstream.
- **build** — Builds from source (e.g., GCC). CI produces ingots and pushes them to `ghcr.io` as OCI artifacts. A build mold can list sources built into the toolchain (`source.build.in_tree`, e.g., GMP, MPFR, MPC and ISL for GCC) and packages installed alongside it (`source.build.companions`, e.g., binutils), so that the ingot runs without the libraries and tools of the machine that built it.

## Platform Tiers

| Tier | Platforms | Support |
|------|-----------|---------|
| Tier 1 | linux-x86_64, linux-aarch64, darwin-aarch64 | Full CI validation, official distribution |
| Tier 2 | darwin-x86_64 | Source build only |

## System Requirements (Linux)

Every toolchain uses the C library of the system: glibc at least the `glibc_version` that `index.toml` lists for the ingot, and its headers (`libc6-dev` on Debian and Ubuntu).

- **GCC** ingots carry everything else they need to compile and link, including binutils and the libraries the compiler loads.
- **LLVM** molds use the upstream release binaries as they are, which also need:
  - the C++ standard library headers (`libstdc++-<N>-dev`)
  - `libxml2` for LLVM 17 to 23.1.2 (except LLVM 17 on aarch64)
  - ICU 70 (`libicu70`, packaged in Ubuntu 22.04) for LLVM 23.1.0 to 23.1.2
  - binutils, unless linking with `-fuse-ld=lld`

## License

This repository is licensed under [MIT](LICENSE).

**Important**: The distributed toolchain ingots are subject to their respective upstream licenses, **not** MIT. Each ingot includes the relevant license files as specified by the `metadata.license_files` field in its `mold.toml`.

| Toolchain | License | License Files | Status |
|-----------|---------|---------------|--------|
| LLVM/Clang | Apache-2.0 WITH LLVM-exception | `LICENSE.TXT` | Available |
| GCC | GPL-3.0-or-later WITH GCC-exception-3.1 AND (LGPL-3.0-or-later OR GPL-2.0-or-later) AND LGPL-3.0-or-later AND MIT | `COPYING`, `COPYING.RUNTIME`, and `licenses/` for binutils, GMP, MPFR, MPC and ISL | Available |

### How licensing works

- **Repository code** (scripts, workflows, schema): MIT
- **Mold definitions** (`mold.toml`): MIT (as part of the repository)
- **Distributed ingots**: Each toolchain's own license. The `mold.toml` `metadata.license` field declares the SPDX identifier, and `metadata.license_files` lists the files that must be present in the upstream distribution. `cast-ingot.sh` verifies their presence during validation.
- **Bundled sources** (`source.build.in_tree` and `source.build.companions`): their own licenses, included in the ingot under `licenses/<name>/` from the `license_files` of each entry, and covered by `metadata.license`.

For contributors adding new molds: ensure `metadata.license` and `metadata.license_files` are accurate for the upstream project. The CI pipeline will fail if specified license files are missing from the upstream distribution.
