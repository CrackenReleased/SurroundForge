# Release signing and public distribution — v0.1.21-local package

Status: signing enforcement is implemented; **no publicly trusted Cracken Released signing identity exists yet**. The old v0.1.10 MSI remains a private, unsigned migration artifact. The v0.1.21 development MSI is unsigned. A separate v0.1.21 MSI is available as a [self-signed test download](../README.md#windows-installer); its local test certificate does not establish publisher identity or Microsoft approval.

## Free options and their limits

| Route | Signing/registration cost | Identity | Required change here |
|---|---|---|---|
| Microsoft Store MSIX | Free company registration and Store package signing | Company on Store listing; Microsoft signs package | Adapt packaging, writable state and startup; install drivers separately; company verification and Store certification |
| SignPath Foundation | Free for accepted open-source projects | SignPath Foundation as certificate publisher | Fully open-source distributable without proprietary drivers; public repository, application and acceptance |
| Self-signing | Free | Locally asserted identity | Does not provide default public Windows trust; excluded from the release pipeline |
| Standalone company-signed MSI | Certificate/service cost varies | Cracken Released, LLC | Verified company signing identity; approved public CA; authenticated vendor media or separate driver installation |

Microsoft does **not** re-sign an MSI/EXE submitted to the Store. Free Store signing applies to MSIX after certification. No free standalone MSI signing option with our company as certificate publisher has been established. A free option can still require an account and identity verification.

Sources checked 2026-10-09: [Microsoft signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options), [free company registration](https://blogs.windows.com/windowsdeveloper/2026/05/07/publish-to-microsoft-store-as-a-company-now-with-free-registration-and-faster-onboarding/), [MSIX driver limitations](https://learn.microsoft.com/en-us/windows/msix/packaging-tool/know-your-installer), [SignPath eligibility and publisher](https://signpath.org/terms.html).

The MSI helpers require our company identity. They are not Store or SignPath integrations. Either free route needs its own packaging/signing integration; acceptance is not guaranteed. No account has been created, business documents submitted, subscription activated or payment authorized by this work.

## What the MSI gate enforces

`Build-Msi.ps1` defaults to a signed release. Missing/invalid signing configuration stops it before staging or output mutation. It signs staging copies of the two native executables, FFmpeg DLLs and three application PowerShell scripts, retaining upstream attribution. Existing Microsoft runtime signatures and original vendor media are preserved. It then signs the MSI with SHA256 and an RFC3161 timestamp.

Verification requires valid Authenticode signatures, the exact publisher `Cracken Released, LLC`, a timestamp and a chain to an explicitly approved public CA root. Self-signed leaves are rejected. SignTool checks every embedded signature under Authenticode policy; warnings, including timestamp failures, stop release publication. Microsoft's signing tools must themselves have valid Microsoft signatures. Keys are selected by certificate-store thumbprint or held by the managed signing service; this code never exports keys or changes Windows trust stores.

Only a successfully verified MSI is copied atomically into `surround/dist/`, with SHA256 and signature report sidecars. Detailed SignTool output stays in ignored `surround/installer/build/signing.log`; reports record file digests, publisher and certificate/timestamp/root thumbprints. Build logs are replaced on the next build; retain reports beside approved releases. Hashes alone are not publisher authentication.

`Test-Msi.ps1` verifies the MSI before extraction and signed application scripts/runtime before normal validation. Unsigned development mode is explicit and outputs only under ignored `surround/installer/build/development/`, with `UNSIGNED-DEVELOPMENT` in the filename. It never substitutes for public release verification.

The included VB-CABLE installer currently verifies as signed. Original C-Media `setup.exe` is **NotSigned**, although its driver catalogs have separate signatures. Signed catalogs do not authenticate the installer wrapper. Public builds reject this media before requesting any application signatures. Do not re-sign the vendor wrapper as company-authored software. Vendor redistribution permission, dependency review and destination-PC testing remain outstanding public-release requirements. Signing proves publisher/integrity; it does not prove absence of vulnerabilities.

## Prepare a company signing identity without committing funds

For a future standalone MSI, the supported adapters are Microsoft Artifact Signing and a public CA certificate in the Windows certificate store. Copy the chosen `*.example.json` into ignored `.local/signing/`; keep the tracked examples free of real account/personal data. The certificate example requires a CA root thumbprint independently checked against the issuer's official documentation, not a locally created CA. No PFX/password command-line path is supported.

Artifact Signing requires an account/subscription, organization identity validation, a **PublicTrust** certificate profile, signing permissions and the official x64 client. It is an optional paid route, not a prerequisite for free alternatives. Before creating billable resources, obtain approval for the actual account, region and current price. Organization validation requires legal business details and supporting records; do not fabricate or submit unreviewed details.

Use the [official quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart) for enrollment and [integration documentation](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations) for the client/prerequisites. Grant the signing identity the **Artifact Signing Certificate Profile Signer** role scoped to its profile. Keep enrollment credentials separate from automation. The metadata template excludes interactive browser authentication; use an explicitly authorized identity, with managed/workload identity preferred for CI.

The Microsoft root template pins `F40042E2E5F7E8EF8189FED15519AECE42C3BFA2`, Microsoft Identity Verification Root Certificate Authority 2020 ([official PKI repository](https://www.microsoft.com/pkiops/docs/repository.htm)). The timestamp endpoint comes from Microsoft's integration instructions. Update pins only for an officially documented rotation; never relax checks to make failed signatures pass.

Once the signing identity and authenticated vendor prerequisites are ready, run from the repository root using **Windows PowerShell 5.1**:

```powershell
# Configure the chosen examples under .local/signing first.
# SDK/client paths must be checked; placeholders intentionally fail validation.
& .\surround\installer\Build-Msi.ps1 `
  -ReleaseDirectory "$PWD\surround\source\engine\build\package\Release" `
  -SigningConfiguration "$PWD\.local\signing\signing.json"
& .\surround\installer\Test-Msi.ps1 `
  -SigningConfiguration "$PWD\.local\signing\signing.json"
```

The bundled C-Media media does not carry a trusted publisher signature; the maintainer has stated that they hold written redistribution rights for both vendor installers. Publisher signing, timestamp validation and trusted-signed MSI install/removal have **not** been tested because no trusted signing identity exists. Do not claim a trusted release until they pass. SmartScreen reputation is separate; a valid new signature does not guarantee immediate absence of warnings.

## Local development verification

```powershell
& .\surround\tests\test_release_signing.ps1
& .\surround\installer\Build-Msi.ps1 -DevelopmentUnsigned `
  -ReleaseDirectory "$PWD\surround\source\engine\build\package\Release"
& .\surround\installer\Test-Msi.ps1 -DevelopmentUnsigned
```

The regression checks required signing mode, real rejection of an unsigned file, wrong publisher, missing timestamps, unapproved roots, self-signing, SHA256/RFC3161 arguments, SignTool warning exits, unsigned vendor wrappers and unchanged `dist` artifacts on a rejected default build. It installs no certificate and makes no audio changes. Mocked certificate facts test policy rejection; they are not evidence of real public signing.

## Custom WaveRT driver: Microsoft signing and certification

Driver source revision: v0.1.16-local, migration revision 1. The solution is `surround/source/driver/SimpleAudioSample.sln`. It advertises a render-only **SurroundForge 5.1 (SurroundForge Audio)** endpoint (`ROOT\SurroundForgeAudio`) with six assigned speakers at 48 kHz, PCM16/PCM32/float32 and physical-speaker mask `0x3f`.

No compiled driver package, enrolled public signing identity, submission or native-driver hardware verification is available. The verified live route uses VB-CABLE. Source metadata and a CAB file do not establish that Windows will load the driver.

Microsoft offers **attestation signing** and **HLK-tested certification** as different routes. Attestation does not make a driver Windows Certified; HLK/WHQL certification requires the applicable test results. See Microsoft's [driver signing options](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/driver-signing-offerings) and [kernel-mode signing policy](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/kernel-mode-code-signing-policy--windows-vista-and-later-). Check the current supported submission route before choosing a distribution target.

1. Establish the company's Hardware Developer Program account and required certificate association using Microsoft's [code-signing requirements](https://learn.microsoft.com/en-us/windows-hardware/drivers/dashboard/code-signing-reqs). No identity enrollment or certificate purchase has been performed by this project.
2. Install a compatible WDK and build `surround/source/driver/SimpleAudioSample.sln` using the existing builder:

   ```powershell
   & .\surround\source\driver\Build-Driver.ps1 -Configuration Release -Platform x64
   & .\surround\source\driver\New-AttestationCab.ps1 -VerifySourceOnly
   & .\surround\source\driver\New-AttestationCab.ps1 -DriverPackageDir "$PWD\surround\source\driver\x64\Release\package"
   ```

3. Sign and submit the built CAB through the applicable Microsoft dashboard route, or supply the required HLK results for certification. The helper only packages files: it neither signs nor uploads a submission.
4. Validate the returned Microsoft-signed package, root device creation, negotiated formats, loopback capture, per-channel AC3 delivery and hardware playback before integrating it into Setup/MSI or publishing a native-driver release.

Legacy upstream test-signing scripts remain private development helpers, excluded from Git. Normal installation must not change Secure Boot, enable test signing or import a local test certificate. Existing publisher-signing safeguards for the application MSI remain independent of kernel-driver approval.
