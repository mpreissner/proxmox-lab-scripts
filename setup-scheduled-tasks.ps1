#Requires -Version 5.1
<#
.SYNOPSIS
    Creates Windows Task Scheduler entries for the Zscaler lab traffic generator.

.DESCRIPTION
    Registers one scheduled task per traffic profile. Each task invokes
    win-traffic.ps1 with the appropriate profile and duration on a schedule
    that matches realistic usage patterns for that persona.

    Existing lab tasks are removed and recreated on each run, so this script
    is safe to re-run after updating win-traffic.ps1 or adjusting schedules.

    Requires elevation (Run as Administrator or SYSTEM).

.PARAMETER ScriptPath
    Full path to win-traffic.ps1 on this machine.
    Default: C:\ProgramData\proxmox-lab\win-traffic.ps1

.PARAMETER Profiles
    Array of profile names to install. Defaults to all five profiles.
    Valid values: office-worker, sales, developer, executive, threat

.EXAMPLE
    .\setup-scheduled-tasks.ps1
    .\setup-scheduled-tasks.ps1 -ScriptPath "D:\lab\win-traffic.ps1"
    .\setup-scheduled-tasks.ps1 -Profiles "office-worker,developer"
#>
param(
    [string]$ScriptPath = "C:\ProgramData\proxmox-lab\win-traffic.ps1",
    [string[]]$Profiles = @("office-worker", "sales", "developer", "executive", "threat")
)

$SCRIPT_VERSION = "3.0.2"

# Normalize: qm guest exec passes -Profiles as a single comma-separated string;
# split it into a proper array so -contains checks work correctly.
if ($Profiles.Count -eq 1 -and $Profiles[0] -match ',') {
    $Profiles = $Profiles[0] -split ','
}

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Elevation check  -  Task Scheduler registration requires Administrator
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Error: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Re-launch PowerShell with 'Run as Administrator' and try again." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $ScriptPath)) {
    Write-Host "Error: win-traffic.ps1 not found at: $ScriptPath" -ForegroundColor Red
    Write-Host "Copy win-traffic.ps1 to that path and re-run, or pass -ScriptPath." -ForegroundColor Red
    exit 1
}

$TASK_PREFIX = "ZscalerTrafficGen"

$allTaskNames = @(
    "$TASK_PREFIX-OfficeWorker",
    "$TASK_PREFIX-Sales",
    "$TASK_PREFIX-Developer",
    "$TASK_PREFIX-Executive",
    "$TASK_PREFIX-Threat"
)

Write-Host ""
Write-Host "Zscaler Lab  -  Scheduled Task Setup" -ForegroundColor Cyan
Write-Host "Script: $ScriptPath" -ForegroundColor Gray
Write-Host ""

# ---------------------------------------------------------------------------
# Remove existing tasks
# ---------------------------------------------------------------------------

foreach ($name in $allTaskNames) {
    if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
        Write-Host "Removing existing task: $name" -ForegroundColor Yellow
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
    }
}

$commonSettings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -DontStopOnIdleEnd `
    -AllowStartIfOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2)

# Weekday trigger helper  -  reused by every task
$weekdays = @("Monday","Tuesday","Wednesday","Thursday","Friday")

function New-WeekdayTrigger {
    param([string]$At)
    New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $weekdays -At $At
}

# ---------------------------------------------------------------------------
# Helper  -  builds the PowerShell action for a given profile + duration
# ---------------------------------------------------------------------------

function New-TrafficAction {
    param([string]$Profile, [int]$DurationMinutes)
    $arg = "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden " +
           "-File `"$ScriptPath`" -Profile $Profile -DurationMinutes $DurationMinutes"
    New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $arg
}

# ---------------------------------------------------------------------------
# Task 1: Office Worker
#   Every hour during business hours (8 AM - 6 PM), 55-minute runs
# ---------------------------------------------------------------------------

if ($Profiles -contains "office-worker") {
    Write-Host "Creating Office Worker task..." -ForegroundColor Green
    $triggers = 8..17 | ForEach-Object { New-WeekdayTrigger -At "$($_):00" }
    Register-ScheduledTask `
        -TaskName    "$TASK_PREFIX-OfficeWorker" `
        -Action      (New-TrafficAction -Profile "office-worker" -DurationMinutes 55) `
        -Trigger     $triggers `
        -Settings    $commonSettings `
        -User        "SYSTEM" `
        -RunLevel    Highest `
        -Description "Zscaler lab: office-worker traffic (M365, SaaS, personal browsing)" |
        Out-Null
    Write-Host "  office-worker: hourly 8 AM - 6 PM, 55-min runs" -ForegroundColor Gray
} else {
    Write-Host "Skipping Office Worker task (not in selected profiles)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Task 2: Sales
#   Every 2 hours during business hours (8:30 AM - 4:30 PM), 45-minute runs
# ---------------------------------------------------------------------------

if ($Profiles -contains "sales") {
    Write-Host "Creating Sales task..." -ForegroundColor Green
    $triggers = @(
        New-WeekdayTrigger -At "8:30AM"
        New-WeekdayTrigger -At "10:30AM"
        New-WeekdayTrigger -At "12:30PM"
        New-WeekdayTrigger -At "2:30PM"
        New-WeekdayTrigger -At "4:30PM"
    )
    Register-ScheduledTask `
        -TaskName    "$TASK_PREFIX-Sales" `
        -Action      (New-TrafficAction -Profile "sales" -DurationMinutes 45) `
        -Trigger     $triggers `
        -Settings    $commonSettings `
        -User        "SYSTEM" `
        -RunLevel    Highest `
        -Description "Zscaler lab: sales traffic (CRM, LinkedIn, travel, GenAI)" |
        Out-Null
    Write-Host "  sales: 5x/day 8:30 AM - 4:30 PM, 45-min runs" -ForegroundColor Gray
} else {
    Write-Host "Skipping Sales task (not in selected profiles)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Task 3: Developer
#   5x/day including one evening run (late coding), 45-minute runs
# ---------------------------------------------------------------------------

if ($Profiles -contains "developer") {
    Write-Host "Creating Developer task..." -ForegroundColor Green
    $triggers = @(
        New-WeekdayTrigger -At "9:00AM"
        New-WeekdayTrigger -At "11:00AM"
        New-WeekdayTrigger -At "2:00PM"
        New-WeekdayTrigger -At "4:00PM"
        New-WeekdayTrigger -At "8:00PM"
    )
    Register-ScheduledTask `
        -TaskName    "$TASK_PREFIX-Developer" `
        -Action      (New-TrafficAction -Profile "developer" -DurationMinutes 45) `
        -Trigger     $triggers `
        -Settings    $commonSettings `
        -User        "SYSTEM" `
        -RunLevel    Highest `
        -Description "Zscaler lab: developer traffic (GitHub, registries, cloud consoles, GenAI)" |
        Out-Null
    Write-Host "  developer: 5x/day including 8 PM, 45-min runs" -ForegroundColor Gray
} else {
    Write-Host "Skipping Developer task (not in selected profiles)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Task 4: Executive
#   4x/day  -  the 10:30 PM run is the UEBA trigger (after-hours O365 access)
#   20-minute runs: light usage, quick check-ins
# ---------------------------------------------------------------------------

if ($Profiles -contains "executive") {
    Write-Host "Creating Executive task..." -ForegroundColor Green
    $triggers = @(
        New-WeekdayTrigger -At "7:30AM"
        New-WeekdayTrigger -At "10:00AM"
        New-WeekdayTrigger -At "3:00PM"
        New-WeekdayTrigger -At "10:30PM"   # UEBA: after-hours access
    )
    Register-ScheduledTask `
        -TaskName    "$TASK_PREFIX-Executive" `
        -Action      (New-TrafficAction -Profile "executive" -DurationMinutes 20) `
        -Trigger     $triggers `
        -Settings    $commonSettings `
        -User        "SYSTEM" `
        -RunLevel    Highest `
        -Description "Zscaler lab: executive traffic (O365, business news, GenAI); 10:30 PM run triggers UEBA" |
        Out-Null
    Write-Host "  executive: 4x/day including 10:30 PM (UEBA), 20-min runs" -ForegroundColor Gray
} else {
    Write-Host "Skipping Executive task (not in selected profiles)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Task 5: Threat
#   3x/day during business hours  -  AV, DLP, and policy violation events
#   10-minute runs: each session runs through all test types once
# ---------------------------------------------------------------------------

if ($Profiles -contains "threat") {
    Write-Host "Creating Threat task..." -ForegroundColor Green
    $triggers = @(
        New-WeekdayTrigger -At "9:15AM"
        New-WeekdayTrigger -At "1:15PM"
        New-WeekdayTrigger -At "4:15PM"
    )
    Register-ScheduledTask `
        -TaskName    "$TASK_PREFIX-Threat" `
        -Action      (New-TrafficAction -Profile "threat" -DurationMinutes 10) `
        -Trigger     $triggers `
        -Settings    $commonSettings `
        -User        "SYSTEM" `
        -RunLevel    Highest `
        -Description "Zscaler lab: security test events (EICAR, DLP, policy violation)" |
        Out-Null
    Write-Host "  threat: 3x/day at 9:15 AM, 1:15 PM, 4:15 PM, 10-min runs" -ForegroundColor Gray
} else {
    Write-Host "Skipping Threat task (not in selected profiles)" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Verify  -  query back what Task Scheduler actually registered
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Verifying registered tasks..." -ForegroundColor Cyan

$verified  = 0
$missing   = 0

foreach ($name in $allTaskNames) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($task) {
        $triggerCount = $task.Triggers.Count
        Write-Host "  [OK] $name  ($triggerCount trigger$(if ($triggerCount -ne 1) { 's' })  |  state: $($task.State))" -ForegroundColor Green
        $verified++
    } else {
        Write-Host "  [MISSING] $name" -ForegroundColor Red
        $missing++
    }
}

Write-Host ""
$skipped = $allTaskNames.Count - $Profiles.Count
if ($missing -eq 0) {
    Write-Host "$verified task(s) registered successfully." -ForegroundColor Green
} else {
    Write-Host "$verified registered, $missing missing  -  check for errors above." -ForegroundColor Yellow
}
if ($Profiles.Count -lt $allTaskNames.Count) {
    $skippedProfiles = $allTaskNames | Where-Object {
        $name = $_
        -not ($Profiles | Where-Object { $name -like "*$_*" })
    }
    Write-Host "Profiles not installed: $($skippedProfiles -join ', ')" -ForegroundColor Gray
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "=======================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Management:" -ForegroundColor Yellow
Write-Host "  List:       Get-ScheduledTask | Where-Object TaskName -like 'Zscaler*'" -ForegroundColor Gray
Write-Host "  Run now:    Start-ScheduledTask -TaskName '$TASK_PREFIX-Threat'" -ForegroundColor Gray
Write-Host "  Stop all:   Get-ScheduledTask | Where-Object TaskName -like 'Zscaler*' | Stop-ScheduledTask" -ForegroundColor Gray
Write-Host "  Remove all: Get-ScheduledTask | Where-Object TaskName -like 'Zscaler*' | Unregister-ScheduledTask -Confirm:`$false" -ForegroundColor Gray
Write-Host ""
