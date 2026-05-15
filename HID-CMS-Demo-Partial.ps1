# ==============================================================================
# HID CMS Demo - Partial Template Repair Script
# ==============================================================================
$ErrorActionPreference = "Stop"
$LogFile = "C:\Users\Public\Downloads\Setup-Demo-Partial.log"

function Write-Log ($Message) {
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Time - $Message" | Out-File $LogFile -Append
    Write-Host "$Time - $Message" -ForegroundColor Cyan
}

function Test-ADTemplateExists {
    param([string]$TemplateCN)

    $ConfigNC = (Get-ADRootDSE).configurationNamingContext
    $Template = [ADSI]"LDAP://CN=$TemplateCN,CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
    return [bool]$Template.distinguishedName
}

function Test-TemplatePublishedToCA {
    param(
        [string]$TemplateCN,
        [string]$TemplateDisplayName
    )

    Import-Module ADCSAdministration -ErrorAction Stop
    $Templates = Get-CATemplate -ErrorAction Stop
    foreach ($T in $Templates) {
        if ($T.Name -eq $TemplateCN -or $T.Name -eq $TemplateDisplayName) { return $true }
    }
    return $false
}

function Publish-HIDTemplate {
    param(
        [string]$TemplateCN,
        [string]$TemplateDisplayName
    )

    Import-Module ADCSAdministration -ErrorAction Stop
    $MaxAttempts = 6

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        if (-not (Test-ADTemplateExists -TemplateCN $TemplateCN)) {
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

function New-TemplateOID {
    param([string]$ConfigNC)

    $ForestOID = ([ADSI]"LDAP://CN=OID,CN=Public Key Services,CN=Services,$ConfigNC").'msPKI-Cert-Template-OID'
    return "$ForestOID.$(Get-Random -Min 100 -Max 999).$(Get-Random -Min 1000000 -Max 9999999)"
}

function New-HIDTemplateFromSource {
    param(
        [string]$ConfigNC,
        [string]$SourceTemplateCN,
        [string]$NewTemplateCN,
        [string]$NewTemplateDisplayName
    )

    $TemplatesOU = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$ConfigNC"
    $Container = [ADSI]"LDAP://$TemplatesOU"
    $SourceADSI = [ADSI]"LDAP://CN=$SourceTemplateCN,$TemplatesOU"

    if (-not $SourceADSI.distinguishedName) {
        throw "Source template '$SourceTemplateCN' was not found in AD."
    }

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
    $NewTemplate.Put("msPKI-Cert-Template-OID", (New-TemplateOID -ConfigNC $ConfigNC))
    $NewTemplate.Put("msPKI-Template-Schema-Version", 4)
    $NewTemplate.Put("msPKI-Template-Minor-Revision", 1)
    $NewTemplate.Put("pKIDefaultCSPs", @("1,Microsoft Smart Card Key Storage Provider"))
    $NewTemplate.Put("msPKI-Minimal-Key-Size", 256)
    $NewTemplate.Put("msPKI-Private-Key-Flag", 1)
    $NewTemplate.SetInfo()

    Write-Log "Template '$NewTemplateDisplayName' created."
}

Write-Log "Starting partial run: certificate templates only."

$CS = Get-WmiObject -Class Win32_ComputerSystem
if ($CS.DomainRole -lt 4) {
    throw "This partial script must run on a domain controller."
}

$CertSvc = Get-Service -Name "CertSvc" -ErrorAction SilentlyContinue
if (-not $CertSvc) {
    throw "Certificate Services (CertSvc) is not installed."
}

$ConfigNC = (Get-ADRootDSE).configurationNamingContext

if (-not (Test-ADTemplateExists -TemplateCN "HIDSmartcardLogon")) {
    New-HIDTemplateFromSource -ConfigNC $ConfigNC -SourceTemplateCN "SmartcardLogon" -NewTemplateCN "HIDSmartcardLogon" -NewTemplateDisplayName "HID Smartcard Logon"
} else {
    Write-Log "Template 'HID Smartcard Logon' already exists in AD."
}

if (-not (Test-ADTemplateExists -TemplateCN "HIDEnrollmentAgent")) {
    New-HIDTemplateFromSource -ConfigNC $ConfigNC -SourceTemplateCN "EnrollmentAgent" -NewTemplateCN "HIDEnrollmentAgent" -NewTemplateDisplayName "HID Enrollment Agent"
} else {
    Write-Log "Template 'HID Enrollment Agent' already exists in AD."
}

Publish-HIDTemplate -TemplateCN "HIDSmartcardLogon" -TemplateDisplayName "HID Smartcard Logon"
Publish-HIDTemplate -TemplateCN "HIDEnrollmentAgent" -TemplateDisplayName "HID Enrollment Agent"

Write-Log "Partial template run completed successfully."
