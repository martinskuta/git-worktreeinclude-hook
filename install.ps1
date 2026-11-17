<#
.SYNOPSIS
    1-command Windows PowerShell bootstrapper for git-worktreeinclude.
.DESCRIPTION
    Locates Git for Windows's bundled POSIX sh.exe and delegates to git-worktreeinclude.
    Defaults to 'install' when called with no arguments (e.g. .\install.ps1),
    or forwards any arguments (e.g. .\install.ps1 --local, .\install.ps1 uninstall).
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

$ErrorActionPreference = 'Stop'

function Find-GitPosixShell {
    $gitCmd = Get-Command 'git' -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "Git is not installed or not on PATH. Please install Git for Windows first."
    }

    $execPath = (& git --exec-path 2>$null)
    $candidates = New-Object System.Collections.Generic.List[string]

    foreach ($startPath in @($execPath, (Split-Path -Parent $gitCmd.Source))) {
        if ([string]::IsNullOrWhiteSpace($startPath)) { continue }
        $curr = $startPath -replace '/', '\'
        for ($i = 0; $i -lt 5 -and -not [string]::IsNullOrWhiteSpace($curr); $i++) {
            $usrSh = Join-Path $curr 'usr\bin\sh.exe'
            $binSh = Join-Path $curr 'bin\sh.exe'
            if (Test-Path -LiteralPath $usrSh) { $candidates.Add($usrSh) }
            if (Test-Path -LiteralPath $binSh) { $candidates.Add($binSh) }
            $parent = Split-Path -Parent $curr
            if ($parent -eq $curr) { break }
            $curr = $parent
        }
    }

    foreach ($shPath in $candidates) {
        return $shPath
    }

    $pathSh = Get-Command 'sh' -ErrorAction SilentlyContinue
    if ($pathSh) {
        return $pathSh.Source
    }

    throw "Could not locate Git's bundled POSIX sh.exe."
}

$shExe = Find-GitPosixShell
$shDir = Split-Path -Parent $shExe
$gitExecDir = (& git --exec-path 2>$null) -replace '/', '\'
$gitCmdDir = Split-Path -Parent (Get-Command 'git').Source

# Ensure POSIX coreutils (/usr/bin) and git are available on PATH for usr\bin\sh.exe
$extraPaths = @($shDir, $gitCmdDir, $gitExecDir) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$oldPath = $env:PATH
$tmpScript = $null
try {
    $env:PATH = (($extraPaths -join ';') + ';' + $oldPath)

    $scriptPath = $null
    if ($PSScriptRoot) {
        $localCandidate = Join-Path $PSScriptRoot 'git-worktreeinclude'
        if (Test-Path -LiteralPath $localCandidate) {
            $scriptPath = $localCandidate
        }
    }
    if (-not $scriptPath -and (Test-Path -LiteralPath '.\git-worktreeinclude')) {
        $scriptPath = (Resolve-Path -LiteralPath '.\git-worktreeinclude').Path
    }
    if (-not $scriptPath) {
        $rawUrl = if ($env:GIT_WORKTREEINCLUDE_RAW_URL) {
            $env:GIT_WORKTREEINCLUDE_RAW_URL
        } else {
            'https://raw.githubusercontent.com/martinskuta/git-worktreeinclude-hook/main/git-worktreeinclude'
        }
        $tmpScript = Join-Path ([System.IO.Path]::GetTempPath()) "git-worktreeinclude-$PID"
        Invoke-WebRequest -UseBasicParsing -Uri $rawUrl -OutFile $tmpScript
        $scriptPath = $tmpScript
    }

    $effectiveArgs = @()
    if (-not $ForwardArgs -or $ForwardArgs.Count -eq 0) {
        $effectiveArgs = @('install')
    } elseif ($ForwardArgs[0].StartsWith('-')) {
        $effectiveArgs = @('install') + $ForwardArgs
    } else {
        $effectiveArgs = $ForwardArgs
    }

    & $shExe $scriptPath @effectiveArgs
    $code = $LASTEXITCODE
    if ($MyInvocation.MyCommand.Path) {
        exit $code
    } elseif ($code -ne 0) {
        throw "git-worktreeinclude failed with exit code $code"
    }
} finally {
    $env:PATH = $oldPath
    if ($tmpScript -and (Test-Path -LiteralPath $tmpScript)) {
        Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
    }
}
