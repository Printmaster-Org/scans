param([switch]$Elevated)

# Setup variables and defaults
[string]$scanUser = 'scans'
[string]$scanPass = 'scans'
[string]$folderPath = 'C:\scans'
[string]$shareName = 'scans'
[string]$description = 'Scanning provided by PrintMaster'

# Load the .NET Framework classes
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
$ProgressPreference = 'SilentlyContinue'

# --- Error popup helper ---
function Show-ErrorPopup {
	param(
		[string]$Title,
		[string]$Message,
		[string]$Remediation,
		$Owner
	)
	$body = "$Message`n`nHow to fix:`n$Remediation"
	if ($Owner) {
		[System.Windows.MessageBox]::Show($Owner, $body, $Title, 'OK', 'Error') | Out-Null
	}
	else {
		[System.Windows.MessageBox]::Show($body, $Title, 'OK', 'Error') | Out-Null
	}
}

function Show-ErrorAndExit {
	param(
		[string]$Title,
		[string]$Message,
		[string]$Remediation
	)
	Show-ErrorPopup -Title $Title -Message $Message -Remediation $Remediation
	Exit 1
}

# --- Common error remediation messages ---
$script:Remediation = @{
	NotAdmin       = "Right-click start button and select 'Powershell/Terminal (Admin)'."
	NoInternet     = "Check your network connection and ensure you can reach github.com.`nIf behind a proxy, configure your system proxy settings."
	OldPowerShell  = "Use Windows PowerShell 5.1 (included with Windows 10/11), or install PowerShell 7 from https://aka.ms/powershell."
	TrustRelation  = "The domain trust is broken. Run the following from an admin prompt:`nTest-ComputerSecureChannel -Repair -Credential (Get-Credential)`nOr rejoin the machine to the domain."
	AccessDenied   = "The current user does not have permission. Ensure you are running as Administrator and the folder is not read-only."
	ShareInUse     = "Close any open files or Explorer windows pointing to the share, then try again."
	PasswordPolicy = "Use Generate or enter a longer password with uppercase and lowercase letters, numbers, and symbols, then retry. Avoid including the username.`nLocal or domain Group Policy can enforce minimum length, complexity, password history, or additional restrictions. The generated password is not guaranteed to meet every policy. If it is still rejected, ask your administrator for the effective password requirements; do not disable the policy."
}

# --- Preflight checks ---
# 1. Require Administrator
$currentPrincipal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	try {
		# When run via irm|iex $PSCommandPath is empty; dump ourselves to temp and re-launch elevated
		$scriptPath = $PSCommandPath
		if (-not $scriptPath) {
			$scriptDir = Join-Path $env:TEMP "scans_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
			[IO.Directory]::CreateDirectory($scriptDir) | Out-Null
			$scriptPath = Join-Path $scriptDir 'scans.ps1'
			$scriptBody = $MyInvocation.MyCommand.ScriptBlock.ToString()
			if (-not $scriptBody) { throw 'Could not capture script content for elevation.' }
			[IO.File]::WriteAllText($scriptPath, $scriptBody, [Text.Encoding]::UTF8)
		}
		Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Elevated" -Verb RunAs
	} catch {
		Show-ErrorAndExit -Title 'Administrator Required' `
			-Message "This script must be run as Administrator to create users, shares, and configure network settings.`n`n$($_.Exception.Message)" `
			-Remediation $script:Remediation.NotAdmin
	}
	return
}

# If we self-elevated, hide the console window — the WPF GUI is the only UI the user needs
if ($Elevated) {
	Add-Type -Name ConsoleWindow -Namespace Win32 -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction SilentlyContinue
	try { [Win32.ConsoleWindow]::ShowWindow([Win32.ConsoleWindow]::GetConsoleWindow(), 0) | Out-Null } catch { }
}

# 2. Require PowerShell 5.1+
if ($PSVersionTable.PSVersion -lt [version]'5.1') {
	Show-ErrorAndExit -Title 'PowerShell Version Too Old' `
		-Message "This script requires Windows PowerShell 5.1 or PowerShell 7. You are running $($PSVersionTable.PSVersion)." `
		-Remediation $script:Remediation.OldPowerShell
}

# Detect OS capabilities for legacy fallback
$script:hasLocalAccounts = [bool](Get-Command -Name 'Get-LocalUser' -ErrorAction SilentlyContinue)
$script:hasSmbShareCmdlets = [bool](Get-Command -Name 'Get-SmbShare' -ErrorAction SilentlyContinue)
$script:hasNetSecurity = [bool](Get-Command -Name 'Get-NetFirewallRule' -ErrorAction SilentlyContinue)
$script:hasNetConnection = [bool](Get-Command -Name 'Get-NetConnectionProfile' -ErrorAction SilentlyContinue)
$script:hasCimInstance = [bool](Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)
$script:hasSetClipboard = [bool](Get-Command -Name 'Set-Clipboard' -ErrorAction SilentlyContinue)

# --- Theme detection (Solarized Light/Dark, defaults to Dark) ---
$script:useDarkTheme = $true
try {
	$themeReg = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'AppsUseLightTheme' -ErrorAction SilentlyContinue
	if ($themeReg -and $themeReg.AppsUseLightTheme -eq 1) { $script:useDarkTheme = $false }
} catch { }

if ($script:useDarkTheme) {
	$script:thBg = '#002b36'; $script:thBgAlt = '#073642'
	$script:thFg = '#839496'; $script:thFgEm = '#93a1a1'; $script:thFgStrong = '#eee8d5'
	$script:thAccent = '#268bd2'; $script:thAccentHi = '#2aa198'
	$script:thBorder = '#586e75'; $script:thBtnText = '#fdf6e3'
} else {
	$script:thBg = '#fdf6e3'; $script:thBgAlt = '#eee8d5'
	$script:thFg = '#657b83'; $script:thFgEm = '#586e75'; $script:thFgStrong = '#073642'
	$script:thAccent = '#268bd2'; $script:thAccentHi = '#2aa198'
	$script:thBorder = '#93a1a1'; $script:thBtnText = '#fdf6e3'
}

$script:themeResources = @"
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="$($script:thAccent)"/>
            <Setter Property="Foreground" Value="$($script:thBtnText)"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="3"
                                Padding="6,3" SnapsToDevicePixels="True">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="$($script:thAccentHi)"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Opacity" Value="0.45"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="$($script:thBgAlt)"/>
            <Setter Property="Foreground" Value="$($script:thFgStrong)"/>
            <Setter Property="BorderBrush" Value="$($script:thBorder)"/>
            <Setter Property="Padding" Value="4,3"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="$($script:thFg)"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="$($script:thFg)"/>
        </Style>
        <Style TargetType="ProgressBar">
            <Setter Property="Background" Value="$($script:thBgAlt)"/>
            <Setter Property="Foreground" Value="$($script:thAccent)"/>
            <Setter Property="BorderBrush" Value="$($script:thBorder)"/>
        </Style>
        <Style TargetType="ListBox">
            <Setter Property="Background" Value="$($script:thBgAlt)"/>
            <Setter Property="Foreground" Value="$($script:thFg)"/>
            <Setter Property="BorderBrush" Value="$($script:thBorder)"/>
        </Style>
        <Style TargetType="{x:Type ScrollBar}" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
            <Setter Property="Background" Value="$($script:thBgAlt)"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ScrollBar}" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" CornerRadius="4"/>
                            <Track Name="PART_Track" IsDirectionReversed="True">
                                <Track.Thumb>
                                    <Thumb>
                                        <Thumb.Style>
                                            <Style TargetType="Thumb">
                                                <Setter Property="Template">
                                                    <Setter.Value>
                                                        <ControlTemplate TargetType="Thumb">
                                                            <Border Background="$($script:thBorder)" CornerRadius="4"
                                                                    Margin="1" SnapsToDevicePixels="True"/>
                                                        </ControlTemplate>
                                                    </Setter.Value>
                                                </Setter>
                                            </Style>
                                        </Thumb.Style>
                                    </Thumb>
                                </Track.Thumb>
                            </Track>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="Orientation" Value="Horizontal">
                                <Setter TargetName="PART_Track" Property="IsDirectionReversed" Value="False"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
"@

# --- DWM title bar theming (Win10 1809+ dark mode, Win11 22H2+ caption color) ---
$script:hasDwmTheming = $false
if (-not ([System.Management.Automation.PSTypeName]'DwmHelper').Type) {
	try {
		Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DwmHelper {
    [DllImport("dwmapi.dll", PreserveSig = true)]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern void SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}
"@ -ErrorAction Stop
	} catch { }
}
if (([System.Management.Automation.PSTypeName]'DwmHelper').Type) {
	$script:hasDwmTheming = $true
	# Give the process its own taskbar identity so Windows shows our icon instead of PowerShell's
	try { [DwmHelper]::SetCurrentProcessExplicitAppUserModelID('mstrhakr.scans.setup') } catch { }
}

function Set-WindowTheme($window) {
	if (-not $script:hasDwmTheming) { return }
	$window.Add_SourceInitialized({
		try {
			$helper = [System.Windows.Interop.WindowInteropHelper]::new($this)
			$hwnd = $helper.Handle
			# DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (Win10 1809+)
			$darkMode = if ($script:useDarkTheme) { 1 } else { 0 }
			[DwmHelper]::DwmSetWindowAttribute($hwnd, 20, [ref]$darkMode, 4) | Out-Null
			# DWMWA_CAPTION_COLOR = 35 (Win11 22H2+)
			$bgHex = $script:thBg.TrimStart('#')
			$r = [Convert]::ToInt32($bgHex.Substring(0,2), 16)
			$g = [Convert]::ToInt32($bgHex.Substring(2,2), 16)
			$b = [Convert]::ToInt32($bgHex.Substring(4,2), 16)
			$colorRef = $r -bor ($g -shl 8) -bor ($b -shl 16)
			[DwmHelper]::DwmSetWindowAttribute($hwnd, 35, [ref]$colorRef, 4) | Out-Null
		} catch { }
	})
}

$createUser = $true
$hideUser = $true
$createFolder = $true
$setPermissions = $true
$setShare = $true
$createShortcut = $true
$checkNetworkSettings = $true

function New-RandomPassword {
	param([int]$Length = 10)
	$chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*+-=?'
	$rng = [System.Security.Cryptography.RNGCryptoServiceProvider]::new()
	$bytes = [byte[]]::new($Length)
	$rng.GetBytes($bytes)
	$result = -join ((0..($Length - 1)) | ForEach-Object { $chars[[int]($bytes[$_] % $chars.Length)] })
	$rng.Dispose()
	return $result
}

function Test-ScanUserAdministrator {
	param(
		[string]$Username,
		$User
	)

	if (-not (Get-Command -Name 'Get-LocalGroupMember' -ErrorAction SilentlyContinue)) {
		throw "Cannot verify whether existing account '$Username' belongs to the local Administrators group. Choose another username or use a Windows version with local account cmdlets."
	}

	$administratorsSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
	$members = @(Get-LocalGroupMember -SID $administratorsSid -ErrorAction Stop)
	foreach ($member in $members) {
		if ($User -and $User.SID -and $member.SID -and $member.SID.Value -eq $User.SID.Value) {
			return $true
		}

		# Legacy account lookup does not return a SID; compare the local account name instead.
		$memberName = ($member.Name -split '\\')[-1]
		if ($memberName -and $memberName -ieq $Username) {
			return $true
		}
	}

	return $false
}

function Confirm-ExistingScanAccountUpdate {
	param([string]$Username)

	$message = "A local account named '$Username' already exists. Continuing will change its password and may affect anything that uses it. Continue only if this is the account you intend to use for scanning."
	Write-Verbose "Requesting confirmation before changing the password for existing account '$Username'."
	if ($script:progressWindow) {
		return [System.Windows.MessageBox]::Show(
			$script:progressWindow,
			$message,
			'Existing Account Password Change',
			[System.Windows.MessageBoxButton]::YesNo,
			[System.Windows.MessageBoxImage]::Warning,
			[System.Windows.MessageBoxResult]::No
		) -eq [System.Windows.MessageBoxResult]::Yes
	}
	return [System.Windows.MessageBox]::Show(
		$message,
		'Existing Account Password Change',
		[System.Windows.MessageBoxButton]::YesNo,
		[System.Windows.MessageBoxImage]::Warning,
		[System.Windows.MessageBoxResult]::No
	) -eq [System.Windows.MessageBoxResult]::Yes
}

function Initialize-ScanUser {
	param(
		[string]$Username,
		[string]$Password,
		[string]$Description,
		[bool]$HideFromLogin,
		[bool]$DomainJoined
	)
	$results = @()
	try {
		$existingUser = $null
		if ($script:hasLocalAccounts) {
			try {
				$existingUser = Get-LocalUser -Name $Username -ErrorAction Stop
			}
			catch {
				if ($_.FullyQualifiedErrorId -match 'UserNotFound') {
					$existingUser = $null
				}
				else {
					throw
				}
			}
		}
		else {
			# Sanitize inputs for external commands to prevent injection.
			$safeUser = $Username -replace '[^a-zA-Z0-9_\-]', ''
			$safePass = $Password -replace '"', ''
			net user $safeUser 2>&1 | Out-Null
			$existingUser = $LASTEXITCODE -eq 0
		}

		if ($existingUser) {
			if (Test-ScanUserAdministrator -Username $Username -User $existingUser) {
				$warning = "Refusing to change the password for '$Username' because it belongs to the local Administrators group."
				Write-Warning $warning
				$exception = New-Object System.InvalidOperationException("$warning Choose a different username or cancel setup.")
				$errorRecord = New-Object System.Management.Automation.ErrorRecord($exception, 'ProtectedAccount', [System.Management.Automation.ErrorCategory]::PermissionDenied, $Username)
				throw $errorRecord
			}
			if (-not (Confirm-ExistingScanAccountUpdate -Username $Username)) {
				Write-Verbose "Setup canceled because confirmation to change existing account '$Username' was declined."
				return @(@{
					Status = 'Skipped'
					Message = "Canceled before changing existing account '$Username'; no account changes were made."
					Error = $null
					AccountSetupFailed = $true
					SetupCanceled = $true
				})
			}
		}

		if ($script:hasLocalAccounts) {
			$securePass = $Password | ConvertTo-SecureString -AsPlainText -Force
			if (-not $existingUser) {
				New-LocalUser -Name $Username -Password $securePass -Description $Description -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -FullName "scans" -ErrorAction Stop | Out-Null
				$results += @{ Status = 'Success'; Message = "Created new user '$Username'"; Error = $null }
			}
			else {
				Set-LocalUser -Name $Username -Password $securePass -Description $Description -ErrorAction Stop | Out-Null
				$results += @{ Status = 'Success'; Message = "Updated existing user '$Username'"; Error = $null }
			}
		}
		else {
			$safeDesc = $Description -replace '"', ''
			if (-not $existingUser) {
				$userOutput = net user $safeUser $safePass /add /fullname:"scans" /comment:"$safeDesc" /active:yes /expires:never /passwordchg:no 2>&1
			}
			else {
				$userOutput = net user $safeUser $safePass /comment:"$safeDesc" 2>&1
			}
			$userExitCode = $LASTEXITCODE
			if ($userExitCode -ne 0) {
				$errorText = ($userOutput | Out-String).Trim()
				$errorId = 'LocalUserCommandFailed'
				# NET.EXE can return exit code 2 while reporting system error 2245 in its output.
				if ($userExitCode -eq 2245 -or $errorText -match '\b2245\b') {
					$errorId = 'InvalidPassword'
				}
				$exception = New-Object System.InvalidOperationException("net user failed (exit code $userExitCode). $errorText")
				$errorRecord = New-Object System.Management.Automation.ErrorRecord($exception, $errorId, [System.Management.Automation.ErrorCategory]::InvalidOperation, $Username)
				throw $errorRecord
			}
			if (-not $existingUser) {
				# Set password to never expire via wmic
				wmic useraccount where "Name='$safeUser'" set PasswordExpires=FALSE 2>&1 | Out-Null
				$results += @{ Status = 'Success'; Message = "Created new user '$Username' (net user)"; Error = $null }
			}
			else {
				$results += @{ Status = 'Success'; Message = "Updated existing user '$Username' (net user)"; Error = $null }
			}
		}
	}
	catch {
		$results += @{ Status = 'Failed'; Message = "Failed to configure user '$Username'"; Error = $_.Exception.Message; ErrorId = $_.FullyQualifiedErrorId; AccountSetupFailed = $true }
		return $results
	}

	if ($HideFromLogin) {
		$regPath = 'HKLM:\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\Userlist'
		try {
			$hideAccount = Get-ItemProperty -Path $regPath -Name $Username -ErrorAction SilentlyContinue
			if ($hideAccount -and $hideAccount.($Username) -eq 0) {
				$results += @{ Status = 'Success'; Message = 'User account is already hidden from login screen'; Error = $null }
			}
			elseif (!$DomainJoined) {
				if (!(Test-Path $regPath)) {
					New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
				}
				New-ItemProperty -Path $regPath -Name $Username -Value 0 -PropertyType 'DWord' -Force -ErrorAction Stop | Out-Null
				$results += @{ Status = 'Success'; Message = 'Hidden user from login screen'; Error = $null }
			}
			else {
				$results += @{ Status = 'Skipped'; Message = 'Computer is domain joined, skipping hide user'; Error = $null }
			}
		}
		catch {
			$results += @{ Status = 'Failed'; Message = 'Failed to hide user from login screen'; Error = $_.Exception.Message }
		}
	}
	return $results
}

function Resolve-ScanAccountSid {
	param([string]$AccountName)

	if ([string]::IsNullOrWhiteSpace($AccountName)) {
		throw 'Choose the receiving Windows user before applying folder permissions.'
	}
	return [System.Security.Principal.NTAccount]::new($AccountName).Translate([System.Security.Principal.SecurityIdentifier])
}

function Get-ScanDesktopUser {
	# ComputerSystem.UserName reports the console user, which can be someone else
	# in an RDP session. Query the session hosting this UI, not the elevated token.
	if (-not ('PrintMaster.ScansDesktopSession' -as [type])) {
		Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace PrintMaster {
    public static class ScansDesktopSession {
        [DllImport("wtsapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WTSQuerySessionInformation(
            IntPtr server, int sessionId, int infoClass, out IntPtr buffer, out int bytes);
        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr buffer);
        private static string Read(int sessionId, int infoClass) {
            IntPtr buffer;
            int bytes;
            if (!WTSQuerySessionInformation(IntPtr.Zero, sessionId, infoClass, out buffer, out bytes))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            try { return Marshal.PtrToStringUni(buffer); }
            finally { WTSFreeMemory(buffer); }
        }
        public static string UserName(int sessionId) {
            string user = Read(sessionId, 5);
            if (String.IsNullOrWhiteSpace(user)) return null;
            string domain = Read(sessionId, 7);
            return String.IsNullOrWhiteSpace(domain) ? user : domain + "\\" + user;
        }
    }
}
'@ -ErrorAction Stop
	}
	return [PrintMaster.ScansDesktopSession]::UserName((Get-Process -Id $PID -ErrorAction Stop).SessionId)
}

function Get-ScanFolderCleanupRules {
	param(
		$Acl,
		[System.Security.Principal.SecurityIdentifier]$ScanSid
	)

	# Old versions did not mark their ACEs. Matching this shape is only a review
	# candidate, never proof that Scans owns the rule or permission to remove it.
	foreach ($rule in $Acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) {
		if ($rule.AccessControlType -ne 'Allow' -or
			$rule.InheritanceFlags -ne 'ContainerInherit,ObjectInherit' -or
			$rule.PropagationFlags -ne 'None') { continue }

		$sid = $rule.IdentityReference.Value
		$isBroad = $sid -eq 'S-1-1-0' -or $sid -match '^S-1-5-21-\d+-\d+-\d+-513$'
		$legacyModify = [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::Synchronize
		if (($isBroad -and $rule.FileSystemRights -eq $legacyModify) -or
			($sid -eq $ScanSid.Value -and $rule.FileSystemRights -eq [System.Security.AccessControl.FileSystemRights]::FullControl)) {
			$rule
		}
	}
}

function Show-ScanFolderAccessDialog {
	param(
		[string]$FolderPath,
		[string]$DesktopUser,
		[string]$ElevatedUser,
		$Acl,
		[array]$CleanupRules
	)

	[xml]$folderAccessXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="PrintMaster Scans - Folder Access" Width="640" SizeToContent="Height" MaxHeight="780"
        WindowStartupLocation="CenterOwner" ResizeMode="CanResize" ShowInTaskbar="False"
        Background="$($script:thBg)" Foreground="$($script:thFg)" FontFamily="Segoe UI" FontSize="13">
$($script:themeResources)
    <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="12">
            <TextBlock Name="txtFolder" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock Text="Scan account: list/read data, create/write files, create folders/append data. No explicit delete, execute, permission-change, or ownership grant. Windows also adds Synchronize." TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock Name="txtIdentity" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock Text="Receiving Windows user (PC\user or DOMAIN\user):" Margin="0,0,0,4"/>
            <TextBox Name="txtRecipient" Margin="0,0,0,8"/>
            <TextBlock Text="This user, local Administrators, and SYSTEM receive Full Control. The receiving user must differ from the scan account." TextWrapping="Wrap" Margin="0,0,0,8"/>
            <CheckBox Name="chkEveryone" Content="Also grant Everyone Modify (not recommended)" Margin="0,0,0,4"/>
            <TextBlock Text="Optional broader access lets other users read, change, and delete scans at the NTFS layer. SMB share access is separate." TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock Name="txtPolicy" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBox Name="txtExistingRules" IsReadOnly="True" TextWrapping="Wrap" Height="140"
                     VerticalScrollBarVisibility="Auto" Visibility="Collapsed" Margin="0,0,0,8"/>
            <StackPanel Name="pnlCleanup"/>
            <TextBlock Text="Read data can expose existing scans; write data can overwrite files. Some printers need extra rights; test your printer before using this destination." TextWrapping="Wrap" Margin="0,8,0,12"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button Name="btnApply" Content="Apply permissions" Width="140" Height="24" IsDefault="True" Margin="0,0,8,0"/>
                <Button Name="btnCancel" Content="Cancel folder setup" Width="140" Height="24" IsCancel="True"/>
            </StackPanel>
        </StackPanel>
    </ScrollViewer>
</Window>
"@
	$window = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($folderAccessXaml))
	if ($script:progressWindow) { $window.Owner = $script:progressWindow }
	$window.Icon = New-PrintMasterIcon
	Set-WindowTheme $window
	$window.FindName('txtFolder').Text = "Review folder access: $FolderPath"
	$window.FindName('txtRecipient').Text = $DesktopUser
	$identityText = "Desktop user: $DesktopUser. Elevated account: $ElevatedUser."
	if ([string]::IsNullOrWhiteSpace($DesktopUser)) {
		$identityText += ' No desktop user was detected. Enter and confirm the receiving user; no administrator fallback is selected.'
	}
	elseif ($DesktopUser -ine $ElevatedUser) {
		$identityText += ' These accounts differ. Applying confirms Full Control for the receiving user shown below, not automatically for the elevated account.'
	}
	$window.FindName('txtIdentity').Text = $identityText
	$window.FindName('txtPolicy').Text = 'New folder: inheritance will be disabled, with only the listed grants (plus Everyone only if selected).'
	$cleanupBoxes = @()
	if ($Acl) {
		$window.FindName('txtPolicy').Text = 'Existing folder: inheritance and custom permissions are preserved. Existing access may exceed the scan profile. Only checked explicit rules below will be removed; matching a legacy Scans rule does not prove Scans created it. Review before applying.'
		$window.FindName('txtExistingRules').Visibility = 'Visible'
		$window.FindName('txtExistingRules').Text = ($Acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object {
			"$($_.IdentityReference): $($_.AccessControlType) $($_.FileSystemRights); inherited=$($_.IsInherited); applies=$($_.InheritanceFlags); propagation=$($_.PropagationFlags)"
		}) -join "`r`n"
		foreach ($rule in $CleanupRules) {
			$box = [System.Windows.Controls.CheckBox]::new()
			$principal = if ($rule.IdentityReference.Value -eq 'S-1-1-0') { 'Everyone' }
				elseif ($rule.IdentityReference.Value -match '-513$') { 'Domain Users' }
				else { 'Scan account' }
			$label = [System.Windows.Controls.TextBlock]::new()
			$label.Text = "Remove explicit $principal [$($rule.IdentityReference)]: $($rule.FileSystemRights)"
			$label.TextWrapping = 'Wrap'
			$label.MaxWidth = 540
			$box.Content = $label
			$box.IsChecked = $false
			$box.Tag = $rule
			$box.Margin = '0,0,0,6'
			$window.FindName('pnlCleanup').Children.Add($box) | Out-Null
			$cleanupBoxes += $box
		}
	}
	$window.FindName('btnApply').IsEnabled = -not [string]::IsNullOrWhiteSpace($DesktopUser)
	$window.FindName('txtRecipient').Add_TextChanged({
		$window.FindName('btnApply').IsEnabled = -not [string]::IsNullOrWhiteSpace($window.FindName('txtRecipient').Text)
	})
	$window.FindName('btnApply').Add_Click({ $window.DialogResult = $true })
	if ($window.ShowDialog() -eq $true) {
		return @{
			Recipient = $window.FindName('txtRecipient').Text.Trim()
			AllowEveryoneModify = [bool]$window.FindName('chkEveryone').IsChecked
			RemoveRules = @($cleanupBoxes | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag })
		}
	}
	return $null
}

function Set-ScanFolderAccessRules {
	param(
		$Acl,
		[System.Security.Principal.SecurityIdentifier]$ScanSid,
		[System.Security.Principal.SecurityIdentifier]$RecipientSid,
		[bool]$NewFolder,
		[bool]$AllowEveryoneModify,
		[array]$RemoveRules
	)

	if ($ScanSid -eq $RecipientSid) {
		throw 'The receiving user must differ from the scan account; granting it Full Control would defeat the restricted scan permissions.'
	}
	if ($NewFolder) {
		$Acl.SetAccessRuleProtection($true, $false)
	}
	foreach ($rule in $RemoveRules) {
		$Acl.RemoveAccessRuleSpecific($rule)
		Write-Verbose "Prepared removal of reviewed explicit folder rule: $($rule.IdentityReference) $($rule.FileSystemRights)."
	}

	$inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
	$scanRights = [System.Security.AccessControl.FileSystemRights]::ListDirectory -bor
		[System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
		[System.Security.AccessControl.FileSystemRights]::CreateDirectories
	$Acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($ScanSid, $scanRights, $inheritance, 'None', 'Allow'))
	foreach ($sid in @($RecipientSid, [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'), [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')) | Select-Object -Unique) {
		$Acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inheritance, 'None', 'Allow'))
	}
	if ($AllowEveryoneModify) {
		$Acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new([System.Security.Principal.SecurityIdentifier]::new('S-1-1-0'), 'Modify', $inheritance, 'None', 'Allow'))
		Write-Warning 'Everyone Modify was explicitly selected for the scan folder. Other users may read, change, and delete scans.'
	}
}

function Initialize-ScanFolder {
	param(
		[string]$FolderPath,
		[string]$ScanUser,
		[bool]$SetPermissions,
		[bool]$DomainJoined,
		[string]$DesktopUser
	)
	$results = @()

	$folderExists = $false
	$permissionsApplied = $false
	$folderCreated = $false
	try {
		$folderExists = Test-Path -LiteralPath $FolderPath -ErrorAction Stop
		if ($SetPermissions) {
			if (-not $PSBoundParameters.ContainsKey('DesktopUser')) {
				$DesktopUser = Get-ScanDesktopUser
			}
			$folderAcl = if ($folderExists) { Get-Acl -LiteralPath $FolderPath -ErrorAction Stop } else { [System.Security.AccessControl.DirectorySecurity]::new() }
			$scanSid = Resolve-ScanAccountSid "$env:COMPUTERNAME\$ScanUser"
			$cleanupRules = @(Get-ScanFolderCleanupRules -Acl $folderAcl -ScanSid $scanSid)
			$elevatedUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
			$choice = Show-ScanFolderAccessDialog -FolderPath $FolderPath -DesktopUser $DesktopUser -ElevatedUser $elevatedUser -Acl $(if ($folderExists) { $folderAcl }) -CleanupRules $cleanupRules
			if ($null -eq $choice) {
				throw [System.OperationCanceledException]::new('Folder setup canceled before creating the folder or changing its permissions. SMB share setup will be skipped.')
			}
			$recipientSid = Resolve-ScanAccountSid $choice.Recipient
			Set-ScanFolderAccessRules -Acl $folderAcl -ScanSid $scanSid -RecipientSid $recipientSid -NewFolder (-not $folderExists) -AllowEveryoneModify $choice.AllowEveryoneModify -RemoveRules $choice.RemoveRules
		}
		if (-not $folderExists) {
			New-Item -Path $FolderPath -ItemType Directory -ErrorAction Stop | Out-Null
			$folderCreated = $true
			$results += @{ Status = 'Success'; Message = "Created folder at $FolderPath"; Error = $null }
		}
		else {
			$results += @{ Status = 'Success'; Message = 'Scans folder already exists'; Error = $null }
		}
		if ($SetPermissions) {
			Set-Acl -LiteralPath $FolderPath -AclObject $folderAcl -ErrorAction Stop
			$permissionsApplied = $true
			$results += @{ Status = 'Success'; Message = "Folder permissions applied: restricted scan rights; Full Control for '$($choice.Recipient)', Administrators, and SYSTEM."; Error = $null }
			if ($folderExists) {
				Write-Warning 'Existing folder inheritance and unselected explicit entries were preserved. Effective access may exceed the scan profile; existing protected child ACLs are not reset.'
				$results += @{ Status = 'Warning'; Message = 'Existing inheritance and unselected permissions preserved; review effective access and protected child folders/files. This is not a guarantee of restricted effective access.'; Error = $null }
			}
		}
	}
	catch {
		$results += @{ Status = 'Failed'; Message = "Failed to prepare scan folder at $FolderPath"; Error = $_.Exception.Message; FolderSetupFailed = $true }
		if ($SetPermissions -and $folderCreated -and -not $permissionsApplied) {
			Write-Warning "Restricted permissions were not applied to '$FolderPath'. The folder retains its inherited permissions; SMB share setup will be skipped."
		}
	}
	return $results
}

function Initialize-ScanShare {
	param(
		[string]$ShareName,
		[string]$FolderPath,
		[string]$ScanUser
	)
	try {
		if ($script:hasSmbShareCmdlets) {
			if (-not (Get-SmbShare -ErrorAction Stop | Where-Object { $_.Name -eq $ShareName })) {
				New-SmbShare -Name $ShareName -Path $FolderPath -FullAccess $ScanUser -ErrorAction Stop | Out-Null
				return @{ Status = 'Success'; Message = "Created SMB share '$ShareName'"; Error = $null }
			}
			else {
				Grant-SmbShareAccess -Name $ShareName -AccountName $ScanUser -AccessRight Full -Force -ErrorAction Stop | Out-Null
				return @{ Status = 'Success'; Message = "Updated SMB share permissions for '$ShareName'"; Error = $null }
			}
		}
		else {
			$existing = net share $ShareName 2>&1
			if ($LASTEXITCODE -ne 0) {
				$shareOutput = net share "$ShareName=$FolderPath" "/grant:$ScanUser,FULL" 2>&1
				if ($LASTEXITCODE -ne 0) { throw "net share failed (exit code $LASTEXITCODE). $($shareOutput | Out-String)" }
				return @{ Status = 'Success'; Message = "Created SMB share '$ShareName' (net share)"; Error = $null }
			}
			else {
				$shareOutput = net share "$ShareName=$FolderPath" "/grant:$ScanUser,FULL" /yes 2>&1
				if ($LASTEXITCODE -ne 0) { throw "net share failed (exit code $LASTEXITCODE). $($shareOutput | Out-String)" }
				return @{ Status = 'Success'; Message = "Updated SMB share '$ShareName' (net share)"; Error = $null }
			}
		}
	}
	catch {
		return @{ Status = 'Failed'; Message = "Failed to configure SMB share '$ShareName'"; Error = $_.Exception.Message }
	}
}

function Initialize-DesktopShortcut {
	param(
		[string]$FolderPath,
		[string]$IconPath,
		[string]$Description
	)
	try {
		$shortcutPath = "C:\Users\Public\Desktop\Scans.lnk"
		$shellObject = New-Object -ComObject ("WScript.Shell")
		$desktopShortCut = $shellObject.CreateShortcut($shortcutPath)
		$desktopShortCut.TargetPath = $FolderPath
		$desktopShortCut.IconLocation = $IconPath
		$desktopShortCut.Description = $Description
		$desktopShortCut.Save() | Out-Null
		return @{ Status = 'Success'; Message = 'Created desktop shortcut'; Error = $null }
	}
	catch {
		return @{ Status = 'Failed'; Message = 'Failed to create desktop shortcut'; Error = $_.Exception.Message }
	}
}

function Set-NetworkConfiguration {
	param([bool]$DomainJoined)
	$results = @()

	if ($script:hasNetConnection) {
		# Modern path: PS cmdlets (Win 8+)
		$networkProfile = Get-NetConnectionProfile | Select-Object -First 1
		$networkCategory = $networkProfile.NetworkCategory
		if (!$DomainJoined -and $networkCategory -ne 'Private') {
			try {
				$networkProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction Stop
				$results += @{ Status = 'Success'; Message = 'Set Network Category to Private'; Error = $null }
			}
			catch {
				$results += @{ Status = 'Failed'; Message = 'Failed to Set Network Category to Private'; Error = $_.Exception.Message }
			}
		}
		elseif ($DomainJoined) {
			$results += @{ Status = 'Skipped'; Message = 'Network Category is managed by domain, skipping'; Error = $null }
		}
		else {
			$results += @{ Status = 'Success'; Message = "Network Category is already $networkCategory"; Error = $null }
		}

		# Re-read after possible change
		$networkCategory = (Get-NetConnectionProfile | Select-Object -First 1).NetworkCategory
	}
	else {
		# Legacy path: netsh (Win 7)
		if (!$DomainJoined) {
			try {
				$networkOutput = netsh advfirewall set currentprofile state on 2>&1
				if ($LASTEXITCODE -ne 0) { throw "netsh failed (exit code $LASTEXITCODE). $($networkOutput | Out-String)" }
				$results += @{ Status = 'Success'; Message = 'Ensured firewall profile is active (netsh)'; Error = $null }
			}
			catch {
				$results += @{ Status = 'Failed'; Message = 'Failed to configure firewall profile'; Error = $_.Exception.Message }
			}
		}
		else {
			$results += @{ Status = 'Skipped'; Message = 'Network Category is managed by domain, skipping'; Error = $null }
		}
	}

	# File and Printer Sharing
	if ($script:hasNetSecurity) {
		$networkCategory = (Get-NetConnectionProfile | Select-Object -First 1).NetworkCategory
		# Map DomainAuthenticated to Domain for firewall cmdlets
		$firewallProfile = if ($networkCategory -eq 'DomainAuthenticated') { 'Domain' } else { $networkCategory.ToString() }
		$sharingEnabled = Get-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Direction Inbound | Where-Object { $_.Enabled -eq 'True' -and $_.Profile -eq $firewallProfile }
		if ($sharingEnabled.count -eq 0) {
			try {
				Set-NetFirewallRule -DisplayGroup "File and Printer Sharing" -Direction Inbound -Enabled True -Profile $firewallProfile -ErrorAction Stop
				$results += @{ Status = 'Success'; Message = 'Network file and printer sharing has been enabled.'; Error = $null }
			}
			catch {
				$results += @{ Status = 'Failed'; Message = 'Failed to enable Network File and Printer Sharing.'; Error = $_.Exception.Message }
			}
		}
		else {
			$results += @{ Status = 'Success'; Message = 'Network File and Printer Sharing is already enabled.'; Error = $null }
		}

		# Network Discovery
		$discoveryEnabled = Get-NetFirewallRule -DisplayGroup "Network Discovery" -Direction Inbound | Where-Object { $_.Enabled -eq 'True' -and $_.Profile -eq $firewallProfile }
		if ($discoveryEnabled.count -eq 0) {
			try {
				Set-NetFirewallRule -DisplayGroup "Network Discovery" -Direction Inbound -Enabled True -Profile $firewallProfile -ErrorAction Stop
				$results += @{ Status = 'Success'; Message = 'Network Discovery has been enabled.'; Error = $null }
			}
			catch {
				$results += @{ Status = 'Failed'; Message = 'Failed to Enable Network Discovery.'; Error = $_.Exception.Message }
			}
		}
		else {
			$results += @{ Status = 'Success'; Message = 'Network Discovery is already enabled.'; Error = $null }
		}
	}
	else {
		# Legacy path: netsh advfirewall (Win 7)
		try {
			$networkOutput = netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes 2>&1
			if ($LASTEXITCODE -ne 0) { throw "netsh failed (exit code $LASTEXITCODE). $($networkOutput | Out-String)" }
			$results += @{ Status = 'Success'; Message = 'Network file and printer sharing has been enabled (netsh).'; Error = $null }
		}
		catch {
			$results += @{ Status = 'Failed'; Message = 'Failed to enable Network File and Printer Sharing.'; Error = $_.Exception.Message }
		}
		try {
			$networkOutput = netsh advfirewall firewall set rule group="Network Discovery" new enable=Yes 2>&1
			if ($LASTEXITCODE -ne 0) { throw "netsh failed (exit code $LASTEXITCODE). $($networkOutput | Out-String)" }
			$results += @{ Status = 'Success'; Message = 'Network Discovery has been enabled (netsh).'; Error = $null }
		}
		catch {
			$results += @{ Status = 'Failed'; Message = 'Failed to Enable Network Discovery.'; Error = $_.Exception.Message }
		}
	}
	return $results
}

# Embedded application icon (base64 ICO) — written to disk for WPF + shortcut use
$script:appIconBase64 = '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qampttJVgZSSkZGQjUX7+/v7+/v7+/v7+/v7+/v7+/v7Wb69l9mV2Li4uLi3s7GxsbCwsK+urq2trKysq6urqqqpqbrTVYGUlJKRkZBF+/v7+/v7+/v7+/v7+/v7+/v7+1m+vpfZl9i5uLi4uLezsbGxsLCwr66ura2srKyrq6uqqqm601WClpSUkpGRRvv7+/v7+/v7+/v7+/v7+/v7+/tcvr6Z25fZubm4uLi4t7OxsbGwsLCvrq6traysrKurq6qqutNXg5aWlJSSkUb7+/v7+/v7+/v7+/v7+/v7+/v7XL++mduX2bq5ubi4uLi3s7GxsbCwsK+urq2trKysq6urqrvTV4OYlpaUlJJG+/v7+/v7+/v7+/v7+/v7+/v7+16/v5nbmdu6urm5uLi4uLezsbGxsLCwr66ura2srKyrq6u701eHm5iWlpSUR/v7+/v7+/v7+/v7+/v7+/v7+/tewL+Z25nbvbq6ubm4uLi4t7OxsbGwsLCvrq6traysrKuru9NYiJubmJaWlEf7+/v7+/v7+/v7+/v7+/v7+/v7XsHAmdyZ2769urq5ubi4uLi3s7GxsbCwsK+urq2trKysq7zUWIidm5uYlpZH+/v7+/v7+/v7+/v7+/v7+/v7+17BwZrcmdu+vr26urm5uLi4uLezsbGxsLCwr66ura2srKy11FqJn52bm5iWSPv7+/v7+/v7+/v7+/v7+/v7+/tewsGc3Zncvr6+vbq6ubm4uLi4t7OxsbGwsLCvrq6traysrNRbjp+fnZubmEj7+/v7+/v7+/v7+/v7+/v7+/v7XsLCnN6a3L++vr69urq5ubi4uLi3s7GxsbCwsK+urq2trKzWc4+in5+dm5tI+/v7+/v7+/v7+/v7+/v7+/v7+2HCwp7enN2/v76+vr26urm5uLi4uLezsbGxsLCwr66ura2s1naAoqKfn52GSPv7+/v7+/v7+/v7+/v7+/v7+/tjw8Ke3pzewL+/vr6+vbq6ubm4uLi4t7OxsbGwsLCvrq6trdB7eKSiop+fdyL7+/v7+/v7+/v7+/v7+/v7+/v7Y8PDnt6e3sHAv7++vr69urq5ubi4uLi3s7GxsbCwsK+urq3JzF96pKKik1MD+/v7+/v7+/v7+/v7+/v7+/v7+2PDw57ent7BwcC/v76+vr26urm5uLi4uLezsbEdHBoZGBYVFBMSERAPDg0MCwoJCAcGBQT7+/v7+/v7+/v7+/tjxsOe357ewsHBwL+/vr6+vbq6ubm4uLi4t7OxH/Ly8vLy8vLy8vLy8vLy8vLy8vLy8vIF+/v7+/v7+/v7+/v7Y8bGnt+e3sLCwcHAv7++vr69urq5ubi4uLi3syDy4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+PyBvv7+/v7+/v7+/v7+2bHxqHfnt/CwsLBwcC/v76+vr26urm5uLi4uLch8+Tj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj8gf7+/v7+/v7+/v7+/tnx8eh4J7fw8LCwsHBwL+/vr6+vbq6ubm4uLi4I/Tm5ubm5eTj4+Pj4+Pj4+Pj4+Pj4/II+/v7+/v7+/v7+/v7Z8fHo+Ch38PDwsLCwcHAv7++vr69urq5ubi4uCT05jU1NTU1NTU1NTU1NTU1NTU1NePyCfv7+/v7+/v7+/v7+2nHx6PgoeDDw8PCwsLBwcC/v74dHBoZGBYVFBMm9Obm5ubm5ubm5ubk4+Pj4+Pj4+Pj8gr7+/v7+/v7+/v7+/tpx8ej4KPgxsPDw8LCwsHBwL+/H/Ly8vLy8vLyJ/Tm5ubm5ubm5ubm5ubk4+Pj4+Pj4/IL+/v7+/v7+/v7+/v7acfHo+Cj4MbGw8PDwsLCwcHAvyDy4+Pj4+Pj4yj05zU1NTU1NTU1NTU1NTU1NTU1NePyDPv7+/v7+/v7+/v7+2rHx6Pgo+DHxsbDw8PCwsLBwcAh8+Tj4+Pj4+Mp9eno6Ojo5+fm5ubm5ubm5uTj4+Pj8g37+/v7+/v7+/v7+/tqx8ej4KPgx8fGxsPDw8LCwsHBI/Tm5ubm5eTjKvXp6enp6eno6Ofn5ubm5ubm5OPj4/IO+/v7+/v7+/v7+/v7asfHo+Cj4MfHx8bGw8PDwsLCwST05l1dXV1dXSv16TU1NTU1NTU1NTU1NTU1NTU1NePyD/v7+/v7+/v7+/v7+2rHx6Pgo+DHx8fHxsbDw8PCwsIm9Obm5ubm5uYs9urq6enp6enp6eno5+bm5ubm5uTj8hD7+/v7+/v7+/v7+/tqx8ej4KPgx8fHx8fGxsPDw8LCJ/Tm5ubm5ubmLfbq6urq6urp6enp6ejn5+bm5ubm5PIR+/v7+/v7+/v7+/v7a8fHo+Cj4MfHx8fHx8bGw8PDwij052BgYF1dXS726zU1NTU1NTU1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'
$iconPath = 'C:\ProgramData\scans.ico'
if (!(Test-Path $iconPath)) {
	[IO.File]::WriteAllBytes($iconPath, [Convert]::FromBase64String($script:appIconBase64))
}
function New-PrintMasterIcon {
	# WPF cannot load SVG directly; embed the site logo as vector artwork.
	[xml]$logoXaml = @'
<DrawingImage xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
    <DrawingImage.Drawing>
        <DrawingGroup>
            <GeometryDrawing Brush="Transparent"><GeometryDrawing.Geometry><RectangleGeometry Rect="0,0,64,64"/></GeometryDrawing.Geometry></GeometryDrawing>
            <GeometryDrawing Brush="#4a5568"><GeometryDrawing.Geometry><RectangleGeometry Rect="16,8,32,12" RadiusX="2" RadiusY="2"/></GeometryDrawing.Geometry></GeometryDrawing>
            <GeometryDrawing Brush="#718096"><GeometryDrawing.Geometry><RectangleGeometry Rect="12,20,40,24" RadiusX="3" RadiusY="3"/></GeometryDrawing.Geometry></GeometryDrawing>
            <GeometryDrawing Brush="#cbd5e0"><GeometryDrawing.Geometry><RectangleGeometry Rect="16,24,32,16" RadiusX="2" RadiusY="2"/></GeometryDrawing.Geometry></GeometryDrawing>
            <GeometryDrawing Brush="#4299e1" Geometry="M20,28 H28 V30 H20 Z M20,32 H32 V34 H20 Z M20,36 H30 V38 H20 Z"/>
            <GeometryDrawing Brush="#48bb78"><GeometryDrawing.Geometry><EllipseGeometry Center="46,32" RadiusX="3" RadiusY="3"/></GeometryDrawing.Geometry></GeometryDrawing>
            <GeometryDrawing Brush="#4a5568"><GeometryDrawing.Geometry><RectangleGeometry Rect="16,44,32,12" RadiusX="2" RadiusY="2"/></GeometryDrawing.Geometry></GeometryDrawing>
            <GeometryDrawing Brush="#e2e8f0"><GeometryDrawing.Geometry><RectangleGeometry Rect="20,48,24,4"/></GeometryDrawing.Geometry></GeometryDrawing>
        </DrawingGroup>
    </DrawingImage.Drawing>
</DrawingImage>
'@
	$icon = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($logoXaml))
	$icon.Freeze()
	return $icon
}

# --- Embedded settings gear icon (base64 PNG, theme-aware via OpacityMask) ---
$script:settingsIconBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAGAAAABkCAQAAADTAP2lAAAAxHpUWHRSYXcgcHJvZmlsZSB0eXBlIGV4aWYAAHjabVDbEcMgDPtnio4AlkPscUiT3nWDjl+DnV5oqzvkhxJhnI7X85FuHVQ48bJK1VqzgZWVmiWSHW1wyTx4oIZk9dRPlUMga8EivJT4o5z98jHw0CxbLkZyD2GbBY0LSL6MyAP6RD3fw0jDCORCCYPW4ikq6/UJ25FniJ/UiWUe+6debXv7YveA6EBBNgaqD4B+OKFZAmOC2ocZOjpszDjNbCH/9nQivQHrcFkdUfZFZgAAASNpQ0NQSUNDIHByb2ZpbGUAAHicnZC/SsNQFMZ/aUVF7KQ4iEIG1y6CmRz8h8GhUNMIRqc0abGYxJCkFN/AN9GH6SAIPoOzgrPfjQ4OZvHCyffjcM733Rto2UmUlgsHkGZV4XqHwWVwZS+90Wabjr67YVTmvcGpT+P5fMUy+tI1Xs1zf57FeFRG0rkqi/KiAmtf7Myq3LCK9VvfOxY/iO04zWLxk3gnTmPDZtdLk2n042luszrKLgamr9rC5YwefWyGTJmQUNGVZuqc4LAndSkIuackkiaM1JtppuJGVMrJ5Ujki3SbhrzNOq+vlKE8JvIyCXek8jR5mP/7vfZxXm9aG/M8LMK61Va1xmN4f4ROAGvPsHLdkLX8+20NM0498883fgEty1CH2lf0fwAADXZpVFh0WE1MOmNvbS5hZG9iZS54bXAAAAAAADw/eHBhY2tldCBiZWdpbj0i77u/IiBpZD0iVzVNME1wQ2VoaUh6cmVTek5UY3prYzlkIj8+Cjx4OnhtcG1ldGEgeG1sbnM6eD0iYWRvYmU6bnM6bWV0YS8iIHg6eG1wdGs9IlhNUCBDb3JlIDQuNC4wLUV4aXYyIj4KIDxyZGY6UkRGIHhtbG5zOnJkZj0iaHR0cDovL3d3dy53My5vcmcvMTk5OS8wMi8yMi1yZGYtc3ludGF4LW5zIyI+CiAgPHJkZjpEZXNjcmlwdGlvbiByZGY6YWJvdXQ9IiIKICAgIHhtbG5zOnhtcE1NPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvbW0vIgogICAgeG1sbnM6c3RFdnQ9Imh0dHA6Ly9ucy5hZG9iZS5jb20veGFwLzEuMC9zVHlwZS9SZXNvdXJjZUV2ZW50IyIKICAgIHhtbG5zOmRjPSJodHRwOi8vcHVybC5vcmcvZGMvZWxlbWVudHMvMS4xLyIKICAgIHhtbG5zOkdJTVA9Imh0dHA6Ly93d3cuZ2ltcC5vcmcveG1wLyIKICAgIHhtbG5zOnRpZmY9Imh0dHA6Ly9ucy5hZG9iZS5jb20vdGlmZi8xLjAvIgogICAgeG1sbnM6eG1wPSJodHRwOi8vbnMuYWRvYmUuY29tL3hhcC8xLjAvIgogICB4bXBNTTpEb2N1bWVudElEPSJnaW1wOmRvY2lkOmdpbXA6NmZhZmE1Y2EtN2VhNy00YTA1LTgzODAtZTM4M2UyMTZhOGZjIgogICB4bXBNTTpJbnN0YW5jZUlEPSJ4bXAuaWlkOmU0NDU3ODRmLTkyNTktNDc3Ny05YWI5LTg3OWU2ZWNjMGMzOSIKICAgeG1wTU06T3JpZ2luYWxEb2N1bWVudElEPSJ4bXAuZGlkOmFiYjc3ZGRiLTYyYmQtNGQ5Yi1iYzViLTk4YTBmM2VlZWY5NCIKICAgZGM6Rm9ybWF0PSJpbWFnZS9wbmciCiAgIEdJTVA6QVBJPSIyLjAiCiAgIEdJTVA6UGxhdGZvcm09IldpbmRvd3MiCiAgIEdJTVA6VGltZVN0YW1wPSIxNzExNzE3NDgwNTk0NDgyIgogICBHSU1QOlZlcnNpb249IjIuMTAuMzYiCiAgIHRpZmY6T3JpZW50YXRpb249IjEiCiAgIHhtcDpDcmVhdG9yVG9vbD0iR0lNUCAyLjEwIgogICB4bXA6TWV0YWRhdGFEYXRlPSIyMDI0OjAzOjI5VDA5OjA0OjQwLTA0OjAwIgogICB4bXA6TW9kaWZ5RGF0ZT0iMjAyNDowMzoyOVQwOTowNDo0MC0wNDowMCI+CiAgIDx4bXBNTTpIaXN0b3J5PgogICAgPHJkZjpTZXE+CiAgICAgPHJkZjpsaQogICAgICBzdEV2dDphY3Rpb249InNhdmVkIgogICAgICBzdEV2dDpjaGFuZ2VkPSIvIgogICAgICBzdEV2dDppbnN0YW5jZUlEPSJ4bXAuaWlkOjc5NjdmN2QxLTUyMTgtNDM5Ni05NTUwLTVkN2M1YzJmMmExNiIKICAgICAgc3RFdnQ6c29mdHdhcmVBZ2VudD0iR2ltcCAyLjEwIChXaW5kb3dzKSIKICAgICAgc3RFdnQ6d2hlbj0iMjAyNC0wMy0yOVQwOTowNDo0MCIvPgogICAgPC9yZGY6U2VxPgogICA8L3htcE1NOkhpc3Rvcnk+CiAgPC9yZGY6RGVzY3JpcHRpb24+CiA8L3JkZjpSREY+CjwveDp4bXBtZXRhPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAKICAgICAgICAgICAgICAgICAgICAgICAgICAgCjw/eHBhY2tldCBlbmQ9InciPz6lj/qJAAAAAmJLR0QA/4ePzL8AAAAJcEhZcwAACxMAAAsTAQCanBgAAAAHdElNRQfoAx0NBCiKEThwAAAG8UlEQVR42t2cW2xURRjHf3NWqFRku1yUFQI7FDAUtSUUUzRoQghaUBNijbQ18fIgJj4IvEhifDDRxBdvqAnqA77QaqzRoIJBokGUNlqQgiVcusxK0IKI3XJptbp7fEBkl57dnplzSs/xe9yd75v5z3wz893mCHwjaXEdFcxhJtOYzESilDIKwQD99PIb3Ryji4N08qvK+tWr8EdMwhKreZLpRFw0zvATb9qvpnwBEfEHQOwJ1hPDctXYIsZd4mS6PTArIGEP8zSZ9jBf+dC35csClDJbm2c2pQQGQDnXaPOMZUZwANxsxHVLcABUGXFVBgSANAVQJYMBwLZMVci2AgFAxJlkxDhJxIOxByoMr8MIFcEAUDkCnP4BSJhuYYCqxMgDEJ4AeLdkrnKeVSGppZ/P6R7SXol6uFFnEKV3yEM6zt2MYautUu4ARBH30Uwp8CdfyiY+obcIjGWMMQYwhlreKzL0KPfSwGJKgD5RH9vc48YalTV8wdicH87wGZvs7fw5eAbktbQbGHKX6BAL1FmHfVUiltDIcsbl/HyeJaptSAByGq3c4NDVST6kiTaVyWk7jmaWeVTiLdSrMzkyI9TQwP1c79D2FxaqY0UByKv5iprCly5J3ucDDpBlPPfwDOU+HMNJXuATerCo4AEepLyIl9LKYvVHQQASXuWpoW0HzvEHMecDwJD+pocSrnXhYL3GauUMQJBYzmaf7NPhoyz3pT6znQDICXQwheDTcarU6UFOvYTXuZMw0DgmlG1OD7qJF/EoYaFHxKLLVEhGaGUB4aF2ai4c6BdXoD5Uw4dqGnJWQI6mk5mEi7qYqwYurkBj6IYPM2n8dwVkhA7mEj7qtCtTGQtYGsrhw1yxFCwJqwgrPSERcgqKUSEF8BfSYmVohw+jWGlRR5ipTsized6XfzbjIdpJ0gPEKKea2X4lU/Lo3FXsZ6HPQn/hLZpIKjvH0hXMoJFVjr6eF9ovZA1bKfNNYD8v8rI6V8BNH8ta1nkIAlxOaWrFFEbfwkf+JBs4zIPsVcWDJFW87ykMcImOsmJg3wVbaDIt3O6DhbhMnRq6mZzEFqo99/YtderEv7aQOsFSNnkUeMjd8EGdYhmHPfa2iaXqRI5Hlv6r7GNhc4dx1rKPu5XrpGO6L/Y1DxvfP1mes9ekBi5zKdN2bAdHqDUU+xwtaY3mZSeFxWLDqXqEN1J2obDKQj5EP+1wnBtVnx6LvIaDTNXuqZv7ac1d6rwgiiLVym10aIvdYPfpstjn2aDdTwe3p1rzNdUpNhqlmVoNsRnK1U/6uiCnk9S6nbfQoAbFsh3CWKqXOr7XEHyAY0bafIwDGq2/o045hOId43CqjzXYrkXv1mibp0Xs1mi7VvU7/VEokLiLLtfCk2ZFGwqSrhsfYZfzHwUAKJv9roX/bnwduefcr2wtAGCoFlecCgBICI3s+3jj3t1z3pwQWgDEQma5Fl5uVvOQQCM9MkvcpgFAjuEVDatovpkFJYSGTSp4RZa6BCCjtHCrxkgqmGa0BNOZo9F6AS0yOiQAgUywQzNxF+GhhIkCNWp6ybXskFIMWpr/jzEnoZ7tmJTATGVNQlN7WGMwfIiznXqZt/wXl9QSz7Ke0YYHYo34NH1S4/ys5F1Dz2MUKxBlO9N2ngrJUt6+EK724FIucudSgpzENx4d+008fkFpR8Kpv44tzPfLqQ99WCUyscZw4zrRBB4mEtudHigY2FrHRib71FuM+sgOIXddodBiOQ3DEFpsHa7gbobD/wV3x1NONbOGJ7grZGuR6pTgU5tFC2GmFiGncjTEKaYZFsfZGtr538pxS2EQYAoKbVBYwDY6Qzn8TraBBSrDS6EE8JLK/A+KPSIA6UwszYqQAVitfsh1aJpoD9Xw22nK88hUhrVkQzP8LGsvFuBecil3sjE0ADay08GpD03Z5c9UXiq7zHHqU6dZFQI1yrIqddrBqQeIHWG8C9vU5ixnKPG1xvdvTpNhtIsY3+us73EOq4CCdbQVHXoXLzCPicSJ85hGDqEYJXmMOHEmMo/n6SoaF2/j6SFyZCEvv4dCDyDYbjs/gPieGz2FAaqdHkCIEpbQwD0GDyCgjFjOExSGeIIiV9LsAUCDai4Swch7gkJ97+bBKR3HTaPzCEhG6TYuoOknrjw+AvL8DkrCj8Zlm53c5PVVt+ej0Ia9xsx7vSfiPANIeQKQGnkAYFBb4Z3TVwAHyBjxZbRKDYYPgN3NKSPGU3Z3IACIrEZWP5f2iWwgACjTbbw3OB/G6BipLewXgH1XkGtYACQ5r81zjqPBAdBnUAd6mL7AAFDwjjbTO8qXufPr+0J7OMMsxrmakAwpnufNtC8VST594Qku+0RVnAlX5hNV/wDkVh2zQRBX5QAAAABJRU5ErkJggg=='
$script:settingsIconBitmap = $null
try {
	$stream = [System.IO.MemoryStream]::new([Convert]::FromBase64String($script:settingsIconBase64))
	$bmp = [System.Windows.Media.Imaging.BitmapImage]::new()
	$bmp.BeginInit()
	$bmp.StreamSource = $stream
	$bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
	$bmp.EndInit()
	$bmp.Freeze()
	$script:settingsIconBitmap = $bmp
} catch {
	Write-Warning "Could not load the settings gear image; using the built-in fallback. $($_.Exception.Message)"
}

# --- WPF Settings Dialog ---
function New-SettingsPage {
	[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="PrintMaster Scans - Settings" SizeToContent="Height" Width="300" WindowStartupLocation="CenterScreen" ResizeMode="NoResize"
        Background="$($script:thBg)" Foreground="$($script:thFg)" FontFamily="Segoe UI" FontSize="13">
$($script:themeResources)
    <StackPanel Margin="12">
        <CheckBox Name="chkCreateUser" Content="Create new user account" Margin="0,0,0,6"/>
        <CheckBox Name="chkHideUser" Content="Hide user from login screen" Margin="0,0,0,6"/>
        <CheckBox Name="chkCreateFolder" Content="Create scans folder" Margin="0,0,0,6"/>
        <CheckBox Name="chkSetPermissions" Content="Set folder permissions" Margin="0,0,0,6"/>
        <CheckBox Name="chkSetShare" Content="Set SMB share" Margin="0,0,0,6"/>
        <CheckBox Name="chkCreateShortcut" Content="Create desktop shortcut" Margin="0,0,0,6"/>
        <CheckBox Name="chkNetworkSettings" Content="Check network settings" Margin="0,0,0,6"/>
        <Button Name="btnOK" Content="OK" Width="75" Height="24" HorizontalAlignment="Right" Margin="0,12,0,0"/>
    </StackPanel>
</Window>
"@
	$reader = [System.Xml.XmlNodeReader]::new($xaml)
	$window = [Windows.Markup.XamlReader]::Load($reader)
	$window.Icon = New-PrintMasterIcon
	Set-WindowTheme $window

	$window.FindName('chkCreateUser').IsChecked = $script:createUser
	$window.FindName('chkHideUser').IsChecked = $script:hideUser
	$window.FindName('chkCreateFolder').IsChecked = $script:createFolder
	$window.FindName('chkSetPermissions').IsChecked = $script:setPermissions
	$window.FindName('chkSetShare').IsChecked = $script:setShare
	$window.FindName('chkCreateShortcut').IsChecked = $script:createShortcut
	$window.FindName('chkNetworkSettings').IsChecked = $script:checkNetworkSettings

	$window.FindName('btnOK').Add_Click({
		$script:createUser = [bool]$window.FindName('chkCreateUser').IsChecked
		$script:hideUser = [bool]$window.FindName('chkHideUser').IsChecked
		$script:createFolder = [bool]$window.FindName('chkCreateFolder').IsChecked
		$script:setPermissions = [bool]$window.FindName('chkSetPermissions').IsChecked
		$script:setShare = [bool]$window.FindName('chkSetShare').IsChecked
		$script:createShortcut = [bool]$window.FindName('chkCreateShortcut').IsChecked
		$script:checkNetworkSettings = [bool]$window.FindName('chkNetworkSettings').IsChecked
		$window.DialogResult = $true
	})

	$window.ShowDialog() | Out-Null
}

# --- WPF Setup Window ---
[xml]$setupXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="PrintMaster Scans Setup" Height="250" Width="440" WindowStartupLocation="CenterScreen" ResizeMode="NoResize" ShowInTaskbar="True"
        Background="$($script:thBg)" Foreground="$($script:thFg)" FontFamily="Segoe UI" FontSize="13">
$($script:themeResources)
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="75"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock Grid.Row="0" Text="Username:" VerticalAlignment="Center" Margin="0,0,0,6"/>
        <TextBox Grid.Row="0" Grid.Column="1" Grid.ColumnSpan="2" Name="txtUsername" Margin="0,0,0,6"/>
        <TextBlock Grid.Row="1" Text="Password:" VerticalAlignment="Center" Margin="0,0,0,6"/>
        <TextBox Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" Name="txtPassword" Margin="0,0,0,6"/>
        <TextBlock Grid.Row="2" Text="Local Dir:" VerticalAlignment="Center" Margin="0,0,0,6"/>
        <TextBox Grid.Row="2" Grid.Column="1" Name="txtFolderPath" Margin="0,0,4,6"/>
        <Button Grid.Row="2" Grid.Column="2" Name="btnBrowse" Content="..." Width="28" Margin="0,0,0,6"/>
        <TextBlock Grid.Row="3" Text="SMB Share:" VerticalAlignment="Center" Margin="0,0,0,6"/>
        <TextBox Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" Name="txtShareName" Margin="0,0,0,6"/>
        <TextBlock Grid.Row="5" Grid.ColumnSpan="3" Name="txtProvider" Text="Provided by PrintMaster" FontSize="11" VerticalAlignment="Center"/>
        <StackPanel Grid.Row="5" Grid.ColumnSpan="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnSettings" Width="30" Height="28" Margin="0,0,8,0" ToolTip="Settings">
                <Grid Width="18" Height="18">
                    <TextBlock Name="txtSettingsIconFallback" Text="&#x2699;" FontFamily="Segoe UI Symbol" FontSize="18"
                               Foreground="$($script:thBtnText)" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    <Rectangle Name="rectSettingsIcon" Width="16" Height="16" Fill="$($script:thBtnText)" Visibility="Collapsed"/>
                </Grid>
            </Button>
            <Button Name="btnOK" Content="OK" Width="75" Height="24" Margin="0,0,8,0" IsDefault="True"/>
            <Button Name="btnCancel" Content="Cancel" Width="75" Height="24" IsCancel="True"/>
        </StackPanel>
    </Grid>
</Window>
"@
$reader = [System.Xml.XmlNodeReader]::new($setupXaml)
$setupWindow = [Windows.Markup.XamlReader]::Load($reader)
$setupWindow.Icon = New-PrintMasterIcon
Set-WindowTheme $setupWindow

# Apply gear icon as OpacityMask so it picks up the theme fill color
if ($script:settingsIconBitmap) {
	$brush = [System.Windows.Media.ImageBrush]::new($script:settingsIconBitmap)
	$settingsIcon = $setupWindow.FindName('rectSettingsIcon')
	$settingsIcon.OpacityMask = $brush
	$settingsIcon.Visibility = 'Visible'
	$setupWindow.FindName('txtSettingsIconFallback').Visibility = 'Collapsed'
}

$setupWindow.FindName('txtUsername').Text = $scanUser
$setupWindow.FindName('txtPassword').Text = New-RandomPassword
$setupWindow.FindName('txtFolderPath').Text = $folderPath
$setupWindow.FindName('txtShareName').Text = $shareName

$setupWindow.FindName('btnBrowse').Add_Click({
	$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
	$folderBrowser.Description = "Select folder for scans"
	$folderBrowser.SelectedPath = $setupWindow.FindName('txtFolderPath').Text
	$folderBrowser.ShowNewFolderButton = $true
	if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
		$setupWindow.FindName('txtFolderPath').Text = $folderBrowser.SelectedPath
	}
})

$setupWindow.FindName('btnSettings').Add_Click({ New-SettingsPage })
$setupWindow.FindName('btnOK').Add_Click({ $setupWindow.DialogResult = $true })

$setupResult = $setupWindow.ShowDialog()

if ($setupResult -eq $true) {
	$script:scanUser = $setupWindow.FindName('txtUsername').Text
	$script:scanPass = $setupWindow.FindName('txtPassword').Text
	$script:folderPath = $setupWindow.FindName('txtFolderPath').Text
	$script:shareName = $setupWindow.FindName('txtShareName').Text
	Write-Verbose "Username: $script:scanUser `nLocal Dir: $script:folderPath`nSMB Share: $script:shareName"
}
else {
	Write-Verbose "User canceled scanning setup"
	Exit 0
}
$details = New-Object System.Collections.ArrayList
$script:progressMax = 2
if ($createUser) { $script:progressMax += 2 }
if ($hideUser) { $script:progressMax += 1 }
if ($createFolder) { $script:progressMax += 1 }
if ($setPermissions) { $script:progressMax += 1 }
if ($setShare) { $script:progressMax += 1 }
if ($createShortcut) { $script:progressMax += 1 }
if ($checkNetworkSettings) { $script:progressMax += 3 }

[xml]$progressXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="PrintMaster Scans Setup - Loading..." Height="300" Width="440" WindowStartupLocation="CenterScreen" ResizeMode="NoResize" ShowInTaskbar="True"
        Background="$($script:thBg)" Foreground="$($script:thFg)" FontFamily="Segoe UI" FontSize="13">
$($script:themeResources)
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Name="txtStatus" Text="Loading..." Margin="0,0,0,6"/>
        <ProgressBar Grid.Row="1" Name="progressBar" Height="20" Minimum="0" Value="0" Margin="0,0,0,6"/>
        <ListBox Grid.Row="2" Name="lstDetails" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="3" Name="txtProvider" Text="Provided by PrintMaster" FontSize="11" VerticalAlignment="Center"/>
        <StackPanel Grid.Row="3" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnCopyPassword" Content="Copy Password" Width="110" Height="24" IsEnabled="False" Margin="0,0,8,0"/>
            <Button Name="btnDone" Content="Done" Width="75" Height="24" IsEnabled="False"/>
        </StackPanel>
    </Grid>
</Window>
"@
$reader = [System.Xml.XmlNodeReader]::new($progressXaml)
$script:progressWindow = [Windows.Markup.XamlReader]::Load($reader)
$script:progressWindow.Icon = New-PrintMasterIcon
Set-WindowTheme $script:progressWindow
$script:progressWindow.FindName('progressBar').Maximum = $script:progressMax

# Prevent closing during work
$script:progressWindow.Add_Closing({
	if (-not $script:progressWindow.FindName('btnDone').IsEnabled) {
		$_.Cancel = $true
	}
})

$script:progressWindow.FindName('btnCopyPassword').Add_Click({
	if ($script:hasSetClipboard) {
		Set-Clipboard -Value $scanPass
	}
	else {
		[System.Windows.Forms.Clipboard]::SetText($scanPass)
	}
	Write-Verbose "Copied scan password to clipboard"
	[System.Windows.MessageBox]::Show('Password has been copied to Clipboard')
})

$script:progressWindow.FindName('btnDone').Add_Click({
	$script:progressWindow.Close()
})

$script:progressWindow.Show()
$script:percent = 0
$script:hasErrors = $false

function Get-ErrorRemediation([string]$errorText) {
	switch -Regex ($errorText) {
		'InvalidPassword|password.*(policy|requirements)|\b2245\b' { return $script:Remediation.PasswordPolicy }
		'ProtectedAccount|AccountMembershipCheckFailed' { return "Choose a different username. Scans will not change an account in the local Administrators group or when its membership cannot be safely verified." }
		'trust relationship'        { return $script:Remediation.TrustRelation }
		'Access is denied|access denied|UnauthorizedAccess' { return $script:Remediation.AccessDenied }
		'share.*in use|being used'  { return $script:Remediation.ShareInUse }
		default { return $null }
	}
}

function Set-ProgressBar($text, $sleep = 250) {
	$script:progressWindow.FindName('txtStatus').Text = $text
	$script:percent += 1
	$script:progressWindow.FindName('progressBar').Value = [Math]::Min($script:percent, $script:progressMax)
	$script:details.Insert(0, $text) | Out-Null
	$script:progressWindow.FindName('lstDetails').Items.Insert(0, $text) | Out-Null
	Write-Verbose "Progress Text: $text"
	[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
	Start-Sleep -Milliseconds $sleep
}

function Show-StepResult($result) {
	Set-ProgressBar $result.Message
	if ($result.Error) {
		$script:hasErrors = $true
		Set-ProgressBar "  Error: $($result.Error)" 0
		$tip = Get-ErrorRemediation "$($result.ErrorId) $($result.Error)"
		if (-not $tip) {
			$tip = 'Review the error details and correct the reported issue, then run setup again. If the problem persists, share the error details with your administrator.'
		}
		Set-ProgressBar "  Tip: $tip" 0
		$title = 'Scans Setup - Step Failed'
		$message = "$($result.Message)`n`n$($result.Error)"
		if ($result.ErrorId -match 'InvalidPassword') {
			$title = 'Scan Account Password Rejected'
			$message = "Windows rejected the password for the scan account. It may not meet the effective local or domain password policy."
		}
		Show-ErrorPopup -Owner $script:progressWindow -Title $title -Message $message -Remediation $tip
	}
}

function Show-PasswordRetryDialog {
	param([string]$ErrorText)

	[xml]$passwordRetryXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="PrintMaster Scans - Password Rejected" Width="480" SizeToContent="Height"
        WindowStartupLocation="CenterOwner" ResizeMode="NoResize" ShowInTaskbar="False"
        Background="$($script:thBg)" Foreground="$($script:thFg)" FontFamily="Segoe UI" FontSize="13">
$($script:themeResources)
    <StackPanel Margin="12">
        <TextBlock Text="Windows rejected the scan-account password. Setup is paused." TextWrapping="Wrap" Margin="0,0,0,8"/>
        <TextBlock Name="txtError" TextWrapping="Wrap" Margin="0,0,0,8"/>
        <TextBlock Name="txtRemediation" TextWrapping="Wrap" Margin="0,0,0,12"/>
        <TextBlock Text="New password:" Margin="0,0,0,6"/>
        <DockPanel Margin="0,0,0,12">
            <Button DockPanel.Dock="Right" Name="btnGenerate" Content="Generate" Width="85" Margin="8,0,0,0"/>
            <TextBox Name="txtPassword"/>
        </DockPanel>
        <TextBlock Text="Retry resumes account setup before any remaining steps. Cancel stops setup." TextWrapping="Wrap" Margin="0,0,0,12"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button Name="btnRetry" Content="Retry" Width="75" Height="24" IsDefault="True" Margin="0,0,8,0"/>
            <Button Name="btnCancel" Content="Cancel setup" Width="100" Height="24" IsCancel="True"/>
        </StackPanel>
    </StackPanel>
</Window>
"@
	$passwordWindow = [Windows.Markup.XamlReader]::Load([System.Xml.XmlNodeReader]::new($passwordRetryXaml))
	$passwordWindow.Owner = $script:progressWindow
	$passwordWindow.Icon = New-PrintMasterIcon
	Set-WindowTheme $passwordWindow
	$passwordWindow.FindName('txtError').Text = $ErrorText
	$passwordWindow.FindName('txtRemediation').Text = $script:Remediation.PasswordPolicy
	$passwordWindow.FindName('txtPassword').Add_TextChanged({
		$passwordWindow.FindName('btnRetry').IsEnabled = -not [string]::IsNullOrWhiteSpace($passwordWindow.FindName('txtPassword').Text)
	})
	$passwordWindow.FindName('txtPassword').Text = $script:scanPass
	$passwordWindow.FindName('btnGenerate').Add_Click({
		$passwordWindow.FindName('txtPassword').Text = New-RandomPassword
	})
	$passwordWindow.FindName('btnRetry').Add_Click({ $passwordWindow.DialogResult = $true })
	if ($passwordWindow.ShowDialog() -eq $true) {
		return $passwordWindow.FindName('txtPassword').Text
	}
	return $null
}

# Gather computer details
Set-ProgressBar "Gathering local computer details"
if ($script:hasCimInstance) {
	$computerDetails = Get-CimInstance -ClassName Win32_ComputerSystem
}
else {
	$computerDetails = Get-WmiObject -Class Win32_ComputerSystem
}
$domainJoined = $computerDetails.PartOfDomain

# Create/update scans user account and hide from login screen
$scanUserConfigured = $true
$setupCancelled = $false
$setupCancelReason = 'password rejection'
if ($createUser -or $hideUser) {
	do {
		$userResults = @(Initialize-ScanUser -Username $scanUser -Password $scanPass -Description $description -HideFromLogin $hideUser -DomainJoined $domainJoined)
		$accountCancellation = $userResults | Where-Object { $_.SetupCanceled } | Select-Object -First 1
		if ($accountCancellation) {
			$setupCancelled = $true
			$setupCancelReason = 'existing account confirmation was declined'
			break
		}
		$passwordFailure = $userResults | Where-Object { $_.AccountSetupFailed -and ($_.ErrorId -match 'InvalidPassword' -or $_.Error -match '\b2245\b') } | Select-Object -First 1
		if ($passwordFailure) {
			$newPassword = Show-PasswordRetryDialog -ErrorText $passwordFailure.Error
			if ($null -eq $newPassword) {
				$setupCancelled = $true
				break
			}
			$script:scanPass = $newPassword
		}
	} while ($passwordFailure)
	if (-not $setupCancelled) {
		foreach ($r in $userResults) { Show-StepResult $r }
	}
	$scanUserConfigured = @($userResults | Where-Object { $_.AccountSetupFailed }).Count -eq 0
}

if ($setupCancelled) {
	if ($accountCancellation) { Show-StepResult $accountCancellation }
	Set-ProgressBar "Setup canceled because $setupCancelReason; remaining steps were not run." 0
	$script:progressWindow.Title = 'PrintMaster Scans Setup - Canceled'
}
else {
	if (-not $scanUserConfigured) {
		Show-StepResult @{ Status = 'Skipped'; Message = 'Skipped scan-user folder permissions and SMB share configuration because account setup failed'; Error = $null }
	}

	$scanFolderConfigured = $true
	if ($createFolder -eq $true) {
		$folderResults = @(Initialize-ScanFolder -FolderPath $folderPath -ScanUser $scanUser -SetPermissions ($setPermissions -and $scanUserConfigured) -DomainJoined $domainJoined)
		foreach ($r in $folderResults) { Show-StepResult $r }
		$scanFolderConfigured = @($folderResults | Where-Object { $_.FolderSetupFailed }).Count -eq 0
		if (-not $scanFolderConfigured) {
			Show-StepResult @{ Status = 'Skipped'; Message = 'Skipped SMB share configuration because folder setup failed or was canceled'; Error = $null }
		}
	}

	if ($setShare -eq $true -and $scanUserConfigured -and $scanFolderConfigured) {
		$shareResult = Initialize-ScanShare -ShareName $shareName -FolderPath $folderPath -ScanUser $scanUser
		Show-StepResult $shareResult
	}

	if ($createShortcut -eq $true) {
		$shortcutResult = Initialize-DesktopShortcut -FolderPath $folderPath -IconPath $iconPath -Description $description
		Show-StepResult $shortcutResult
	}

	if ($checkNetworkSettings -eq $true) {
		$netResults = Set-NetworkConfiguration -DomainJoined $domainJoined
		foreach ($r in $netResults) { Show-StepResult $r }
	}

	Set-ProgressBar "Finished" 0
	$script:progressWindow.FindName('progressBar').Value = $script:progressMax
	if ($script:hasErrors) {
		$script:progressWindow.Title = 'PrintMaster Scans Setup - Completed with errors'
		$script:progressWindow.FindName('txtStatus').Text = 'Completed with errors (see details above)'
	}
	else {
		$script:progressWindow.Title = 'PrintMaster Scans Setup - Finished'
	}
}
$script:progressWindow.FindName('btnDone').IsEnabled = $true
if ($createUser -and $scanUserConfigured) { $script:progressWindow.FindName('btnCopyPassword').IsEnabled = $true }
[System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)

# Block until user closes the progress window
$frame = [System.Windows.Threading.DispatcherFrame]::new()
$script:progressWindow.Add_Closed({ $frame.Continue = $false })
[System.Windows.Threading.Dispatcher]::PushFrame($frame)
if ($Elevated) { Exit 0 }
