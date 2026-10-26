#requires -Version 5.1
[CmdletBinding()]param([string]$ProjectDirectory,[string]$GitUserName,[string]$GitUserEmail,[string]$ProjectRemoteUrl,[switch]$NoGitLfs,[string]$GitPath='git')
$ErrorActionPreference='Stop'
if (-not $ProjectDirectory) { $ProjectDirectory=Split-Path $PSScriptRoot -Parent }
$ProjectDirectory=(Get-Item -LiteralPath $ProjectDirectory).FullName
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'project-init/Project-Git.ps1')
Set-ProjectGit $GitPath $ProjectDirectory $GitUserName $GitUserEmail ([bool]$NoGitLfs)
if ($ProjectRemoteUrl) { Set-ProjectRemote $GitPath $ProjectDirectory $ProjectRemoteUrl }
Write-Host 'Local project Git settings configured. Global settings were not changed.'
