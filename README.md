# HID Test Deployments

This repository contains scripts to install evaluation environments of HID products

## HID Credential Management System

Prerequisites:

- Clean Windows Server 2025 server
- Windows 11 Workstations to be connected to the server
- Copy CMS installation package into C:\Users\Public\Downloads

Virtual Machines with the Evaluation Version from Microsoft are fine.

Deploy:

Open an **elevated PowerShell prompt** (Run as Administrator) and paste:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/hidglobal/test-deploy/main/HID-CMS-Demo.ps1" -OutFile "C:\Users\Public\Downloads\HID-CMS-Demo.ps1"
& "C:\Users\Public\Downloads\HID-CMS-Demo.ps1"
```

> **Why these steps?**
> - `Set-ExecutionPolicy Bypass -Scope Process` is required because Windows Server's default policy (`RemoteSigned`) blocks scripts downloaded from the internet. The `-Scope Process` flag limits the change to this session only — it does not permanently alter your security policy.
> - The script is saved to `C:\Users\Public\Downloads\` rather than a temporary folder because it needs to resume automatically after each reboot; the scheduled task created by the script points back to this path.
> - The script itself passes `-ExecutionPolicy Bypass` to PowerShell when registering the resume task, so no further policy changes are needed after the first run.