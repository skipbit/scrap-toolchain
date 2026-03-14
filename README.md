# scrap-toolchain

Toolchain registry for [scrap](https://github.com/skipbit/scrap) — a C/C++ build system.

This repository defines **molds** (toolchain recipes) and the CI/CD pipeline that transforms them into **ingots** (prebuilt toolchain packages) distributed via GitHub Releases.

## Directory Structure

```
scrap-toolchain/
├── molds/                          # Toolchain recipes
│   └── {family}/{version}/
│       ├── mold.toml               # Recipe definition
│       └── patches/                # Optional patches
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
2. **PR Validation** — the mold is validated against `schema/mold-v1.schema.json`
3. On merge, **Ingot Cast** — CI builds/fetches the toolchain for each Tier 1 platform
4. Built artifacts are uploaded to **GitHub Releases** as ingots
5. **Index Update** — `index.toml` is regenerated and committed, serving as the registry index

## Mold Types

- **fetch** — Downloads prebuilt binaries (e.g., LLVM official releases)
- **build** — Builds from source (e.g., GCC)

## Platform Tiers

| Tier | Platforms | Support |
|------|-----------|---------|
| Tier 1 | linux-x86_64, linux-aarch64, darwin-aarch64 | Official binaries, full CI |
| Tier 2 | darwin-x86_64 | Source build only |

## License

[MIT](LICENSE)
