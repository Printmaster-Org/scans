<div align="center">
  <img src="img/banner.png" alt="PrintMaster Scans banner" width="900">

[![Latest release](https://img.shields.io/github/v/release/Printmaster-Org/scans?label=release&color=268BD2&style=flat)](https://github.com/Printmaster-Org/scans/releases/latest)
[![CI](https://github.com/Printmaster-Org/scans/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Printmaster-Org/scans/actions/workflows/ci.yml)
[![Release downloads](https://img.shields.io/github/downloads/Printmaster-Org/scans/total?color=2AA198&style=flat)](https://github.com/Printmaster-Org/scans/releases)
[![Documentation](https://img.shields.io/badge/docs-scan--to--SMB-268BD2?style=flat)](https://docs.printmaster.work/guides/scans/)
![Profile Views](https://komarev.com/ghpvc/?username=mstrhakr-scans&label=views&color=268BD2&style=flat)

</div>

A lightweight PowerShell utility that configures a Windows PC for network scanning in one click. Creates a dedicated scan user, shared folder, firewall rules, and desktop shortcut — no manual setup required.

Provided by [PrintMaster](https://printmaster.work/). This is a standalone utility; no PrintMaster Agent or Server is required.

**[Get started](https://scans.printmaster.work/)** · **[Setup and troubleshooting guide](https://docs.printmaster.work/guides/scans/)**

## Quick Start

Paste the following into an **Administrator** PowerShell window:

```powershell
irm https://scans.printmaster.work/scans.ps1 | iex
```

### Stable releases and existing commands

The utility is maintained at **printmaster-org/scans**. The root script and the website use one shared loader implementation. The organization raw URL is also supported:

```powershell
irm https://raw.githubusercontent.com/printmaster-org/scans/main/scans.ps1 | iex
```

The new loader selects the promoted stable release from the site's manifest, downloads its version-specific GitHub asset, checks SHA-256, and only then executes it. A version can be selected explicitly:

```powershell
& ([scriptblock]::Create((irm https://scans.printmaster.work/scans.ps1))) -Version 'v2.1.0'
```

Pinned commands still require the loader and manifest to be available online. The old `mstrhakr/scans` raw URL relies on GitHub's repository-transfer redirect and now also runs the loader, not development utility code. If the site or manifest is unavailable, setup stops rather than falling back to `main`.

See the [transfer and release guide](docs/DEPLOYMENT.md) for rollout order, DNS, publishing, and cutover verification.

## Requirements

| Requirement | Details |
| --- | --- |
| **OS** | Windows 11 primary; Windows 10 22H2 best-effort compatibility |
| **PowerShell** | Windows PowerShell 5.1 or PowerShell 7 |
| **Privileges** | Must be run as Administrator |
| **Network** | Internet access to the release site and GitHub for the loader |

Windows 7/8/8.1 and Windows Server are not validated support targets. Windows 10 compatibility is not a claim of continued Microsoft support. Legacy command fallbacks remain for now; removing them is a separate change.

## What It Does

This script completely sets up the user environment for quick scan-to-SMB:

- Creates a dedicated scan user account or, after confirmation, updates an existing non-administrator account (hidden from login screen)
- Creates the scan folder at **C:\scans** (configurable)
- Sets restricted advanced folder permissions for the scan account, with Full Control for the receiving Windows user, local Administrators, and SYSTEM
- Shares the folder via SMB as **scans** (configurable)
- Creates a desktop shortcut to the scan folder
- Sets the network category to Private (non-domain PCs)
- Enables File and Printer Sharing firewall rules
- Enables Network Discovery firewall rules

All settings are configurable through the UI before execution.

## Usage

First choose the inputs — the password is randomly generated with a cryptographically secure generator. Screenshots use example credentials and simulated progress/completion states rendered from the current app UI; they do not show a real machine setup. Do not reuse the example password.

![Setup](img/scans-setup.png)

The UI automatically matches your Windows theme (light or dark).

App windows use the PrintMaster logo and attribution. The scan-folder desktop shortcut keeps its original scan icon. The self-contained utility embeds the window logo as WPF vector artwork matching [site/logo.svg](site/logo.svg), so branding needs no extra download.

![Setup Light Theme](img/scans-setup-theme.png)

Click the gear icon to enable/disable individual steps.

Choosing **Cancel** or closing the initial setup window exits normally without running the selected setup steps or displaying a loader error.

![Settings](img/scans-settings.png)

Wait for the utility to complete all changes.

![Loading](img/scans-loading.png)

When finished, copy the password and click Done.

![Finished](img/scans-finished.png)

### Existing account safety

Before changing the password of an existing local account, Scans explains the impact and asks for confirmation. Declining cancels setup without changing the account. Accounts in the local Administrators group are never changed; choose another username or cancel setup. If Scans cannot verify group membership, it also refuses to change the account.

### Themed dialogs

Since v2.2.0, Scans uses a shared Solarized light/dark dialog shell for account confirmation, folder access, password retry, startup/step errors, and clipboard confirmation. Dialogs carry the PrintMaster logo and attribution, center on their parent when available, and keep longer content scrollable with the action buttons visible.

Existing-account confirmation offers **Change password** and **Cancel setup**, with Cancel as the keyboard default. Closing the window or pressing Escape is not consent. The same shell hosts text fields and custom actions: folder access keeps its recipient field, and password retry retains **Generate**, blank-input validation, **Retry**, and **Cancel setup**.

Shared dialog footers place an outlined, neutral **Cancel** to the left of the filled, emphasized approval action at the far right. Folder/share permission confirmations initially focus Cancel and do not default Enter to approval. Their permission tables keep themed, readable full-row hover and selection states, including when keyboard focus moves elsewhere; a border distinguishes selection and keyboard focus.

This UI refactor does not implement password masking or secure-state changes. [Issue #29](https://github.com/Printmaster-Org/scans/issues/29) tracks generation, reveal controls, minimizing plaintext copies, command-argument exposure, logging safeguards, and clipboard cleanup. Until that work ships, passwords remain visible in entry fields and are held as strings before conversion for local-account cmdlets. Copying places the accepted secret on the clipboard; treat clipboard history/sync and screenshots as potential exposure.

### Folder access review

Available since v2.2.0. Earlier releases granted the scan account Full Control and added Everyone Modify (plus Domain Users Modify on domain-joined PCs) without review.

When **Set folder permissions** is selected, a separate review asks which Windows user should receive scans. It defaults to the user of the desktop session hosting Scans, including an RDP session, not the elevated administrator token. If these identities differ, the dialog explains that **Apply permissions** confirms the receiving user. You can edit the recipient; if no desktop user is detected, you must enter one. The recipient cannot be the scan account.

For a **new folder**, inheritance is disabled and the following Allow rules apply to the folder, subfolders, and files:

| Principal | NTFS rights |
| --- | --- |
| Local scan account | List folder / read data; Create files / write data; Create folders / append data |
| Receiving Windows user | Full Control |
| Local Administrators and SYSTEM | Full Control |

Windows adds `Synchronize` to the scan account's Allow rule. The scan profile does not explicitly grant delete, execute, permission changes, or ownership. Read data can expose existing scans, and write data can allow overwriting them; this is not a write-only drop box or a universal printer-compatibility guarantee.

Neither Everyone nor Domain Users is added by default. **Also grant Everyone Modify** is an explicit, unchecked option for broader NTFS access; it allows other users to read, change, and delete scans. SMB share permissions are separate.

For an **existing folder**, review the displayed ACL. Scans preserves inheritance, custom rules, and protected child ACLs. Explicit Everyone/Domain Users Modify rules and scan-account Full Control rules matching the old utility's exact shape appear as individually selectable cleanup candidates, all unchecked. Old versions did not record rule ownership, so no matching rule is assumed to belong to Scans. Only entries you select are removed; inherited and unrelated entries remain. Retained grants or group memberships can give the scan account more effective access than the new profile. Review **Effective Access** in Windows rather than treating the folder as hardened.

The review separates the recipient, scan-account rights, and folder policy into sections. Existing permissions appear in a table with resolved Windows account names, Allow/Deny indicators, access, explicit/inherited source, and scope. Hover over a row for the SID and exact rights. Deleted or unavailable identities are labeled **Unresolved account** and logged rather than given an invented name. Only eligible cleanup rows offer a **Remove** checkbox. Amber notices highlight permission risks and alternate-admin identities; the optional Everyone grant is under **Advanced**, with an additional warning while selected. This is a presentation of individual ACL entries, not an effective-access calculation.

Canceling the review or failing folder setup skips SMB share configuration and reports an error; independent selected steps can still run. Cancellation happens before creating the folder or writing its ACL, but earlier account changes are not rolled back. If folder creation succeeds and the ACL write fails, the error warns that the folder retains inherited permissions.

Test a real scan before relying on the destination. Some printers require additional attributes, rename, or delete access; do not broaden permissions silently to make a test pass.

### Existing SMB shares

Since v2.2.0, Scans checks the selected local folder and any existing share's path before changing share permissions. A conflicting name opens **Share name conflict**: choose another share name to check or cancel share setup. Scans never repoints, deletes, or recreates the conflicting share. Use the actual share name reported in the progress details for printer configuration.

New shares grant **Change**, not Full, to the explicitly qualified local scan account. This is the SMB permission layer; the folder's NTFS ACL still limits actual file operations. No Everyone share grant is added.

For an existing share pointing to the selected folder, **Review SMB share access** shows resolved account names, Allow/Deny entries, and Read/Change/Full rights. The warning counts other-account grants, scan-account Full grants, and Deny entries. Existing access is preserved unless you explicitly select individual **Remove** checkboxes, all unchecked initially. Deny entries are never removed. When several Allow entries resolve to the same principal, removal is unavailable because Windows' revoke command would remove all of them. Review such ACLs in Windows.

**Apply share access** adds Change only if the scan account does not already have Change or Full. Existing scan Full is retained unless you select its removal; selecting it replaces Full with Change. Other selected Allow grants are removed without resetting the share ACL. Preserved group grants can still give broader access, and Deny entries can still block scanning; this is not an effective-access calculation.

Cancel, Escape, or closing a review makes no share changes. Scans rechecks the share path, scope, and ACL after review and stops if they changed. This is a best-effort concurrency check, not an atomic lock against other administrators. Special/scoped or unreadable shares are refused rather than guessed. If a later write fails, progress details report successful partial changes; no automatic rollback is attempted. Earlier account/folder work is not rolled back, and independent selected steps can continue.

Without SMB cmdlets, Scans uses structured WMI lookup and a create-only WMI operation with an explicit Change ACL for new shares. It refuses to edit existing shares in this mode; configure them in Windows or rerun with SMB cmdlets. Lookup failures are errors, never evidence that a share is absent. Validate both normal and legacy paths on a disposable VM and test real printer delivery before release.

### Password policy errors

Windows can reject a scan-account password that does not meet the effective local or domain Group Policy requirements, even for a local account. A short, lowercase-only password may fail minimum-length or complexity rules.

If Windows reports `InvalidPassword` (or `net user` system error `2245` on older systems), setup pauses and returns to password entry. Enter a replacement or click **Generate**, then **Retry**. Account setup is retried before hiding the account, setting folder permissions, configuring the SMB share, or running any other remaining steps. Your other setup choices are preserved. If Windows rejects another password, you can edit or generate one and retry again.

Choosing **Cancel setup** or closing the password dialog stops the remaining setup steps and leaves **Copy Password** disabled. After a successful retry, setup continues normally and copies only the accepted password when requested.

Use the generated password or a longer password containing uppercase and lowercase letters, numbers, and symbols, without the username. Generated passwords are not guaranteed to satisfy every policy. If the password is still rejected, ask your administrator for the effective minimum length, complexity, history, and any additional restrictions rather than disabling the policy.

### Other setup errors

Startup failures already stop setup with an error popup. Failed setup steps also show a popup and keep the error and remediation in the progress list. Domain trust failures, access denied, and shares in use have specific guidance; unexpected errors retain their original details with general troubleshooting guidance. Successful and skipped steps do not show error popups. Independent steps can continue after a failed step, and the final window reports **Completed with errors**.

## Development and deployment

Both public entrypoints select manually published, versioned GitHub Releases. Merging utility code does not deploy it to users. Merging loader changes does update the raw-main loader; website loader changes require a Pages refresh.

Pushing a stable SemVer tag starts the [Prepare release workflow](.github/workflows/release.yml). It reuses successful main-push CI for that exact commit instead of running tests again, then creates a draft with generated PR-based notes, a pinned command, the utility, metadata, and SHA-256. It waits briefly if main CI is still running and fails if that CI did not pass. Manual dispatch from `main` can retry an existing tag and packages that tag's source, not newer main code. Review/edit the notes, manually test on a disposable Windows VM, then publish the draft in GitHub. User publication triggers the [Pages workflow](.github/workflows/pages.yml), which also reuses existing CI, verifies published assets against their tagged source, and deploys the site plus manifest as generated artifacts. No bot pushes or protection bypasses are needed.

Website source is in [site/](site/); the only loader source is [scans.ps1](scans.ps1). The site builder copies it unchanged into its deployment output. The actual utility is [src/scans.ps1](src/scans.ps1); release packaging selects that file, never the loader. New stable tags must use `vMAJOR.MINOR.PATCH`; historical four-part tags are retained and linked through GitHub Releases, but not exposed through the new checksum-verified channel.

The landing page follows the PrintMaster site's Solarized palette, teal accents, wordmark, and panel styling. Standalone navigation is Scans-focused: its brand links home locally, setup and release links stay on the page, and external Scans resources are explicitly labeled. The footer separates Agent/Server downloads and fleet-monitoring links under "More from PrintMaster." Styles and the logo are local to this repository; navigation works without JavaScript, and the layout supports light/dark preferences, keyboard navigation, and reduced motion. Release rendering and copy buttons use [site/releases.js](site/releases.js).

The landing page loads GoatCounter asynchronously using `https://printmaster-scans.goatcounter.com/count`, matching the analytics integration on the main and documentation sites. This website-only integration does not change the PowerShell loader or utility.

The main website can frame `https://scans.printmaster.work/?embed=1` at `/scans/`. [site/embed.js](site/embed.js) hides this site's header/footer and locks the dark palette only after a handshake from the immediate parent at `https://printmaster.work`. Without that handshake (including direct visits and JavaScript disabled), the full standalone site remains visible. Origin- and source-checked messages report content height and anchor positions to the main site's wrapper. External links open at the top level; setup commands retain their canonical standalone URLs. The main site owns its header/footer and clipboard delegation. Deploy this embed support before the main-site wrapper.

The handshake restricts embed-mode activation, not who can frame the public standalone site. GitHub Pages cannot set a custom HTTP `Content-Security-Policy: frame-ancestors` header; a meta tag cannot enforce it. If the domain later uses a configurable edge/server, set `frame-ancestors 'self' https://printmaster.work` there and avoid `X-Frame-Options: DENY`/`SAMEORIGIN`, which would block the cross-origin main-site frame.

Direct, fast-forward pushes to `main` are permitted; feature branches and pull requests are optional. Run the relevant local tests before pushing. The [CI workflow](.github/workflows/ci.yml) runs syntax checks and mocked Pester tests on Windows using both Windows PowerShell 5.1 and PowerShell 7. Its **Required checks** job passes only when both test jobs succeed, including when using a merge queue. CI also runs after pushes to `main` and can be started manually.

External actions are pinned to full commit SHAs. [Dependabot](.github/dependabot.yml) checks GitHub Actions dependencies weekly and opens update PRs.

`main` does not require pull requests or pre-merge status checks; a repository ruleset only blocks force-pushes and branch deletion. Secret scanning push protection rejects pushes containing detected credentials. Post-push CI detects failures but does not prevent a push or merge. Release preparation and Pages promotion still require successful main-push CI for the selected source commits. Utility changes reach users only through a manually published release; the raw-main loader itself still changes immediately when pushed.

### Running tests locally

Install the pinned development dependency once (it is not needed by users running the utility):

```powershell
Install-Module Pester -RequiredVersion 4.10.1 -Scope CurrentUser -Force -SkipPublisherCheck
```

From the repository root, run either runtime:

```powershell
powershell.exe -NoProfile -STA -File .\tests\Invoke-Tests.ps1
pwsh.exe -NoProfile -STA -File .\tests\Invoke-Tests.ps1
node --test .\tests\site.test.cjs .\tests\embed.test.cjs
```

The [test runner](tests/Invoke-Tests.ps1) fails on syntax errors, failing tests, or an empty test run. The [regression suite](tests/Scans.Tests.ps1) extracts function definitions without running the utility's elevation or setup code. Account, registry, filesystem, SMB, firewall, clipboard-related setup gating, and COM changes are mocked; WPF windows are loaded and selected binding tests render off-screen. Legacy share tests construct real in-memory CIM security descriptors but mock the machine-changing calls. Tests cover password failures, error-popup routing, account visibility, folder setup, share conflicts/reviews/partial failures, network configuration, shortcuts, generated password shape, and setup options. The generator tests do not claim that every generated password satisfies policy.

The [release tests](tests/Releases.Tests.ps1) cover loader selection, verification failures, temporary-file cleanup, package integrity, and site generation. Site rendering tests use Node's built-in test runner with no additional dependencies.

These checks do not replace a manual test of the real GUI and machine configuration on a disposable Windows VM. CI uses a current Windows runner; Windows 10 compatibility and legacy command paths are not exercised on an actual Windows 10 runner.

## Features

- **Solarized theming** — auto-detects Windows light/dark mode, defaults to dark
- **Platform support** — Windows 11 primary; Windows 10 22H2 best-effort compatibility
- **Error remediation** — shared error popups and inline tips for common failures (password policy, trust relationship, access denied, share in use), plus dependent-step safeguards
- **Portable utility** — no application installation; release loader verifies downloads before execution
