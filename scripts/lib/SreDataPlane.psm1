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
    if (([DateTime]::UtcNow - $Context.tokenAtUtc).TotalMinutes -gt 30) {
        $Context.token = Invoke-SreAz -SubscriptionId $Context.subscriptionId -Arguments @('account', 'get-access-token', '--resource', 'https://azuresre.dev', '--query', 'accessToken', '-o', 'tsv')
        $Context.tokenAtUtc = [DateTime]::UtcNow
    }
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

Export-ModuleMember -Function Get-SreProperty, New-SreDataContext, ConvertTo-SreDataContext, Invoke-SreData, Assert-SreDataSuccess, Get-SreThreads, Get-SreThreadMessages, Get-SrePendingCards, Remove-SreThread
