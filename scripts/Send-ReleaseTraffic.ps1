#Requires -Version 7.4
<#
.SYNOPSIS
    Sends simulated checkout traffic to the ticketing web app and logs the status and latency of every call.

.DESCRIPTION
    The app reports the telemetry its alert watches only when it receives POST /checkout, so a bad release stays invisible without traffic.
    Invoke-FridayRelease.ps1 starts this script in the background for a run and stops it on Reset; you can also run it by hand.
    It writes one CSV row per call (UTC time, HTTP status, milliseconds) and exits by itself after DurationSeconds, so it cannot run forever.
    It sends no credentials and changes nothing in Azure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^https://[a-z0-9][a-z0-9.-]*\.azurewebsites\.net$')]
    [string]$AppUrl,

    [Parameter(Mandatory = $true)]
    [string]$LogPath,

    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 3,

    [ValidateRange(30, 14400)]
    [int]$DurationSeconds = 7200
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogPath)) { 'utc,status,ms' | Set-Content -LiteralPath $LogPath -Encoding utf8 }
$end = [DateTimeOffset]::UtcNow.AddSeconds($DurationSeconds)
while ([DateTimeOffset]::UtcNow -lt $end) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest -Uri "$AppUrl/checkout" -Method POST -ContentType 'application/json' -Body '{}' -SkipHttpErrorCheck -TimeoutSec 20
        $status = [int]$response.StatusCode
    } catch {
        $status = -1
    }
    $clock.Stop()
    ('{0:o},{1},{2}' -f [DateTimeOffset]::UtcNow, $status, $clock.ElapsedMilliseconds) | Add-Content -LiteralPath $LogPath -Encoding utf8
    Start-Sleep -Seconds $IntervalSeconds
}
