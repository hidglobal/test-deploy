# HID Test Deployments

This repository contains scripts to install evaluation environments of HID products

## HID Credential Management System

Prerequisites:

- Clean Windows Server 2025 server
- Windows 11 Workstations to be connected to the server
- Copy CMS installation package into C:\Users\Public\Downloads

Virtual Machines with the Evaluation Version from Microsoft are fine.

Deploy:
```
Invoke-WebRequest -Uri "https://github.com/hidglobal/test-deploy/HID-CMS-Demo.ps1" -OutFile "$env:TEMP\Deploy-Demo.ps1"; & "$env:TEMP\Deploy-Demo.ps1"
```