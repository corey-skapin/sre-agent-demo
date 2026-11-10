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
        $text = ''
        if ($request.HasEntityBody) { $reader = [IO.StreamReader]::new($request.InputStream, [Text.Encoding]::UTF8); $text = $reader.ReadToEnd(); $reader.Dispose() }
        $body = if ($text) { $text | ConvertFrom-Json -AsHashtable -Depth 30 } else { $null }
        $null = $state.log.Add([pscustomobject]@{ method = $method; path = $path; ifMatch = $request.Headers['If-Match']; authorization = $request.Headers['Authorization']; body = $body })
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
        } elseif ($path -eq '/api/v1/threads') {
            Send-Reply $context 200 @{ value = @($state.threads) }
        } elseif ($path -match '^/api/v1/threads/(?<id>[^/]+)/messages$') {
            $id = $Matches.id
            $messages = if ($state.messages.ContainsKey($id)) { @($state.messages[$id]) } else { @() }
            Send-Reply $context 200 @{ value = $messages; state = 'Running' }
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
