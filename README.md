# flume-openssl

Prebuilt OpenSSL artifacts for [Flume](https://github.com/saratoga-data-systems/flume),
per platform. This repo is a **git submodule** of `saratoga-data-systems/flume`,
mounted at `openssl/`, so the Flume build links these libraries directly.

## Contents

Per platform (`x86_64_linux`, `aarch64_linux`, `armv7l_linux`, `i686_linux`, `win64`,
`android/<abi>`):

- `libcrypto.a` / `libssl.a` — the **base** OpenSSL static libraries (hardened,
  `no-shared`), statically linked into `flume`. Outside the FIPS boundary.
- `fips.so` / `fips.dll` — the **CMVP-validated FIPS provider** (OpenSSL 3.1.2,
  cert #4985), built per its Security Policy with no extra flags. Loaded at runtime.
- `openssl` — the static OpenSSL CLI, kept per platform for testing.

Plus a **single, shared** set of OpenSSL headers at `include/`, used by all platforms.

## Version coupling (important)

Because there is **one shared `include/`**, every platform's `lib*.a` must be built
from the **same OpenSSL version** as the headers — so version bumps are
all-platforms-together. The base libraries track the latest **OpenSSL 3.5.x LTS**
(currently 3.5.2; for CVE/bug fixes); the FIPS provider stays pinned to validated
**3.1.2**.

## Rebuilding

- Base libs + CLI: `./build-base-libs` (Linux, native per arch) / `build-base-libs.ps1` (Windows).
- FIPS provider: `./build-fips-provider` (Linux) / `-android` (NDK) / `.ps1` (Windows).

## License

OpenSSL is licensed under the **Apache License 2.0** — see [`LICENSE`](LICENSE). The
Flume build scripts in this repo are (c) Saratoga Data Systems, Inc.
