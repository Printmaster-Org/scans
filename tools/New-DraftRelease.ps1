param(
	[Parameter(Mandatory)][string]$Version,
	[Parameter(Mandatory)][string]$SourceCommit,
	[Parameter(Mandatory)][string]$PackageDirectory
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Release.Common.ps1')
Assert-ReleaseVersion $Version
$repository = 'printmaster-org/scans'
if ($env:GITHUB_REPOSITORY -ine $repository -or
	$env:GITHUB_REF -cnotin @('refs/heads/main', "refs/tags/$Version")) {
	throw 'Draft releases must be prepared from main or the matching release tag in printmaster-org/scans.'
}
$metadata = Get-Content -LiteralPath (Join-Path $PackageDirectory 'release.json') -Raw | ConvertFrom-Json
Assert-ReleaseMetadata -Metadata $metadata -Version $Version -ScriptPath (Join-Path $PackageDirectory 'scans.ps1')
if ($metadata.sourceCommit -cne $SourceCommit) { throw 'Package source does not match the tested commit.' }
$tagCommit = gh api "repos/$repository/commits/$Version" --jq .sha
if ($LASTEXITCODE -ne 0 -or $tagCommit -cne $SourceCommit) { throw 'The release tag must exist and match the packaged commit.' }
Assert-CommitCI -SourceCommit $SourceCommit
$request = @{ tag_name = $Version; target_commitish = $SourceCommit } | ConvertTo-Json
$response = $request | gh api "repos/$repository/releases/generate-notes" --method POST --input -
if ($LASTEXITCODE -ne 0) { throw 'Could not generate release notes.' }
$generatedNotes = ($response | ConvertFrom-Json).body
$notes = @"
$generatedNotes

## Run this version

Requires Windows PowerShell 5.1 or PowerShell 7 on Windows and administrator approval: the loader requests UAC when it is not already elevated.
The pinned command becomes available after this release is published and its Pages deployment succeeds.

``````powershell
& ([scriptblock]::Create((irm https://scans.printmaster.work/scans.ps1))) -Version '$Version'
``````

Direct download: https://github.com/$repository/releases/download/$Version/scans.ps1

SHA-256: ``$($metadata.sha256)``

Tested source commit: $SourceCommit
Validation: successful main-push CI for this exact commit (reused, not rerun).

Windows 11 is the primary platform; Windows 10 22H2 is best-effort compatibility.
Historical four-part release tags remain unchanged; new releases use SemVer.
"@
$notesPath = Join-Path $PackageDirectory 'notes.md'
$notes | Set-Content -LiteralPath $notesPath -Encoding UTF8
$assets = @('scans.ps1', 'release.json', 'SHA256SUMS.txt') | ForEach-Object { Join-Path $PackageDirectory $_ }
gh release create $Version @assets --repo $repository --target $SourceCommit --title "Scans $Version" --notes-file $notesPath --draft
if ($LASTEXITCODE -ne 0) { throw 'Could not create the draft release. Existing releases are never overwritten.' }
