### What is OmniThreadLibrary NG?

OmniThreadLibrary NG ("New Generation") is the cross-platform successor of [OmniThreadLibrary](https://github.com/gabr42/OmniThreadLibrary) (OTL v3), a threading library for Delphi. It keeps the core OTL programming model - tasks, workers, message passing, thread pools, blocking collections, pipelines, `Parallel.For`/`ForEach`, futures and more - and removes the dependency on Windows.

OTL NG is **pre-alpha**. It is not a drop-in replacement for OTL v3; see [MIGRATION.md](MIGRATION.md) for all differences from v3.09 and how to migrate.

### How do I get OTL NG?

Clone the repository and use the `develop` branch:

    git clone https://github.com/gabr42/OmniThreadLibrary-NG.git

The library has no external dependencies. The unit tests use [DUnitX](https://github.com/VSoftTechnologies/DUnitX), and the `FastMM4` submodule is used by the test runners only.

OTL NG is not available through GetIt, Delphinus or DPM.

### How do I use OTL NG?

Add the folder with the sources to your library path (or use the runtime package from the `packages` folder) and add the OTL units to your `uses` clause. There are no design-time packages. Examples are in the `examples` folder; [OtlParallel.md](OtlParallel.md) documents the high-level `Parallel` abstractions. Tutorials for OTL v3 on [www.omnithreadlibrary.com](http://www.omnithreadlibrary.com) are mostly applicable, except for the differences listed in [MIGRATION.md](MIGRATION.md).

### Is OTL NG supported on my platform?

Minimum compiler version is **Delphi 11 Alexandria**; Delphi 12 and 13 are also supported. Runtime packages are provided for Delphi 11, 12 and 13.

| Platform | Status |
|----------|--------|
| Win32, Win64 | Tested (VCL, FMX and console) |
| Linux64 | Tested (console), Delphi 13 only |
| Android64 | Tested (FMX runner on an ARM64 device), Delphi 13 only |
| Windows ARM64EC | Compiles, not tested |
| macOS, iOS | Targeted, not verified |

There are no plans to support older Delphi compilers. If you need Delphi 2007-10.4 or you only target Windows, use [OTL v3](https://github.com/gabr42/OmniThreadLibrary).

### How do I run the tests?

Build and run `unittests/ConsoleTestRunner.dpr` (Win32, Win64, Linux64) or `unittests/OtlAndroidTests.dpr` (Android). `unittests/CompileAllUnits.dpr` is a compile-only smoke test across all units. See [CLAUDE.md](CLAUDE.md) for the exact compiler command lines.

### How do I get support?

Support is provided through the [OmniThreadLibrary forum](https://en.delphipraxis.net/forum/32-omnithreadlibrary/). Bugs can be reported on the [issue tracker](https://github.com/gabr42/OmniThreadLibrary-NG/issues).

### Where can I get more information?

Go to [www.omnithreadlibrary.com](http://www.omnithreadlibrary.com).
