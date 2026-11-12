# Repairs the line-of-business app after a fault: sets FaultMode back to Healthy, restarts its scheduled task and prints one result line.
# Installed on the server by Invoke-ArcServerRoom.ps1 -Action Prepare; the SRE agent runs it through one Run Command that a person approves.
# It changes nothing when the app is already Healthy. The previous config stays beside it as appsettings.json.bak.
$ErrorActionPreference = 'Stop'
$task = '{lobTaskName}'
$path = Join-Path '{lobAppRoot}' 'appsettings.json'
$config = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$was = [string]$config.FaultMode
if ($was -ne 'Healthy') {
    Copy-Item -LiteralPath $path -Destination "$path.bak" -Force
    $config.FaultMode = 'Healthy'
    $config | Add-Member -NotePropertyName IncidentId -NotePropertyValue 'repaired' -Force
    $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    # The task allows one instance, so a worker that outlived the stop would make the start below do nothing. End it only if it is the app's own script.
    $pidPath = Join-Path '{lobAppRoot}' 'lob-arc-app.pid'
    if ((Test-Path -LiteralPath $pidPath) -and ((Get-Content -LiteralPath $pidPath -Raw) -match '^\s*([1-9]\d*)\s*$')) {
        $worker = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Matches[1])" -ErrorAction SilentlyContinue
        if ($worker -and $worker.CommandLine -like '*LobArcBridgeApp.ps1*') { Stop-Process -Id $worker.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Start-ScheduledTask -TaskName $task
    Start-Sleep -Seconds 8
}
$now = [string](Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).FaultMode
$state = [string](Get-ScheduledTask -TaskName $task).State
$last = (Get-ScheduledTaskInfo -TaskName $task).LastTaskResult
"was=$was now=$now state=$state last=$last"
if ($now -ne 'Healthy' -or $state -ne 'Running') { throw "The app is not healthy after the repair: now=$now state=$state." }
