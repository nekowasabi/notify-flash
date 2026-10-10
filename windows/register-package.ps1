param(
    [Parameter(Mandatory)] [string] $PackageDir,
    [Parameter(Mandatory)] [string] $ExternalLocation
)
$ErrorActionPreference = 'Stop'
$subject = 'CN=NotifyFlash Dev'

$sdk = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Directory -Filter '10.*' |
    Sort-Object { [version]$_.Name } -Descending |
    Where-Object { Test-Path (Join-Path $_.FullName 'x64\makeappx.exe') } |
    Select-Object -First 1
# Why: Windows PowerShell 5.1 reads BOM-less UTF-8 as the ANSI code page, so this file stays ASCII-only.
if (-not $sdk) { throw 'makeappx.exe from the Windows SDK was not found' }
$makeappx = Join-Path $sdk.FullName 'x64\makeappx.exe'
$signtool = Join-Path $sdk.FullName 'x64\signtool.exe'

# Why: Reuse one certificate so only the first release needs elevation to trust it.
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq $subject | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -Type Custom -Subject $subject -KeyUsage DigitalSignature `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
}
# Why: Add-AppxPackage rejects a CurrentUser-trusted signer with 0x800B0109; it must be trusted machine-wide.
if (-not (Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $cert.Thumbprint)) {
    $cer = Join-Path $env:TEMP 'NotifyFlash.cer'
    Export-Certificate -Cert $cert -FilePath $cer | Out-Null
    Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command',
        "Import-Certificate -FilePath '$cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
    if (-not (Get-ChildItem Cert:\LocalMachine\TrustedPeople | Where-Object Thumbprint -eq $cert.Thumbprint)) {
        throw 'Certificate is not trusted in LocalMachine\TrustedPeople (approve the UAC prompt)'
    }
}

$msix = Join-Path $env:TEMP 'NotifyFlash.msix'
& $makeappx pack /o /nv /d $PackageDir /p $msix | Out-Null
if ($LASTEXITCODE) { throw "makeappx failed: $LASTEXITCODE" }
& $signtool sign /q /fd SHA256 /sha1 $cert.Thumbprint $msix
if ($LASTEXITCODE) { throw "signtool failed: $LASTEXITCODE" }

# Why: Re-adding the same version is not an update; remove first so every release converges to this manifest and location.
Get-AppxPackage -Name NotifyFlash | Remove-AppxPackage
Add-AppxPackage -Path $msix -ExternalLocation $ExternalLocation
Get-AppxPackage -Name NotifyFlash | Select-Object -ExpandProperty PackageFullName
