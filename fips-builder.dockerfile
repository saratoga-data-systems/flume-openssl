# fips-builder.dockerfile -- reproducible build environment for the CMVP #4985
# OpenSSL 3.1.2 FIPS provider (fips.so).
#
# WHY debian:11.5: it pins gcc 10.2.1 / glibc 2.31 -- the lowest-glibc operating
# environment in the #4985 Security Policy (140sp4985.pdf) Sec. 5.3 tested list,
# so ONE fips.so is both validation-matched AND portable across modern x86_64
# Linux (RHEL 9 = glibc 2.34, Ubuntu 20.04+, Debian 11/12).  Do NOT bump the
# base image and do NOT add compiler hardening flags -- a different build is no
# longer the validated module.  (The base libcrypto/libssl and the flume app
# are hardened separately; they sit outside the FIPS boundary.)
#
# Build the image (from the repo root, so the COPY context sees openssl/):
#   podman build -f openssl/fips-builder.dockerfile -t flume-fips-builder .
#
# Produce the module onto the host (SELinux hosts need the :z mount flag):
#   mkdir -p fips-out
#   podman run --rm -v "$PWD/fips-out:/out:z" flume-fips-builder
#   # -> fips-out/fips.so  (+ fips.so sha256 + fipsmodule.cnf.sample)
#
# AARCH64: run this SAME recipe on a native arm64 host (a Pi 5 works).
# `FROM debian:11.5` is multi-arch, so on arm64
# hardware docker/podman pulls the arm64 variant and build-fips-provider
# auto-detects `linux-aarch64` (uname -m) -> an arm64 fips.so.  Commit it to
# openssl/aarch64_linux/fips.so (beside the base libs already there).  aarch64
# has NO #4985 tested OE -- it's a vendor-affirmed port regardless -- but
# debian:11.5 is still the right base: glibc 2.31 floor -> one arm64 .so loads
# across RHEL 9 / Ubuntu 20.04+ / Debian 11+ arm64.  Bonus over the Android
# cross-build: the Pi runs the module natively, so the in-build `fipsinstall`
# KATs actually execute = real on-target self-test proof.
#
FROM debian:11.5

# build-essential -> gcc 10.2.1, make, libc6-dev, binutils (as/ld)
# perl            -> OpenSSL Configure + perlasm generators
# curl + ca-certs -> fetch + HTTPS-verify the pinned 3.1.2 tarball
# (tar / gzip / sha256sum are already in the base image)
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        perl \
        curl \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY openssl/build-fips-provider /usr/local/bin/build-fips-provider
RUN chmod 0755 /usr/local/bin/build-fips-provider

# Drop the module into the mounted /out (the script pins the source to 3.1.2,
# verifies its SHA-256, and Configures with `enable-fips` -- no hardening flags).
CMD ["bash", "-c", "DEST_DIR=/out build-fips-provider"]
