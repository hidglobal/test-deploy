reg add "HKLM\SOFTWARE\Microsoft\Policies\PassportForWork\SecurityKeys" /v "UseSecurityKeyForSignIn" /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\PassportForWork" /v "DisablePostLogonProvisioning" /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\PassportForWork" /v "Enabled" /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\Current\Device\Authentication" /v "EnablePasswordlessExperience" /t REG_DWORD /d 1 /f

Install-PackageProvider -Name NuGet -Force
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery
Repair-WinGetPackageManager -AllUsers

Write-Host "Don't forget to enable USB HID passthrough in your VM settings if you are using a virtual machine."