$root = Split-Path $PSScriptRoot -Parent
$tokens = $null
$errors = $null
$loaderAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'scans.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($definition in $loaderAst.FindAll({
	param($node)
	$node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $true)) {
	. ([scriptblock]::Create($definition.Extent.Text))
}
. (Join-Path $root 'tools\Release.Common.ps1')

function gh {
	param(
		[Parameter(Position = 0)]$Command,
		[Parameter(Position = 1)]$Target,
		[Parameter(ValueFromRemainingArguments = $true)]$Arguments,
		[Parameter(ValueFromPipeline = $true)]$InputObject
	)
	throw 'Unmocked GitHub CLI call'
}

function New-TestRelease {
	param([string]$Version = 'v2.1.0')
	[pscustomobject]@{
		version = $Version
		url = "https://github.com/printmaster-org/scans/releases/download/$Version/scans.ps1"
		sha256 = 'a' * 64
		sourceCommit = 'b' * 40
		publishedAt = '2026-10-15T12:00:00Z'
		releaseUrl = "https://github.com/printmaster-org/scans/releases/tag/$Version"
	}
}

Describe 'Release version policy' {
	It 'accepts stable SemVer and rejects new four-part, malformed, or prerelease tags' {
		foreach ($version in @('v0.1.0', 'v2.0.3', 'v2.1.0', 'v10.0.0')) {
			{ Assert-ReleaseVersion $version } | Should Not Throw
		}
		foreach ($version in @('2.1.0', 'v2.0.2.0', 'v02.1.0', 'v2.1', 'v2.1.0-beta', 'v2.1.0+build', '../evil')) {
			{ Assert-ReleaseVersion $version } | Should Throw
		}
	}
}

Describe 'Loader release selection' {
	BeforeEach {
		$script:manifest = [pscustomobject]@{
			schemaVersion = 1
			stable = 'v2.1.0'
			releases = @((New-TestRelease), (New-TestRelease -Version 'v2.0.3'))
		}
	}

	It 'selects the promoted stable release and supports older pinned versions' {
		(Get-ScanRelease -Manifest $script:manifest).version | Should Be 'v2.1.0'
		(Get-ScanRelease -Manifest $script:manifest -RequestedVersion v2.0.3).version | Should Be 'v2.0.3'
	}

	It 'rejects unknown schemas, missing versions, and duplicate entries' {
		$script:manifest.schemaVersion = 2
		{ Get-ScanRelease -Manifest $script:manifest } | Should Throw
		$script:manifest.schemaVersion = 1
		{ Get-ScanRelease -Manifest $script:manifest -RequestedVersion v9.0.0 } | Should Throw
		$script:manifest.releases += New-TestRelease
		{ Get-ScanRelease -Manifest $script:manifest } | Should Throw
	}

	It 'rejects latest URLs, other repositories, HTTP, and malformed hashes' {
		foreach ($url in @(
			'https://github.com/printmaster-org/scans/releases/latest/download/scans.ps1',
			'https://github.com/attacker/scans/releases/download/v2.1.0/scans.ps1',
			'http://github.com/printmaster-org/scans/releases/download/v2.1.0/scans.ps1'
		)) {
			$script:manifest.releases[0].url = $url
			{ Get-ScanRelease -Manifest $script:manifest } | Should Throw
		}
		$script:manifest.releases[0] = New-TestRelease
		$script:manifest.releases[0].sha256 = 'not a hash'
		{ Get-ScanRelease -Manifest $script:manifest } | Should Throw
	}
}

Describe 'Verified loader execution' {
	BeforeEach {
		$script:release = New-TestRelease
		$fixture = Join-Path $TestDrive 'payload.ps1'
		[IO.File]::WriteAllText($fixture, "throw 'This fixture must never execute'")
		$script:payloadBytes = [IO.File]::ReadAllBytes($fixture)
		$script:release.sha256 = (Get-FileHash $fixture -Algorithm SHA256).Hash
		$script:downloadPath = $null
		Mock Invoke-RestMethod { [pscustomobject]@{ schemaVersion = 1; stable = 'v2.1.0'; releases = @($script:release) } }
		Mock Invoke-WebRequest {
			$script:downloadPath = $OutFile
			[IO.File]::WriteAllBytes($OutFile, $script:payloadBytes)
		}
		Mock Start-ScanScript { }
	}

	It 'executes only a verified download and removes its temporary file and directory' {
		Invoke-ScanRelease
		Assert-MockCalled Start-ScanScript -Times 1 -Exactly -Scope It -ParameterFilter { $ReleaseVersion -eq 'v2.1.0' -and $Sha256 -eq $script:release.sha256 }
		Test-Path -LiteralPath $script:downloadPath | Should Be $false
		Test-Path -LiteralPath (Split-Path $script:downloadPath -Parent) | Should Be $false
	}

	It 'cleans up the verified download when the user declines UAC' {
		Mock Start-ScanScript { $false }
		{ Invoke-ScanRelease } | Should Not Throw
		Test-Path -LiteralPath (Split-Path $script:downloadPath -Parent) | Should Be $false
	}

	It 'cleans up the verified download when setup fails' {
		Mock Start-ScanScript { throw 'Scans exited with code 1.' }
		{ Invoke-ScanRelease } | Should Throw 'exited with code 1'
		Test-Path -LiteralPath (Split-Path $script:downloadPath -Parent) | Should Be $false
	}

	It 'does not execute a checksum mismatch or leave the download behind' {
		$script:release.sha256 = '0' * 64
		{ Invoke-ScanRelease } | Should Throw 'SHA-256 verification failed'
		Assert-MockCalled Start-ScanScript -Times 0 -Exactly -Scope It
		Test-Path -LiteralPath (Split-Path $script:downloadPath -Parent) | Should Be $false
	}

	It 'fails closed on network errors without attempting to execute anything' {
		Mock Invoke-WebRequest { throw 'Download unavailable' }
		{ Invoke-ScanRelease } | Should Throw 'Download unavailable'
		Assert-MockCalled Start-ScanScript -Times 0 -Exactly -Scope It
	}

	It 'does not download an asset when manifest retrieval fails' {
		Mock Invoke-RestMethod { throw 'Manifest unavailable' }
		{ Invoke-ScanRelease } | Should Throw 'Manifest unavailable'
		Assert-MockCalled Invoke-WebRequest -Times 0 -Exactly -Scope It
		Assert-MockCalled Start-ScanScript -Times 0 -Exactly -Scope It
	}
}

Describe 'Loader elevation' {
	BeforeEach {
		$script:payload = Join-Path $TestDrive 'utility.ps1'
		$script:marker = Join-Path $TestDrive 'marker.txt'
		Remove-Item -LiteralPath $script:marker -ErrorAction SilentlyContinue
		# Fixture utility: records whether it ran and with -Elevated, then exits with a chosen code.
		$script:writePayload = {
			param([int]$ExitCode = 0)
			$markerLiteral = "'" + $script:marker.Replace("'", "''") + "'"
			[IO.File]::WriteAllText($script:payload, "param([switch]`$Elevated)`n[IO.File]::WriteAllText($markerLiteral, ('ran elevated=' + [bool]`$Elevated))`nexit $ExitCode`n", [Text.UTF8Encoding]::new($true))
			(Get-FileHash -LiteralPath $script:payload -Algorithm SHA256).Hash
		}
		$script:hostExe = Join-Path $PSHOME $(if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh.exe' } else { 'powershell.exe' })
		$script:processStarted = $false
		$script:processWaited = $false
		$script:processDisposed = $false
		$script:processStartError = $null
		$script:elevatedProcess = [pscustomobject]@{ StartInfo = $null; ExitCode = 0 }
		$script:elevatedProcess | Add-Member ScriptMethod Start {
			$script:processStarted = $true
			if ($script:processStartError) { throw $script:processStartError }
			return $true
		}
		$script:elevatedProcess | Add-Member ScriptMethod WaitForExit { $script:processWaited = $true }
		$script:elevatedProcess | Add-Member ScriptMethod Dispose { $script:processDisposed = $true }
		Mock New-Object { $script:elevatedProcess } -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }
		Mock Write-Host { }
	}

	It 'runs the verified bytes in a real child and passes -Elevated only when requested' {
		$hash = & $script:writePayload 0
		& $script:hostExe -NoProfile -NonInteractive -EncodedCommand (New-ScanLaunchCommand -Path $script:payload -Sha256 $hash -Elevated)
		$LASTEXITCODE | Should Be 0
		Get-Content -LiteralPath $script:marker | Should Be 'ran elevated=True'
		& $script:hostExe -NoProfile -NonInteractive -EncodedCommand (New-ScanLaunchCommand -Path $script:payload -Sha256 $hash)
		Get-Content -LiteralPath $script:marker | Should Be 'ran elevated=False'
	}

	It 'propagates the utility exit code from the child' {
		$hash = & $script:writePayload 1
		& $script:hostExe -NoProfile -NonInteractive -EncodedCommand (New-ScanLaunchCommand -Path $script:payload -Sha256 $hash)
		$LASTEXITCODE | Should Be 1
	}

	It 'refuses to run a file that changed after the loader verified it' {
		$hash = & $script:writePayload 0
		Add-Content -LiteralPath $script:payload -Value '# tampered'
		# Capture stderr through the process API: Windows PowerShell 5.1 turns redirected native
		# stderr into a terminating RemoteException when ErrorActionPreference is Stop.
		$stderr = Join-Path $TestDrive 'stderr.txt'
		$child = Start-Process -FilePath $script:hostExe -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', (New-ScanLaunchCommand -Path $script:payload -Sha256 $hash)) -NoNewWindow -Wait -PassThru -RedirectStandardError $stderr
		$child.ExitCode | Should Be (Get-ScanVerifyFailedExitCode)
		(Get-Content -LiteralPath $stderr -Raw) | Should Match 're-check failed'
		Test-Path -LiteralPath $script:marker | Should Be $false
	}

	It 'requests UAC with a waiting, re-verifying elevated child when not elevated' {
		Mock Test-ScanAdministrator { $false }
		Start-ScanScript -Path 'C:\temp\scans.ps1' -Sha256 ('a' * 64) -ReleaseVersion 'v2.3.0' | Should Be $true
		$info = $script:elevatedProcess.StartInfo
		$info.FileName | Should Be $script:hostExe
		$info.UseShellExecute | Should Be $true
		$info.Verb | Should Be 'runas'
		$info.Arguments | Should Match '^-NoProfile -STA -EncodedCommand '
		$command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(($info.Arguments -split ' ')[-1]))
		$command.Contains("'C:\temp\scans.ps1'") | Should Be $true
		$command.Contains('a' * 64) | Should Be $true
		$command.Contains(' -Elevated') | Should Be $true
		$script:processStarted | Should Be $true
		$script:processWaited | Should Be $true
		$script:processDisposed | Should Be $true
	}

	It 'treats a declined UAC prompt as a normal cancellation' {
		Mock Test-ScanAdministrator { $false }
		$script:processStartError = [ComponentModel.Win32Exception]::new(1223, 'Localized cancellation text')
		Start-ScanScript -Path 'C:\temp\scans.ps1' -Sha256 ('a' * 64) -ReleaseVersion 'v2.3.0' | Should Be $false
		Assert-MockCalled Write-Host -Scope It -ParameterFilter { "$Object" -match 'declined' }
		$script:processWaited | Should Be $false
		$script:processDisposed | Should Be $true
		Test-Path -LiteralPath $script:marker | Should Be $false
	}

	It 'cleans up the download after cancellation through the real launch and cleanup functions' {
		Mock Test-ScanAdministrator { $false }
		$script:processStartError = [ComponentModel.Win32Exception]::new(1223)
		$script:release = New-TestRelease
		$script:release.sha256 = & $script:writePayload 0
		Mock Invoke-RestMethod { [pscustomobject]@{ schemaVersion = 1; stable = 'v2.1.0'; releases = @($script:release) } }
		Mock Invoke-WebRequest {
			$script:canceledDownload = $OutFile
			Copy-Item -LiteralPath $script:payload -Destination $OutFile
		}
		{ Invoke-ScanRelease } | Should Not Throw
		Test-Path -LiteralPath (Split-Path $script:canceledDownload -Parent) | Should Be $false
		Test-Path -LiteralPath $script:marker | Should Be $false
		Assert-MockCalled Write-Host -Scope It -ParameterFilter { "$Object" -match 'declined' }
	}

	It 'rethrows other elevation failures' {
		Mock Test-ScanAdministrator { $false }
		foreach ($code in @(2, 5)) {
			$script:processStartError = [ComponentModel.Win32Exception]::new($code)
			{ Start-ScanScript -Path 'C:\temp\scans.ps1' -Sha256 ('a' * 64) -ReleaseVersion 'v2.3.0' } | Should Throw
		}
		$script:processDisposed | Should Be $true
		Assert-MockCalled Write-Host -Times 0 -Exactly -Scope It -ParameterFilter { "$Object" -match 'declined' }
	}

	It 'reports elevated child failures and post-verification tampering distinctly' {
		Mock Test-ScanAdministrator { $false }
		$script:elevatedProcess.ExitCode = 1
		{ Start-ScanScript -Path 'C:\temp\scans.ps1' -Sha256 ('a' * 64) -ReleaseVersion 'v2.3.0' } | Should Throw 'exited with code 1'
		$script:elevatedProcess.ExitCode = Get-ScanVerifyFailedExitCode
		{ Start-ScanScript -Path 'C:\temp\scans.ps1' -Sha256 ('a' * 64) -ReleaseVersion 'v2.3.0' } | Should Throw 'changed after verification'
	}

	It 'runs directly without UAC when already elevated' {
		Mock Test-ScanAdministrator { $true }
		Mock Start-Process { throw 'UAC must not be requested' }
		$hash = & $script:writePayload 0
		Start-ScanScript -Path $script:payload -Sha256 $hash -ReleaseVersion 'v2.3.0' | Should Be $true
		Get-Content -LiteralPath $script:marker | Should Be 'ran elevated=False'
		Assert-MockCalled Start-Process -Times 0 -Exactly -Scope It
		Assert-MockCalled New-Object -Times 0 -Exactly -Scope It -ParameterFilter { $TypeName -eq 'System.Diagnostics.Process' }
	}
}

	Describe 'Published release catalog verification' {
		BeforeEach {
			$script:catalogFile = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.json')
			$script:fixture = Join-Path $TestDrive 'catalog-payload.ps1'
			[IO.File]::WriteAllText($script:fixture, '# packaged utility')
			$script:metadata = [ordered]@{
				schemaVersion = 1
				version = 'v2.1.0'
				sourceCommit = 'b' * 40
				sourcePath = 'scans.ps1'
				sha256 = (Get-FileHash $script:fixture).Hash.ToLowerInvariant()
			}
			$script:published = [pscustomobject]@{
				tag_name = 'v2.1.0'; draft = $false; prerelease = $false; published_at = '2026-10-15T12:00:00Z'
			}
			$script:releasePages = ,@(
				$script:published,
				[pscustomobject]@{ tag_name = '2.0.2.0'; draft = $false; prerelease = $false },
				[pscustomobject]@{ tag_name = 'v9.0.0'; draft = $true; prerelease = $false },
				[pscustomobject]@{ tag_name = 'v3.0.0-beta'; draft = $false; prerelease = $true }
			)
			$global:ScansCatalogTestState = @{
				Pages = $script:releasePages
				Metadata = $script:metadata
				Fixture = $script:fixture
			}
			Mock gh {
				$state = $global:ScansCatalogTestState
				$global:LASTEXITCODE = 0
				if ($Command -eq 'api' -and $Target -like '*releases?per_page*') {
					ConvertTo-Json -InputObject $state.Pages -Depth 5
				}
				elseif ($Command -eq 'api' -and $Target -like '*commits/v2.1.0') {
					'b' * 40
				}
				elseif ($Command -eq 'release' -and $Target -eq 'download') {
					$directory = $Arguments[[Array]::IndexOf($Arguments, '--dir') + 1]
					Copy-Item -LiteralPath $state.Fixture -Destination (Join-Path $directory 'scans.ps1')
					$state.Metadata | ConvertTo-Json | Set-Content (Join-Path $directory 'release.json')
					"$($state.Metadata.sha256)  scans.ps1" | Set-Content (Join-Path $directory 'SHA256SUMS.txt')
				}
				else { throw "Unexpected GitHub call: $Command $Target $Arguments" }
			}
			Mock Invoke-WebRequest { Copy-Item -LiteralPath $global:ScansCatalogTestState.Fixture -Destination $OutFile }
		}
		AfterEach { Remove-Variable -Name ScansCatalogTestState -Scope Global -ErrorAction SilentlyContinue }

		It 'verifies published bytes and source while excluding old, draft, and prerelease tags' {
			& (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile -SelectedVersion v2.1.0
			$catalog = @(Get-Content $script:catalogFile -Raw | ConvertFrom-Json)
			$catalog.Count | Should Be 1
			$catalog[0].version | Should Be 'v2.1.0'
			$catalog[0].sha256 | Should Be $script:metadata.sha256
			Assert-MockCalled gh -Times 1 -Exactly -Scope It -ParameterFilter { $Command -eq 'release' -and $Target -eq 'download' }
		}

		It 'explains how to publish the selected draft instead of returning an empty catalog error' {
			$script:published.draft = $true
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile -SelectedVersion v2.1.0 } |
				Should Throw "Release 'v2.1.0' is still a draft"
			Assert-MockCalled gh -Times 0 -Exactly -Scope It -ParameterFilter { $Command -eq 'release' -and $Target -eq 'download' }
			Test-Path $script:catalogFile | Should Be $false
		}

		It 'rejects missing releases and prereleases before downloading assets' {
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile -SelectedVersion v8.0.0 } |
				Should Throw 'A Git tag alone is not a published release'
			$script:published.prerelease = $true
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile -SelectedVersion v2.1.0 } |
				Should Throw 'prerelease and cannot be promoted'
			Assert-MockCalled gh -Times 0 -Exactly -Scope It -ParameterFilter { $Command -eq 'release' -and $Target -eq 'download' }
		}

		It 'refuses metadata hashes that do not match the release asset' {
			$script:metadata.sha256 = '0' * 64
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile } | Should Throw 'SHA-256'
			Test-Path $script:catalogFile | Should Be $false
		}

		It 'reads every page of published releases' {
			$older = [pscustomobject]@{
				tag_name = 'v2.0.3'; draft = $false; prerelease = $false; published_at = '2026-10-14T12:00:00Z'
			}
			$global:ScansCatalogTestState.Pages = @(@($script:published), @($older))
			Mock gh {
				$state = $global:ScansCatalogTestState
				$global:LASTEXITCODE = 0
				if ($Command -eq 'api' -and $Target -like '*releases?per_page*') {
					ConvertTo-Json -InputObject $state.Pages -Depth 5
				}
				elseif ($Command -eq 'api' -and $Target -like '*commits/*') {
					'b' * 40
				}
				elseif ($Command -eq 'release' -and $Target -eq 'download') {
					$directory = $Arguments[[Array]::IndexOf($Arguments, '--dir') + 1]
					$version = $Arguments[0]
					Copy-Item -LiteralPath $state.Fixture -Destination (Join-Path $directory 'scans.ps1')
					$metadata = $state.Metadata | ConvertTo-Json | ConvertFrom-Json
					$metadata.version = $version
					$metadata | ConvertTo-Json | Set-Content (Join-Path $directory 'release.json')
					"$($metadata.sha256)  scans.ps1" | Set-Content (Join-Path $directory 'SHA256SUMS.txt')
				}
				else { throw "Unexpected GitHub call: $Command $Target $Arguments" }
			}
			& (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile
			$catalog = @(Get-Content $script:catalogFile -Raw | ConvertFrom-Json | ForEach-Object { $_ })
			$catalog.Count | Should Be 2
			$catalog[0].version | Should Be 'v2.1.0'
			$catalog[1].version | Should Be 'v2.0.3'
		}

		It 'refuses a tag pointing to a different source commit' {
			$script:metadata.sourceCommit = 'c' * 40
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile } | Should Throw 'different source commit'
		}

		It 'refuses assets that differ from their recorded source file' {
			Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value '# different source' }
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile } | Should Throw 'tagged source'
		}

		It 'fails explicitly if there are no eligible releases or GitHub is unavailable' {
			$global:ScansCatalogTestState.Pages = ,@([pscustomobject]@{ tag_name = '2.0.2.0'; draft = $false; prerelease = $false })
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile } | Should Throw 'No published'
			Mock gh { $global:LASTEXITCODE = 1 }
			{ & (Join-Path $root 'tools\Get-ReleaseCatalog.ps1') -OutputFile $script:catalogFile } | Should Throw 'Could not list'
		}
	}

	Describe 'Draft release preparation' {
		BeforeEach {
			$script:previousRepo = $env:GITHUB_REPOSITORY
			$script:previousRef = $env:GITHUB_REF
			$env:GITHUB_REPOSITORY = 'printmaster-org/scans'
			$env:GITHUB_REF = 'refs/heads/main'
			$script:draftPackage = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
			& (Join-Path $root 'tools\New-ReleasePackage.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -OutputDirectory $script:draftPackage
			Mock gh {
				$global:LASTEXITCODE = 0
				if ($Command -eq 'api' -and $Target -like '*commits/*') { 'b' * 40 }
				elseif ($Command -eq 'api' -and $Target -like '*actions/workflows/ci.yml/runs?*') {
					ConvertTo-Json -InputObject @(@{ workflow_runs = @(@{
						id = 100; head_sha = 'b' * 40; event = 'push'; head_branch = 'main'
						status = 'completed'; conclusion = 'success'; html_url = 'https://github.com/Printmaster-Org/scans/actions/runs/100'
					}) }) -Depth 6
				}
				elseif ($Command -eq 'api') { '{"body":"## Changes\n- Example merged PR"}' }
			}
		}
		AfterEach {
			$env:GITHUB_REPOSITORY = $script:previousRepo
			$env:GITHUB_REF = $script:previousRef
		}

		It 'creates a draft with editable notes, pinned instructions, and the actual SHA' {
			& (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -PackageDirectory $script:draftPackage
			$notes = Get-Content (Join-Path $script:draftPackage 'notes.md') -Raw
			$notes | Should Match 'Example merged PR'
			$notes | Should Match "-Version 'v2.1.0'"
			$notes | Should Match '```powershell'
			$metadata = Get-Content (Join-Path $script:draftPackage 'release.json') -Raw | ConvertFrom-Json
			$notes | Should Match $metadata.sha256
			Assert-MockCalled gh -Times 1 -Exactly -Scope It -ParameterFilter {
				$Command -eq 'release' -and $Target -eq 'create' -and $Arguments -contains '--draft' -and $Arguments -contains ('b' * 40)
			}
		}

		It 'rejects publication from the old owner or a feature branch' {
			$env:GITHUB_REPOSITORY = 'mstrhakr/scans'
			{ & (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -PackageDirectory $script:draftPackage } | Should Throw
			$env:GITHUB_REPOSITORY = 'printmaster-org/scans'
			$env:GITHUB_REF = 'refs/heads/feature/example'
			{ & (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -PackageDirectory $script:draftPackage } | Should Throw
			Assert-MockCalled gh -Times 0 -Exactly -Scope It
		}

		It 'rejects packages that do not belong to the tested commit' {
			{ & (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('c' * 40) -PackageDirectory $script:draftPackage } | Should Throw 'tested commit'
			Assert-MockCalled gh -Times 0 -Exactly -Scope It
		}

		It 'accepts the matching tag trigger and requires existing main CI' {
			$env:GITHUB_REF = 'refs/tags/v2.1.0'
			& (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -PackageDirectory $script:draftPackage
			Assert-MockCalled gh -Times 1 -Exactly -Scope It -ParameterFilter { $Target -like '*actions/workflows/ci.yml/runs?*' }
		}

		It 'rejects tags that do not match the packaged commit' {
			Mock gh { $global:LASTEXITCODE = 0; 'c' * 40 }
			{ & (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -PackageDirectory $script:draftPackage } | Should Throw 'tag must exist'
			Assert-MockCalled gh -Times 0 -Exactly -Scope It -ParameterFilter { $Target -like '*actions/workflows/ci.yml/runs?*' }
		}

		It 'does not create a draft when main CI has not passed' {
			Mock gh { throw 'CI evidence unavailable' } -ParameterFilter { $Target -like '*actions/workflows/ci.yml/runs?*' }
			{ & (Join-Path $root 'tools\New-DraftRelease.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -PackageDirectory $script:draftPackage } | Should Throw 'CI evidence unavailable'
			Assert-MockCalled gh -Times 0 -Exactly -Scope It -ParameterFilter { $Command -eq 'release' }
		}
	}

Describe 'Reusing exact main commit CI evidence' {
	BeforeEach {
		$global:ScansCITestRuns = @([pscustomobject]@{
			id = 100; head_sha = 'b' * 40; event = 'push'; head_branch = 'main'
			status = 'completed'; conclusion = 'success'; html_url = 'https://github.com/Printmaster-Org/scans/actions/runs/100'
		})
		Mock gh {
			$global:LASTEXITCODE = 0
			ConvertTo-Json -InputObject @(@{ workflow_runs = @($global:ScansCITestRuns) }) -Depth 6
		}
		Mock Start-Sleep { }
	}
	AfterEach { Remove-Variable ScansCITestRuns -Scope Global -ErrorAction SilentlyContinue }

	It 'reuses main-push CI for the exact SHA and only the CI workflow' {
		Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 1
		Assert-MockCalled gh -Times 1 -Exactly -Scope It -ParameterFilter {
			$Target -like 'repos/printmaster-org/scans/actions/workflows/ci.yml/runs?*' -and
			$Target.Contains('event=push&branch=main&head_sha=' + ('b' * 40))
		}
		Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
	}

	It 'rejects PR evidence, other commits, and runs on other branches' {
		$global:ScansCITestRuns[0].event = 'pull_request'
		{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 1 } | Should Throw 'No completed successful'
		$global:ScansCITestRuns[0].event = 'push'
		$global:ScansCITestRuns[0].head_sha = 'c' * 40
		{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 1 } | Should Throw
		$global:ScansCITestRuns[0].head_sha = 'b' * 40
		$global:ScansCITestRuns[0].head_branch = 'feature/test'
		{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 1 } | Should Throw
	}

	It 'fails immediately for failed, cancelled, or skipped CI' {
		foreach ($conclusion in @('failure', 'cancelled', 'skipped', 'timed_out')) {
			$global:ScansCITestRuns[0].conclusion = $conclusion
			{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 2 } | Should Throw 'did not pass'
		}
		Assert-MockCalled Start-Sleep -Times 0 -Exactly -Scope It
	}

	It 'waits for existing in-progress CI instead of dispatching new tests' {
		$global:ScansCITestRuns[0].status = 'in_progress'
		Mock Start-Sleep { $global:ScansCITestRuns[0].status = 'completed' }
		Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 2 -RetrySeconds 0
		Assert-MockCalled gh -Times 2 -Exactly -Scope It
		Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
	}

	It 'waits briefly for a main-push run that has not appeared yet' {
		$global:ScansCITestRuns = @()
		{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 2 -RetrySeconds 0 } | Should Throw 'No completed successful'
		Assert-MockCalled Start-Sleep -Times 1 -Exactly -Scope It
	}

	It 'does not fall back to an older success when a newer run failed' {
		$failed = $global:ScansCITestRuns[0] | ConvertTo-Json | ConvertFrom-Json
		$failed.id = 101
		$failed.conclusion = 'failure'
		$global:ScansCITestRuns += $failed
		{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 1 } | Should Throw 'did not pass'
	}

	It 'fails explicitly if GitHub cannot supply CI evidence' {
		Mock gh { $global:LASTEXITCODE = 1 }
		{ Assert-CommitCI -SourceCommit ('b' * 40) -MaxAttempts 1 } | Should Throw 'Could not verify'
	}
}

Describe 'Workflow dependency pinning' {
	It 'pins every external action reference to a full commit SHA' {
		$references = @(Get-ChildItem (Join-Path $root '.github\workflows') -Filter '*.yml' |
			Select-String -Pattern 'uses:\s+([^\s#]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value })
		$references.Count | Should BeGreaterThan 0
		foreach ($reference in $references) {
			if ($reference.StartsWith('./')) { continue }
			$reference | Should Match '^[\w.-]+/[\w./-]+@[a-f0-9]{40}$'
		}
	}
}

Describe 'Release packaging and site generation' {
	BeforeEach {
		$script:package = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
		$script:site = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
		$script:catalogPath = Join-Path $TestDrive 'catalog.json'
	}

	It 'packages exact utility bytes with matching metadata and checksums' {
		& (Join-Path $root 'tools\New-ReleasePackage.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -OutputDirectory $script:package
		$metadata = Get-Content (Join-Path $script:package 'release.json') -Raw | ConvertFrom-Json
		$asset = Join-Path $script:package 'scans.ps1'
		Assert-ReleaseMetadata -Metadata $metadata -Version v2.1.0 -ScriptPath $asset
		(Get-FileHash $asset).Hash | Should Be (Get-FileHash (Join-Path $root 'src\scans.ps1')).Hash
		$metadata.sourcePath | Should Be 'src/scans.ps1'
		(Get-Content (Join-Path $script:package 'SHA256SUMS.txt') -Raw).Trim() | Should Be "$($metadata.sha256)  scans.ps1"
		Add-Content -LiteralPath $asset -Value '# tampered'
		{ Assert-ReleaseMetadata -Metadata $metadata -Version v2.1.0 -ScriptPath $asset } | Should Throw
	}

	It 'rejects invalid package versions before producing output' {
		{ & (Join-Path $root 'tools\New-ReleasePackage.ps1') -Version v2.0.2.0 -SourceCommit ('b' * 40) -OutputDirectory $script:package } | Should Throw
		Test-Path $script:package | Should Be $false
	}

	It 'packages the selected tag checkout rather than the workflow checkout' {
		$source = Join-Path $TestDrive 'tag-checkout'
		New-Item -Path $source -ItemType Directory -Force | Out-Null
		Set-Content -LiteralPath (Join-Path $source 'scans.ps1') -Value '# selected tagged utility'
		& (Join-Path $root 'tools\New-ReleasePackage.ps1') -Version v2.1.0 -SourceCommit ('b' * 40) -SourceDirectory $source -OutputDirectory $script:package
		(Get-Content (Join-Path $script:package 'scans.ps1') -Raw).Trim() | Should Be '# selected tagged utility'
	}

	It 'builds the manifest, pinned history, and byte-identical shared loader without modifying source' {
		ConvertTo-Json -InputObject @((New-TestRelease -Version v2.0.3), (New-TestRelease)) | Set-Content $script:catalogPath
		& (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v2.1.0 -OutputDirectory $script:site
		$manifest = Get-Content (Join-Path $script:site 'releases.json') -Raw | ConvertFrom-Json
		$manifest.stable | Should Be 'v2.1.0'
		$manifest.releases.Count | Should Be 2
		$manifest.releases[0].version | Should Be 'v2.1.0'
		(Get-FileHash (Join-Path $script:site 'scans.ps1')).Hash | Should Be (Get-FileHash (Join-Path $root 'scans.ps1')).Hash
		(Get-Content (Join-Path $script:site 'CNAME') -Raw).Trim() | Should Be 'scans.printmaster.work'
		Test-Path (Join-Path $script:site 'index.html') | Should Be $true
		Test-Path (Join-Path $script:site 'img\scans-setup.png') | Should Be $true
		(Get-FileHash (Join-Path $script:site 'logo.svg')).Hash | Should Be (Get-FileHash (Join-Path $root 'site\logo.svg')).Hash
		Test-Path (Join-Path $script:site '.nojekyll') | Should Be $true
		Test-Path (Join-Path $root 'site\releases.json') | Should Be $false
	}

	It 'supports explicit rollback without dropping other pinned releases' {
		ConvertTo-Json -InputObject @((New-TestRelease), (New-TestRelease -Version v2.0.3)) | Set-Content $script:catalogPath
		& (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v2.0.3 -OutputDirectory $script:site
		$manifest = Get-Content (Join-Path $script:site 'releases.json') -Raw | ConvertFrom-Json
		$manifest.stable | Should Be 'v2.0.3'
		$manifest.releases.Count | Should Be 2
	}

	It 'keeps the first release as an array in the generated manifest' {
		ConvertTo-Json -InputObject @((New-TestRelease)) | Set-Content $script:catalogPath
		& (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v2.1.0 -OutputDirectory $script:site
		$manifest = Get-Content (Join-Path $script:site 'releases.json') -Raw | ConvertFrom-Json
		$manifest.releases -is [array] | Should Be $true
		$manifest.releases.Count | Should Be 1
		(Get-ScanRelease -Manifest $manifest).version | Should Be 'v2.1.0'
	}

	It 'rejects unknown stable versions and duplicate or untrusted catalog entries' {
		ConvertTo-Json -InputObject @((New-TestRelease)) | Set-Content $script:catalogPath
		{ & (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v9.0.0 -OutputDirectory $script:site } | Should Throw
		ConvertTo-Json -InputObject @((New-TestRelease), (New-TestRelease)) | Set-Content $script:catalogPath
		{ & (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v2.1.0 -OutputDirectory $script:site } | Should Throw
		$bad = New-TestRelease
		$bad.url = 'https://example.invalid/scans.ps1'
		ConvertTo-Json -InputObject @($bad) | Set-Content $script:catalogPath
		{ & (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v2.1.0 -OutputDirectory $script:site } | Should Throw
		Test-Path $script:site | Should Be $false
	}

	It 'does not overwrite an existing site output directory' {
		ConvertTo-Json -InputObject @((New-TestRelease)) | Set-Content $script:catalogPath
		New-Item -Path $script:site -ItemType Directory | Out-Null
		{ & (Join-Path $root 'tools\Build-Site.ps1') -CatalogPath $script:catalogPath -StableVersion v2.1.0 -OutputDirectory $script:site } | Should Throw
	}
}
