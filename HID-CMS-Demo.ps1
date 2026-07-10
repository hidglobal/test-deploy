# ==============================================================================
# Demo Environment Orchestration Script
# ==============================================================================
param(
    [switch]$OnlyTemplates,
    [switch]$SkipConfirmation
)

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

function Test-EnterpriseCAInstalled {
    $Svc = Get-Service -Name "CertSvc" -ErrorAction SilentlyContinue
    if (-not $Svc) { return $false }

    try {
        $CaConfigRoot = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration"
        $Children = Get-ChildItem -Path $CaConfigRoot -ErrorAction Stop | Where-Object { $_.PSChildName -ne "Configuration" }
        return ($Children.Count -ge 1)
    } catch {
        return $false
    }
}

function Test-IISPkiPublished {
    $IisService = Get-Service -Name "W3SVC" -ErrorAction SilentlyContinue
    if (-not $IisService) { return $false }
    if (-not (Test-Path "C:\pki")) { return $false }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        return (Test-Path "IIS:\Sites\Default Web Site\pki")
    } catch {
        return $false
    }
}

function Test-SQLExpressInstalled {
    $Svc = Get-Service -Name "MSSQL`$SQLEXPRESS" -ErrorAction SilentlyContinue
    return ($null -ne $Svc)
}

function Test-ADTemplateExists {
    param([string]$TemplateCN)

    try {
        $ConfigNC = (Get-ADRootDSE).configurationNamingContext
        $Template = [ADSI]"LDAP://CN=$TemplateCN,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
        return [bool]$Template.distinguishedName
    } catch {
        return $false
    }
}

function Test-TemplatePublishedToCA {
    param(
        [string]$TemplateCN,
        [string]$TemplateDisplayName
    )

    try {
        Import-Module ADCSAdministration -ErrorAction Stop
        $Templates = Get-CATemplate -ErrorAction Stop
        foreach ($T in $Templates) {
            if ($T.Name -eq $TemplateCN -or $T.Name -eq $TemplateDisplayName) { return $true }
        }
    } catch {
        return $false
    }

    return $false
}

function Get-DemoEnvironmentStatus {
    $CS = Get-WmiObject -Class Win32_ComputerSystem
    $IsDc = ($CS.DomainRole -ge 4)

    $Status = [PSCustomObject]@{
        IsDomainController   = $IsDc
        HasIisAndPkiVDir     = $false
        HasEnterpriseCA      = $false
        HasTemplateObjects   = $false
        HasTemplatesPublished= $false
        HasSqlExpress        = $false
    }

    if ($IsDc) {
        $Status.HasIisAndPkiVDir = Test-IISPkiPublished
        $Status.HasEnterpriseCA = Test-EnterpriseCAInstalled
        $Status.HasSqlExpress = Test-SQLExpressInstalled

        $HasSc = Test-ADTemplateExists -TemplateCN "HIDSmartcardLogon"
        $HasEa = Test-ADTemplateExists -TemplateCN "HIDEnrollmentAgent"
        $Status.HasTemplateObjects = ($HasSc -and $HasEa)

        $PubSc = Test-TemplatePublishedToCA -TemplateCN "HIDSmartcardLogon" -TemplateDisplayName "HID Smartcard Logon"
        $PubEa = Test-TemplatePublishedToCA -TemplateCN "HIDEnrollmentAgent" -TemplateDisplayName "HID Enrollment Agent"
        $Status.HasTemplatesPublished = ($PubSc -and $PubEa)
    }

    return $Status
}

function Show-EnvironmentChecklist {
    param($Status)

    Write-Host ""
    Write-Host "  Current machine state:" -ForegroundColor White
    Write-Host "  " + ([string]([char]0x2500) * 66) -ForegroundColor DarkGray

    if ($Status.IsDomainController) {
        Write-Host "  [X] Is the machine already a domain controller for a domain" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Is the machine already a domain controller for a domain" -ForegroundColor DarkGray
    }

    if ($Status.HasIisAndPkiVDir) {
        Write-Host "  [X] Is there IIS and the PKI virtual directory published" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Is there IIS and the PKI virtual directory published" -ForegroundColor DarkGray
    }

    if ($Status.HasEnterpriseCA) {
        Write-Host "  [X] Is there already an Enterprise CA" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Is there already an Enterprise CA" -ForegroundColor DarkGray
    }

    if ($Status.HasTemplatesPublished) {
        Write-Host "  [X] Are the templates published" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Are the templates published" -ForegroundColor DarkGray
    }

    if ($Status.HasSqlExpress) {
        Write-Host "  [X] Is SQL Server Express installed" -ForegroundColor Green
    } else {
        Write-Host "  [ ] Is SQL Server Express installed" -ForegroundColor DarkGray
    }

    Write-Host "  " + ([string]([char]0x2500) * 66) -ForegroundColor DarkGray
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

# If this host was already promoted in a previous run, skip the fresh-server state machine.
if ($State -eq 0) {
    $DetectedStatus = Get-DemoEnvironmentStatus
    if ($DetectedStatus.IsDomainController) {
        Write-Log "Detected existing domain controller. Switching to resume mode (State 2)."
        Show-EnvironmentChecklist -Status $DetectedStatus
        if (-not $SkipConfirmation) {
            $Resume = Read-Host "  Existing environment detected. Type YES to run only missing steps"
            if ($Resume -ne "YES") {
                Write-Host ""
                Write-Host "  Setup cancelled." -ForegroundColor Red
                Exit 0
            }
        }
        $State = 2
    }
}

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

    $CurrentStatus = Get-DemoEnvironmentStatus
    Show-EnvironmentChecklist -Status $CurrentStatus

    # --- IIS Web Server (installed first so C:\pki exists before ADCS publishes its CRL) ---
    # IIS must be in place before ADCS so that when certutil publishes the first CRL to C:\pki it can
    # immediately be served over HTTP — the CDP and AIA URLs embedded in issued certificates point to
    # http://<server>/pki, so the virtual directory must exist before any certificates are issued.
    if ($OnlyTemplates) {
        Write-Log "OnlyTemplates mode enabled. Skipping IIS and CA provisioning sections."
    } elseif ($CurrentStatus.HasIisAndPkiVDir) {
        Write-Log "IIS and PKI virtual directory already present. Skipping IIS configuration."
    } else {
        Write-Log "Installing IIS and creating PKI distribution point directory..."

        try {
            Install-WindowsFeature -Name Web-Server,Web-Asp-Net -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Log "IIS features installed successfully."
        } catch {
            Write-Log "ERROR installing IIS: $_"
            Exit 1
        }

        try {
            New-Item -Path "C:\pki" -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-Log "Created C:\pki directory."
        } catch {
            Write-Log "ERROR creating C:\pki: $_"
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
    }

    # --- Task 2: Enterprise Root CA ---
    if ($OnlyTemplates) {
        Write-Log "OnlyTemplates mode enabled. Skipping CA provisioning section."
    } elseif ($CurrentStatus.HasEnterpriseCA) {
        Write-Log "Enterprise CA already configured. Skipping CA installation."
    } else {
        Write-Log "Installing ADCS feature and configuring Enterprise Root CA..."
        try {
            Install-WindowsFeature -Name Adcs-Cert-Authority -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Log "ADCS feature installed."
        } catch {
            Write-Log "ERROR installing ADCS feature: $_"
            Exit 1
        }

        try {
            Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName "$MachineName-CA" `
                -KeyLength 2048 -HashAlgorithm SHA256 `
                -CryptoProviderName "RSA#Microsoft Software Key Storage Provider" -Force -ErrorAction Stop | Out-Null
            Write-Log "Enterprise Root CA configured."
        } catch {
            Write-Log "ERROR configuring Enterprise Root CA: $_"
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
    }

    Show-Progress 2   # AD [X], CA [X], SmartCard [>]

    # --- Task 3: Smart Card and Enrollment Agent Certificate Templates ---
    Write-Log "Creating HID certificate templates..."

    $ConfigNC    = (Get-ADRootDSE).configurationNamingContext
    $TemplatesOU = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
    $Container   = [ADSI]"LDAP://$TemplatesOU"

    # Generate a unique OID rooted in this forest's OID space.
    function New-TemplateOID {
        $ForestOID = ([ADSI]"LDAP://CN=OID,CN=Public Key Services,CN=Services,$ConfigNC").'msPKI-Cert-Template-OID'
        return "$ForestOID.$(Get-Random -Min 100 -Max 999).$(Get-Random -Min 1000000 -Max 9999999)"
    }

    function New-HIDTemplateFromSource {
        param(
            [string]$SourceTemplateCN,
            [string]$NewTemplateCN,
            [string]$NewTemplateDisplayName
        )

        $SourceADSI = [ADSI]"LDAP://CN=$SourceTemplateCN,$TemplatesOU"
        if (-not $SourceADSI.distinguishedName) {
            throw "Source template '$SourceTemplateCN' was not found in AD."
        }

        # Remove a previous partial run, if any.
        try { $Container.Delete("pKICertificateTemplate", "CN=$NewTemplateCN") } catch {}

        $NewTemplate = $Container.Create("pKICertificateTemplate", "CN=$NewTemplateCN")
        foreach ($Attr in @(
            "flags", "pKIDefaultKeySpec", "pKIKeyUsage", "pKIMaxIssuingDepth",
            "pKICriticalExtensions", "pKIExtendedKeyUsage", "msPKI-RA-Signature",
            "msPKI-Enrollment-Flag", "msPKI-Certificate-Name-Flag",
            "msPKI-Certificate-Application-Policy", "pKIExpirationPeriod", "pKIOverlapPeriod"
        )) {
            $Val = $SourceADSI.Properties[$Attr].Value
            if ($null -ne $Val) { $NewTemplate.Put($Attr, $Val) }
        }

        $NewTemplate.Put("displayName", $NewTemplateDisplayName)
        $NewTemplate.Put("msPKI-Cert-Template-OID", (New-TemplateOID))

        # Compatibility: Windows Server 2012 R2 CA / Windows 8.1 recipient (schema version 4).
        $NewTemplate.Put("msPKI-Template-Schema-Version", 4)
        $NewTemplate.Put("msPKI-Template-Minor-Revision", 1)

        # Cryptography: CNG/KSP with Microsoft Smart Card KSP and P-256-sized key material.
        # This enforces ECC-capable smart-card keys for the demo flow.
        $NewTemplate.Put("pKIDefaultCSPs", @("1,Microsoft Smart Card Key Storage Provider"))
        $NewTemplate.Put("msPKI-Minimal-Key-Size", 256)
        $NewTemplate.Put("msPKI-Private-Key-Flag", 1)

        $NewTemplate.SetInfo()

        # Security: Domain Admins + Enterprise Admins can read and enroll.
        $EnrollGuid   = [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55"
        $NetBIOS      = (Get-ADDomain).NetBIOSName
        $DomainAdmins = New-Object System.Security.Principal.NTAccount("$NetBIOS\Domain Admins")
        $EntAdmins    = New-Object System.Security.Principal.NTAccount("$NetBIOS\Enterprise Admins")
        $CurrentUser  = New-Object System.Security.Principal.NTAccount(
                            [System.Security.Principal.WindowsIdentity]::GetCurrent().Name)

        $SD = $NewTemplate.ObjectSecurity
        foreach ($Identity in @($DomainAdmins, $EntAdmins)) {
            $SD.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $Identity, "GenericRead,GenericExecute", "Allow")))
            $SD.AddAccessRule((New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
                $Identity, "ExtendedRight", "Allow", $EnrollGuid,
                ([System.DirectoryServices.ActiveDirectorySecurityInheritance]::None))))
        }
        $SD.PurgeAccessRules($CurrentUser)
        $NewTemplate.CommitChanges()

        Write-Log "Template '$NewTemplateDisplayName' created and secured."
    }

    function Publish-HIDTemplate {
        param(
            [string]$TemplateCN,
            [string]$TemplateDisplayName
        )

        Import-Module ADCSAdministration -ErrorAction Stop
        $MaxAttempts = 6

        for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
            $ExistsInAD = Test-ADTemplateExists -TemplateCN $TemplateCN
            if (-not $ExistsInAD) {
                Write-Log "Template '$TemplateCN' not yet visible in AD (attempt $Attempt/$MaxAttempts). Waiting 5s..."
                Start-Sleep -Seconds 5
                continue
            }

            if (Test-TemplatePublishedToCA -TemplateCN $TemplateCN -TemplateDisplayName $TemplateDisplayName) {
                Write-Log "Template '$TemplateDisplayName' is already published to CA."
                return
            }

            try {
                Add-CATemplate -Name $TemplateCN -Force -ErrorAction Stop
                Write-Log "Published template using CN '$TemplateCN'."
                return
            } catch {
                try {
                    Add-CATemplate -Name $TemplateDisplayName -Force -ErrorAction Stop
                    Write-Log "Published template using display name '$TemplateDisplayName'."
                    return
                } catch {
                    if ($Attempt -eq $MaxAttempts) {
                        throw "Failed to publish template '$TemplateDisplayName' after $MaxAttempts attempts. Last error: $($_.Exception.Message)"
                    }
                    Write-Log "Publish attempt $Attempt/$MaxAttempts failed for '$TemplateDisplayName'. Retrying in 5s..."
                    Start-Sleep -Seconds 5
                }
            }
        }
    }

    # 3.1 HID Smartcard Logon
    if (-not (Test-ADTemplateExists -TemplateCN "HIDSmartcardLogon")) {
        New-HIDTemplateFromSource -SourceTemplateCN "SmartcardLogon" -NewTemplateCN "HIDSmartcardLogon" -NewTemplateDisplayName "HID Smartcard Logon"
    } else {
        Write-Log "Template 'HID Smartcard Logon' already exists in AD. Skipping create."
    }

    # 3.2 HID Enrollment Agent
    if (-not (Test-ADTemplateExists -TemplateCN "HIDEnrollmentAgent")) {
        New-HIDTemplateFromSource -SourceTemplateCN "EnrollmentAgent" -NewTemplateCN "HIDEnrollmentAgent" -NewTemplateDisplayName "HID Enrollment Agent"
    } else {
        Write-Log "Template 'HID Enrollment Agent' already exists in AD. Skipping create."
    }

    # Publish both templates to the CA.
    Write-Log "Publishing HID templates to the CA..."
    Publish-HIDTemplate -TemplateCN "HIDSmartcardLogon" -TemplateDisplayName "HID Smartcard Logon"
    Publish-HIDTemplate -TemplateCN "HIDEnrollmentAgent" -TemplateDisplayName "HID Enrollment Agent"
    Write-Log "Templates published to CA."

    # Configure Default Domain Policy for smart-card sign-in UX.
    Write-Log "Configuring Default Domain Policy for smart-card interactive logon..."
    try {
        Import-Module GroupPolicy -ErrorAction Stop
    } catch {
        Install-WindowsFeature -Name GPMC -IncludeManagementTools | Out-Null
        Import-Module GroupPolicy -ErrorAction Stop
    }

    $DefaultGpo = "Default Domain Policy"
    # Interactive logon: Do not require CTRL+ALT+DEL (DisableCAD = 1)
    Set-GPRegistryValue -Name $DefaultGpo -Key "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -ValueName "DisableCAD" -Type DWord -Value 1

    # Enable ECC certificates for smart-card logon/authentication via KDC policy-backed key.
    # This maps the domain policy equivalent used for ECC smart-card logon in demo environments.
    Set-GPRegistryValue -Name $DefaultGpo -Key "HKLM\SOFTWARE\Policies\Microsoft\Windows\Kdc" -ValueName "AllowEccCertificatesForLogon" -Type DWord -Value 1

    # Apply policy immediately on the DC hosting the demo.
    gpupdate /force | Out-Null
    Write-Log "Default Domain Policy updated (DisableCAD + ECC smart-card logon)."

    Write-Log "Reissuing Domain Controller Certificate..."
    try {
        certreq -enroll -machine -q DomainController 2>&1 | Out-Null
        Write-Log "DC certificate reissued."
    } catch {
        Write-Log "WARNING reissuing DC cert: $_"
    }

    Show-Progress 3   # AD [X], CA [X], SmartCard [X], IIS [>]  (already done — tick it off)
    Show-Progress 4   # AD [X], CA [X], SmartCard [X], IIS [X], SQL [>]

    # --- Task 5: SQL Server Express ---
    if ($OnlyTemplates) {
        Write-Log "OnlyTemplates mode enabled. Skipping SQL installation and finishing now."
        Write-Log "Template-only run completed successfully."
        return
    }

    $SqlSysAdmin = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($CurrentStatus.HasSqlExpress) {
        Write-Log "SQL Server Express is already installed. Skipping SQL installation."
    } else {
        Write-Log "Downloading SQL Server Express..."
        # NOTE: For resilient setups, host the installer locally rather than relying on a live Microsoft link.
        $SqlUrl = "https://go.microsoft.com/fwlink/p/?linkid=2216019"
        $SqlExe = "C:\Users\Public\Downloads\SQLBootstrap.exe"

        try {
            Invoke-WebRequest -Uri $SqlUrl -OutFile $SqlExe -TimeoutSec 300 -ErrorAction Stop
            Write-Log "SQL Server Express installer downloaded successfully."
        } catch {
            Write-Log "ERROR downloading SQL installer: $_"
            Exit 1
        }

        # Now Dowload the full SQL Express installation media
        Start-Process -FilePath $SqlExe -ArgumentList "/ACTION=Download /MEDIAPATH=C:\Users\Public\Downloads /MEDIATYPE=Core /QUIET" -Wait -ErrorAction Stop
        $SqlExe = "C:\Users\Public\Downloads\SQLEXPR_x64_ENU.exe"

        # Use the account running setup as SQL sysadmin (works even if admin account was renamed).
        $SqlSysAdmin = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Write-Log "Configuring SQL sysadmin account: $SqlSysAdmin"

        try {
            Start-Process -FilePath $SqlExe -ArgumentList "/qs /ACTION=Install /FEATURES=SQLEngine,Conn /INSTANCENAME=SQLEXPRESS /SQLSVCACCOUNT=`"NT AUTHORITY\SYSTEM`" /SQLSYSADMINACCOUNTS=`"$SqlSysAdmin`" /BROWSERSVCSTARTUPTYPE=Automatic /TCPENABLED=1 /IACCEPTSQLSERVERLICENSETERMS" -Wait -ErrorAction Stop
            Write-Log "SQL Server Express installation completed."
        } catch {
            Write-Log "ERROR installing SQL Server: $_"
            # Don't exit; try to continue
        }
    }

    Show-Progress 5   # All tasks [X] done

    Write-Log "Generating Walkthrough Document..."
    $DocContent = @"
# Evaluation Environment Walkthrough
Welcome to your pre-configured environment.
* **Active Directory:** configured ($DomainName)
* **SQL Server:** Installed (SQLEXPRESS), sysadmin: $SqlSysAdmin
* **PKI:** Enterprise Root CA configured with HTTP/SMB endpoints.
* **Setup Log:** C:\Users\Public\Downloads\Setup-Demo.log
"@
    $DesktopPath = [Environment]::GetFolderPath("Desktop")
    if ([string]::IsNullOrWhiteSpace($DesktopPath) -or -not (Test-Path $DesktopPath)) {
        $DesktopPath = "C:\Users\Public\Desktop"
        New-Item -Path $DesktopPath -ItemType Directory -Force | Out-Null
    }
    $WalkthroughPath = Join-Path $DesktopPath "Evaluation-Walkthrough.md"
    $DocContent | Out-File $WalkthroughPath
    Write-Log "Walkthrough written to: $WalkthroughPath"

    Write-Log "Cleaning up scheduled task and registry state..."
    Unregister-ScheduledTask -TaskName "ResumeDemoSetup" -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -Path $StateKey -Force -ErrorAction SilentlyContinue

    Write-Host "  +==================================================================+" -ForegroundColor Green
    Write-Host "  |                       Setup Complete!                            |" -ForegroundColor Green
    Write-Host "  +==================================================================+" -ForegroundColor Green
    Write-Log "Setup Complete! Enjoy your coffee."
    
    Read-Host "Press Enter to close this window"
}