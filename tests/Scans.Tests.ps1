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

function Initialize-TestTheme {
	foreach ($name in @('thBg', 'thBgAlt', 'thFg', 'thFgEm', 'thFgStrong', 'thAccent', 'thAccentHi', 'thBorder', 'thBtnText')) {
		Set-Variable -Name $name -Value '#002b36' -Scope Script
	}
	$script:themeResources = ''
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

	It 'does not configure a share when folder permissions fail or their review is canceled' {
		$script:testUserResults = @{ Status = 'Success'; Error = $null }
		Mock Initialize-ScanFolder { @{ Status = 'Failed'; Error = 'Folder review canceled'; FolderSetupFailed = $true } }
		. $script:runSteps
		Assert-MockCalled Initialize-ScanShare -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-NetworkConfiguration -Times 1 -Exactly -Scope It
		$script:progressWindow.Title | Should Match 'Completed with errors'
		$script:controls.btnDone.IsEnabled | Should Be $true
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
		$script:scanSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
		$script:recipientSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002')
		$script:folderAcl = [System.Security.AccessControl.DirectorySecurity]::new()
		$script:resolveRecipientFails = $false
		Mock Test-Path { $false }
		Mock New-Item { }
		Mock Get-Acl { $script:folderAcl }
		Mock Set-Acl { }
		Mock Get-ScanDesktopUser { 'DOMAIN\recipient' }
		Mock Resolve-ScanAccountSid {
			if ($AccountName -eq 'DOMAIN\recipient') {
				if ($script:resolveRecipientFails) { throw 'Account not found' }
				$script:recipientSid
			}
			else { $script:scanSid }
		}
		Mock Show-ScanFolderAccessDialog {
			@{ Recipient = 'DOMAIN\recipient'; AllowEveryoneModify = $false; RemoveRules = @() }
		}
	}

	It 'creates a missing folder without touching disabled permissions' {
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans')
		$results[0].Status | Should Be 'Success'
		Assert-MockCalled New-Item -Times 1 -Exactly -Scope It -ParameterFilter { $Path -eq 'C:\scans' -and $ItemType -eq 'Directory' }
		Assert-MockCalled Get-Acl -Times 0 -Exactly -Scope It
		Assert-MockCalled Get-ScanDesktopUser -Times 0 -Exactly -Scope It
	}

	It 'defaults folder review to the user of the UI session rather than the elevated identity' {
		Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true | Out-Null
		Assert-MockCalled Get-ScanDesktopUser -Times 1 -Exactly -Scope It
		Assert-MockCalled Show-ScanFolderAccessDialog -Times 1 -Exactly -Scope It -ParameterFilter {
			$DesktopUser -eq 'DOMAIN\recipient'
		}
	}

	It 'passes an empty detected user to review without substituting the elevated account' {
		Mock Get-ScanDesktopUser { $null }
		Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true | Out-Null
		Assert-MockCalled Show-ScanFolderAccessDialog -Times 1 -Exactly -Scope It -ParameterFilter {
			[string]::IsNullOrWhiteSpace($DesktopUser)
		}
	}

	It 'reports desktop-session lookup failure before modifying the folder' {
		Mock Get-ScanDesktopUser { throw 'Session identity lookup failed' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].Error | Should Match 'Session identity lookup failed'
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
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
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'reports non-terminating ACL read failures' {
		Mock Test-Path { $true }
		Mock Get-Acl { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -SetPermissions $true)
		$results[0].Status | Should Be 'Failed'
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'writes a protected new-folder ACL with the exact restricted rights on domain and non-domain PCs' {
		foreach ($joined in @($false, $true)) {
			$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -DesktopUser 'DOMAIN\recipient' -SetPermissions $true -DomainJoined $joined)
			$results[-1].Status | Should Be 'Success'
			Assert-MockCalled Set-Acl -Scope It -ParameterFilter {
				$rules = @($AclObject.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
				$scanRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $script:scanSid.Value })
				$AclObject.AreAccessRulesProtected -and $rules.Count -eq 4 -and $scanRule.Count -eq 1 -and
				[int]$scanRule[0].FileSystemRights -eq 1048583 -and
				$scanRule[0].InheritanceFlags -eq 'ContainerInherit,ObjectInherit'
			}
		}
		Assert-MockCalled Set-Acl -Times 2 -Exactly -Scope It
	}

	It 'cancels before creating a folder or writing any ACL' {
		Mock Show-ScanFolderAccessDialog { $null }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].FolderSetupFailed | Should Be $true
		$results[0].Error | Should Match 'canceled'
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'does not modify an existing folder when its review is canceled' {
		Mock Test-Path { $true }
		Mock Show-ScanFolderAccessDialog { $null }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].FolderSetupFailed | Should Be $true
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
		$script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]).Count | Should Be 0
	}

	It 'fails explicitly before creation if a receiving user cannot be resolved' {
		$script:resolveRecipientFails = $true
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[0].Error | Should Match 'Account not found'
		Assert-MockCalled New-Item -Times 0 -Exactly -Scope It
		Assert-MockCalled Set-Acl -Times 0 -Exactly -Scope It
	}

	It 'reports ACL write failure and never claims permissions were applied' {
		Mock Set-Acl { Write-Error 'Access is denied' }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		$results[-1].FolderSetupFailed | Should Be $true
		@($results | Where-Object { $_.Message -like 'Folder permissions applied*' }).Count | Should Be 0
	}

	It 'logs retained inherited and custom access on an existing folder' {
		Mock Test-Path { $true }
		$results = @(Initialize-ScanFolder -FolderPath 'C:\scans' -ScanUser scans -SetPermissions $true)
		($results | Where-Object { $_.Error } | ForEach-Object { $_.Error } | Out-String).Trim() | Should BeNullOrEmpty
		$results[-1].Status | Should Be 'Warning'
		$results[-1].Message | Should Match 'not a guarantee'
		$script:folderAcl.AreAccessRulesProtected | Should Be $false
	}
}

Describe 'Folder ACL policy' {
	BeforeEach {
		$script:scanSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')
		$script:recipientSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1002')
		$script:folderAcl = [System.Security.AccessControl.DirectorySecurity]::new()
	}

	It 'grants Full Control to the recipient, local Administrators, and SYSTEM using SIDs' {
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid -NewFolder $true
		$rules = @($script:folderAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
		foreach ($sid in @($script:recipientSid.Value, 'S-1-5-32-544', 'S-1-5-18')) {
			$rule = @($rules | Where-Object { $_.IdentityReference.Value -eq $sid })
			$rule.Count | Should Be 1
			$rule[0].FileSystemRights | Should Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
			$rule[0].InheritanceFlags | Should Be ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit')
			$rule[0].PropagationFlags | Should Be 'None'
		}
	}

	It 'never gives the scan account the receiving users Full Control grant' {
		{ Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:scanSid -NewFolder $true } | Should Throw 'must differ'
		$script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]).Count | Should Be 0
	}

	It 'grants Everyone Modify only after an explicit opt-in' {
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid -NewFolder $true -AllowEveryoneModify $true
		$rules = @($script:folderAcl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))
		$rule = @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' })
		$rule.Count | Should Be 1
		[int]$rule[0].FileSystemRights | Should Be 1245631
	}

	It 'identifies only exact explicit legacy-shaped rules as cleanup candidates' {
		$script:folderAcl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;0x1301bf;;;S-1-5-21-1-2-3-513)(A;;0x1301bf;;;WD)(A;OICI;FR;;;S-1-5-21-1-2-3-1003)(A;OICIID;0x1301bf;;;WD)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $script:folderAcl -ScanSid $script:scanSid)
		$candidates.Count | Should Be 3
		@($candidates | Where-Object { $_.IsInherited }).Count | Should Be 0
	}

	It 'preserves all existing access including inherited broad grants unless explicitly selected' {
		$script:folderAcl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;FR;;;S-1-5-21-1-2-3-1003)(A;OICIID;0x1301bf;;;WD)')
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid
		$rules = @($script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
		$script:folderAcl.AreAccessRulesProtected | Should Be $false
		@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' }).Count | Should Be 2
		@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-21-1-2-3-1003' }).Count | Should Be 1
		@($rules | Where-Object { $_.IdentityReference.Value -eq $script:scanSid.Value })[0].FileSystemRights | Should Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
	}

	It 'removes only approved exact entries and preserves custom and inherited ACEs' {
		$script:folderAcl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)(A;OICI;FR;;;S-1-5-21-1-2-3-1003)(A;OICIID;0x1301bf;;;WD)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $script:folderAcl -ScanSid $script:scanSid)
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid -RemoveRules $candidates
		$rules = @($script:folderAcl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
		$everyone = @($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-1-0' })
		$everyone.Count | Should Be 1
		$everyone[0].IsInherited | Should Be $true
		$scanRule = @($rules | Where-Object { $_.IdentityReference.Value -eq $script:scanSid.Value })
		[int]$scanRule[0].FileSystemRights | Should Be 1048583
		@($rules | Where-Object { $_.IdentityReference.Value -eq 'S-1-5-21-1-2-3-1003' }).Count | Should Be 1
	}

	It 'retains a protected existing folder instead of enabling inheritance' {
		$script:folderAcl.SetAccessRuleProtection($true, $false)
		Set-ScanFolderAccessRules -Acl $script:folderAcl -ScanSid $script:scanSid -RecipientSid $script:recipientSid
		$script:folderAcl.AreAccessRulesProtected | Should Be $true
	}

	It 'rejects a blank receiving account rather than selecting the elevated account' {
		{ Resolve-ScanAccountSid '' } | Should Throw 'Choose the receiving Windows user'
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

Describe 'Shared themed dialogs' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		Initialize-TestTheme
		$script:dialogAccepted = $true
		$script:inspectDialog = { param($window) }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				& $script:inspectDialog $this
				return $script:dialogAccepted
			} -Force
		}
	}

	It 'supports source-owned input controls without treating runtime text as markup' {
		$message = 'Account <test> & "example": {Binding Secret}'
		$window = New-ScanDialog -Title $message -Message $message -Guidance $message `
			-ContentXaml '<TextBox Name="txtInput"/>' -AcceptText 'Continue' -CancelText 'Stop'
		$window.Title | Should Be "PrintMaster Scans - $message"
		$window.FindName('txtMessage').Text | Should Be $message
		$window.FindName('txtGuidance').Text | Should Be $message
		$window.FindName('txtInput') | Should Not BeNullOrEmpty
		$window.FindName('btnAccept').Content | Should Be 'Continue'
		$window.FindName('btnCancel').Content | Should Be 'Stop'
		$window.FindName('txtProvider').Text | Should Be 'Provided by PrintMaster'
		$window.Icon | Should Not BeNullOrEmpty
		$window.Close()
	}

	It 'inherits application resources in both light and dark palettes' {
		$resourceAssignment = $ast.Find({
			param($node)
			$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
			$node.Left.Extent.Text -eq '$script:themeResources'
		}, $true)
		foreach ($background in @('#002b36', '#fdf6e3')) {
			$script:thBg = $background
			. ([scriptblock]::Create($resourceAssignment.Extent.Text))
			$window = New-ScanDialog -Title 'Theme Test' -Message 'Themed message'
			$window.Background.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($background))
			$window.FindName('btnAccept').Style | Should Not BeNullOrEmpty
			$window.FindName('btnAccept').Background.Color | Should Be ([System.Windows.Media.ColorConverter]::ConvertFromString($script:thAccent))
			Assert-MockCalled Set-WindowTheme -Scope It -ParameterFilter { $window.Title -eq 'PrintMaster Scans - Theme Test' }
			$window.Close()
		}
	}

	It 'centers on an owner when supplied and on screen for startup failures' {
		$ownerWindow = [System.Windows.Window]::new()
		[System.Windows.Interop.WindowInteropHelper]::new($ownerWindow).EnsureHandle() | Out-Null
		$owned = New-ScanDialog -Title 'Owned' -Owner $ownerWindow
		$owned.Owner | Should Be $ownerWindow
		$owned.WindowStartupLocation | Should Be ([System.Windows.WindowStartupLocation]::CenterOwner)
		$unowned = New-ScanDialog -Title 'Startup'
		$unowned.Owner | Should BeNullOrEmpty
		$unowned.WindowStartupLocation | Should Be ([System.Windows.WindowStartupLocation]::CenterScreen)
		$owned.Close()
		$unowned.Close()
		$ownerWindow.Close()
	}

	It 'defaults account confirmation to cancel and returns true only for explicit acceptance' {
		$script:progressWindow = $null
		$script:inspectDialog = {
			param($window)
			$window.FindName('btnAccept').IsDefault | Should Be $false
			$window.FindName('btnCancel').IsDefault | Should Be $true
			$window.FindName('btnCancel').IsCancel | Should Be $true
			$window.FindName('btnAccept').Content | Should Be 'Change password'
			$window.FindName('btnCancel').Content | Should Be 'Cancel setup'
			$window.FindName('txtMessage').Text | Should Match "local account named 'scans'"
			$window.FindName('txtMessage').Text | Should Match 'will change its password'
		}
		foreach ($accepted in @($true, $false, $null)) {
			$script:dialogAccepted = $accepted
			Confirm-ExistingScanAccountUpdate -Username scans | Should Be ($accepted -eq $true)
		}
	}

	It 'shows error details and remediation without a cancel button or leaking a return value' {
		$script:inspectDialog = {
			param($window)
			$window.FindName('txtMessage').Text | Should Be 'Access denied <example>'
			$window.FindName('txtGuidance').Text | Should Match 'How to fix:'
			$window.FindName('txtGuidance').Text | Should Match 'Try again as administrator'
			$window.FindName('btnCancel').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
		}
		Show-ErrorPopup -Title 'Test Error' -Message 'Access denied <example>' -Remediation 'Try again as administrator' | Should BeNullOrEmpty
	}

	It 'accepts through the shared button handler without caller-specific wiring' {
		Mock Set-WindowTheme { }
		$window = New-ScanDialog -Title 'Button Test'
		$window.WindowStartupLocation = 'Manual'
		$window.Left = -32000
		$window.Top = -32000
		$window.ShowActivated = $false
		$window.Add_ContentRendered({
			$this.FindName('btnAccept').RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.Button]::ClickEvent))
		})
		$window.ShowDialog() | Should Be $true
	}

	It 'never treats closing the dialog as consent' {
		Mock Set-WindowTheme { }
		$window = New-ScanDialog -Title 'Close Test' -DefaultCancel
		$window.WindowStartupLocation = 'Manual'
		$window.Left = -32000
		$window.Top = -32000
		$window.ShowActivated = $false
		$window.Add_ContentRendered({ $this.Close() })
		($window.ShowDialog() -eq $true) | Should Be $false
	}

	It 'initializes theme and icon before any preflight error can open a dialog' {
		$source = Get-Content $sourcePath -Raw
		$preflight = $source.IndexOf('$currentPrincipal =')
		$source.IndexOf('$script:themeResources =') | Should BeLessThan $preflight
		$source.IndexOf('function Set-WindowTheme') | Should BeLessThan $preflight
		$source.IndexOf('function New-PrintMasterIcon') | Should BeLessThan $preflight
		$source.IndexOf('$iconPath =') | Should BeGreaterThan $preflight
	}
}

Describe 'Password correction dialog' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		$script:progressWindow = $null
		$script:scanPass = 'Rejected'
		Initialize-TestTheme
		Mock New-RandomPassword { 'GeneratedReplacement123!' }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				$this.FindName('txtError').Text | Should Be 'Password policy rejected'
				$this.FindName('txtPassword').Text | Should Be 'Rejected'
				$this.FindName('txtPassword').Text = ''
				$this.FindName('btnAccept').IsEnabled | Should Be $false
				$this.FindName('txtPassword').Text = 'ManualReplacement!'
				$this.FindName('btnAccept').IsEnabled | Should Be $true
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

	It 'starts with Retry disabled when the previous password is empty' {
		$script:scanPass = ''
		$script:retryAccepted = $false
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				$this.FindName('txtPassword').Text | Should BeNullOrEmpty
				$this.FindName('btnAccept').IsEnabled | Should Be $false
				return $false
			} -Force
		}
		Show-PasswordRetryDialog -ErrorText 'Password required' | Should BeNullOrEmpty
	}
}

Describe 'Folder access review dialog' {
	BeforeEach {
		Add-Type -AssemblyName PresentationFramework
		Initialize-TestTheme
		$script:progressWindow = $null
		$script:accessAccepted = $true
		$script:inspectAccessWindow = { param($window) }
		Mock Resolve-ScanPrincipalDisplay { "TEST\account-$($Sid.Value.Split('-')[-1])" }
		Mock Set-WindowTheme {
			$window | Add-Member ScriptMethod ShowDialog {
				& $script:inspectAccessWindow $this
				return $script:accessAccepted
			} -Force
		}
	}

	It 'defaults to the desktop user and explicitly discloses a different elevated identity' {
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('txtIdentityWarning').Text | Should Match 'These accounts differ'
			$window.FindName('txtIdentityWarning').Text | Should Match 'not automatically for the elevated account'
			$window.FindName('txtRecipient').Text | Should Be 'DOMAIN\recipient'
			$window.FindName('chkEveryone').IsChecked | Should Be $false
			$window.FindName('txtPolicy').Text | Should Match 'inheritance will be disabled'
			$window.FindName('btnAccept').IsEnabled | Should Be $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'DOMAIN\recipient' -ElevatedUser 'PC\admin'
		$result.Recipient | Should Be 'DOMAIN\recipient'
		$result.AllowEveryoneModify | Should Be $false
		$result.RemoveRules.Count | Should Be 0
	}

	It 'requires an explicit receiving user when no desktop user was detected' {
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('txtRecipient').Text | Should BeNullOrEmpty
			$window.FindName('txtIdentityWarning').Text | Should Match 'No desktop user was detected'
			$window.FindName('btnAccept').IsEnabled | Should Be $false
			$window.FindName('txtRecipient').Text = '   '
			$window.FindName('btnAccept').IsEnabled | Should Be $false
			$window.FindName('txtRecipient').Text = ' PC\recipient '
			$window.FindName('btnAccept').IsEnabled | Should Be $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -ElevatedUser 'PC\admin'
		$result.Recipient | Should Be 'PC\recipient'
	}

	It 'shows existing ACLs and removes only individually checked legacy-shaped rules' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;S-1-5-21-1-2-3-1001)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $acl -ScanSid ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')))
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('txtPolicy').Text | Should Match 'inheritance and custom permissions are preserved'
			$rows = $window.FindName('lstExistingRules').ItemsSource
			$rows.Count | Should Be 2
			foreach ($row in $rows) {
				$row.Remove | Should Be $false
				$row.Principal | Should Match 'TEST\\account-'
				$row.CanRemove | Should Be $true
			}
			$rows[0].Remove = $true
			$window.FindName('chkEveryone').IsChecked = $true
			$window.FindName('pnlEveryoneWarning').Visibility | Should Be ([System.Windows.Visibility]::Visible)
			$window.FindName('chkEveryone').IsChecked = $false
			$window.FindName('pnlEveryoneWarning').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('chkEveryone').IsChecked = $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\admin' -Acl $acl -CleanupRules $candidates
		$result.AllowEveryoneModify | Should Be $true
		$result.RemoveRules.Count | Should Be 1
		$result.RemoveRules[0].IdentityReference.Value | Should Be $candidates[0].IdentityReference.Value
	}

	It 'returns no permission choices when canceled or closed' {
		foreach ($accepted in @($false, $null)) {
			$script:accessAccepted = $accepted
			Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\admin' | Should BeNullOrEmpty
		}
	}

	It 'hides the existing permissions section for new folders and keeps safe defaults' {
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('pnlExistingAccess').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('txtIdentityWarning').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('pnlEveryoneWarning').Visibility | Should Be ([System.Windows.Visibility]::Collapsed)
			$window.FindName('lstExistingRules').View.Columns.Count | Should Be 6
			$window.FindName('txtFolder').Text | Should Be 'C:\scans & <example>'
		}
		Show-ScanFolderAccessDialog -FolderPath 'C:\scans & <example>' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\recipient' | Out-Null
	}

	It 'keeps warning text readable against the light and dark panel backgrounds' {
		$script:inspectAccessWindow = {
			param($window)
			$foreground = $window.FindName('txtIdentityWarning').Foreground.Color
			$background = [System.Windows.Media.ColorConverter]::ConvertFromString($script:thBgAlt)
			$luminance = foreach ($color in @($foreground, $background)) {
				$channels = foreach ($channel in @($color.R, $color.G, $color.B)) {
					$value = $channel / 255.0
					if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
				}
				0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
			}
			$ratio = ([Math]::Max($luminance[0], $luminance[1]) + 0.05) / ([Math]::Min($luminance[0], $luminance[1]) + 0.05)
			($ratio -ge 4.5) | Should Be $true
		}
		foreach ($dark in @($true, $false)) {
			$script:useDarkTheme = $dark
			$script:thBgAlt = if ($dark) { '#073642' } else { '#eee8d5' }
			Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\admin' | Out-Null
		}
	}

	It 'does not return an ineligible row even if its model is marked for removal' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;FA;;;SY)')
		$script:inspectAccessWindow = {
			param($window)
			$window.FindName('lstExistingRules').ItemsSource[0].Remove = $true
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\recipient' -Acl $acl
		$result.RemoveRules.Count | Should Be 0
	}

	It 'binds the table removal checkbox to the exact returned ACE' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;OICI;0x1301bf;;;WD)(A;OICI;FA;;;SY)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $acl -ScanSid ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')))
		$script:tableBindingError = $null
		Mock Set-WindowTheme {
			$window.WindowStartupLocation = 'Manual'
			$window.Left = -32000
			$window.Top = -32000
			$window.ShowActivated = $false
			$window.Add_ContentRendered({
				try {
					$table = $this.FindName('lstExistingRules')
					$table.UpdateLayout()
					$index = 0
					while (-not $table.Items[$index].CanRemove) { $index++ }
					$pending = [System.Collections.Generic.Queue[System.Windows.DependencyObject]]::new()
					$pending.Enqueue($table.ItemContainerGenerator.ContainerFromIndex($index))
					$checkbox = $null
					while ($pending.Count -and -not $checkbox) {
						$node = $pending.Dequeue()
						if ($node -is [System.Windows.Controls.CheckBox]) { $checkbox = $node }
						else {
							for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node); $i++) {
								$pending.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($node, $i))
							}
						}
					}
					if (-not $checkbox) { throw 'Removal checkbox was not rendered.' }
					$checkbox.IsChecked = $true
				}
				catch { $script:tableBindingError = $_.Exception.Message }
				finally { $this.DialogResult = $true }
			})
		}
		$result = Show-ScanFolderAccessDialog -FolderPath 'C:\scans' -DesktopUser 'PC\recipient' -ElevatedUser 'PC\recipient' -Acl $acl -CleanupRules $candidates
		$script:tableBindingError | Should BeNullOrEmpty
		$result.RemoveRules.Count | Should Be 1
		$result.RemoveRules[0].IdentityReference.Value | Should Be 'S-1-1-0'
	}
}

Describe 'Readable folder permission rows' {
	BeforeEach {
		Initialize-TestTheme
	}

	It 'resolves a well-known SID to its Windows account name' {
		$sid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
		Resolve-ScanPrincipalDisplay $sid | Should Be $sid.Translate([System.Security.Principal.NTAccount]).Value
	}

	It 'marks an unresolved SID honestly rather than inventing a username' {
		$result = Resolve-ScanPrincipalDisplay ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-4294967294'))
		$result | Should Match '^Unresolved account \(S-1-5-21-'
	}

	It 'shows readable access, source, scope, deny indicators, and exact tooltip data' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(D;;SD;;;WD)(A;OICI;FA;;;SY)(A;OICI;0x100007;;;S-1-5-21-1-2-3-1001)(A;OICIID;0x1301bf;;;WD)')
		Mock Resolve-ScanPrincipalDisplay { "Resolved $($Sid.Value)" }
		$rows = @(Get-ScanFolderAccessRows -Acl $acl)
		$rows.Count | Should Be 4
		$rows[0].Type | Should Be 'Deny'
		$rows[0].Color | Should Be '#cb4b16'
		$rows[0].Scope | Should Be 'This folder'
		$rows[1].Access | Should Be 'Full control'
		$rows[2].Access | Should Be 'Scan: read, write, append'
		$rows[3].Access | Should Be 'Modify'
		$rows[3].Source | Should Be 'Inherited'
		$rows[3].Scope | Should Be 'This folder, subfolders, files'
		$rows[3].CanRemove | Should Be $false
		$rows[3].Details | Should Match 'SID: S-1-1-0'
		Assert-MockCalled Resolve-ScanPrincipalDisplay -Times 3 -Exactly -Scope It
	}

	It 'does not enable removal for another rule on the same principal or inherited entries' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:AI(A;;0x1301bf;;;WD)(A;OICI;0x1301bf;;;WD)(A;OICIID;0x1301bf;;;WD)')
		$candidates = @(Get-ScanFolderCleanupRules -Acl $acl -ScanSid ([System.Security.Principal.SecurityIdentifier]::new('S-1-5-21-1-2-3-1001')))
		$rows = @(Get-ScanFolderAccessRows -Acl $acl -CleanupRules $candidates)
		@($rows | Where-Object { $_.CanRemove }).Count | Should Be 1
		@($rows | Where-Object { $_.CanRemove })[0].Scope | Should Be 'This folder, subfolders, files'
	}

	It 'describes inherit-only and one-level rules without claiming they apply to the folder' {
		$acl = [System.Security.AccessControl.DirectorySecurity]::new()
		$acl.SetSecurityDescriptorSddlForm('D:(A;CINPIO;FR;;;SY)')
		$row = @(Get-ScanFolderAccessRows -Acl $acl)[0]
		$row.Scope | Should Be 'subfolders (one level)'
		$row.Access | Should Match '^Special:'
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
		$source | Should Not Match '\[System\.Windows\.MessageBox\]::Show'
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
		Initialize-TestTheme
		foreach ($name in @('$script:themeResources', '$setupXaml', '$progressXaml', '$passwordRetryContent')) {
			$assignment = $ast.Find({
				param($node)
				$node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
				($node.Left.Extent.Text -replace '^\[xml\]', '') -eq $name
			}, $true)
			. ([scriptblock]::Create($assignment.Extent.Text))
		}
		$setup = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($setupXaml))
		$progress = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($progressXaml))
		$passwordRetry = New-ScanDialog -Title 'Password Rejected' -ContentXaml $passwordRetryContent -AcceptText 'Retry' -CancelText 'Cancel setup'
		foreach ($name in @('txtError', 'txtRemediation', 'txtPassword', 'btnGenerate', 'btnAccept', 'btnCancel')) {
			$passwordRetry.FindName($name) | Should Not BeNullOrEmpty
		}
		$passwordRetry.FindName('btnCancel').IsCancel | Should Be $true
		$passwordRetry.FindName('btnAccept').IsDefault | Should Be $true
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
