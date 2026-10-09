# Release-only Authenticode helpers. No certificate creation or trust-store changes.
Set-StrictMode -Version Latest
$script:ReleasePublisher='Cracken Released, LLC'
$script:ArtifactSigningRoot='F40042E2E5F7E8EF8189FED15519AECE42C3BFA2'
$script:SigningLog=$null

function Assert-MicrosoftSigningTool([string]$Path) {
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw "Signing tool is missing: $Path"}
  $signature=Get-AuthenticodeSignature -LiteralPath $Path
  if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne 'Microsoft Corporation') {
    throw "Signing tool must have a valid Microsoft signature: $Path"
  }
}
function Test-VendorInstallerSignature([string]$Path,$Policy) {
  $signature=Get-AuthenticodeSignature -LiteralPath $Path
  if($signature.Status -ne 'Valid'){throw "Vendor installer is $($signature.Status); public packaging requires an authenticated installer or separately installed drivers: $Path"}
  Invoke-SigningTool $Policy.SignToolPath @('verify','/pa','/all','/v',$Path)
}
function Read-SigningConfiguration([string]$Path) {
  if(-not $Path){throw 'Signing configuration is required. Unsigned development builds require -DevelopmentUnsigned and never go to dist.'}
  if($PSVersionTable.PSVersion.Major -ne 5){throw 'Release signing requires Windows PowerShell 5.1 for Authenticode verification.'}
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){throw 'Signing configuration file is missing.'}
  $config=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  $required=@('Provider','SignToolPath','TimestampUrl','TrustedRootThumbprints')
  $allowed=$required+@('CertificateThumbprint','StoreLocation','DlibPath','MetadataPath')
  foreach($name in $required){if(-not $config.PSObject.Properties[$name] -or -not $config.$name){throw "Signing configuration requires $name"}}
  foreach($name in $config.PSObject.Properties.Name){if($name -notin $allowed){throw "Unknown signing configuration field: $name"}}
  if($config.Provider -notin @('CertificateStore','ArtifactSigning')){throw 'Unsupported signing provider.'}
  $url=$null
  if(-not [Uri]::TryCreate($config.TimestampUrl,[UriKind]::Absolute,[ref]$url) -or $url.Scheme -notin @('http','https') -or $url.UserInfo){throw 'Invalid RFC3161 timestamp URL.'}
  foreach($root in $config.TrustedRootThumbprints){if($root -notmatch '^[A-Fa-f0-9]{40}$'){throw 'Trusted roots require explicit 40-character certificate thumbprints.'}}
  Assert-MicrosoftSigningTool $config.SignToolPath
  if($config.Provider -eq 'ArtifactSigning') {
    foreach($name in 'DlibPath','MetadataPath'){if(-not $config.PSObject.Properties[$name] -or -not $config.$name){throw "Artifact Signing requires $name"}}
    if(@($config.TrustedRootThumbprints).Count -ne 1 -or @($config.TrustedRootThumbprints)[0] -ne $script:ArtifactSigningRoot){throw 'Artifact Signing requires the documented Microsoft public-trust root.'}
    Assert-MicrosoftSigningTool $config.DlibPath
    $metadata=Get-Content -LiteralPath $config.MetadataPath -Raw | ConvertFrom-Json
    foreach($name in 'Endpoint','CodeSigningAccountName','CertificateProfileName'){if(-not $metadata.PSObject.Properties[$name] -or -not $metadata.$name -or $metadata.$name -match 'REPLACE'){throw "Artifact metadata requires configured $name"}}
    $endpoint=$null
    if(-not [Uri]::TryCreate($metadata.Endpoint,[UriKind]::Absolute,[ref]$endpoint) -or $endpoint.Scheme -ne 'https' -or $endpoint.Host -notmatch '^[a-z]+\.codesigning\.azure\.net$' -or $endpoint.UserInfo){throw 'Artifact endpoint must be an official HTTPS codesigning.azure.net endpoint.'}
  } else {
    foreach($name in 'CertificateThumbprint','StoreLocation'){if(-not $config.PSObject.Properties[$name] -or -not $config.$name){throw "Certificate store signing requires $name"}}
    if($config.CertificateThumbprint -notmatch '^[A-Fa-f0-9]{40}$' -or $config.StoreLocation -notin @('CurrentUser','LocalMachine')){throw 'Invalid signing certificate selection.'}
    $certificate=Get-Item -LiteralPath ("Cert:\"+$config.StoreLocation+'\My\'+$config.CertificateThumbprint)
    if(-not $certificate.HasPrivateKey){throw 'The selected certificate has no accessible signing key.'}
    if($certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne $script:ReleasePublisher){throw 'Signing certificate publisher does not match Cracken Released, LLC.'}
    $chain=Get-ReleaseCertificateChain $certificate
    if($chain.SelfSigned -or $chain.RootThumbprint -notin $config.TrustedRootThumbprints){throw 'Signing certificate must chain to an explicitly approved public root; self-signing is not supported.'}
  }
  return $config
}
function Invoke-SigningTool([string]$Tool,[string[]]$Arguments) {
  $output=(& $Tool @Arguments 2>&1 | Out-String)
  $code=$LASTEXITCODE
  if($script:SigningLog){Add-Content -LiteralPath $script:SigningLog -Value $output}
  Write-Verbose $output
  if($code -ne 0){throw "SignTool failed (exit $code). $output"}
}
function Get-ReleaseCertificateChain($Certificate) {
  $chain=New-Object Security.Cryptography.X509Certificates.X509Chain
  try {
    # Authenticode validity at signing time is checked by SignTool below. This
    # second chain build extracts/pins its root, including expired timestamped leaves.
    $chain.ChainPolicy.VerificationFlags=[Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreNotTimeValid
    $chain.ChainPolicy.RevocationMode=[Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    if(-not $chain.Build($Certificate)){throw 'Could not build the signing certificate chain.'}
    $root=$chain.ChainElements[$chain.ChainElements.Count-1].Certificate
    return [pscustomobject]@{RootThumbprint=$root.Thumbprint;SelfSigned=($root.Thumbprint -eq $Certificate.Thumbprint)}
  } finally {$chain.Dispose()}
}
function Assert-ReleaseSignatureFacts([string]$Status,[string]$Publisher,[bool]$HasTimestamp,[string]$RootThumbprint,[string[]]$ApprovedRoots,[bool]$SelfSigned) {
  if($Status -ne 'Valid'){throw "Release signature is $Status"}
  if($Publisher -cne $script:ReleasePublisher){throw 'Release signature publisher does not match Cracken Released, LLC.'}
  if(-not $HasTimestamp){throw 'Release signature has no trusted timestamp.'}
  if($SelfSigned){throw 'Self-signed release certificates are not accepted.'}
  if($RootThumbprint -notin $ApprovedRoots){throw 'Release certificate root is not approved.'}
}
function Test-ReleaseSignature([string]$Path,$Policy) {
  $signature=Get-AuthenticodeSignature -LiteralPath $Path
  if($signature.Status -ne 'Valid'){throw "Release signature is $($signature.Status): $Path"}
  # /pa verifies Authenticode, /all covers every embedded signature, /tw requires
  # timestamps. Warnings (exit 2) are rejected as well as verification errors.
  Invoke-SigningTool $Policy.SignToolPath @('verify','/pa','/all','/v','/tw',$Path)
  $certificate=$signature.SignerCertificate
  $chain=Get-ReleaseCertificateChain $certificate
  $publisher=$certificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false)
  Assert-ReleaseSignatureFacts ([string]$signature.Status) $publisher ([bool]$signature.TimeStamperCertificate) $chain.RootThumbprint $Policy.TrustedRootThumbprints $chain.SelfSigned
  return [pscustomobject]@{File=[IO.Path]::GetFileName($Path);SHA256=(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash;Publisher=$publisher;SignerThumbprint=$certificate.Thumbprint;RootThumbprint=$chain.RootThumbprint;TimestampSigner=$signature.TimeStamperCertificate.Thumbprint;Status='Valid'}
}
function Invoke-ReleaseSigning([string]$Path,$Policy) {
  $arguments=@('sign','/v','/fd','SHA256','/tr',$Policy.TimestampUrl,'/td','SHA256','/d','SurroundForge')
  if($Policy.Provider -eq 'ArtifactSigning'){$arguments+=@('/dlib',$Policy.DlibPath,'/dmdf',$Policy.MetadataPath)}
  else {
    $arguments+=@('/s','My','/sha1',$Policy.CertificateThumbprint)
    if($Policy.StoreLocation -eq 'LocalMachine'){$arguments+='/sm'}
  }
  Invoke-SigningTool $Policy.SignToolPath ($arguments+@($Path))
  return Test-ReleaseSignature -Path $Path -Policy $Policy
}
