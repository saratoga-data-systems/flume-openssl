# flume-openssl

Prebuilt OpenSSL artifacts for [Flume](https://github.com/saratoga-data-systems/flume),
per platform. This repo is a **git submodule** of `saratoga-data-systems/flume`,
mounted at `openssl/`, so the Flume build links these libraries directly.

## Contents

Per platform (`x86_64_linux`, `aarch64_linux`, `armv7l_linux`, `win64`, `android/<abi>`).  32-bit x86
(`i686_linux`) was retired in Flume 3.5.0 and is no longer built:

- `libcrypto.a` / `libssl.a` — the **base** OpenSSL static libraries (hardened,
  `no-shared`), statically linked into `flume`. Outside the FIPS boundary.
- `fips.so` / `fips.dll` — the **CMVP-validated FIPS provider** (OpenSSL 3.1.2,
  cert #4985), built per its Security Policy with no extra flags. Loaded at runtime.
  `win64/fips.dll` is Authenticode-signed (below).
- `openssl` — the static OpenSSL CLI, kept per platform for testing.

Plus a **single, shared** set of OpenSSL headers at `include/`, used by all platforms.

## Version coupling (important)

Because there is **one shared `include/`**, every platform's `lib*.a` must be built
from the **same OpenSSL version** as the headers — so version bumps are
all-platforms-together. The base libraries track the latest **OpenSSL 3.5.x LTS**
(currently 3.5.9; for CVE/bug fixes); the FIPS provider stays pinned to validated
**3.1.2**.

## Rebuilding

- Base libs + CLI: `./build-base-libs` (Linux, native per arch) / `build-base-libs.ps1` (Windows).
- FIPS provider: `./build-fips-provider` (Linux) / `-android` (NDK) / `.ps1` (Windows).

### Version bump (the base libraries; 3.5.6 -> 3.5.9 on 2026-10-25)

Every platform is built from the same OpenSSL release, then the headers are refreshed, then everything goes in one
commit:

1. **Get the release** `openssl-X.Y.Z.tar.gz` and check it against OpenSSL's published `.sha256`.  The scripts
   check it when they can fetch it; a container without curl prints the hash to check by hand.
2. **Build each platform** with `OSSL_VER=X.Y.Z`.  Every Linux arch is built in **Debian 11 (bullseye, GCC 10.2.1,
   glibc 2.31)**, the environment the libraries' `.comment` sections name, so they link on every supported
   distribution down to Ubuntu 20.04:
   - x86_64: `build-base-libs` in an amd64 `debian:bullseye` container.  Bullseye is past its LTS, and
     deb.debian.org's security pool no longer serves every file its index lists, so point apt at the image's own
     `snapshot.debian.org` lines (`-o Acquire::Check-Valid-Until=false`) and install with
     `--no-install-recommends`: `gcc make perl libc6-dev curl ca-certificates`;
   - aarch64: `build-base-libs` in CI's `pi64bullseyebuild` image on pi64build;
   - armv7l: `build-base-libs` in CI's `pi32bullseyebuild` image on pi64build, under `--platform linux/arm/v7` and
     `setarch linux32`, the way the Jenkinsfile runs the 32-bit stages (`uname -m` then reads `armv8l`, which the
     script maps to `armv7l_linux`);
   - Android: `build-base-libs-android` in CI's `androidbuild` image (its NDK);
   - win64: `build-base-libs.ps1` on a box with Visual Studio, Strawberry Perl and NASM.
3. **Refresh the headers**, `include/openssl/*.h`, from the x86_64 build tree (a `no-shared` build).  Only the
   word-size block of `configuration.h` differs by platform, and flume calls no `BN_*` function, so one set serves
   every platform.
4. **Check each library**: `OpenSSL X.Y.Z` in its strings, the hardening flags in its `compiler:` line, its
   compiler stamp (`readelf -p .comment` on one member), and its property note (`x86 feature: IBT, SHSTK` on
   x86_64, `AArch64 feature: BTI, PAC` on aarch64; armv7l's `readelf -A` reads `v7`, `Thumb-2`, `VFPv3-D16`).
5. **Commit every platform and the headers together.**  The FIPS providers (`fips.so`, `fips.dll`) are not
   touched.  Then bump flume's submodule pointer and run its full CI matrix, a release run included.

## Windows: `fips.dll` is Authenticode-signed (2026-10-24)

`win64/fips.dll` is the module `build-fips-provider.ps1` builds from the validated 3.1.2 source (Security
Policy sec. 11.1), **signed once** with Saratoga Data Systems' code-signing identity: Azure Artifact
Signing, Public Trust, signer `CN="Saratoga Data Systems, Inc."`, timestamped by Microsoft's RFC 3161
authority.

- **Signed before any integrity value exists.**  The policy's integrity test is an HMAC over the whole file,
  computed per host at install by `flume --fips-install` (or `openssl fipsinstall`), so every install's
  value covers the signed bytes.  Signing a module AFTER its value was computed would break the self-test.
  The decision is the FIPS/ATO owner's (WWH, 2026-10-23).
- **What the signature changes:** a certificate table appended to the file (15,712 bytes) and three PE
  header fields: the optional header's `CheckSum`, and the `SECURITY` data directory's address and size.
  Every other byte is the unsigned build's, so the module's code and data are unchanged.

  | `win64/fips.dll` | SHA-256 |
  |---|---|
  | as built, unsigned | `d947c7dd1765ec40e6df67afc6348506da790aa8cb137fdf001a6a55d33b98c3` |
  | as committed, signed | `d62784976779209fdf03c6e0658111c41a2638433f935c496b4919e786d44541` |

- **To check:**
  - `signtool verify /pa /tw win64\fips.dll` verifies the signature and its timestamp.
  - The signed file's first 2,876,416 bytes are the unsigned file's, apart from those three header fields.
  - `signtool remove /s` restores the size but leaves a computed `CheckSum` where the build left 0.
  - Measured on 2026-10-24: with the signed module, `flume --fips-install` passes the KATs and FIPS provider
    3.1.2 loads.  With one byte of the signature changed, the module is refused.
- **Re-sign only when the module is rebuilt:** `build-fips-provider.ps1 -Sign` signs between the copy and
  `fipsinstall`, through flume's `flume-windows-installer/sign-files.ps1 -FipsModule`.  The signing
  certificate's 3-day life does not matter, because the timestamp keeps the signature valid.  `fips.so`
  (Linux, Android) is not signed.

## License

OpenSSL is licensed under the **Apache License 2.0** — see [`LICENSE`](LICENSE). The
Flume build scripts in this repo are (c) Saratoga Data Systems, Inc.
