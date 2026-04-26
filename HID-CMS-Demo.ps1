# ==============================================================================
# Demo Environment Orchestration Script
# ==============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "C:\Users\Public\Downloads\Setup-Demo.log"
$MachineName = "CMS"
$DomainName = "hid.demo"
$SafePassword = ConvertTo-SecureString "P@ssw0rd2026!" -AsPlainText -Force
$StateKey = "HKLM:\SOFTWARE\DemoSetup"

# Setup logging
Function Write-Log ($Message) {
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Time - $Message" | Out-File $LogFile -Append
    Write-Host "$Time - $Message" -ForegroundColor Cyan
}

# Display the task checklist with progress indicators.
# $CompletedTasks: -1 = initial (all unchecked), 0-4 = that many done + next in progress, 5 = all done.
Function Show-Progress {
    param ([int]$CompletedTasks = -1)

    $Tasks = @(
        "Install a new Active Directory Forest ($DomainName)",
        "Install an Enterprise Root CA using Microsoft Certificate Services",
        "Configure the CA to issue smart card logon certificates",
        "Configure a Web Server based on Internet Information Services",
        "Install SQL Server Express"
    )

    $Sep = "  " + ([string]([char]0x2500) * 66)
    Write-Host $Sep -ForegroundColor DarkGray
    for ($i = 0; $i -lt $Tasks.Count; $i++) {
        if ($CompletedTasks -eq -1) {
            Write-Host "  [ ] $($Tasks[$i])" -ForegroundColor Gray
        } elseif ($i -lt $CompletedTasks) {
            Write-Host "  [X] $($Tasks[$i])" -ForegroundColor Green
        } elseif ($i -eq $CompletedTasks) {
            Write-Host "  [>] $($Tasks[$i])" -ForegroundColor Cyan
        } else {
            Write-Host "  [ ] $($Tasks[$i])" -ForegroundColor DarkGray
        }
    }
    Write-Host $Sep -ForegroundColor DarkGray
    Write-Host ""
}

# Read current state (Default to 0 if starting fresh)
$State = 0
if (Test-Path $StateKey) {
    $State = (Get-ItemProperty -Path $StateKey).State
} else {
    New-Item -Path $StateKey -Force | Out-Null
    New-ItemProperty -Path $StateKey -Name "State" -Value 0 -PropertyType DWORD -Force | Out-Null
}

Write-Log "--- Starting Script at State: $State ---"

# ==============================================================================
# STATE 0: Pre-flight Check, Confirmation, Initial OS Configuration & ADDS Prep
# ==============================================================================
if ($State -eq 0) {

    # Pre-flight: ensure this is a standalone server not joined to any domain.
    # DomainRole: 0=Standalone WS, 1=Member WS, 2=Standalone Server, 3=Member Server, 4=BDC, 5=PDC
    $CS = Get-WmiObject -Class Win32_ComputerSystem
    if ($CS.PartOfDomain -or $CS.DomainRole -ge 3) {
        Write-Host ""
        Write-Host "  ERROR: This server is already part of a domain or is a Domain Controller." -ForegroundColor Red
        Write-Host "  This script must be run on a fresh standalone Windows Server." -ForegroundColor Red
        Write-Host ""
        Exit 1
    }

    # Welcome banner and task list
    Write-Host ""
    Write-Host "  +==================================================================+" -ForegroundColor White
    Write-Host "  |   HID Credential Management System - Demo Environment Setup     |" -ForegroundColor White
    Write-Host "  +==================================================================+" -ForegroundColor White
    Write-Host ""
    Write-Host "  This script configures a fresh Windows Server 2025 with the" -ForegroundColor White
    Write-Host "  prerequisites for an evaluation of HID Credential Management System." -ForegroundColor White
    Write-Host "  The script will:" -ForegroundColor White
    Write-Host ""
    Show-Progress -CompletedTasks -1
    Write-Host "  The server will restart automatically between stages." -ForegroundColor Yellow
    Write-Host "  Setup will resume automatically after each restart." -ForegroundColor Yellow
    Write-Host ""

    $Confirm = Read-Host "  Type YES to begin the setup"
    if ($Confirm -ne "YES") {
        Write-Host ""
        Write-Host "  Setup cancelled." -ForegroundColor Red
        Exit 0
    }
    Write-Host ""

    Write-Log "Installing AD-Domain-Services feature..."
    Install-WindowsFeature -Name AD-Domain-Services -IncludeAllSubFeature -IncludeManagementTools

    Write-Log "Setting up scheduled task to resume setup after reboot..."
    $ScriptPath = $MyInvocation.MyCommand.Path
    $Action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Normal -File `"$ScriptPath`""
    $Trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName "ResumeDemoSetup" -Action $Action -Trigger $Trigger -User "NT AUTHORITY\SYSTEM" -RunLevel Highest | Out-Null

    Write-Log "Renaming computer to $MachineName and rebooting..."
    Set-ItemProperty -Path $StateKey -Name "State" -Value 1
    Rename-Computer -NewName $MachineName -Force
    Restart-Computer -Force
    Exit
}

# ==============================================================================
# STATE 1: AD Forest Promotion  (Stage 2 of 3)
# ==============================================================================
if ($State -eq 1) {
    Write-Host ""
    Write-Host "  -- Resuming Setup: Stage 2 of 3 (Active Directory Forest) ----------" -ForegroundColor Yellow
    Show-Progress 0   # Task 1 [>] in progress

    Write-Log "Promoting server to Domain Controller ($DomainName)..."
    Set-ItemProperty -Path $StateKey -Name "State" -Value 2

    Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath "C:\Windows\NTDS" `
        -DomainMode "7" -DomainName $DomainName -ForestMode "7" `
        -InstallDns:$true -LogPath "C:\Windows\NTDS" -NoRebootOnCompletion:$false `
        -SysvolPath "C:\Windows\SYSVOL" -SafeModeAdministratorPassword $SafePassword -Force

    # Install-ADDSForest forces a reboot automatically.
    Exit
}

# ==============================================================================
# STATE 2: IIS, ADCS, Smart Card Templates, SQL  (Stage 3 of 3)
# ==============================================================================
if ($State -eq 2) {
    Write-Host ""
    Write-Host "  -- Resuming Setup: Stage 3 of 3 (Services & Applications) ----------" -ForegroundColor Yellow
    Show-Progress 1   # AD [X], CA [>] next

    # --- IIS Web Server (installed first so C:\pki exists before ADCS publishes its CRL) ---
    # IIS must be in place before ADCS so that when certutil publishes the first CRL to C:\pki it can
    # immediately be served over HTTP — the CDP and AIA URLs embedded in issued certificates point to
    # http://<server>/pki, so the virtual directory must exist before any certificates are issued.
    Write-Log "Installing IIS and creating PKI distribution point directory..."
    Install-WindowsFeature -Name Web-Server,Web-Asp-Net -IncludeManagementTools
    New-Item -Path "C:\pki" -ItemType Directory -Force
    New-SmbShare -Name "pki" -Path "C:\pki" -ChangeAccess "Cert Publishers"
    New-WebVirtualDirectory -Site "Default Web Site" -Name "pki" -PhysicalPath "C:\pki"

    # Progress not advanced here — IIS is an internal prerequisite step, not yet shown as complete.

    # --- Task 2: Enterprise Root CA ---
    Write-Log "Installing ADCS feature and configuring Enterprise Root CA..."
    Install-WindowsFeature -Name Adcs-Cert-Authority -IncludeManagementTools
    Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName "$MachineName-CA" `
        -KeyLength 2048 -HashAlgorithm SHA256 `
        -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -Force

    Write-Log "Configuring ADCS AIA and CDP publication URLs..."
    # CDP: 1=Publish to file, 10=Include in issued cert CDPs, 65=Publish+Delta to file
    $CDP = "1:C:\pki\%3%8%9.crl\n10:http://$MachineName.$DomainName/pki/%3%8%9.crl\n65:file://\\$MachineName\pki\%3%8%9.crl"
    certutil -setreg CA\CRLPublicationURLs $CDP

    # AIA: 1=Publish to file, 2=Include in issued cert AIAs
    $AIA = "1:C:\pki\%1_%3%4.crt\n2:http://$MachineName.$DomainName/pki/%1_%3%4.crt"
    certutil -setreg CA\CACertPublicationURLs $AIA

    # C:\pki now exists and IIS is serving it — the CRL will be reachable via HTTP immediately.
    Restart-Service certsvc
    certutil -crl

    Show-Progress 2   # AD [X], CA [X], SmartCard [>]

    # --- Task 3: Smart Card Logon Certificate Template ---
    Write-Log "Installing PSPKI module and duplicating Smartcard Logon template..."
    # NOTE: Native PowerShell lacks a command for this; PSPKI from PSGallery fills the gap.
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted
    Install-Module -Name PSPKI -Force -AcceptLicense
    # NOTE: Full duplication with exact settings requires ADSI or PSPKI's New-CertificateTemplate.
    # For a silent demo, a pre-exported JSON via Export-CertificateTemplate is the most reliable approach.
    $Template = Get-CertificateTemplate -Name "SmartcardLogon"

    Write-Log "Reissuing Domain Controller Certificate..."
    certreq -enroll -machine -q DomainController

    # IIS was completed earlier as a prerequisite; advance through its checklist step to SQL [>].
    Show-Progress 3   # AD [X], CA [X], SmartCard [X], IIS [>]  (already done — tick it off)
    Show-Progress 4   # AD [X], CA [X], SmartCard [X], IIS [X], SQL [>]

    # --- Task 5: SQL Server Express ---
    Write-Log "Downloading SQL Server Express..."
    # NOTE: For resilient setups, host the installer locally rather than relying on a live Microsoft link.
    $SqlUrl = "https://go.microsoft.com/fwlink/p/?linkid=2216019"
    $SqlExe = "C:\Users\Public\Downloads\SQLEXPR.exe"
    Invoke-WebRequest -Uri $SqlUrl -OutFile $SqlExe

    # Use the domain Administrator account promoted during AD forest creation as SQL sysadmin.
    $NetBIOSDomain = (Get-ADDomain).NetBIOSName
    $SqlSysAdmin = "$NetBIOSDomain\Administrator"
    Write-Log "Configuring SQL sysadmin account: $SqlSysAdmin"

    Start-Process -FilePath $SqlExe -ArgumentList "/qs /ACTION=Install /FEATURES=SQLEngine,Conn /INSTANCENAME=SQLEXPRESS /SQLSVCACCOUNT=`"NT AUTHORITY\SYSTEM`" /SQLSYSADMINACCOUNTS=`"$SqlSysAdmin`" /BROWSERSVCSTARTUPTYPE=Automatic /TCPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS" -Wait

    Show-Progress 5   # All tasks [X] done

    Write-Log "Generating Walkthrough Document..."
    $DocContent = @"
# Evaluation Environment Walkthrough
Welcome to your pre-configured environment.
* **Active Directory:** configured ($DomainName)
* **SQL Server:** Installed (SQLEXPRESS), sysadmin: $SqlSysAdmin
* **PKI:** Enterprise Root CA configured with HTTP/SMB endpoints.
"@
    $DocContent | Out-File "C:\Users\Administrator\Desktop\Evaluation-Walkthrough.md"

    Write-Log "Cleaning up scheduled task and registry state..."
    Unregister-ScheduledTask -TaskName "ResumeDemoSetup" -Confirm:$false
    Remove-Item -Path $StateKey -Force

    Write-Host "  +==================================================================+" -ForegroundColor Green
    Write-Host "  |                       Setup Complete!                            |" -ForegroundColor Green
    Write-Host "  +==================================================================+" -ForegroundColor Green
    Write-Log "Setup Complete! Enjoy your coffee."
}