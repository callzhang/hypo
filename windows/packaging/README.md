# Packaging Hypo for Windows

CI packs an **unsigned** MSIX on every green build and publishes it as
`hypo-msix-unsigned-win-x64`. That proves the manifest and layout are valid —
the part that rots silently — and it is not installable as it stands.

Windows refuses to install an unsigned MSIX. That is deliberate on Microsoft's
part and not something a build should work around, so signing is a separate
step, below.

## What is here

- `AppxManifest.xml` — identity, capabilities, visual assets, and a startup task
  so the app runs at login. A clipboard tool that syncs only while someone
  remembers to launch it is one people stop trusting.
- `Assets/` — placeholder artwork: an "H" that is recognisably the same mark at
  every size. Replace it; nothing depends on it beyond the filenames.
- `../scripts/package-msix.ps1` — runs `makeappx` over a published build.

## Signing

**`Publisher` in the manifest must match the signing certificate's subject
character for character.** A mismatch fails installation with a message that
does not mention the mismatch, which is the single most common way to lose an
afternoon here. The script takes `-Publisher` so the manifest does not have to
be edited per certificate.

### With SignPath (the intended path)

SignPath signs an artifact produced by a CI run, so no key material touches the
build. It needs an account, a project, and an API token in repository secrets —
none of which exist yet, which is why CI stops at the unsigned package.

Once they do, add a step after the MSIX upload that submits
`hypo-msix-unsigned-win-x64` to SignPath and publishes the signed result. Pass
the certificate's subject through `-Publisher` so the two cannot drift.

### Locally, to try an installable build

```powershell
# A certificate to test with. Its subject is what the package must claim.
$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject "CN=Hypo Test, O=Hypo, C=US" `
    -CertStoreLocation Cert:\CurrentUser\My

cd windows
dotnet publish src/Hypo.Windows.App/Hypo.Windows.App.csproj `
    -c Release -r win-x64 --self-contained true -o ../artifacts/app

./scripts/package-msix.ps1 `
    -PublishDirectory ../artifacts/app `
    -OutputPath ../artifacts/Hypo.msix `
    -Publisher "CN=Hypo Test, O=Hypo, C=US"

# signtool ships with the Windows SDK.
signtool sign /fd SHA256 /a /sha1 $cert.Thumbprint ../artifacts/Hypo.msix
```

Windows still will not trust that certificate until it is in the machine's
Trusted People store — which is a real trust decision, so it is left to you
rather than scripted:

```powershell
Export-Certificate -Cert $cert -FilePath hypo-test.cer
# Then, elevated:
Import-Certificate -FilePath hypo-test.cer -CertStoreLocation Cert:\LocalMachine\TrustedPeople
```

## Versioning

MSIX versions are four-part and **must increase between builds**, or an upgrade
is skipped with no error. The manifest carries the release version; pass
`-PackageVersion` to override it from CI. The revision field should stay `0`.

## winget

Not set up. It needs a signed, publicly downloadable package first, so it
follows signing rather than preceding it.
