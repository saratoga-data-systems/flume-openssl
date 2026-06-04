# build-fips-provider.ps1 -- Windows companion to openssl/build-fips-provider.
#
# Reproducibly builds the CMVP #4985 OpenSSL FIPS provider (fips.dll) from the
# *validated* OpenSSL 3.1.2 source, for Flume's static-base-library +
# dynamically-loaded-FIPS-module architecture: the base libcrypto/libssl stay
# statically linked into flume.exe (openssl\win64\libcrypto_static.lib /
# libssl_static.lib); only fips.dll is loaded at runtime from Flume's install dir.
#
# RUN FROM the "x64 Native Tools Command Prompt for VS 2019" (or any shell where
# the VS2019 v142 toolset's cl + nmake, Strawberry Perl, and NASM are on PATH,
# AND the Windows SDK is installed -- 'cl' on PATH is not enough; without the SDK
# the very first .c fails with "Cannot open include file: 'stdlib.h'", which
# lives in the SDK's Universal CRT, not next to cl).  Same convention as
# ReleaseWin.ps1, which assumes msbuild is on PATH.
#
# COMPILER (per 140sp4985.pdf sec. 5.3): the tested Windows OE used "Visual
# Studio 2019" (no minor version named).  Use VS2019 16.11 (cl 19.29, the last /
# fully-serviced VS2019) -- it IS "Visual Studio 2019" and is the most-patched
# one.  A newer cl (VS2022) still builds from the validated source but is a
# recompile / OE-portability build.  NOTE: the cert's tested OS is Windows 10
# Pro; building on Windows 11 is already outside the tested OE regardless of cl.
#
# BUILD RECIPE -- adaptive (full documented build first, no-tests fallback):
# The policy's documented sec. 11.1 Windows build is the full `perl Configure
# enable-fips` + `nmake`, which also compiles OpenSSL's own C test suite.  One
# test, test\build_wincrypt_test.c, has a CONDITIONAL `#warning` that fires only
# when the platform SDK's <wincrypt.h> no longer pre-defines the X509_NAME macro
# (a wincrypt/OpenSSL symbol-collision check).  When it fires, MSVC errors C1021
# ("invalid preprocessor command 'warning'") because MSVC did not accept the
# #warning directive until VS2022.  So whether the documented full build
# compiles depends on the SDK, NOT just the compiler:
#   * Older SDK (wincrypt.h still defines X509_NAME, e.g. the SDK that ships
#     with a fresh VS2019 16.11 on Windows 10): #warning is never reached ->
#     the full documented build (with tests) compiles clean.  Best fidelity.
#   * Newer SDK (X509_NAME pre-definition dropped, e.g. 10.0.26100): #warning is
#     reached -> C1021 -> the full build's nmake aborts.
# This script TRIES the full documented build first; if (and only if) it fails
# on exactly that build_wincrypt_test/C1021 signature, it re-builds with
# 'no-tests'.  Any OTHER nmake failure (e.g. a missing Windows SDK) is surfaced,
# NOT silently turned into a no-tests build.  'no-tests' drops only OpenSSL's own
# C test harness from the makefile; the validated module is identical (the
# fips.dll generated code is unchanged, and the FIPS KAT + integrity self-tests
# are baked into the module and verified by `openssl fipsinstall` below).  Both
# paths use 'build_sw' to skip build_docs (fragile Windows POD/HTML; irrelevant
# to the module).
#
# IMPORTANT (per 140sp4985.pdf -- the #4985 Security Policy):
#   * Source is pinned to OpenSSL 3.1.2, the exact CMVP #4985 validated version.
#     Do NOT bump it -- a different source is no longer the validated module.
#   * Build per sec. 11.1: `perl Configure enable-fips` then `nmake`.
#     Do NOT add hardening flags -- build changes that alter generated code void
#     the validation.  (Harden the base library + flume.exe instead; outside the
#     FIPS boundary.)
#
# Output: openssl\win64\fips.dll (+ a fipsmodule.cnf.sample).  The SHIPPED
# fipsmodule.cnf is generated per-install by `flume --fips-install`.

$ErrorActionPreference = 'Stop'
$RepoOsslDir = $PSScriptRoot                      # = openssl\ (the repo dir)

$OsslVer     = '3.1.2'              # CMVP #4985 validated source -- do NOT change
$ExpectedSha = 'a0ce69b8b97ea6a35b96875235aa453b966ba3cba8af2de23657d8b6767d6539'
$Work        = Join-Path $env:TEMP 'flume-fips-build'
$Dest        = Join-Path $RepoOsslDir 'win64'

# --- WORK-TREE CONTAINMENT --------------------------------------------------
# OpenSSL's nmake generates headers via RELATIVE redirects (perl dofile.pl ...
# > include\openssl\X.h).  Those resolve against the *child process's* working
# directory, which on Windows comes from BOTH PowerShell's $PWD AND .NET's
# [Environment]::CurrentDirectory -- and `Set-Location` updates only $PWD, NOT
# [Environment]::CurrentDirectory.  If a build is launched with the shell sitting
# in the repo's openssl\ dir (the natural place -- it's where this script lives),
# a stale [Environment]::CurrentDirectory can make those redirects truncate the
# repo's own openssl\include\openssl\*.h (the 3.5.2 base-lib headers) to empty.
# Set-WorkLocation keeps BOTH in sync so every child write lands inside $Work.
function Set-WorkLocation {
    param([string]$Path)
    Set-Location -LiteralPath $Path
    [System.IO.Directory]::SetCurrentDirectory((Get-Location -PSProvider FileSystem).ProviderPath)
}

# Refuse to run if the TEMP work tree would overlap the repo (it never should;
# this is a belt-and-suspenders guard so we can NEVER build inside the repo).
$repoFull = [System.IO.Path]::GetFullPath($RepoOsslDir).TrimEnd('\')
$workFull = [System.IO.Path]::GetFullPath($Work).TrimEnd('\')
if ($workFull -eq $repoFull -or $workFull.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to build: work dir '$workFull' is inside the repo '$repoFull'. Set `$Work to a path under TEMP."
}

# Snapshot the repo's generated headers so a post-build tripwire can prove the
# build did NOT touch them (only the explicit Copy-Item to win64\ may change the
# repo).  Empty/absent dir -> empty snapshot, which the tripwire also accepts.
$RepoIncludeDir = Join-Path $RepoOsslDir 'include\openssl'
function Get-IncludeSnapshot {
    if (-not (Test-Path $RepoIncludeDir)) { return @{} }
    $snap = @{}
    Get-ChildItem -LiteralPath $RepoIncludeDir -Filter *.h -File -ErrorAction SilentlyContinue | ForEach-Object {
        $snap[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return $snap
}
$includeBefore = Get-IncludeSnapshot

Set-WorkLocation $RepoOsslDir       # cwd = openssl\ (and EnvCurDir synced)

function Invoke-Checked {
    param([string]$Cmd, [string[]]$ArgList)
    Write-Host ">>> $Cmd $($ArgList -join ' ')"
    # `| Out-Host`: show the child's output live but keep it OUT of the success
    # stream, so callers (esp. Build-Module, which returns an exit code) don't
    # capture this command's stdout as part of their return value.
    & $Cmd @ArgList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "FAILED ($LASTEXITCODE): $Cmd $($ArgList -join ' ')" }
}

# Fresh-extract the pinned source, Configure, and nmake one target.  Returns the
# nmake exit code (does NOT throw on a non-zero nmake -- the caller decides,
# because a failure may be the expected wincrypt/#warning case).  nmake is run
# via `cmd /c "... 2>&1"` so cmd does the stderr merge: PowerShell then sees a
# single stdout stream and will NOT promote native stderr to a terminating
# NativeCommandError (a Windows PowerShell 5.1 + ErrorActionPreference=Stop
# trap).  Tee-Object captures the build log (for the C1021 signature check) while
# `| Out-Host` sends the live output to the console -- crucially NOT to the
# function's success stream, so the function's SOLE pipeline output is the
# `[int]` exit code.  (A PowerShell function returns *everything* written to the
# success stream; if nmake's stdout leaked into the return, the caller's `$rc`
# would be a giant string[] and `$rc -ne 0` would be wrongly true.)
function Build-Module {
    param([string[]]$ConfigureArgs, [string]$NmakeTarget, [string]$LogPath)
    Set-WorkLocation $Work
    if (Test-Path "openssl-$OsslVer") { Remove-Item -Recurse -Force "openssl-$OsslVer" }
    Invoke-Checked 'tar' @('xzf', $tarball)
    # Set BOTH $PWD and [Environment]::CurrentDirectory to the extracted tree so
    # nmake's relative `> include\openssl\X.h` redirects land HERE, never in the
    # repo's openssl\include\.
    Set-WorkLocation (Join-Path $Work "openssl-$OsslVer")
    Invoke-Checked 'perl' (@('Configure') + $ConfigureArgs)
    Write-Host ">>> nmake $NmakeTarget"
    cmd /c "nmake $NmakeTarget 2>&1" | Tee-Object -FilePath $LogPath | Out-Host
    return [int]$LASTEXITCODE
}

# --- toolchain check (sec. 5.3 tested compiler = Visual Studio 2019) ---
Write-Host '=== toolchain ==='
foreach ($t in 'perl','nmake','nasm') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        throw "$t not found on PATH -- run from a VS2019 x64 Native Tools prompt with Strawberry Perl + NASM installed."
    }
}
# `& exit 0` so cl's non-zero exit (it has no input file) doesn't trip
# $ErrorActionPreference='Stop' under newer pwsh's native-error handling.
$clLine = (cmd /c 'cl 2>&1 & exit 0' | Select-String 'Version' | Select-Object -First 1)
Write-Host "cl: $clLine"
if ("$clLine" -notmatch 'Version 19\.2[0-9]\.') {
    Write-Warning "cl is NOT a VS2019 v142 toolset (Version 19.2x / _MSC_VER 192x) -- the sec. 5.3 tested Windows compiler for #4985 was Visual Studio 2019. This still builds from the validated source, but it is a recompile / OE-portability-clause build, not a byte-match of the tested OE."
}

# --- fetch + SHA-256 verify ---
New-Item -ItemType Directory -Force -Path $Work | Out-Null
Set-WorkLocation $Work
$tarball = "openssl-$OsslVer.tar.gz"
if (-not (Test-Path $tarball)) {
    Invoke-WebRequest -UseBasicParsing `
        -Uri "https://github.com/openssl/openssl/releases/download/openssl-$OsslVer/$tarball" `
        -OutFile $tarball
}
$sha = (Get-FileHash $tarball -Algorithm SHA256).Hash.ToLower()
if ($sha -ne $ExpectedSha) { throw "SHA-256 mismatch: got $sha, expected $ExpectedSha" }
Write-Host "SHA-256 OK: $sha"

# --- build the FIPS provider (adaptive: full documented build, no-tests fallback) ---
$rc = Build-Module -ConfigureArgs @('VC-WIN64A', 'enable-fips') `
                   -NmakeTarget 'build_sw' -LogPath (Join-Path $Work 'nmake-full.log')
if ($rc -ne 0) {
    # Only the known wincrypt/#warning test-harness incompatibility justifies a
    # no-tests fallback.  Match the exact signature; anything else is a real
    # build failure (missing SDK, etc.) and must be surfaced, not masked.
    $known = Select-String -Path (Join-Path $Work 'nmake-full.log') `
        -Pattern "build_wincrypt_test\.c.*\bC1021\b", "invalid preprocessor command .warning." -Quiet
    if (-not $known) {
        throw ("nmake build_sw failed (exit $rc) for a reason OTHER than the known " +
               "wincrypt/#warning test incompatibility -- see $(Join-Path $Work 'nmake-full.log'). " +
               "Common cause: the Windows SDK is not installed (look for C1083 'Cannot open " +
               "include file: stdlib.h').  This is a real build error; NOT falling back to no-tests.")
    }
    Write-Warning ("Full documented build hit OpenSSL's known wincrypt/#warning test " +
                   "incompatibility (this SDK's wincrypt.h no longer pre-defines X509_NAME, and " +
                   "MSVC < VS2022 rejects #warning).  Re-building with 'no-tests' -- the validated " +
                   "module is identical; only OpenSSL's own C test harness is skipped.")
    $rc2 = Build-Module -ConfigureArgs @('VC-WIN64A', 'enable-fips', 'no-tests') `
                        -NmakeTarget 'build_sw' -LogPath (Join-Path $Work 'nmake-notests.log')
    if ($rc2 -ne 0) {
        throw "FAILED ($rc2): nmake build_sw (no-tests fallback) -- see $(Join-Path $Work 'nmake-notests.log')."
    }
    Write-Host ">>> built via no-tests fallback (module identical; OpenSSL's own test harness skipped)"
} else {
    Write-Host ">>> full documented build (with OpenSSL's C test suite) succeeded"
}

# --- TRIPWIRE: prove the build did NOT touch the repo's generated headers ---
# The only repo write this script is allowed to make is the Copy-Item to win64\
# below.  If openssl\include\openssl\*.h changed, a relative redirect escaped the
# work tree (the 3.5.2 base-lib headers belong to build-base-libs, NOT this
# 3.1.2 FIPS build) -- fail loudly so it can never be silently committed.
$includeAfter = Get-IncludeSnapshot
$touched = @()
foreach ($name in ($includeBefore.Keys + $includeAfter.Keys | Select-Object -Unique)) {
    if ($includeBefore[$name] -ne $includeAfter[$name]) { $touched += $name }
}
if ($touched.Count -gt 0) {
    throw ("REPO HEADER CORRUPTION: this FIPS build modified $($touched.Count) file(s) under " +
           "$RepoIncludeDir -- it must NEVER write there (those are the 3.5.2 base-lib headers). " +
           "Changed: $($touched -join ', '). Restore with: git checkout -- openssl/include/openssl")
}

# Build-Module left us in the (full or fallback) configured source tree.
if (-not (Test-Path 'providers\fips.dll')) { throw 'providers\fips.dll was not built' }
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item 'providers\fips.dll' (Join-Path $Dest 'fips.dll') -Force
Write-Host ">>> wrote $Dest\fips.dll"
Write-Host ('fips.dll SHA-256: ' + (Get-FileHash (Join-Path $Dest 'fips.dll') -Algorithm SHA256).Hash)

# --- reference fipsmodule.cnf (proves self-tests + integrity MAC).  The SHIPPED
#     fipsmodule.cnf is regenerated per-install by `flume --fips-install`. ---
& '.\apps\openssl.exe' fipsinstall `
    -module (Join-Path $Dest 'fips.dll') `
    -out    (Join-Path $Dest 'fipsmodule.cnf.sample') `
    -provider_name fips
if ($LASTEXITCODE -ne 0) { Write-Warning 'sample fipsinstall failed (non-fatal for the build)' }
else { Write-Host ">>> fipsinstall OK -> $Dest\fipsmodule.cnf.sample" }

Write-Host '>>> done.'
