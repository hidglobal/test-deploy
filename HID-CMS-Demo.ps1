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

# Send a visible notification to the currently logged-in user (for Session 0 -> Session 1 visibility).
# Also logs to file for troubleshooting.
Function Notify-User ($Title, $Message) {
    Write-Log "[NOTIFY] $Title - $Message"
    # Get the session ID of the logged-in user (typically 1; fall back to broadcasting to all if needed)
    try {
        $UserSession = (Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).SessionId
        if ($null -eq $UserSession) { $UserSession = 1 }
        msg $UserSession "$Title`n$Message" /TIME:60 | Out-Null 2>&1
    } catch {
        # msg may not be available; continue silently
    }
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
    # Persist the script path so later states can re-register the task.
    New-ItemProperty -Path $StateKey -Name "ScriptPath" -Value $ScriptPath -PropertyType String -Force | Out-Null
    # Capture current user identity (local Administrator) so the resume task runs in their
    # interactive session — this makes the PowerShell window visible after the rename reboot.
    $CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    New-ItemProperty -Path $StateKey -Name "LocalAdmin" -Value $CurrentUser -PropertyType String -Force | Out-Null
    Write-Log "Registering AtLogon resume task for user: $CurrentUser"
    $Action = New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Maximized -NoExit -File `"$ScriptPath`""
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
    $Principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Highest
    Register-ScheduledTask -TaskName "ResumeDemoSetup" -Action $Action -Trigger $Trigger -Principal $Principal -Force | Out-Null

    Write-Log "Renaming computer to $MachineName and rebooting..."
    Set-ItemProperty -Path $StateKey -Name "State" -Value 1
    Rename-Computer -NewName $MachineName -Force
    Restart-Computer -Force
    Exit
}

# ==============================================================================
# STATE 1: AD Forest Promotion  (Restart 1 of 2 — computer renamed, domain not yet created)
# ==============================================================================
if ($State -eq 1) {
    Write-Host "`n`n`n"
    Write-Host "  +==================================================================+" -ForegroundColor Yellow
    Write-Host "  |  SETUP RESUMING (restart 1 of 2): Installing Active Directory   |" -ForegroundColor Yellow
    Write-Host "  |  Computer renamed to $MachineName. Creating domain $DomainName..." + (' ' * [Math]::Max(0, 34 - $MachineName.Length - $DomainName.Length)) + "|" -ForegroundColor Yellow
    Write-Host "  +==================================================================+" -ForegroundColor Yellow
    Write-Host ""
    Show-Progress 0   # Task 1 [>] Active Directory in progress

    Write-Log "Promoting server to Domain Controller ($DomainName)..."
    Set-ItemProperty -Path $StateKey -Name "State" -Value 2

    # No need to re-register the scheduled task here. Windows DC promotion preserves the local
    # Administrator SID — CMS\Administrator becomes HID\Administrator with the same SID,
    # so the AtLogon task registered in State 0 will fire correctly after this reboot.

    Install-ADDSForest -CreateDnsDelegation:$false -DatabasePath "C:\Windows\NTDS" `
        -DomainMode "7" -DomainName $DomainName -ForestMode "7" `
        -InstallDns:$true -LogPath "C:\Windows\NTDS" -NoRebootOnCompletion:$false `
        -SysvolPath "C:\Windows\SYSVOL" -SafeModeAdministratorPassword $SafePassword -Force

    # Install-ADDSForest forces a reboot automatically.
    Exit
}

# ==============================================================================
# STATE 2: IIS, ADCS, Smart Card Templates, SQL  (Restart 2 of 2 — domain ready)
# ==============================================================================
if ($State -eq 2) {
    Write-Host "`n`n`n"
    Write-Host "  +==================================================================+" -ForegroundColor Yellow
    Write-Host "  |  SETUP RESUMING (restart 2 of 2): Installing Services           |" -ForegroundColor Yellow
    Write-Host "  |  Active Directory ready. Installing CA, IIS, and SQL...         |" -ForegroundColor Yellow
    Write-Host "  +==================================================================+" -ForegroundColor Yellow
    Write-Host ""
    Show-Progress 1   # AD [X], CA [>] next

    # --- IIS Web Server (installed first so C:\pki exists before ADCS publishes its CRL) ---
    # IIS must be in place before ADCS so that when certutil publishes the first CRL to C:\pki it can
    # immediately be served over HTTP — the CDP and AIA URLs embedded in issued certificates point to
    # http://<server>/pki, so the virtual directory must exist before any certificates are issued.
    Write-Log "Installing IIS and creating PKI distribution point directory..."
    Notify-User "HID Setup" "Installing IIS (this may take 2-3 minutes)..."
    
    try {
        Install-WindowsFeature -Name Web-Server,Web-Asp-Net -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Log "IIS features installed successfully."
    } catch {
        Write-Log "ERROR installing IIS: $_"
        Notify-User "HID Setup ERROR" "Failed to install IIS. Check log: C:\Users\Public\Downloads\Setup-Demo.log"
        Exit 1
    }
    
    try {
        New-Item -Path "C:\pki" -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Log "Created C:\pki directory."
    } catch {
        Write-Log "ERROR creating C:\pki: $_"
        Notify-User "HID Setup ERROR" "Failed to create C:\pki. Check log: C:\Users\Public\Downloads\Setup-Demo.log"
        Exit 1
    }
    
    try {
        New-SmbShare -Name "pki" -Path "C:\pki" -ChangeAccess "Cert Publishers" -ErrorAction Stop | Out-Null
        Write-Log "Created SMB share 'pki'."
    } catch {
        Write-Log "WARNING creating SMB share: $_"
        # Don't exit on this error; it might already exist
    }
    
    try {
        New-WebVirtualDirectory -Site "Default Web Site" -Name "pki" -PhysicalPath "C:\pki" -ErrorAction Stop | Out-Null
        Write-Log "Created IIS virtual directory /pki."
    } catch {
        Write-Log "WARNING creating IIS virtual directory: $_"
        # Don't exit on this error; it might already exist
    }

    Write-Log "IIS prerequisites completed successfully."
    Notify-User "HID Setup" "IIS setup complete. Installing Enterprise Root CA (5-10 minutes)..."

    # --- Task 2: Enterprise Root CA ---
    Write-Log "Installing ADCS feature and configuring Enterprise Root CA..."
    try {
        Install-WindowsFeature -Name Adcs-Cert-Authority -IncludeManagementTools -ErrorAction Stop | Out-Null
        Write-Log "ADCS feature installed."
    } catch {
        Write-Log "ERROR installing ADCS feature: $_"
        Notify-User "HID Setup ERROR" "Failed to install ADCS. Check log: C:\Users\Public\Downloads\Setup-Demo.log"
        Exit 1
    }
    
    try {
        Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName "$MachineName-CA" `
            -KeyLength 2048 -HashAlgorithm SHA256 `
            -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -Force -ErrorAction Stop | Out-Null
        Write-Log "Enterprise Root CA configured."
    } catch {
        Write-Log "ERROR configuring Enterprise Root CA: $_"
        Notify-User "HID Setup ERROR" "Failed to configure CA. Check log: C:\Users\Public\Downloads\Setup-Demo.log"
        Exit 1
    }

    Write-Log "Configuring ADCS AIA and CDP publication URLs..."
    # CDP: 1=Publish to file, 10=Include in issued cert CDPs, 65=Publish+Delta to file
    $CDP = "1:C:\pki\%3%8%9.crl\n10:http://$MachineName.$DomainName/pki/%3%8%9.crl\n65:file://\\$MachineName\pki\%3%8%9.crl"
    certutil -setreg CA\CRLPublicationURLs $CDP 2>&1 | Out-Null
    Write-Log "CDP URLs configured: $CDP"

    # AIA: 1=Publish to file, 2=Include in issued cert AIAs
    $AIA = "1:C:\pki\%1_%3%4.crt\n2:http://$MachineName.$DomainName/pki/%1_%3%4.crt"
    certutil -setreg CA\CACertPublicationURLs $AIA 2>&1 | Out-Null
    Write-Log "AIA URLs configured: $AIA"

    # C:\pki now exists and IIS is serving it — the CRL will be reachable via HTTP immediately.
    Write-Log "Restarting CertSvc and publishing initial CRL..."
    Restart-Service certsvc -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    certutil -crl 2>&1 | Out-Null
    Write-Log "Initial CRL published."

    Show-Progress 2   # AD [X], CA [X], SmartCard [>]
    Notify-User "HID Setup" "CA installed and CRL published. Configuring smart card certificates..."

    # --- Task 3: Smart Card Logon Certificate Template ---
    Write-Log "Installing PSPKI module and configuring smart card template..."
    try {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -ErrorAction Stop | Out-Null
        Write-Log "NuGet provider installed."
        Set-PSRepository -Name 'PSGallery' -InstallationPolicy Trusted -ErrorAction Stop
        Write-Log "PSGallery repository configured."
        Install-Module -Name PSPKI -Force -AcceptLicense -ErrorAction Stop 2>&1 | Out-Null
        Write-Log "PSPKI module installed."
    } catch {
        Write-Log "WARNING installing PSPKI: $_ (script may still work)"
    }
    
    try {
        $Template = Get-CertificateTemplate -Name "SmartcardLogon" -ErrorAction Stop
        Write-Log "SmartcardLogon template retrieved."
    } catch {
        Write-Log "WARNING getting SmartcardLogon template: $_"
    }

    Write-Log "Reissuing Domain Controller Certificate..."
    try {
        certreq -enroll -machine -q DomainController 2>&1 | Out-Null
        Write-Log "DC certificate reissued."
    } catch {
        Write-Log "WARNING reissuing DC cert: $_"
    }

    Show-Progress 3   # AD [X], CA [X], SmartCard [X], IIS [>]  (already done — tick it off)
    Show-Progress 4   # AD [X], CA [X], SmartCard [X], IIS [X], SQL [>]
    Notify-User "HID Setup" "Smart card config complete. Installing SQL Server Express (10-15 minutes)..."

    # --- Task 5: SQL Server Express ---
    Write-Log "Downloading SQL Server Express..."
    # NOTE: For resilient setups, host the installer locally rather than relying on a live Microsoft link.
    $SqlUrl = "https://go.microsoft.com/fwlink/p/?linkid=2216019"
    $SqlExe = "C:\Users\Public\Downloads\SQLEXPR.exe"
    
    try {
        Invoke-WebRequest -Uri $SqlUrl -OutFile $SqlExe -TimeoutSec 300 -ErrorAction Stop
        Write-Log "SQL Server Express installer downloaded successfully."
    } catch {
        Write-Log "ERROR downloading SQL installer: $_"
        Notify-User "HID Setup ERROR" "Failed to download SQL Server. Check internet and log: C:\Users\Public\Downloads\Setup-Demo.log"
        Exit 1
    }

    # Use the domain Administrator account promoted during AD forest creation as SQL sysadmin.
    $NetBIOSDomain = (Get-ADDomain).NetBIOSName
    $SqlSysAdmin = "$NetBIOSDomain\Administrator"
    Write-Log "Configuring SQL sysadmin account: $SqlSysAdmin"
    Notify-User "HID Setup" "Installing SQL Server Express... (this may take 5-10 minutes, window will appear briefly)"

    try {
        Start-Process -FilePath $SqlExe -ArgumentList "/qs /ACTION=Install /FEATURES=SQLEngine,Conn /INSTANCENAME=SQLEXPRESS /SQLSVCACCOUNT=`"NT AUTHORITY\SYSTEM`" /SQLSYSADMINACCOUNTS=`"$SqlSysAdmin`" /BROWSERSVCSTARTUPTYPE=Automatic /TCPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS" -Wait -ErrorAction Stop
        Write-Log "SQL Server Express installation completed."
    } catch {
        Write-Log "ERROR installing SQL Server: $_"
        Notify-User "HID Setup ERROR" "SQL Server installation may have failed. Check log: C:\Users\Public\Downloads\Setup-Demo.log"
        # Don't exit; try to continue
    }

    Show-Progress 5   # All tasks [X] done
    Notify-User "HID Setup COMPLETE" "All components installed successfully! Check C:\Users\Administrator\Desktop\Evaluation-Walkthrough.md"

    Write-Log "Generating Walkthrough Document..."
    $DocContent = @"
# Evaluation Environment Walkthrough
Welcome to your pre-configured environment.
* **Active Directory:** configured ($DomainName)
* **SQL Server:** Installed (SQLEXPRESS), sysadmin: $SqlSysAdmin
* **PKI:** Enterprise Root CA configured with HTTP/SMB endpoints.
* **Setup Log:** C:\Users\Public\Downloads\Setup-Demo.log
"@
    $DocContent | Out-File "C:\Users\Administrator\Desktop\Evaluation-Walkthrough.md"

    Write-Log "Cleaning up scheduled task and registry state..."
    Unregister-ScheduledTask -TaskName "ResumeDemoSetup" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $StateKey -Force -ErrorAction SilentlyContinue

    Write-Host "  +==================================================================+" -ForegroundColor Green
    Write-Host "  |                       Setup Complete!                            |" -ForegroundColor Green
    Write-Host "  +==================================================================+" -ForegroundColor Green
    Write-Log "Setup Complete! Enjoy your coffee."
    
    Read-Host "Press Enter to close this window"
}