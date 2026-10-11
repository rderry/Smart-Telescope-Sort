# Builds the Microsoft Store bundle for Telescope Data Sort (x64 + arm64 MSIX, signed .msixbundle). Run on Windows
# with the .NET 8 SDK and the Windows 10/11 SDK (makeappx.exe, signtool.exe) installed. Builds only; uploads nothing.
# The version comes from installer\Store\AppxManifest.xml and must match the App csproj Version plus ".0".
# The bundle is self-signed with the manifest's Publisher for local install tests; the Store re-signs what it accepts.
# The manifest must hold the identity Partner Center reserved (BigSkyAstro.TelescopeDataSort, Store ID 9PGPCHV4BMDN);
# -LocalTestOnly skips that check, for a local install test only.
# -CertThumbprint signs in place from CurrentUser\My or LocalMachine\My (the build VM keeps the BigSkyAstro test cert
# that signed the Planner and Weather Wizard packages in LocalMachine\My), so no key is exported to a PFX.
param([switch]$LocalTestOnly, [string]$CertThumbprint)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$csproj = Join-Path $repo "src\SmartTelescopeSort.App\SmartTelescopeSort.App.csproj"
$assets = Join-Path $repo "installer\Store\Assets"
$manifestTemplate = Join-Path $repo "installer\Store\AppxManifest.xml"
$manual = Join-Path $repo "src\SmartTelescopeSort.App\Assets\Telescope-Data-Sort-User-Manual.pdf"
$out = if ($env:STS_STORE_OUT) { $env:STS_STORE_OUT } else { "C:\src\STS-Store" }
if (-not (Test-Path $csproj)) { throw "Project not found: $csproj" }
if (-not (Test-Path $manual)) { throw "User manual PDF missing: run scripts/build-user-manual.py first" }

$kitRoot = "C:\Program Files (x86)\Windows Kits\10\bin"
$kit = Get-ChildItem $kitRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^10\.' } | Sort-Object { [version]$_.Name } -Descending |
    ForEach-Object { foreach ($arch in "arm64", "x64") { Join-Path $_.FullName $arch } } | Where-Object { Test-Path (Join-Path $_ "makeappx.exe") } | Select-Object -First 1
if (-not $kit) { throw "makeappx.exe not found under $kitRoot. Install the Windows SDK, then run this again." }
$makeappx = Join-Path $kit "makeappx.exe"
$signtool = Join-Path $kit "signtool.exe"

[xml]$manifestXml = Get-Content $manifestTemplate -Raw
$version = $manifestXml.Package.Identity.Version
$publisher = $manifestXml.Package.Identity.Publisher
$reserved = @{ Name = "BigSkyAstro.TelescopeDataSort"; Publisher = "CN=6AF192BF-8D2A-4240-829A-06841CBE8558"; PublisherDisplayName = "BigSkyAstro" }
$identity = @{ Name = $manifestXml.Package.Identity.Name; Publisher = $publisher; PublisherDisplayName = $manifestXml.Package.Properties.PublisherDisplayName }
foreach ($key in $reserved.Keys) {
    if ($identity[$key] -ne $reserved[$key] -and -not $LocalTestOnly) {
        throw "AppxManifest.xml $key is '$($identity[$key])', not the Partner Center identity '$($reserved[$key])'. Pass -LocalTestOnly for a local install test."
    }
}
[xml]$proj = Get-Content $csproj -Raw
$projVersion = ($proj.Project.PropertyGroup | Where-Object { $_.Version } | Select-Object -First 1).Version
if ("$projVersion.0" -ne $version) { throw "csproj Version $projVersion does not match manifest $version" }

New-Item -ItemType Directory -Force -Path $out | Out-Null
$pfx = Join-Path $out "store-sign.pfx"
if ($CertThumbprint) {
    $cert = @("CurrentUser", "LocalMachine") | ForEach-Object { Get-Item "Cert:\$_\My\$CertThumbprint" -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $cert -or -not $cert.HasPrivateKey) { throw "No certificate with a private key and thumbprint $CertThumbprint in CurrentUser\My or LocalMachine\My" }
    if ($cert.Subject -ne $publisher) { throw "Certificate subject $($cert.Subject) does not match the manifest Publisher $publisher" }
    if ($cert.NotAfter -le (Get-Date)) { throw "Certificate $CertThumbprint expired on $($cert.NotAfter)" }
    $storeArgs = @("/sha1", $cert.Thumbprint, "/s", "My")
    if ($cert.PSParentPath -match 'LocalMachine') { $storeArgs += "/sm" }
} else {
    $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -eq $publisher -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if (-not $cert) {
        $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher -KeyUsage DigitalSignature -FriendlyName "BigSkyAstro MSIX signing" -CertStoreLocation "Cert:\CurrentUser\My" -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3", "2.5.29.19={text}")
    }
    $pass = [guid]::NewGuid().ToString("N")
    Export-PfxCertificate -Cert $cert -FilePath $pfx -Password (ConvertTo-SecureString -String $pass -AsPlainText -Force) | Out-Null
    $storeArgs = @("/f", $pfx, "/p", $pass)
}
Write-Output "SIGNING WITH $($cert.Thumbprint) ($($cert.Subject), valid to $($cert.NotAfter.ToString('yyyy-MM-dd')))"

function Sign-File([string]$path) {
    & $signtool sign /q /fd SHA256 @storeArgs /tr http://timestamp.digicert.com /td SHA256 $path | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "signtool failed for $path" }
}

function Publish-Arch([string]$rid, [string]$arch) {
    $pub = Join-Path $out "publish-$arch"
    if (Test-Path $pub) { Remove-Item $pub -Recurse -Force }
    & dotnet publish $csproj -c Release -r $rid --self-contained true -p:PublishSingleFile=false -p:DebugType=None -p:DebugSymbols=false -o $pub -nologo -v q | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish $rid failed" }
    if (-not (Test-Path (Join-Path $pub "Assets\Telescope-Data-Sort-User-Manual.pdf"))) { throw "The manual PDF is missing from the $arch build" }

    $layout = Join-Path $out "layout-$arch"
    if (Test-Path $layout) { Remove-Item $layout -Recurse -Force }
    New-Item -ItemType Directory -Path $layout | Out-Null
    Get-ChildItem $pub -Force | Where-Object { $_.Extension -ne ".pdb" } | Copy-Item -Destination $layout -Recurse -Force
    $forbidden = Get-ChildItem $layout -Recurse -Force -File | Where-Object { $_.Extension -in ".pfx", ".p12", ".snk", ".key", ".pem" -or $_.Name -match '^(\.env|settings\.json|Terms-Acceptance\.pdf)$' }
    if ($forbidden) { throw "Refusing to package secrets or user data: $($forbidden.FullName -join ', ')" }

    $images = Join-Path $layout "Images"
    New-Item -ItemType Directory -Force -Path $images | Out-Null
    Get-ChildItem $assets -Filter *.png | Where-Object { $_.Name -ne "StoreListingIcon-300.png" } | Copy-Item -Destination $images -Force
    $manifest = (Get-Content $manifestTemplate -Raw).Replace('ProcessorArchitecture="x64"', "ProcessorArchitecture=`"$arch`"")
    [System.IO.File]::WriteAllText((Join-Path $layout "AppxManifest.xml"), $manifest, (New-Object System.Text.UTF8Encoding $false))

    $msix = Join-Path $out "TelescopeDataSort-$version-$arch.msix"
    if (Test-Path $msix) { Remove-Item $msix -Force }
    & $makeappx pack /o /h SHA256 /d $layout /p $msix | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makeappx pack $arch failed" }
    Sign-File $msix
    return $msix
}

try {
    $x64 = Publish-Arch "win-x64" "x64"
    $arm = Publish-Arch "win-arm64" "arm64"
    $bundleDir = Join-Path $out "bundle"
    if (Test-Path $bundleDir) { Remove-Item $bundleDir -Recurse -Force }
    New-Item -ItemType Directory -Path $bundleDir | Out-Null
    Copy-Item $x64, $arm -Destination $bundleDir
    $bundle = Join-Path $out "TelescopeDataSort-$version.msixbundle"
    if (Test-Path $bundle) { Remove-Item $bundle -Force }
    & $makeappx bundle /o /bv $version /d $bundleDir /p $bundle | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makeappx bundle failed" }
    Sign-File $bundle
} finally {
    if (Test-Path $pfx) { Remove-Item $pfx -Force }
}

Write-Output "STORE_BUNDLE $bundle"
Get-Item $bundle, $x64, $arm | ForEach-Object {
    "{0,12:N0} bytes  SHA256 {1}  {2}" -f $_.Length, (Get-FileHash $_.FullName -Algorithm SHA256).Hash, $_.Name
}
