Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'SreRuntime.psm1')
Import-Module (Join-Path $PSScriptRoot 'SreConfiguration.psm1')

# Data-plane calls to a running SRE agent. Every function here reads or writes with the signed-in CLI identity's
# token for the SRE audience; no token is stored or printed. The agent must already be in Review mode.

function Get-SreProperty {
    # Strict-mode-safe property read on parsed JSON.
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } else { return $null } }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function New-SreDataContext {
    <#
    .SYNOPSIS
    Reads the agent from ARM (it must be Succeeded, Running and in Review mode) and returns its data-plane endpoint and a token.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ResourceGroupName, [Parameter(Mandatory)][string]$AgentName,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
    )
    Assert-SreName -Value $ResourceGroupName -Description 'resource group'
    Assert-SreName -Value $AgentName -Description 'agent name'
    $session = New-SreConfigurationSession -TimeoutSeconds $TimeoutSeconds -Desired @{
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceGroup = $ResourceGroupName; agentName = $AgentName
    }
    @{
        endpoint = $session.endpoint; token = $session.token; tokenAtUtc = [DateTime]::UtcNow
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceId = $session.resourceId
    }
}

function ConvertTo-SreDataContext {
    # Wraps a session from New-SreConfigurationSession so one parent lookup and one token serve both.
    param([Parameter(Mandatory)][Collections.IDictionary]$Session, [Parameter(Mandatory)][string]$SubscriptionId, [Parameter(Mandatory)][string]$TenantId)
    @{
        endpoint = $Session.endpoint; token = $Session.token; tokenAtUtc = [DateTime]::UtcNow
        subscriptionId = $SubscriptionId; tenantId = $TenantId; resourceId = $Session.resourceId
    }
}

function Update-SreDataToken {
    # A long run outlives its token, so ask for a fresh one once the current one is 30 minutes old.
    param([Parameter(Mandatory)][Collections.IDictionary]$Context)
    if (([DateTime]::UtcNow - $Context.tokenAtUtc).TotalMinutes -gt 30) {
        $Context.token = Invoke-SreAz -SubscriptionId $Context.subscriptionId -Arguments @('account', 'get-access-token', '--resource', 'https://azuresre.dev', '--query', 'accessToken', '-o', 'tsv')
        $Context.tokenAtUtc = [DateTime]::UtcNow
    }
}

function Invoke-SreData {
    <#
    .SYNOPSIS
    One data-plane call. Returns Status, Ms, Headers and the parsed Body, including for 4xx and 5xx (it does not throw on HTTP errors).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][ValidatePattern('^/api/v[12]/[A-Za-z0-9_./%~$?&=,:+-]+$')][string]$Path,
        [AllowNull()]$Body,
        [hashtable]$Headers = @{},
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 60
    )
    Update-SreDataToken -Context $Context
    $request = @{
        Uri = $Context.endpoint + $Path; Method = $Method; TimeoutSec = $TimeoutSeconds
        Headers = @{ Authorization = "Bearer $($Context.token)" } + $Headers
        SkipHttpErrorCheck = $true; StatusCodeVariable = 'status'; ResponseHeadersVariable = 'responseHeaders'
    }
    if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $request.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
        $request.ContentType = 'application/json'
    }
    $status = 0
    $responseHeaders = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $parsed = Invoke-RestMethod @request
    $clock.Stop()
    [pscustomobject]@{ Status = [int]$status; Ms = [int]$clock.ElapsedMilliseconds; Headers = $responseHeaders; Body = $parsed }
}

function Assert-SreDataSuccess {
    param([Parameter(Mandatory)]$Response, [Parameter(Mandatory)][string]$What)
    if ($Response.Status -lt 200 -or $Response.Status -ge 300) {
        $detail = try { ($Response.Body | ConvertTo-Json -Compress -Depth 4) } catch { [string]$Response.Body }
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) }
        throw "$What failed: HTTP $($Response.Status) $detail"
    }
}

function Get-SreThreads {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [ValidateRange(1, 100)][int]$Top = 20)
    $query = '$top=' + $Top + '&$orderby=' + [uri]::EscapeDataString('createdTimestamp desc')
    $response = Invoke-SreData -Context $Context -Method GET -Path "/api/v1/threads?$query"
    Assert-SreDataSuccess -Response $response -What 'List threads'
    @(Get-SreProperty $response.Body 'value' | Where-Object { $null -ne $_ })
}

function Get-SreThreadMessages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.:-]+$')][string]$ThreadId, [ValidateRange(1, 500)][int]$Top = 200)
    $response = Invoke-SreData -Context $Context -Method GET -Path "/api/v1/threads/$ThreadId/messages?skip=0&top=$Top&orderby=timestamp"
    Assert-SreDataSuccess -Response $response -What 'Read thread messages'
    [pscustomobject]@{ State = [string](Get-SreProperty $response.Body 'state'); Messages = @(Get-SreProperty $response.Body 'value' | Where-Object { $null -ne $_ }) }
}

function Get-SrePendingCards {
    <#
    .SYNOPSIS
    The cards in a message list that wait for a person: Azure CLI write cards and permission-rule cards. Reads only; it never decides a card.
    #>
    param([AllowNull()][object[]]$Messages)
    foreach ($message in @($Messages)) {
        $cli = Get-SreProperty $message 'azCliExecution'
        if ($cli -and [string](Get-SreProperty $cli 'status') -eq 'Pending') {
            [pscustomobject]@{ kind = 'azure-write'; id = [string](Get-SreProperty $cli 'id'); created = [string](Get-SreProperty $cli 'createdTimestamp')
                summary = [string](Get-SreProperty $cli 'description'); detail = (Get-SreProperty $cli 'originalFunctionCall') }
        }
        $approval = Get-SreProperty $message 'approval'
        if ($approval -and [string](Get-SreProperty $approval 'status') -eq 'Pending') {
            [pscustomobject]@{ kind = 'permission-rule'; id = [string](Get-SreProperty $approval 'id'); created = [string](Get-SreProperty $approval 'createdTimestamp')
                summary = [string](Get-SreProperty $approval 'title'); detail = (Get-SreProperty $approval 'command') }
        }
    }
}

function Remove-SreThread {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.:-]+$')][string]$ThreadId)
    if ($PSCmdlet.ShouldProcess($ThreadId, 'delete the investigation thread')) {
        Invoke-SreData -Context $Context -Method DELETE -Path "/api/v1/threads/$ThreadId"
    }
}

function Invoke-SreDataRaw {
    <#
    .SYNOPSIS
    One data-plane call whose body or answer is bytes: a gzip upload or a file download. Returns Status, Ms and Bytes; it does not throw on HTTP errors.
    Body holds the answer as text only when the status is not 2xx, so Assert-SreDataSuccess can name the failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary]$Context,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
        [Parameter(Mandatory)][ValidatePattern('^/api/v[12]/[A-Za-z0-9_./%~$?&=,:+-]+$')][string]$Path,
        [byte[]]$Bytes,
        [ValidatePattern('^[a-z]+/[a-z0-9.+-]+$')][string]$ContentType = 'application/octet-stream',
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 60
    )
    Update-SreDataToken -Context $Context
    $request = @{
        Uri = $Context.endpoint + $Path; Method = $Method; TimeoutSec = $TimeoutSeconds
        Headers = @{ Authorization = "Bearer $($Context.token)" }; SkipHttpErrorCheck = $true
    }
    if ($PSBoundParameters.ContainsKey('Bytes')) { $request.Body = $Bytes; $request.ContentType = $ContentType }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-WebRequest @request
    $clock.Stop()
    # An if expression would unroll a one-byte answer into a scalar and an empty one into $null, so the bytes are assigned inside the branch.
    $answer = [byte[]]::new(0)
    if ($response.RawContentStream) { $answer = $response.RawContentStream.ToArray() }
    $status = [int]$response.StatusCode
    [pscustomobject]@{
        Status = $status; Ms = [int]$clock.ElapsedMilliseconds; Bytes = $answer
        Body = $(if ($status -lt 200 -or $status -ge 300) { [Text.Encoding]::UTF8.GetString($answer) } else { $null })
    }
}

# The agent's workspace: a file API that lists and reads (it has no write or delete route). Notes live under memories/synthesizedKnowledge,
# files an agent builds for a thread under tmp/ThreadFiles/<threadId>.
$script:WorkspaceRoot = '/root/sreagent/terminalRoot'

function Get-SreWorkspaceRoot { return $script:WorkspaceRoot }

function Assert-SreWorkspacePath {
    # Only plain paths inside the agent's workspace root: no '.' or '..' segments and no unusual characters.
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -cnotmatch '^/root/sreagent/terminalRoot(/[A-Za-z0-9_.: -]+)*$' -or @($Path -split '/') -contains '..' -or @($Path -split '/') -contains '.') {
        throw "Not a plain path inside the agent workspace: '$Path'."
    }
}

function Get-SreWorkspaceEntries {
    # One folder of the workspace: name, path, size, isDir, modifiedTime. A failed read throws; it is never taken for an empty folder.
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Path)
    Assert-SreWorkspacePath -Path $Path
    $response = Invoke-SreData -Context $Context -Method GET -Path "/api/v2/extendedAgent/workspace/agent/files/list?path=$([uri]::EscapeDataString($Path))"
    Assert-SreDataSuccess -Response $response -What "List $Path"
    @(Get-SreProperty $response.Body 'entries' | Where-Object { $null -ne $_ })
}

function Get-SreWorkspaceFiles {
    <#
    .SYNOPSIS
    Every file under a workspace folder as path, relativePath, size and modified. Symlinks, folders below MaxDepth and anything past MaxFiles are skipped.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Path,
        [ValidateRange(0, 8)][int]$MaxDepth = 4, [ValidateRange(1, 1000)][int]$MaxFiles = 300)
    $found = [Collections.Generic.List[object]]::new()
    function Add-WorkspaceFolder([string]$Folder, [string]$Relative, [int]$Depth) {
        foreach ($entry in Get-SreWorkspaceEntries -Context $Context -Path $Folder) {
            $name = [string](Get-SreProperty $entry 'name')
            if (-not $name -or (Get-SreProperty $entry 'isSymlink') -or $found.Count -ge $MaxFiles) { continue }
            $childRelative = if ($Relative) { "$Relative/$name" } else { $name }
            if (Get-SreProperty $entry 'isDir') {
                if ($Depth -lt $MaxDepth) { Add-WorkspaceFolder -Folder "$Folder/$name" -Relative $childRelative -Depth ($Depth + 1) }
            } else {
                $found.Add([pscustomobject]@{ path = "$Folder/$name"; relativePath = $childRelative; size = [long](Get-SreProperty $entry 'size'); modified = [string](Get-SreProperty $entry 'modifiedTime') })
            }
        }
    }
    Add-WorkspaceFolder -Folder $Path -Relative '' -Depth 0
    return @($found.ToArray())
}

function Get-SreWorkspaceFile {
    # The raw bytes of one workspace file.
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Path)
    Assert-SreWorkspacePath -Path $Path
    $response = Invoke-SreDataRaw -Context $Context -Method GET -Path "/api/v2/extendedAgent/workspace/agent/files/content?path=$([uri]::EscapeDataString($Path))"
    Assert-SreDataSuccess -Response $response -What "Read $Path"
    return , $response.Bytes
}

function Test-SreWorkspaceFolder {
    # True when the folder exists, shown by listing each level down from the workspace root. A failed read throws instead of reading as absent.
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][string]$Path)
    Assert-SreWorkspacePath -Path $Path
    $current = $script:WorkspaceRoot
    foreach ($segment in @($Path.Substring($script:WorkspaceRoot.Length) -split '/' | Where-Object { $_ })) {
        $inside = @(Get-SreWorkspaceEntries -Context $Context -Path $current | Where-Object { [string](Get-SreProperty $_ 'name') -ceq $segment -and (Get-SreProperty $_ 'isDir') })
        if (-not $inside.Count) { return $false }
        $current = "$current/$segment"
    }
    return $true
}

function Get-SreNotesState {
    <#
    .SYNOPSIS
    Whether the agent's notes folder exists and what it holds. An absent folder is shown to be absent, and a failed read throws: it is never mistaken for empty.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context)
    $path = "$script:WorkspaceRoot/memories/synthesizedKnowledge"
    if (-not (Test-SreWorkspaceFolder -Context $Context -Path $path)) { return [pscustomobject]@{ exists = $false; path = $path; files = @() } }
    [pscustomobject]@{ exists = $true; path = $path; files = @(Get-SreWorkspaceFiles -Context $Context -Path $path) }
}

function New-SreNotesArchive {
    <#
    .SYNOPSIS
    A gzip tar of plain text files (name to text), built here so no tar program is needed. Fixed timestamps: the same notes give the same bytes.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Files)
    $block = 512
    $tar = [IO.MemoryStream]::new()
    function Write-TarEntry([string]$Name, [byte[]]$Content, [bool]$IsDirectory) {
        $header = [byte[]]::new($block)
        $put = { param([int]$Offset, [string]$Text) $bytes = [Text.Encoding]::ASCII.GetBytes($Text); [Array]::Copy($bytes, 0, $header, $Offset, $bytes.Length) }
        & $put 0 $Name
        & $put 100 $(if ($IsDirectory) { '0000755' } else { '0000644' })
        & $put 108 '0000000'
        & $put 116 '0000000'
        & $put 124 ([Convert]::ToString([long]$Content.Length, 8).PadLeft(11, '0'))
        & $put 136 '00000000000'
        & $put 148 '        '
        & $put 156 $(if ($IsDirectory) { '5' } else { '0' })
        & $put 257 'ustar'
        & $put 263 '00'
        $sum = 0
        foreach ($byte in $header) { $sum += $byte }
        & $put 148 ([Convert]::ToString($sum, 8).PadLeft(6, '0'))
        $header[154] = 0
        $header[155] = 32
        $tar.Write($header, 0, $block)
        if ($Content.Length) {
            $tar.Write($Content, 0, $Content.Length)
            $padding = ($block - ($Content.Length % $block)) % $block
            if ($padding) { $tar.Write([byte[]]::new($padding), 0, $padding) }
        }
    }
    $directories = [Collections.Generic.HashSet[string]]::new()
    foreach ($name in @($Files.Keys | Sort-Object)) {
        if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*$' -or $name.Length -gt 90) { throw "Notes file name '$name' is not a plain relative path." }
        $parts = @($name -split '/')
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $directory = $parts[0..$i] -join '/'
            if ($directories.Add($directory)) { Write-TarEntry -Name "./$directory/" -Content ([byte[]]@()) -IsDirectory $true }
        }
        Write-TarEntry -Name "./$name" -Content ([Text.Encoding]::UTF8.GetBytes([string]$Files[$name])) -IsDirectory $false
    }
    $tar.Write([byte[]]::new($block * 2), 0, $block * 2)
    $packed = [IO.MemoryStream]::new()
    $gzip = [IO.Compression.GZipStream]::new($packed, [IO.Compression.CompressionLevel]::Optimal, $true)
    $gzip.Write($tar.ToArray(), 0, [int]$tar.Length)
    $gzip.Dispose()
    return , $packed.ToArray()
}

function Send-SreNotes {
    <#
    .SYNOPSIS
    Puts notes files (name to text) into the agent's notes folder through the one route that takes them, a gzip tar. The caller decides when that is safe:
    the route's effect on files already there is not known, so Invoke-SreActs only calls it for an empty folder.
    #>
    param([Parameter(Mandatory)][Collections.IDictionary]$Context, [Parameter(Mandatory)][Collections.IDictionary]$Files)
    $archive = New-SreNotesArchive -Files $Files
    Invoke-SreDataRaw -Context $Context -Method POST -Path '/api/v1/WorkspaceMemory/synthesized-knowledge' -Bytes $archive -ContentType 'application/gzip'
}

Export-ModuleMember -Function Get-SreProperty, New-SreDataContext, ConvertTo-SreDataContext, Invoke-SreData, Assert-SreDataSuccess, Get-SreThreads, Get-SreThreadMessages, Get-SrePendingCards, Remove-SreThread, Invoke-SreDataRaw, Get-SreWorkspaceRoot, Assert-SreWorkspacePath, Get-SreWorkspaceEntries, Get-SreWorkspaceFiles, Get-SreWorkspaceFile, Test-SreWorkspaceFolder, Get-SreNotesState, New-SreNotesArchive, Send-SreNotes
