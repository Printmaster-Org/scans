$sourcePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'src\scans.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Load only function definitions, without elevation, UI, or machine configuration.
foreach ($definition in $ast.FindAll({
		param($node)
		$node -is [System.Management.Automation.Language.FunctionDefinitionAst]
	}, $true)) {
	. ([scriptblock]::Create($definition.Extent.Text))
}
$remediationAssignment = $ast.Find({
	param($node)
	$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:Remediation'
}, $true)
. ([scriptblock]::Create($remediationAssignment.Extent.Text))

# Test-local command signatures keep the mocks usable without LocalAccounts or WMIC installed.
function Get-LocalUser {
	[CmdletBinding()]
	param([string]$Name)
	throw 'Unmocked Get-LocalUser'
}
function Get-LocalGroupMember {
	[CmdletBinding()]
	param($SID)
	throw 'Unmocked Get-LocalGroupMember'
}
function New-LocalUser {
	[CmdletBinding()]
	param([string]$Name, [securestring]$Password, [string]$Description, [switch]$AccountNeverExpires,
		[switch]$PasswordNeverExpires, [switch]$UserMayNotChangePassword, [string]$FullName)
	throw 'Unmocked New-LocalUser'
}
function Set-LocalUser {
	[CmdletBinding()]
	param([string]$Name, [securestring]$Password, [string]$Description)
	throw 'Unmocked Set-LocalUser'
}
function wmic { throw 'Unmocked wmic' }
function net {
	param([string]$Operation, [string]$Name, [string]$Password)
	throw 'Unmocked net'
}
function Get-CimInstance {
	param([string]$ClassName)
	throw 'Unmocked Get-CimInstance'
}
function Get-SmbShare {
	[CmdletBinding()]
	param()
	throw 'Unmocked Get-SmbShare'
}
function New-SmbShare {
	[CmdletBinding()]
	param($Name, $Path, $FullAccess)
	throw 'Unmocked New-SmbShare'
}
function Grant-SmbShareAccess {
	[CmdletBinding()]
	param($Name, $AccountName, $AccessRight, [switch]$Force)
	throw 'Unmocked Grant-SmbShareAccess'
}
function Get-NetConnectionProfile { throw 'Unmocked Get-NetConnectionProfile' }
function Set-NetConnectionProfile {
	[CmdletBinding()]
	param($NetworkCategory, [Parameter(ValueFromPipeline)]$InputObject)
	throw 'Unmocked Set-NetConnectionProfile'
}
function Get-NetFirewallRule {
	param($DisplayGroup, $Direction)
	throw 'Unmocked Get-NetFirewallRule'
}
function Set-NetFirewallRule {
	[CmdletBinding()]
	param($DisplayGroup, $Direction, $Enabled, $Profile)
	throw 'Unmocked Set-NetFirewallRule'
}
function netsh {
	param($Operation, $Area)
	throw 'Unmocked netsh'
}

Describe 'Scan account password errors' {
	BeforeEach {
		$script:hasLocalAccounts = $true
		Mock Get-LocalUser { $null }
		Mock Get-LocalGroupMember { @() }
		Mock New-LocalUser { }
		Mock Set-LocalUser { }
		Mock Confirm-ExistingScanAccountUpdate { $true }
		Mock Get-ItemProperty { throw 'Account hiding must not run after account setup fails' }
	}

	It 'catches a non-terminating New-LocalUser password rejection and stops hiding' {
		Mock New-LocalUser { Write-Error 'Password rejected' -ErrorId InvalidPassword }
		$result = @(Initialize-ScanUser -Username scans -Password weak -HideFromLogin $true)
		$result.Count | Should Be 1
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Match 'InvalidPassword'
		$result[0].AccountSetupFailed | Should Be $true
		Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'catches a non-terminating Set-LocalUser password rejection' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Set-LocalUser { Write-Error 'Password rejected' -ErrorId InvalidPassword }
		$result = @(Initialize-ScanUser -Username scans -Password weak)
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Match 'InvalidPassword'
	}

	It 'preserves successful account creation and updates' {
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!')
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled New-LocalUser -Times 1 -Exactly -Scope It
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!')
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled Set-LocalUser -Times 1 -Exactly -Scope It
	}

	It 'requires confirmation before changing an existing account password' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!')
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled Confirm-ExistingScanAccountUpdate -Times 1 -Exactly -Scope It -ParameterFilter { $Username -eq 'scans' }
		Assert-MockCalled Set-LocalUser -Times 1 -Exactly -Scope It
	}

	It 'cancels before changing an existing account when confirmation is declined' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Confirm-ExistingScanAccountUpdate { $false }
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!' -HideFromLogin $true)
		$result[0].SetupCanceled | Should Be $true
		$result[0].Message | Should Match 'no account changes were made'
		Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
		Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'refuses to change an existing local Administrators account' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Get-LocalGroupMember { @([pscustomobject]@{ Name = 'COMPUTER\scans' }) }
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!')
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Match 'ProtectedAccount'
		$result[0].Error | Should Match 'local Administrators group'
		Assert-MockCalled Confirm-ExistingScanAccountUpdate -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
	}

	It 'fails closed when administrator membership cannot be checked' {
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Get-LocalGroupMember { throw 'Membership lookup failed' }
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!')
		$result[0].Status | Should Be 'Failed'
		$result[0].Error | Should Match 'Membership lookup failed'
		Assert-MockCalled Confirm-ExistingScanAccountUpdate -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-LocalUser -Times 0 -Exactly -Scope It
	}

	It 'passes the production description within the 48-character account limit on creation and update' {
		$assignment = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			($node.Left.Extent.Text -replace '^\[string\]', '') -eq '$description'
		}, $true)
		. ([scriptblock]::Create($assignment.Extent.Text))
		$description | Should Not BeNullOrEmpty
		($description.Length -le 48) | Should Be $true
		$description | Should Be 'Scanning provided by PrintMaster'
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!' -Description $description)
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled New-LocalUser -Times 1 -Exactly -Scope It -ParameterFilter {
			$Description -eq 'Scanning provided by PrintMaster' -and $Description.Length -le 48
		}
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!' -Description $description)
		$result[0].Status | Should Be 'Success'
		Assert-MockCalled Set-LocalUser -Times 1 -Exactly -Scope It -ParameterFilter {
			$Description -eq 'Scanning provided by PrintMaster' -and $Description.Length -le 48
		}
	}

	It 'preserves non-password failures without classifying them as password errors' {
		Mock New-LocalUser { Write-Error 'Access is denied' -ErrorId AccessDenied }
		$result = @(Initialize-ScanUser -Username scans -Password example)
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Not Match 'InvalidPassword'
		Get-ErrorRemediation $result[0].Error | Should Be $script:Remediation.AccessDenied
	}

	It 'recognizes password error identifiers even when the message is generic' {
		Get-ErrorRemediation 'InvalidPassword,Microsoft.PowerShell.Commands.NewLocalUserCommand' | Should Be $script:Remediation.PasswordPolicy
		Get-ErrorRemediation 'System error 2245 has occurred.' | Should Be $script:Remediation.PasswordPolicy
		Get-ErrorRemediation 'Unrelated failure' | Should BeNullOrEmpty
	}

	It 'handles legacy system error 2245 for new and existing accounts without relying on English text' {
		$script:hasLocalAccounts = $false
		Mock net {
			if (-not $Password) {
				$global:LASTEXITCODE = $script:lookupExitCode
			}
			else {
				$global:LASTEXITCODE = 2
				'2245'
			}
		}
		Mock wmic { }
		foreach ($lookupExitCode in @(2, 0)) {
			$script:lookupExitCode = $lookupExitCode
			$result = @(Initialize-ScanUser -Username scans -Password weak -HideFromLogin $true)
			$result.Count | Should Be 1
			$result[0].Status | Should Be 'Failed'
			$result[0].ErrorId | Should Match 'InvalidPassword'
			$result[0].Error | Should Match '2245'
		}
		Assert-MockCalled wmic -Times 0 -Exactly -Scope It
		Assert-MockCalled Get-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'reports other legacy command failures rather than claiming success' {
		$script:hasLocalAccounts = $false
		Mock net { $global:LASTEXITCODE = 2; 'System error 5 has occurred. Access is denied.' }
		$result = @(Initialize-ScanUser -Username scans -Password example)
		$result[0].Status | Should Be 'Failed'
		$result[0].ErrorId | Should Not Match 'InvalidPassword'
		$result[0].Error | Should Match 'Access is denied'
	}

	It 'preserves legacy account creation and update success' {
		$script:hasLocalAccounts = $false
		Mock net {
			if (-not $Password) { $global:LASTEXITCODE = $script:lookupExitCode }
			else { $global:LASTEXITCODE = 0 }
		}
		Mock wmic { }
		foreach ($lookupExitCode in @(2, 0)) {
			$script:lookupExitCode = $lookupExitCode
			$result = @(Initialize-ScanUser -Username scans -Password 'Valid-Example123!')
			$result[0].Status | Should Be 'Success'
		}
		Assert-MockCalled wmic -Times 1 -Exactly -Scope It
	}
}

Describe 'Setup cancellation' {
	It 'exits successfully without continuing setup when Cancel or window close dismisses the dialog' {
		$decision = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.IfStatementAst] -and
			$node.Clauses[0].Item1.Extent.Text -eq '$setupResult -eq $true'
		}, $true)
		$decision | Should Not BeNullOrEmpty
		foreach ($result in @('$false', '$null')) {
			$childScript = @(
				'$ErrorActionPreference = "Stop"'
				"`$setupResult = $result"
				$decision.Extent.Text
				'throw "Canceled setup must not continue."'
			) -join "`n"
			$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
			$executable = (Get-Process -Id $PID).Path
			$output = & $executable -NoProfile -NonInteractive -STA -EncodedCommand $encoded 2>&1
			$LASTEXITCODE | Should Be 0
			($output | Out-String).Trim() | Should BeNullOrEmpty
		}
	}
}

Describe 'Account-dependent setup steps' {
	BeforeEach {
		$source = Get-Content $sourcePath -Raw
		$start = $source.IndexOf('# Gather computer details')
		$end = $source.IndexOf('[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke', $start)
		$script:runSteps = [scriptblock]::Create($source.Substring($start, $end - $start))
		$script:createUser = $true
		$script:hideUser = $true
		$script:createFolder = $true
		$script:setPermissions = $true
		$script:setShare = $true
		$script:createShortcut = $true
		$script:checkNetworkSettings = $true
		$script:hasCimInstance = $true
		$script:hasErrors = $false
		$script:progressMax = 10
		$script:controls = @{}
		foreach ($name in @('progressBar', 'txtStatus', 'btnDone', 'btnCopyPassword')) {
			$script:controls[$name] = [pscustomobject]@{ Value = 0; Text = ''; IsEnabled = $false }
		}
		$script:progressWindow = New-Object PSObject -Property @{ Title = '' }
		$script:progressWindow | Add-Member ScriptMethod FindName { param($name) $script:controls[$name] }
		Mock Set-ProgressBar { }
		Mock Show-StepResult { if ($result.Error) { $script:hasErrors = $true } }
		Mock Get-CimInstance { [pscustomobject]@{ PartOfDomain = $false } }
		Mock Initialize-ScanUser { $script:testUserResults }
		Mock Show-PasswordRetryDialog { throw 'Unexpected password retry dialog' }
		Mock Initialize-ScanFolder { }
		Mock Initialize-ScanShare { }
		Mock Initialize-DesktopShortcut { }
		Mock Set-NetworkConfiguration { }
	}

	It 'skips permissions and shares and disables copying after account failure' {
		$script:testUserResults = @{ Status = 'Failed'; Error = 'Rejected'; AccountSetupFailed = $true }
		. $script:runSteps
		Assert-MockCalled Initialize-ScanFolder -Times 1 -Exactly -Scope It -ParameterFilter { -not $SetPermissions }
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $false
		$script:controls.btnDone.IsEnabled | Should Be $true
		$script:progressWindow.Title | Should Match 'Completed with errors'
	}

	It 'also gates dependent steps when the hide-user option triggers account setup' {
		$script:createUser = $false
		$script:testUserResults = @{ Status = 'Failed'; Error = 'Rejected'; AccountSetupFailed = $true }
		. $script:runSteps
		Assert-MockCalled Initialize-ScanUser -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $false
	}

	It 'preserves dependent steps and password copying after successful account setup' {
		$script:testUserResults = @{ Status = 'Success'; Error = $null }
		. $script:runSteps
		Assert-MockCalled Initialize-ScanFolder -Times 1 -Exactly -Scope It -ParameterFilter { $SetPermissions }
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $true
	}

	It 'pauses for replacement passwords until accepted, then resumes all selected steps' {
		$script:scanPass = 'Rejected'
		$script:attempts = 0
		Mock Initialize-ScanUser {
			$script:attempts++
			if ($script:attempts -lt 3) {
				@{ Status = 'Failed'; Error = 'Policy rejected'; ErrorId = 'InvalidPassword,NewLocalUserCommand'; AccountSetupFailed = $true }
			}
			else { @{ Status = 'Success'; Message = 'Account configured'; Error = $null } }
		}
		Mock Show-PasswordRetryDialog {
			Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
			Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
			Assert-MockCalled Set-NetworkConfiguration -Times 0 -Exactly -Scope It
			"Replacement$script:attempts!"
		}
		. $script:runSteps
		Assert-MockCalled Initialize-ScanUser -Times 3 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanUser -Times 1 -Exactly -Scope It -ParameterFilter { $Password -eq 'Replacement2!' -and $HideFromLogin }
		Assert-MockCalled Show-PasswordRetryDialog -Times 2 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanFolder -Times 1 -Exactly -Scope It -ParameterFilter { $SetPermissions }
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-DesktopShortcut -Times 1 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It
		$script:scanPass | Should Be 'Replacement2!'
		$script:hasErrors | Should Be $false
		$script:progressWindow.Title | Should Be 'PrintMaster Scans Setup - Finished'
		$script:controls.btnCopyPassword.IsEnabled | Should Be $true
	}

	It 'stops all remaining steps if password correction is canceled or closed' {
		$script:testUserResults = @{ Status = 'Failed'; Error = '2245'; ErrorId = 'InvalidPassword'; AccountSetupFailed = $true }
		Mock Show-PasswordRetryDialog { $null }
		. $script:runSteps
		Assert-MockCalled Initialize-ScanUser -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-DesktopShortcut -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 0 -Exactly -Scope It
		Assert-MockCalled Show-StepResult -Times 0 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $false
		$script:controls.btnDone.IsEnabled | Should Be $true
		$script:progressWindow.Title | Should Be 'PrintMaster Scans Setup - Canceled'
	}

	It 'also offers correction for legacy error 2245 when only hiding is selected' {
		$script:createUser = $false
		Mock Initialize-ScanUser {
			if ($Password -ne 'LegacyReplacement!') {
				@{ Status = 'Failed'; Error = 'System error 2245'; AccountSetupFailed = $true }
			}
			else { @{ Status = 'Success'; Error = $null } }
		}
		Mock Show-PasswordRetryDialog { 'LegacyReplacement!' }
		. $script:runSteps
		Assert-MockCalled Show-PasswordRetryDialog -Times 1 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanUser -Times 2 -Exactly -Scope It -ParameterFilter { $HideFromLogin }
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $false
	}

	It 'does not block shares when only hiding the successfully configured account fails' {
		$script:testUserResults = @(@{ Status = 'Success'; Error = $null }, @{ Status = 'Failed'; Error = 'Registry denied' })
		. $script:runSteps
		Assert-MockCalled Initialize-ScanShare -Times 1 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $true
	}

	It 'respects disabled setup steps and leaves password copying disabled' {
		$script:createUser = $false
		$script:hideUser = $false
		$script:createFolder = $false
		$script:setShare = $false
		$script:createShortcut = $false
		$script:checkNetworkSettings = $false
		. $script:runSteps
		Assert-MockCalled Initialize-ScanUser -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanFolder -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Initialize-DesktopShortcut -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 0 -Exactly -Scope It
		$script:controls.btnCopyPassword.IsEnabled | Should Be $false
		$script:progressWindow.Title | Should Be 'PrintMaster Scans Setup - Finished'
	}
}

Describe 'Error popup routing' {
	BeforeEach {
		$script:hasErrors = $false
		$script:progressWindow = [pscustomobject]@{ Title = 'Test owner' }
		Mock Set-ProgressBar { }
		Mock Show-ErrorPopup { }
	}

	It 'does not show a popup for successful or skipped steps' {
		Show-StepResult @{ Message = 'Created folder'; Error = $null }
		Show-StepResult @{ Message = 'Skipped share'; Error = $null }
		Assert-MockCalled Show-ErrorPopup -Times 0 -Exactly -Scope It
		$script:hasErrors | Should Be $false
	}

	It 'shows password-specific remediation' {
		Show-StepResult @{ Message = 'Account failed'; Error = 'Rejected'; ErrorId = 'InvalidPassword,NewLocalUserCommand' }
		Assert-MockCalled Show-ErrorPopup -Times 1 -Exactly -Scope It -ParameterFilter {
			$Title -eq 'Scan Account Password Rejected' -and
			$Remediation -eq $script:Remediation.PasswordPolicy -and
			$Message -match 'Windows rejected' -and $Owner -eq $script:progressWindow
		}
		$script:hasErrors | Should Be $true
	}

	It 'shows matching remediation for each other known setup error' {
		foreach ($message in @('The trust relationship failed', 'Access is denied', 'UnauthorizedAccess', 'share is in use', 'File is being used')) {
			Show-StepResult @{ Message = 'Step failed'; Error = $message }
		}
		Assert-MockCalled Show-ErrorPopup -Times 1 -Exactly -Scope It -ParameterFilter { $Remediation -eq $script:Remediation.TrustRelation }
		Assert-MockCalled Show-ErrorPopup -Times 2 -Exactly -Scope It -ParameterFilter { $Remediation -eq $script:Remediation.AccessDenied }
		Assert-MockCalled Show-ErrorPopup -Times 2 -Exactly -Scope It -ParameterFilter { $Remediation -eq $script:Remediation.ShareInUse }
	}

	It 'preserves unexpected error details with generic actionable guidance' {
		Show-StepResult @{ Message = 'Shortcut failed'; Error = 'COM error 123' }
		Assert-MockCalled Show-ErrorPopup -Times 1 -Exactly -Scope It -ParameterFilter {
			$Message -match 'Shortcut failed' -and $Message -match 'COM error 123' -and $Remediation -match 'administrator'
		}
		Assert-MockCalled Set-ProgressBar -Times 1 -Exactly -Scope It -ParameterFilter { $text -match 'Error: COM error 123' }
		$script:hasErrors | Should Be $true
	}
}

Describe 'Account visibility' {
	BeforeEach {
		$script:hasLocalAccounts = $true
		Mock Get-LocalUser { [pscustomobject]@{ Name = 'scans' } }
		Mock Get-LocalGroupMember { @() }
		Mock Set-LocalUser { }
		Mock Confirm-ExistingScanAccountUpdate { $true }
		Mock Get-ItemProperty { $null }
		Mock Test-Path { $false }
		Mock New-Item { }
		Mock New-ItemProperty { }
	}

	It 'creates the hiding key and value on non-domain computers' {
		$results = @(Initialize-ScanUser -Username scans -Password 'Example123!' -HideFromLogin $true)
		$results.Count | Should Be 2
		$results[1].Status | Should Be 'Success'
		Assert-MockCalled New-ItemProperty -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'scans' -and $Value -eq 0 }
	}

	It 'does not modify visibility on a domain-joined computer' {
		$results = @(Initialize-ScanUser -Username scans -Password 'Example123!' -HideFromLogin $true -DomainJoined $true)
		$results[1].Status | Should Be 'Skipped'
		Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'leaves an already hidden account unchanged' {
		Mock Get-ItemProperty { [pscustomobject]@{ scans = 0 } }
		$results = @(Initialize-ScanUser -Username scans -Password 'Example123!' -HideFromLogin $true)
		$results[1].Message | Should Match 'already hidden'
		Assert-MockCalled New-ItemProperty -Times 0 -Exactly -Scope It
	}

	It 'reports non-terminating registry failures separately from account setup' {
		Mock New-ItemProperty { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanUser -Username scans -Password 'Example123!' -HideFromLogin $true)
		$results[1].Status | Should Be 'Failed'
		$results[1].AccountSetupFailed | Should BeNullOrEmpty
	}
}

Describe 'Scan folder setup' {
	BeforeEach {
		Mock Test-Path { $false }
		Mock New-Item { }
		Mock Get-Acl { throw 'ACL should not be read' }
		Mock Set-Acl { }
	}

	It 'creates a missing folder without touching disabled permissions' {
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans')
		$results[0].Status | Should Be 'Success'
		Assert-MockCalled New-Item -Times 1 -Exactly -Scope It -ParameterFilter { $Path -eq 'C:\scans' -and $ItemType -eq 'Directory' }
		Assert-MockCalled Get-Acl -Times 0 -Exactly -Scope It
	}

	It 'does not recreate an existing folder' {
		Mock Test-Path { $true }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans')
		$results[0].Message | Should Match 'already exists'
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
	}

	It 'stops before ACL work when folder creation fails' {
		Mock New-Item { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -SetPermissions $true)
		$results.Count | Should Be 1
		$results[0].Status | Should Be 'Failed'
		Assert-MockCalled Get-Acl -Times 0 -Exactly -Scope It
	}

	It 'reports non-terminating ACL read failures' {
		Mock Get-Acl { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -SetPermissions $true)
		$results[1].Status | Should Be 'Failed'
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'sets the intended ACL rules including Domain Users only on joined computers' {
		$script:ruleCount = 0
		$script:fakeAcl = [pscustomobject]@{}
		$script:fakeAcl | Add-Member ScriptMethod SetAccessRule { param($rule) $script:ruleCount++ }
		Mock Get-Acl { $script:fakeAcl }
		Mock New-Object { 'Mock access rule' } -ParameterFilter { $TypeName -like 'System.Security.AccessControl.FileSystemAccessRule*' }
		Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true | Out-Null
		$script:ruleCount | Should Be 3
		Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true -DomainJoined $true | Out-Null
		$script:ruleCount | Should Be 7
		Assert-MockCalled Set-Acl -Times 2 -Exactly -Scope It
	}
}

Describe 'SMB share setup' {
	BeforeEach {
		$script:hasSmbShareCmdlets = $true
		Mock Get-SmbShare { $null }
		Mock New-SmbShare { }
		Mock Grant-SmbShareAccess { }
	}

	It 'creates a share when no shares exist' {
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Success'
		Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'scans' -and $FullAccess -eq 'scans' }
	}

	It 'matches existing share names case-insensitively and exactly' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'SCANS' } }
		$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
		$result.Status | Should Be 'Success'
		Assert-MockCalled Grant-SmbShareAccess -Times 1 -Exactly -Scope It
		Assert-MockCalled New-SmbShare -Times 0 -Exactly -Scope It
	}

	It 'does not confuse a partial name with an existing share' {
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans-backup' } }
		Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans | Out-Null
		Assert-MockCalled New-SmbShare -Times 1 -Exactly -Scope It
	}

	It 'reports share lookup, creation, and permission errors' {
		Mock Get-SmbShare { Write-Error 'Access is denied' }
		(Initialize-ScanShare -ShareName scans).Status | Should Be 'Failed'
		Mock Get-SmbShare { $null }
		Mock New-SmbShare { Write-Error 'Access is denied' }
		(Initialize-ScanShare -ShareName scans).Status | Should Be 'Failed'
		Mock Get-SmbShare { [pscustomobject]@{ Name = 'scans' } }
		Mock Grant-SmbShareAccess { Write-Error 'Access is denied' }
		(Initialize-ScanShare -ShareName scans).Status | Should Be 'Failed'
	}

	It 'handles successful legacy creation and updates' {
		$script:hasSmbShareCmdlets = $false
		Mock net {
			if (-not $Password) { $global:LASTEXITCODE = $script:lookupExitCode }
			else { $global:LASTEXITCODE = 0 }
		}
		foreach ($code in @(2, 0)) {
			$script:lookupExitCode = $code
			(Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans).Status | Should Be 'Success'
		}
	}

	It 'reports legacy write failures for both creation and update' {
		$script:hasSmbShareCmdlets = $false
		Mock net {
			if (-not $Password) { $global:LASTEXITCODE = $script:lookupExitCode }
			else { $global:LASTEXITCODE = 2; 'Access is denied' }
		}
		foreach ($code in @(2, 0)) {
			$script:lookupExitCode = $code
			$result = Initialize-ScanShare -ShareName scans -FolderPath 'C:\scans' -ScanUser scans
			$result.Status | Should Be 'Failed'
			$result.Error | Should Match 'Access is denied'
		}
	}
}

Describe 'Network setup' {
	BeforeEach {
		$script:hasNetConnection = $true
		$script:hasNetSecurity = $true
		Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Private' } }
		Mock Set-NetConnectionProfile { }
		Mock Get-NetFirewallRule { $null }
		Mock Set-NetFirewallRule { }
		Mock netsh { $global:LASTEXITCODE = 0 }
	}

	It 'sets a public non-domain profile to private and enables both firewall groups' {
		Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'Public' } }
		$results = @(Set-NetworkConfiguration -DomainJoined $false)
		@($results | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 0
		Assert-MockCalled Set-NetConnectionProfile -Times 1 -Exactly -Scope It -ParameterFilter { $NetworkCategory -eq 'Private' }
		Assert-MockCalled Set-NetFirewallRule -Times 2 -Exactly -Scope It
	}

	It 'does not change a domain profile and maps DomainAuthenticated to Domain' {
		Mock Get-NetConnectionProfile { [pscustomobject]@{ NetworkCategory = 'DomainAuthenticated' } }
		$results = @(Set-NetworkConfiguration -DomainJoined $true)
		$results[0].Status | Should Be 'Skipped'
		Assert-MockCalled Set-NetConnectionProfile -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetFirewallRule -Times 2 -Exactly -Scope It -ParameterFilter { $Profile -eq 'Domain' }
	}

	It 'leaves already enabled private networking unchanged' {
		Mock Get-NetFirewallRule { [pscustomobject]@{ Enabled = 'True'; Profile = 'Private' } }
		Set-NetworkConfiguration -DomainJoined $false | Out-Null
		Assert-MockCalled Set-NetConnectionProfile -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetFirewallRule -Times 0 -Exactly -Scope It
	}

	It 'reports non-terminating firewall failures' {
		Mock Set-NetFirewallRule { Write-Error 'Access is denied' }
		$results = @(Set-NetworkConfiguration -DomainJoined $false)
		@($results | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 2
	}

	It 'runs the legacy firewall path and respects domain management' {
		$script:hasNetConnection = $false
		$script:hasNetSecurity = $false
		$results = @(Set-NetworkConfiguration -DomainJoined $true)
		$results[0].Status | Should Be 'Skipped'
		Assert-MockCalled netsh -Times 2 -Exactly -Scope It
	}

	It 'reports every failed legacy firewall command rather than claiming success' {
		$script:hasNetConnection = $false
		$script:hasNetSecurity = $false
		Mock netsh { $global:LASTEXITCODE = 1; 'Access is denied' }
		$results = @(Set-NetworkConfiguration -DomainJoined $false)
		@($results | Where-Object { $_.Status -eq 'Failed' }).Count | Should Be 3
	}
}

Describe 'Desktop shortcut setup' {
	It 'writes the expected public desktop shortcut without using COM' {
		$script:saved = $false
		$script:shortcut = [pscustomobject]@{ TargetPath = ''; IconLocation = ''; Description = '' }
		$script:shortcut | Add-Member ScriptMethod Save { $script:saved = $true }
		$script:shell = [pscustomobject]@{}
		$script:shell | Add-Member ScriptMethod CreateShortcut {
			param($path)
			$path | Should Be 'C:\Users\Public\Desktop\Scans.lnk'
			return $script:shortcut
		}
		Mock New-Object { $script:shell } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
		$result = Initialize-DesktopShortcut -FolderPath 'C:\scans' -IconPath 'C:\scans.ico' -Description 'Test shortcut'
		$result.Status | Should Be 'Success'
		$script:shortcut.TargetPath | Should Be 'C:\scans'
		$script:shortcut.IconLocation | Should Be 'C:\scans.ico'
		$script:shortcut.Description | Should Be 'Test shortcut'
		$script:saved | Should Be $true
	}

	It 'reports COM activation failure' {
		Mock New-Object { throw 'COM unavailable' } -ParameterFilter { $ComObject -eq 'WScript.Shell' }
		$result = Initialize-DesktopShortcut -FolderPath 'C:\scans'
		$result.Status | Should Be 'Failed'
		$result.Error | Should Match 'COM unavailable'
	}
}

Describe 'Generated passwords' {
	It 'returns the default length using only supported characters' {
		$password = New-RandomPassword
		$password.Length | Should Be 10
		$password | Should Match '^[A-Za-z0-9!@#$%^&*+\-=?]+$'
	}

	It 'honors an explicitly requested password length' {
		(New-RandomPassword -Length 24).Length | Should Be 24
	}
}

Describe 'Password correction dialog' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		$script:progressWindow = $null
		$script:scanPass = 'Rejected'
		foreach ($name in @('thBg', 'thBgAlt', 'thFg', 'thFgEm', 'thFgStrong', 'thAccent', 'thAccentHi', 'thBorder', 'thBtnText')) {
			Set-Variable -Name $name -Value '#002b36' -Scope Script
		}
		$script:themeResources = ''
		Mock New-RandomPassword { 'GeneratedReplacement123!' }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				$this.FindName('txtError').Text | Should Be 'Password policy rejected'
				$this.FindName('txtPassword').Text | Should Be 'Rejected'
				$this.FindName('txtPassword').Text = ''
				$this.FindName('btnRetry').IsEnabled | Should Be $false
				$this.FindName('txtPassword').Text = 'ManualReplacement!'
				$this.FindName('btnRetry').IsEnabled | Should Be $true
				$this.FindName('btnGenerate').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
				$this.FindName('txtPassword').Text | Should Be 'GeneratedReplacement123!'
				return $script:retryAccepted
			} -Force
		}
	}

	It 'generates a replacement and returns only the accepted password without displaying a window' {
		$script:retryAccepted = $true
		Show-PasswordRetryDialog -ErrorText 'Password policy rejected' | Should Be 'GeneratedReplacement123!'
		Assert-MockCalled New-RandomPassword -Times 1 -Exactly -Scope It
		$script:scanPass | Should Be 'Rejected'
	}

	It 'returns no password when canceled or closed' {
		foreach ($accepted in @($false, $null)) {
			$script:retryAccepted = $accepted
			$result = Show-PasswordRetryDialog -ErrorText 'Password policy rejected'
			$result | Should BeNullOrEmpty
		}
	}
}

Describe 'WPF window markup' {
	It 'renders the embedded PrintMaster window logo without external files' {
		Add-Type -AssemblyName PresentationFramework
		$icon = New-PrintMasterIcon
		$icon.IsFrozen | Should Be $true
		$icon.Width | Should Be 64
		$icon.Height | Should Be 64
		$visual = [System.Windows.Media.DrawingVisual]::new()
		$context = $visual.RenderOpen()
		$context.DrawImage($icon, [System.Windows.Rect]::new(0, 0, 64, 64))
		$context.Close()
		$bitmap = [System.Windows.Media.Imaging.RenderTargetBitmap]::new(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
		$bitmap.Render($visual)
		$pixels = New-Object byte[] (64 * 64 * 4)
		$bitmap.CopyPixels($pixels, 64 * 4, 0)
		# The center of the green printer status light, in BGRA order.
		$offset = (32 * 64 + 46) * 4
		($pixels[$offset..($offset + 3)] -join ',') | Should Be '120,187,72,255'
		$source = Get-Content $sourcePath -Raw
		([regex]::Matches($source, '\.Icon = New-PrintMasterIcon')).Count | Should Be 4
		$source | Should Match "Initialize-DesktopShortcut -FolderPath .folderPath -IconPath .iconPath"
		$source | Should Match '\[IO.File\]::WriteAllBytes\(\$iconPath, \[Convert\]::FromBase64String\(\$script:appIconBase64\)\)'
	}

	It 'decodes the settings image in a fresh PowerShell process before loading any windows' {
		$assemblyLoads = $ast.FindAll({
			param($node)
			$node -is [System.Management.Automation.Language.CommandAst] -and
			$node.GetCommandName() -eq 'Add-Type' -and $node.Extent.StartLineNumber -lt 20
		}, $true)
		$iconAssignment = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			$node.Left.Extent.Text -eq '$script:settingsIconBase64'
		}, $true)
		$iconLoad = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.TryStatementAst] -and
			$node.Body.Extent.Text -match '\$script:settingsIconBase64'
		}, $true)
		$childScript = @(
			'$ErrorActionPreference = "Stop"; $WarningPreference = "Stop"'
			$assemblyLoads | ForEach-Object { $_.Extent.Text }
			$iconAssignment.Extent.Text
			$iconLoad.Extent.Text
			'if ($script:settingsIconBitmap.PixelWidth -le 0) { throw "Settings image was not decoded." }'
			'$script:settingsIconBitmap.GetType().FullName'
		) -join "`n"
		$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
		$executable = (Get-Process -Id $PID).Path
		$output = & $executable -NoProfile -NonInteractive -STA -EncodedCommand $encoded 2>&1
		$LASTEXITCODE | Should Be 0
		($output | Out-String).Trim() | Should Be 'System.Windows.Media.Imaging.BitmapImage'
	}

	It 'loads setup and progress windows without displaying them or running setup' {
		Add-Type -AssemblyName PresentationFramework
		foreach ($name in @('thBg', 'thBgAlt', 'thFg', 'thFgEm', 'thFgStrong', 'thAccent', 'thAccentHi', 'thBorder', 'thBtnText')) {
			Set-Variable -Name $name -Value '#002b36' -Scope Script
		}
		foreach ($name in @('$script:themeResources', '$setupXaml', '$progressXaml', '$passwordRetryXaml')) {
			$assignment = $ast.Find({
				param($node)
				$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
				($node.Left.Extent.Text -replace '^\[xml\]', '') -eq $name
			}, $true)
			. ([scriptblock]::Create($assignment.Extent.Text))
		}
		$setup = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($setupXaml))
		$progress = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($progressXaml))
		$passwordRetry = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($passwordRetryXaml))
		foreach ($name in @('txtError', 'txtRemediation', 'txtPassword', 'btnGenerate', 'btnRetry', 'btnCancel')) {
			$passwordRetry.FindName($name) | Should Not BeNullOrEmpty
		}
		$passwordRetry.FindName('btnCancel').IsCancel | Should Be $true
		$passwordRetry.FindName('btnRetry').IsDefault | Should Be $true
		foreach ($window in @($setup, $progress)) {
			$window.Icon = New-PrintMasterIcon
			$window.Icon | Should Not BeNullOrEmpty
			$window.Title | Should Match '^PrintMaster Scans'
			$window.FindName('txtProvider').Text | Should Be 'Provided by PrintMaster'
		}
		foreach ($name in @('txtUsername', 'txtPassword', 'txtFolderPath', 'txtShareName', 'btnOK', 'btnCancel', 'btnSettings')) {
			$setup.FindName($name) | Should Not BeNullOrEmpty
		}
		$setup.FindName('txtSettingsIconFallback') | Should Not BeNullOrEmpty
		$setup.FindName('rectSettingsIcon').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
		$progress.FindName('btnDone').IsEnabled | Should Be $false
		$progress.FindName('btnCopyPassword').IsEnabled | Should Be $false
		$setup.Close()
		$progress.Close()
		$passwordRetry.Close()
	}
}
