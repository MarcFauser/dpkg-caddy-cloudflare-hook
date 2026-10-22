#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Installs the project's git hooks from _git_hooks into .git/hooks.

.DESCRIPTION
    Copies every hook from the versioned _git_hooks folder into the local
    .git/hooks directory and marks it executable. Run this once after cloning
    or copying the repository, since .git/hooks is not version controlled.

.EXAMPLE
    ./install-git-hooks.ps1
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$sourceDir = Join-Path $scriptDir '_git_hooks'
$targetDir = Join-Path $scriptDir '.git/hooks'

if (-not (Test-Path -LiteralPath $sourceDir))
{
    Write-Error "Hook source folder not found: $sourceDir"
    exit 1
}

if (-not (Test-Path -LiteralPath $targetDir))
{
    Write-Error "Not a git repository (missing $targetDir). Run 'git init' first."
    exit 1
}

# @() because a single hook comes back as one FileInfo, not an array - and under
# strict mode .Count on a scalar is an error, not a quiet 1.
$hooks = @(Get-ChildItem -LiteralPath $sourceDir -File)
if ($hooks.Count -eq 0)
{
    Write-Warning "No hooks found in $sourceDir - nothing to install."
    return
}

foreach ($hook in $hooks)
{
    $target = Join-Path $targetDir $hook.Name
    Copy-Item -LiteralPath $hook.FullName -Destination $target -Force

    # Mark executable so git runs it on Unix. On Windows there is no chmod and
    # Git for Windows runs hooks via its bundled sh regardless, so skip it.
    if (-not $IsWindows -and (Get-Command chmod -ErrorAction SilentlyContinue))
    {
        chmod +x "$target"
    }

    Write-Host "  Installed: $($hook.Name)" -ForegroundColor Green
}

Write-Host "Git hooks installed into $targetDir" -ForegroundColor Cyan
