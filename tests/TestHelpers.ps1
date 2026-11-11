#Requires -Version 7.4
# Shared by the T12 test suites (Test-SreRelease, Test-SreReleaseExtras, Test-FridayRelease). Dot-source it. No Azure sign-in, no network beyond loopback.

function New-TestT12SkinFile {
    # Writes a schema-valid skin that requires the given scenarios plus the release section, and returns its path. The caller deletes it.
    param([Parameter(Mandatory)][string]$Root, [string[]]$Scenarios = @('T12'), [hashtable]$Release = @{})
    $data = Get-Content -LiteralPath (Join-Path $Root 'config\demo-skin.json') -Raw | ConvertFrom-Json -AsHashtable
    $data.sre.requiredScenarios = @($Scenarios)
    $section = @{ location = 'australiasoutheast'; appRepository = 'example-owner/ticketing-app'; goodVersion = 'v1.2.0'; badVersion = 'v1.3.0' }
    foreach ($key in $Release.Keys) { $section[$key] = $Release[$key] }
    $data.release = $section
    $path = Join-Path ([IO.Path]::GetTempPath()) "t12-skin-$([guid]::NewGuid()).json"
    [IO.File]::WriteAllText($path, ($data | ConvertTo-Json -Depth 20))
    return $path
}

function Get-TestT12Skin {
    param([Parameter(Mandatory)][string]$Root, [string[]]$Scenarios = @('T12'), [hashtable]$Release = @{})
    $path = New-TestT12SkinFile -Root $Root -Scenarios $Scenarios -Release $Release
    try { return Get-DemoSkin -Path $path -RepoRoot $Root } finally { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

$script:FakeAgentScript = @'
param($listener, $state)
function Send-Reply($context, [int]$status, $payload, [hashtable]$headers = @{}) {
    $text = if ($null -eq $payload) { '' } elseif ($payload -is [string]) { $payload } else { $payload | ConvertTo-Json -Depth 20 -Compress }
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $context.Response.StatusCode = $status
    $context.Response.ContentType = 'application/json'
    foreach ($key in $headers.Keys) { $context.Response.Headers.Add($key, [string]$headers[$key]) }
    $context.Response.ContentLength64 = $bytes.Length
    if ($bytes.Length) { $context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $context.Response.Close()
}
while ($listener.IsListening) {
    try { $context = $listener.GetContext() } catch { break }
    try {
        $request = $context.Request
        $method = $request.HttpMethod
        $path = $request.Url.AbsolutePath
        $raw = [byte[]]@()
        if ($request.HasEntityBody) { $memory = [IO.MemoryStream]::new(); $request.InputStream.CopyTo($memory); $raw = $memory.ToArray(); $memory.Dispose() }
        $isGzip = [string]$request.ContentType -like 'application/gzip*'
        $text = if ($raw.Length -and -not $isGzip) { [Text.Encoding]::UTF8.GetString($raw) } else { '' }
        $body = if ($text) { $text | ConvertFrom-Json -AsHashtable -Depth 30 } else { $null }
        $null = $state.log.Add([pscustomobject]@{ method = $method; path = $path; ifMatch = $request.Headers['If-Match']; authorization = $request.Headers['Authorization']; body = $body; bytes = $raw.Length; contentType = [string]$request.ContentType })
        if ($method -eq 'PUT' -and $state.failPut -and $path -match $state.failPut) {
            Send-Reply $context 400 @{ error = 'bad request' }
        } elseif ($path -eq '/api/v2/agent/settings/global') {
            if ($method -eq 'GET') {
                $headers = @{}
                if ($state.etag) { $headers['ETag'] = '"' + $state.etag + '"' }
                Send-Reply $context 200 @{ permissions = $state.policy } $headers
            } else {
                $match = $request.Headers['If-Match']
                if ($state.etag -and $match -ne '*' -and ($state.rejectEtagOnce -or $match -ne ('"' + $state.etag + '"'))) {
                    $state.rejectEtagOnce = $false
                    Send-Reply $context 412 @{ error = 'precondition failed' }
                } else {
                    if (-not $state.ignoreWrites) {
                        $state.policy = @{ allow = @($body.permissions.allow); ask = @($body.permissions.ask); deny = @($body.permissions.deny) }
                        if ($state.etag) { $state.etag = $state.etag + 'x' }
                    }
                    Send-Reply $context 202 $null
                }
            }
        } elseif ($path -eq '/api/v2/agent/customInstructions') {
            if ($method -eq 'GET') { Send-Reply $context 200 @{ instructions = $state.instructions } }
            else {
                if (-not $state.ignoreWrites) { $state.instructions = [string]$body.instructions }
                Send-Reply $context 202 $null
            }
        } elseif ($path -match '^/api/v2/extendedAgent/(?<kind>skills|hooks)/(?<name>[^/]+)$') {
            $kind = $Matches.kind
            $store = $state[$kind]
            $name = $Matches.name
            if ($method -eq 'GET') {
                if ($store.ContainsKey($name)) {
                    $item = $store[$name]
                    if ($state.omitSkillTools -and $kind -eq 'skills') {
                        # Some services drop an empty list on the way back out.
                        $item = $item | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -Depth 20
                        $null = $item.properties.Remove('tools')
                    }
                    if ($kind -eq 'hooks') {
                        # A live agent stores a hook but never returns properties.enabled.
                        $item = $item | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable -Depth 20
                        $null = $item.properties.Remove('enabled')
                    }
                    Send-Reply $context 200 $item
                } else { Send-Reply $context 404 @{ error = 'not found' } }
            } else {
                if (-not $state.ignoreWrites) { $store[$name] = $body }
                Send-Reply $context 202 $null
            }
        } elseif ($path -eq '/api/v2/github/domains') {
            if ($state.domainsStatus -ne 200) { Send-Reply $context ([int]$state.domainsStatus) @{ error = 'unavailable' } }
            else { Send-Reply $context 200 @{ values = @($state.domains) } }
        } elseif ($path -eq '/api/v2/github/oauth/config') {
            if ($state.signInOnOAuth) { $state.domains = @(@{ name = 'github.com'; authType = 'OAuth' }) }
            Send-Reply $context 200 @{ oAuthUrl = $state.oauthUrl }
        } elseif ($path -match '^/api/v2/repos/(?<name>[^/]+)/test$') {
            Send-Reply $context 200 @{ ok = $true }
        } elseif ($path -match '^/api/v2/repos/(?<name>[^/]+)$') {
            $name = $Matches.name
            if ($method -eq 'GET') {
                if ($state.repos.ContainsKey($name)) { Send-Reply $context 200 $state.repos[$name] } else { Send-Reply $context 404 @{ error = 'not found' } }
            } else {
                if (-not $state.ignoreWrites) {
                    $stored = $body
                    $stored.properties.latestCommit = 'abcdef0123456789'
                    $state.repos[$name] = $stored
                }
                Send-Reply $context 202 $null
            }
        } elseif ($path -match '^/api/v2/extendedAgent/scheduledtasks/(?<name>[^/]+)$') {
            $name = [uri]::UnescapeDataString($Matches.name)
            if ($method -eq 'GET') {
                if ($state.tasks.ContainsKey($name)) {
                    $task = $state.tasks[$name].Clone()
                    if ($state.omitTaskId) { $task.Remove('id') }
                    if ($state.taskEnvelope) { Send-Reply $context 200 @{ name = $name; type = 'ScheduledTask'; properties = $task } } else { Send-Reply $context 200 $task }
                } else { Send-Reply $context 404 @{ error = 'not found' } }
            } else {
                if (-not $state.ignoreWrites) {
                    $p = $body.properties
                    $existing = if ($state.tasks.ContainsKey($name)) { $state.tasks[$name] } else { $null }
                    # The live service ignores isEnabled: a new task starts Active and an existing one keeps its status.
                    $status = if ($existing) { $existing.status } else { 'Active' }
                    if ($state.honorIsEnabled) { $status = if ($p.isEnabled -ne $false) { 'Active' } else { 'Paused' } }
                    $state.tasks[$name] = @{
                        id = $(if ($existing) { $existing.id } else { [guid]::NewGuid().ToString() }); name = $name; description = $p.description
                        status = $status; cronExpression = $p.cronExpression; agentPrompt = $p.agentPrompt; agent = $p.agent
                        agentMode = $p.agentMode; executionCount = $(if ($existing) { $existing.executionCount } else { 0 }); lastExecutionTime = $null; nextExecutionTime = $null; threadId = $null
                    }
                }
                Send-Reply $context 202 $null
            }
        } elseif ($path -eq '/api/v1/scheduledtasks') {
            # The live service lists the tasks as a bare array; a list under 'value' is the other shape the code accepts.
            if ($state.listAsValue) { Send-Reply $context 200 @{ value = @($state.tasks.Values) } } else { Send-Reply $context 200 (ConvertTo-Json -InputObject @($state.tasks.Values) -Depth 20 -Compress) }
        } elseif ($path -match '^/api/v1/scheduledtasks/(?<id>[^/]+)/(?<verb>pause|resume)$' -and $method -eq 'POST') {
            $verb = $Matches.verb
            $found = @($state.tasks.Values | Where-Object { $_.id -eq $Matches.id }) | Select-Object -First 1
            if (-not $found) { Send-Reply $context 404 @{ error = 'no such task' } }
            else {
                if (-not $state.ignorePause) { $found.status = $(if ($verb -eq 'pause') { 'Paused' } else { 'Active' }) }
                Send-Reply $context 200 @{ message = "Scheduled task $($verb)d successfully" }
            }
        } elseif ($path -match '^/api/v1/scheduledtasks/(?<id>[^/]+)/execute$' -and $method -eq 'POST') {
            $found = @($state.tasks.Values | Where-Object { $_.id -eq $Matches.id }) | Select-Object -First 1
            if (-not $found) { Send-Reply $context 404 @{ error = 'no such task' } }
            elseif ($state.refuseRunNow -and $found.status -ne 'Active') { Send-Reply $context 409 @{ error = 'task is not active' } }
            else {
                $threadId = [guid]::NewGuid().ToString()
                $found.executionCount = [int]$found.executionCount + 1
                $found.threadId = $threadId
                $state.threads = @($state.threads) + @(@{ id = $threadId })
                $state.messages[$threadId] = @(@{ id = 'm1'; text = 'report' })
                $state.threadStates[$threadId] = $state.runThreadState
                Send-Reply $context 200 @{ execution = @{ threadId = $threadId; manualExecution = $true } }
            }
        } elseif ($path -eq '/api/v2/extendedAgent/workspace/agent/files/list') {
            $folder = [string]$request.QueryString['path']
            $prefix = $folder.TrimEnd('/') + '/'
            $known = $folder -eq '/root/sreagent/terminalRoot' -or @($state.dirs) -contains $folder -or @($state.files.Keys | Where-Object { $_.StartsWith($prefix) }).Count -gt 0 -or @($state.dirs | Where-Object { $_.StartsWith($prefix) }).Count -gt 0
            if ($state.listStatus -ne 200) { Send-Reply $context ([int]$state.listStatus) @{ error = 'list failed' } }
            elseif (-not $known) { Send-Reply $context ([int]$state.missingFolderStatus) @{ error = 'no such folder' } }
            else {
                $entries = [Collections.Generic.List[object]]::new()
                $seen = @{}
                foreach ($filePath in @($state.files.Keys | Sort-Object)) {
                    if (-not $filePath.StartsWith($prefix)) { continue }
                    $rest = $filePath.Substring($prefix.Length)
                    $first = ($rest -split '/')[0]
                    if ($seen.ContainsKey($first)) { continue }
                    $seen[$first] = $true
                    $isDir = $rest.Contains('/')
                    $entries.Add(@{ name = $first; path = $prefix + $first; size = $(if ($isDir) { 0 } else { $state.files[$filePath].Length }); isDir = $isDir; isSymlink = $false; modifiedTime = $(if ($state.epochTimes) { 1794376277 } else { '2026-11-12T00:00:00Z' }) })
                }
                foreach ($dir in @($state.dirs)) {
                    if (-not $dir.StartsWith($prefix)) { continue }
                    $first = ($dir.Substring($prefix.Length) -split '/')[0]
                    if ($first -and -not $seen.ContainsKey($first)) { $seen[$first] = $true; $entries.Add(@{ name = $first; path = $prefix + $first; size = 0; isDir = $true; isSymlink = $false; modifiedTime = '2026-11-12T00:00:00Z' }) }
                }
                Send-Reply $context 200 @{ root = '/root/sreagent/terminalRoot'; path = $folder; entries = @($entries.ToArray()) }
            }
        } elseif ($path -eq '/api/v2/extendedAgent/workspace/agent/files/content') {
            $file = [string]$request.QueryString['path']
            if ($state.files.ContainsKey($file)) {
                $bytes = [byte[]]$state.files[$file]
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'application/octet-stream'
                $context.Response.ContentLength64 = $bytes.Length
                if ($bytes.Length) { $context.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
                $context.Response.Close()
            } else { Send-Reply $context 404 @{ error = 'no such file' } }
        } elseif ($path -eq '/api/v1/WorkspaceMemory/synthesized-knowledge' -and $method -eq 'POST') {
            if ($state.ignoreUpload) { Send-Reply $context 200 $null }
            else {
                try {
                    $packed = [IO.MemoryStream]::new($raw)
                    $gzip = [IO.Compression.GZipStream]::new($packed, [IO.Compression.CompressionMode]::Decompress)
                    $unpacked = [IO.MemoryStream]::new()
                    $gzip.CopyTo($unpacked)
                    $tar = $unpacked.ToArray()
                    $offset = 0
                    $names = @()
                    while ($offset + 512 -le $tar.Length) {
                        $header = [byte[]]($tar[$offset..($offset + 511)])
                        if (@($header | Where-Object { $_ -ne 0 }).Count -eq 0) { break }
                        $entryName = [Text.Encoding]::ASCII.GetString($header, 0, 100).Split([char]0)[0]
                        $size = [Convert]::ToInt64([Text.Encoding]::ASCII.GetString($header, 124, 11).Trim([char]0, ' '), 8)
                        $stored = [Convert]::ToInt64([Text.Encoding]::ASCII.GetString($header, 148, 6).Trim([char]0, ' '), 8)
                        $sum = 0
                        for ($i = 0; $i -lt 512; $i++) { $sum += $(if ($i -ge 148 -and $i -lt 156) { 32 } else { $header[$i] }) }
                        if ($sum -ne $stored) { throw "bad tar checksum for $entryName" }
                        $offset += 512
                        if ([char]$header[156] -eq '0') {
                            $content = if ($size -gt 0) { [byte[]]($tar[$offset..($offset + $size - 1)]) } else { [byte[]]@() }
                            $relative = if ($entryName.StartsWith('./')) { $entryName.Substring(2) } else { $entryName }
                            $state.files["/root/sreagent/terminalRoot/memories/synthesizedKnowledge/$relative"] = $content
                            $names += $relative
                            $offset += [int]([Math]::Ceiling($size / 512.0) * 512)
                        }
                    }
                    $state.uploads = @($state.uploads) + @(, $names)
                    Send-Reply $context 200 $null
                } catch { Send-Reply $context 400 @{ error = $_.Exception.Message } }
            }
        } elseif ($path -eq '/api/v1/threads') {
            Send-Reply $context 200 @{ value = @($state.threads) }
        } elseif ($path -match '^/api/v1/threads/(?<id>[^/]+)/messages$') {
            $id = $Matches.id
            $messages = if ($state.messages.ContainsKey($id)) { @($state.messages[$id]) } else { @() }
            $threadState = if ($state.threadStates.ContainsKey($id)) { $state.threadStates[$id] } else { 'Running' }
            Send-Reply $context 200 @{ value = $messages; state = $threadState }
        } elseif ($path -match '^/api/v1/threads/(?<id>[^/]+)$' -and $method -eq 'DELETE') {
            $state.threads = @($state.threads | Where-Object { $_.id -ne $Matches.id })
            Send-Reply $context 200 $null
        } else {
            Send-Reply $context 404 @{ error = 'no such route' }
        }
    } catch {
        try { Send-Reply $context 500 @{ error = $_.Exception.Message } } catch { }
    }
}
'@

function Start-FakeAgent {
    <#
    .SYNOPSIS
    Starts a small stateful stand-in for the SRE agent's data plane on a loopback port, so the real Invoke-SreData code runs against it.
    Returns a handle with .endpoint, .state (settings, instructions, skills, hooks, repos, domains, threads, messages, log) and the pieces Stop-FakeAgent disposes.
    #>
    $tcp = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $tcp.Start()
    $port = $tcp.LocalEndpoint.Port
    $tcp.Stop()
    $listener = [Net.HttpListener]::new()
    $listener.Prefixes.Add("http://127.0.0.1:$port/")
    $listener.Start()
    $githubHost = 'github.com'
    $state = [hashtable]::Synchronized(@{
        policy = @{ allow = @(); ask = @(); deny = @() }; etag = $null; instructions = ''; oauthUrl = "https://$githubHost/login/oauth/authorize?client_id=test"
        skills = @{}; hooks = @{}; repos = @{}; domains = @(); signInOnOAuth = $true; ignoreWrites = $false; rejectEtagOnce = $false; failPut = $null
        omitSkillTools = $false; domainsStatus = 200
        tasks = @{}; files = @{}; dirs = @(); threadStates = @{}; taskEnvelope = $false; honorIsEnabled = $false; ignorePause = $false; listAsValue = $false; refuseRunNow = $false; omitTaskId = $false; epochTimes = $false
        ignoreUpload = $false; uploads = @(); runThreadState = 'Idle'; listStatus = 200; missingFolderStatus = 404
        threads = @(); messages = @{}; log = [Collections.ArrayList]::Synchronized([Collections.ArrayList]::new())
    })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $shell = [powershell]::Create()
    $shell.Runspace = $runspace
    $null = $shell.AddScript($script:FakeAgentScript).AddArgument($listener).AddArgument($state)
    $handle = $shell.BeginInvoke()
    [pscustomobject]@{ endpoint = "http://127.0.0.1:$port"; state = $state; listener = $listener; shell = $shell; runspace = $runspace; handle = $handle }
}

function Stop-FakeAgent {
    param([Parameter(Mandatory)]$Agent)
    try { $Agent.listener.Stop(); $Agent.listener.Close() } catch { }
    try { if (-not $Agent.handle.AsyncWaitHandle.WaitOne(5000)) { $Agent.shell.Stop() } } catch { }
    try { $Agent.shell.Dispose(); $Agent.runspace.Dispose() } catch { }
}

function New-TestDataContext {
    param([Parameter(Mandatory)]$Agent, [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$TenantId)
    @{
        endpoint = $Agent.endpoint; token = 'test-token'; tokenAtUtc = [DateTime]::UtcNow; subscriptionId = $SubscriptionId; tenantId = $TenantId
        resourceId = "/subscriptions/$SubscriptionId/resourceGroups/rg-arc-demo-sre/providers/Microsoft.App/agents/sre-arc-demo"
    }
}

function Get-FakeAgentWrites {
    # The PUT, POST and DELETE requests the fake agent received (after the first Since requests), as "METHOD path", in order.
    param([Parameter(Mandatory)]$Agent, [int]$Since = 0)
    @($Agent.state.log | Select-Object -Skip $Since | Where-Object { $_.method -in @('PUT', 'POST', 'DELETE') } | ForEach-Object { "$($_.method) $($_.path)" })
}
