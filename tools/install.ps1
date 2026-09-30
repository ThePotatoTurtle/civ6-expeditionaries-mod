<#
.SYNOPSIS
  EFV install script (PLAN 6.4): static checks -> mirror EFV\ into the game's Mods folder -> optional log tail.

.DESCRIPTION
  Default:     runs tools\check_all.py on EFV\ (and EFV_Dev\ with -Dev); aborts on errors unless -Force;
               then robocopy /MIR EFV\ -> <Mods>\EFV (and EFV_Dev\ -> <Mods>\EFV_Dev with -Dev).
  -DevOnly:    checks and installs ONLY EFV_Dev\ (the dev tools), for testing against VEF from the Steam
               Workshop: <Mods>\EFV is not touched. Warns when a local <Mods>\EFV exists (it has the same
               mod id as the Workshop VEF: remove it so the game loads the Workshop copy).
  Installing refuses to run while Civilization VI is running (the game locks and caches mod files).
  -Watch:      after installing, tails Lua.log live, filtered to EFV lines and Lua errors.
               Start it after the game's main menu is up: the game recreates Lua.log at launch
               (the tail re-attaches when the file is recreated). Lua.log is buffered while playing;
               some output only appears after exiting to the menu or desktop.
  -WatchOnly:  tail without checking/installing.
  -CheckLogs:  only scan Database.log, Modding.log, Lua.log and UserInterface.log of the last run for
               EFV-related errors (tools\check_logs.py); exit code 1 if any.
  Mirroring deletes files in the target that no longer exist in the source; the target folders are EFV-owned.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\install.ps1
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Dev -Watch
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -DevOnly
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -Force -Src D:\other\EFV
#>
[CmdletBinding()]
param(
    [switch]$Dev,
    [switch]$DevOnly,
    [switch]$Watch,
    [switch]$WatchOnly,
    [switch]$CheckLogs,
    [switch]$Force,
    [switch]$SkipChecks,
    [switch]$Strict,
    [string]$Src,
    [string]$DevSrc,
    [string]$ModsDir = "S:\Libraries\Documents\My Games\Sid Meier's Civilization VI\Mods",
    [string]$LogsDir = (Join-Path $env:LOCALAPPDATA "Firaxis Games\Sid Meier's Civilization VI\Logs"),
    [string]$Python = "python",
    [string]$Pattern = "EFV|Runtime Error|Syntax Error|stack traceback"
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
$ProjectDir = Split-Path -Parent $ToolsDir
if (-not $Src)    { $Src    = Join-Path $ProjectDir "EFV" }
if (-not $DevSrc) { $DevSrc = Join-Path $ProjectDir "EFV_Dev" }

function Write-Step([string]$msg) { Write-Host ""; Write-Host "== $msg" -ForegroundColor Cyan }

function Invoke-Python([string[]]$argList) {
    # Out-Host keeps python's output out of the function's return value
    & $Python @argList | Out-Host
    return [int]$LASTEXITCODE
}

function Invoke-LogCheck {
    Write-Step "Scanning logs in $LogsDir"
    $code = Invoke-Python @((Join-Path $ToolsDir "check_logs.py"), "--logs", $LogsDir, "--tail", "5")
    return $code
}

function Invoke-Mirror([string]$from, [string]$to) {
    if (-not (Test-Path -LiteralPath $from -PathType Container)) { throw "source folder not found: $from" }
    if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) { throw "Mods folder not found: $ModsDir" }
    # safety: only ever mirror into <ModsDir>\<same leaf name as the source>
    $leaf = Split-Path -Leaf $from
    $expected = Join-Path $ModsDir $leaf
    if ((Resolve-Path -LiteralPath $ModsDir).Path.TrimEnd('\') -ne (Split-Path -Parent $expected).TrimEnd('\')) { throw "refusing to mirror outside $ModsDir" }
    if ($to -ne $expected) { throw "refusing to mirror to $to (expected $expected)" }
    if ($leaf -notmatch '^EFV') { throw "refusing to mirror a folder that is not EFV-owned: $leaf" }
    Write-Step "Mirroring $from -> $to"
    & robocopy $from $to /MIR /NFL /NDL /NJH /NP /R:2 /W:1 /XF "*.bak" "*~" "Thumbs.db" | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }
    Write-Host "robocopy ok (exit $rc)"
    $global:LASTEXITCODE = 0
}

function Start-LuaLogWatch {
    $log = Join-Path $LogsDir "Lua.log"
    Write-Step "Watching $log  (filter: $Pattern)  Ctrl+C to stop"
    Write-Host "Note: start this after the main menu is up; Lua.log is buffered while playing." -ForegroundColor DarkGray
    while ($true) {
        while (-not (Test-Path -LiteralPath $log)) { Start-Sleep -Milliseconds 500 }
        $created = (Get-Item -LiteralPath $log).CreationTime
        $job = Start-Job -ScriptBlock {
            param($path, $pat)
            Get-Content -LiteralPath $path -Wait -Tail 0 | Where-Object { $_ -match $pat }
        } -ArgumentList $log, $Pattern
        try {
            while ($true) {
                Receive-Job $job | ForEach-Object {
                    if ($_ -match 'Runtime Error|Syntax Error|stack traceback|ERROR') { Write-Host $_ -ForegroundColor Red }
                    else { Write-Host $_ }
                }
                Start-Sleep -Milliseconds 300
                # game relaunch recreates the file: re-attach
                if (-not (Test-Path -LiteralPath $log)) { break }
                if ((Get-Item -LiteralPath $log).CreationTime -ne $created) { Write-Host "-- Lua.log recreated, re-attaching" -ForegroundColor DarkGray; break }
                if ($job.State -ne 'Running') { break }
            }
        } finally {
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------- modes
if ($CheckLogs) {
    $code = Invoke-LogCheck
    exit $code
}
if ($WatchOnly) {
    Start-LuaLogWatch
    exit 0
}

# 0. the game must not be running while its Mods folder changes
$game = Get-Process -Name "CivilizationVI*" -ErrorAction SilentlyContinue
if ($game) {
    Write-Host "Civilization VI is running ($($game[0].ProcessName)). Quit the game, then run this again." -ForegroundColor Red
    exit 3
}
if ($DevOnly) {
    $localEfv = Join-Path $ModsDir (Split-Path -Leaf $Src)
    if (Test-Path -LiteralPath $localEfv -PathType Container) {
        Write-Host "WARNING: a local copy of VEF is in $localEfv. It has the same mod id as the Steam Workshop VEF;" -ForegroundColor Yellow
        Write-Host "         delete that folder so the game loads the Workshop version." -ForegroundColor Yellow
    }
}

# 1. static checks
if (-not $SkipChecks) {
    $roots = @($Src)
    if ($Dev) { $roots += $DevSrc }
    if ($DevOnly) { $roots = @($DevSrc) }
    Write-Step ("Static checks: " + ($roots -join ", "))
    $argList = @((Join-Path $ToolsDir "check_all.py")) + $roots + @("--no-checklist")
    if ($Strict) { $argList += "--strict" }
    $code = Invoke-Python $argList
    if ($code -ne 0) {
        if ($Force) {
            Write-Host "Checks FAILED (exit $code) - continuing because of -Force" -ForegroundColor Yellow
        } else {
            Write-Host "Checks FAILED (exit $code) - not installing. Fix the errors or rerun with -Force." -ForegroundColor Red
            exit $code
        }
    }
} else {
    Write-Host "Skipping static checks (-SkipChecks)" -ForegroundColor Yellow
}

# 2. mirror (-DevOnly: the dev tools only; VEF comes from the Steam Workshop)
if (-not $DevOnly) { Invoke-Mirror $Src (Join-Path $ModsDir (Split-Path -Leaf $Src)) }
if ($Dev -or $DevOnly) { Invoke-Mirror $DevSrc (Join-Path $ModsDir (Split-Path -Leaf $DevSrc)) }
Write-Host ""
Write-Host "Installed. Enable the mod(s) in Additional Content, start/load a game, then run:" -ForegroundColor Green
Write-Host "  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -CheckLogs"

# 3. watch
if ($Watch) { Start-LuaLogWatch }
exit 0
