<#
.SYNOPSIS
    Packs a published Hypo build into an MSIX.

.DESCRIPTION
    Runs makeappx over a published self-contained build plus the manifest and
    assets in windows/packaging.

    The result is unsigned. Windows will not install an unsigned MSIX, which is
    deliberate on Microsoft's part and not something to work around: signing is a
    separate step with a real certificate, and for local testing a self-signed
    one whose subject matches -Publisher exactly.

.PARAMETER PublishDirectory
    A directory produced by `dotnet publish` containing Hypo.exe.

.PARAMETER OutputPath
    Where to write the .msix.

.PARAMETER Publisher
    Overrides the manifest's Publisher. It must match the signing certificate's
    subject character for character, or installation fails with a message that
    does not mention the mismatch.

.PARAMETER PackageVersion
    Four-part version. MSIX requires the revision to be 0 for Store submission
    and it must increase between builds, or upgrades are silently skipped.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $PublishDirectory,
    [Parameter(Mandatory = $true)] [string] $OutputPath,
    [string] $Publisher,
    [string] $PackageVersion
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path (Join-Path $PublishDirectory 'Hypo.exe'))) {
    throw "No Hypo.exe in '$PublishDirectory'. Publish the app first."
}

$packagingRoot = Resolve-Path (Join-Path $PSScriptRoot '..\packaging')

# makeappx lives under a versioned Windows SDK directory. Picking the newest
# rather than hard-coding one keeps this working when the runner image moves.
$makeappx = Get-ChildItem `
    -Path 'C:\Program Files (x86)\Windows Kits\10\bin' `
    -Filter 'makeappx.exe' -Recurse -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\x64\\' } |
    Sort-Object FullName -Descending |
    Select-Object -First 1

if (-not $makeappx) {
    throw 'makeappx.exe not found. Install the Windows 10/11 SDK.'
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("hypo-msix-" + [Guid]::NewGuid())
New-Item -ItemType Directory -Path $staging | Out-Null

try {
    Copy-Item -Path (Join-Path $PublishDirectory '*') -Destination $staging -Recurse -Force
    Copy-Item -Path (Join-Path $packagingRoot 'Assets') -Destination $staging -Recurse -Force

    $manifestPath = Join-Path $staging 'AppxManifest.xml'
    Copy-Item -Path (Join-Path $packagingRoot 'AppxManifest.xml') -Destination $manifestPath -Force

    if ($Publisher -or $PackageVersion) {
        [xml] $manifest = Get-Content $manifestPath
        if ($Publisher) { $manifest.Package.Identity.Publisher = $Publisher }
        if ($PackageVersion) { $manifest.Package.Identity.Version = $PackageVersion }
        $manifest.Save($manifestPath)
    }

    $outputDirectory = Split-Path -Parent $OutputPath
    if ($outputDirectory -and -not (Test-Path $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }

    & $makeappx.FullName pack /d $staging /p $OutputPath /o
    if ($LASTEXITCODE -ne 0) {
        throw "makeappx failed with exit code $LASTEXITCODE."
    }

    Write-Host "Packed $OutputPath (unsigned)."
}
finally {
    Remove-Item -Path $staging -Recurse -Force -ErrorAction SilentlyContinue
}
