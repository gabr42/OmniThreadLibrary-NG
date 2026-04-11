# OmniThreadLibrary NG

**OmniThreadLibrary New Generation** is a cross-platform rewrite of [OmniThreadLibrary](https://github.com/gabr42/OmniThreadLibrary), a mature Delphi threading library providing task-based concurrency, parallel abstractions, thread pools, and synchronization primitives.

## What's different from OTL v3?

- **Cross-platform**: Targets Windows, macOS, Linux, iOS, and Android (v3 is Windows-only)
- **Minimum Delphi version**: 11 Alexandria (v3 supports back to XE2)
- **No inline assembly**: All synchronization primitives use `TInterlocked` / `System.SyncObjs`
- **Platform abstraction layer**: `IOmniEvent`, `TSynchroWaitFor`, condition-variable-based waiting replace Windows-specific `THandle`, `WaitForMultipleObjects`

## Status

Active development. See the `develop` branch for current work.

## OTL v3

The stable, production-ready, Windows-only version of OmniThreadLibrary is maintained at:
https://github.com/gabr42/OmniThreadLibrary

## Author

Primoz Gabrijelcic (gabr42)

## License

BSD-3-Clause (same as OTL v3)
