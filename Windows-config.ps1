reg add "HKLM\SOFTWARE\Microsoft\Policies\PassportForWork\SecurityKey" /v "UseSecurityKeyForSignIn" /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\PassportForWork" /v "DisablePostLogonProvisioning" /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Policies\Microsoft\PassportForWork" /v "Enabled" /t REG_DWORD /d 0 /f
reg add "HKLM\SOFTWARE\Microsoft\PolicyManager\Current\Device\Authentication" /v "EnablePasswordlessExperience" /t REG_DWORD /d 1 /f

Install-PackageProvider -Name NuGet -Force
Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery

Write-Host ""
Write-Host "===============================================================" -ForegroundColor Yellow
Write-Host "NEXT STEPS" -ForegroundColor Cyan
Write-Host "- Don't forget to enable USB HID passthrough in your VM settings if you are using a virtual machine." -ForegroundColor Yellow
Write-Host "- After logging in, run Repair-WinGetPackageManager -AllUsers to ensure WinGet is fully functional." -ForegroundColor Green
Write-Host "===============================================================" -ForegroundColor Yellow