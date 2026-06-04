# build-base-libs.ps1 -- Windows companion to openssl/build-base-libs.
#
# Builds Flume's BASE OpenSSL static libs (libcrypto_static.lib /
# libssl_static.lib) from CURRENT OpenSSL 3.5.x, WITH MSVC hardening.
#
# Unlike build-fips-provider.ps1 (the validated FIPS module, which MUST use the
# VS2019 sec.5.3 toolset), the BASE library is OUTSIDE the FIPS boundary and links
# *with* flume.exe -- so build it with the SAME toolchain flume normally builds
# with (your VS2026 x64 Native Tools prompt), track the latest 3.5.x for fixes,
# and add hardening (/guard:cf, etc.).  (CET on Windows is the linker's
# /CETCompat on flume.exe -- already set in the vcxprojs -- so the static base lib
# needs no CET *compile* flag, unlike the Linux -fcf-protection.)
#
# *** DRAFT -- written on the Linux dev box (no MSVC here to test).  A Claude
# session on the Windows build box should run + refine it.  Two things to VERIFY there:
#   1. The produced static-lib names.  OpenSSL VC `no-shared` typically emits
#      libcrypto.lib / libssl.lib; the repo + vcxprojs use the *_static.lib
#      names, so this copies/renames -- confirm the actual output names.
#   2. The MSVC hardening flag set (/guard:cf [+ /Qspectre /sdl ...]).
#   `git pull` before editing and before pushing (main tracks origin/main). ***
#
# Output: openssl\win64\libcrypto_static.lib, libssl_static.lib

$ErrorActionPreference = 'Stop'
$RepoOsslDir = $PSScriptRoot

$OsslVer = if ($env:OSSL_VER) { $env:OSSL_VER } else { '3.5.2' }   # bump to latest 3.5.x
$Work    = Join-Path $env:TEMP 'flume-base-libs-build'
$Dest    = Join-Path $RepoOsslDir 'win64'

# --- WORK-TREE CONTAINMENT (see build-fips-provider.ps1 for the full rationale) --
# OpenSSL's nmake generates headers via RELATIVE redirects (perl dofile.pl ...
# > include\openssl\X.h) that resolve against the child process's working dir.
# On Windows that comes from BOTH $PWD AND [Environment]::CurrentDirectory, and
# `Set-Location` updates only $PWD.  Launched from the repo's openssl\ dir, a
# stale [Environment]::CurrentDirectory can make those redirects truncate the
# repo's own openssl\include\openssl\*.h.  Set-WorkLocation keeps both in sync so
# every child write stays inside $Work.  (Updating the SHIPPED headers for a base
# -lib version bump is a SEPARATE, explicit step -- see UpdateWinOpenssl.cmd --
# never a build side-effect.)
function Set-WorkLocation {
    param([string]$Path)
    Set-Location -LiteralPath $Path
    [System.IO.Directory]::SetCurrentDirectory((Get-Location -PSProvider FileSystem).ProviderPath)
}

# Belt-and-suspenders: never build inside the repo tree.
$repoFull = [System.IO.Path]::GetFullPath($RepoOsslDir).TrimEnd('\')
$workFull = [System.IO.Path]::GetFullPath($Work).TrimEnd('\')
if ($workFull -eq $repoFull -or $workFull.StartsWith($repoFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to build: work dir '$workFull' is inside the repo '$repoFull'. Set `$Work to a path under TEMP."
}

Set-WorkLocation $RepoOsslDir

function Invoke-Checked {
    param([string]$Cmd, [string[]]$ArgList)
    Write-Host ">>> $Cmd $($ArgList -join ' ')"
    & $Cmd @ArgList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "FAILED ($LASTEXITCODE): $Cmd $($ArgList -join ' ')" }
}

foreach ($t in 'perl','nmake','nasm') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        throw "$t not found on PATH -- run from an x64 Native Tools prompt with Strawberry Perl + NASM."
    }
}

New-Item -ItemType Directory -Force -Path $Work | Out-Null
Set-WorkLocation $Work
$tarball = "openssl-$OsslVer.tar.gz"
$url     = "https://github.com/openssl/openssl/releases/download/openssl-$OsslVer/$tarball"
if (-not (Test-Path $tarball)) { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tarball }
try {
    Invoke-WebRequest -UseBasicParsing -Uri "$url.sha256" -OutFile "$tarball.sha256"
    $exp = ((Get-Content "$tarball.sha256") -split '\s+')[0].ToLower()
    $got = (Get-FileHash $tarball -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $exp) { throw "SHA-256 mismatch: got $got, expected $exp" }
    Write-Host "SHA-256 OK: $got"
} catch {
    Write-Warning "could not verify published .sha256 -- computed $((Get-FileHash $tarball -Algorithm SHA256).Hash)"
}

if (Test-Path "openssl-$OsslVer") { Remove-Item -Recurse -Force "openssl-$OsslVer" }
Invoke-Checked 'tar' @('xzf', $tarball)
# cwd = extracted tree (both $PWD and EnvCurDir) so nmake's relative header
# redirects stay inside $Work, never in the repo's openssl\include\.
Set-WorkLocation (Join-Path $Work "openssl-$OsslVer")

# Static + hardened.  /guard:cf = Control Flow Guard; /Qspectre = Spectre-v1.
# no-shared = static only; no-tests = skip the test suite.
Invoke-Checked 'perl'  @('Configure','VC-WIN64A','no-shared','no-tests','/guard:cf','/Qspectre')
Invoke-Checked 'nmake' @()

# Copy to the *_static.lib names the repo + vcxprojs expect.  VERIFY the actual
# produced names on the Windows build box (adjust the source names below if needed).
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item 'libcrypto.lib' (Join-Path $Dest 'libcrypto_static.lib') -Force
Copy-Item 'libssl.lib'    (Join-Path $Dest 'libssl_static.lib')    -Force
# Save the openssl CLI too (apps\openssl.exe), like the Linux build, so every
# platform's tests can use the SAME-version bundled CLI for keygen/verify.
# (Android is the one exception: its CLI is cross-compiled and cannot run on
# the build host.)  The VC build emits it at apps\openssl.exe.
if (Test-Path 'apps\openssl.exe') {
    Copy-Item 'apps\openssl.exe' (Join-Path $Dest 'openssl.exe') -Force
    Write-Host ">>> wrote $Dest\openssl.exe"
} else {
    Write-Warning 'apps\openssl.exe not found -- CLI not saved (check the nmake output)'
}
Write-Host ">>> wrote $Dest\libcrypto_static.lib + libssl_static.lib  (OpenSSL $OsslVer, hardened)"
Write-Host '>>> done.  Rebuild flume.sln against these to pick up the fixes.'
