Set-StrictMode -Version Latest

function Assert-SreName {
    param([string]$Value, [string]$Description, [string]$Pattern = '^[A-Za-z0-9][A-Za-z0-9_.-]{0,89}$')
    if ($Value -notmatch $Pattern) { throw "Invalid $Description '$Value'." }
}

function Assert-SreContextIds {
    param([string]$SubscriptionId, [string]$TenantId)
    foreach ($value in @($SubscriptionId, $TenantId)) {
        if ($value -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            throw 'Explicit GUID SubscriptionId and TenantId are required; ambient Azure context is not accepted.'
        }
    }
}

function Invoke-SreAz {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$SubscriptionId)
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --subscription $SubscriptionId --only-show-errors 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderrText = Get-Content -LiteralPath $stderrPath -Raw
        if ($exitCode -ne 0) { throw "az $($Arguments -join ' ') failed ($exitCode): $stderrText" }
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) { Write-Warning $stderrText.Trim() }
        return ($output | Out-String).Trim()
    } finally {
        Remove-Item -LiteralPath $stderrPath -Force
    }
}

function Assert-SreContext {
    param([string]$SubscriptionId, [string]$TenantId)
    Assert-SreContextIds -SubscriptionId $SubscriptionId -TenantId $TenantId
    $account = Invoke-SreAz -SubscriptionId $SubscriptionId -Arguments @('account', 'show', '-o', 'json') | ConvertFrom-Json
    if ($account.id -ne $SubscriptionId -or $account.tenantId -ne $TenantId -or $account.state -ne 'Enabled') {
        throw "Azure context does not match enabled subscription $SubscriptionId in tenant $TenantId. Sign in explicitly; no account selection was changed."
    }
    return $account
}

function Assert-SreArmId {
    param([string]$ResourceId, [string]$SubscriptionId, [string]$Description)
    $prefix = '/subscriptions/' + $SubscriptionId + '/resourceGroups/'
    if (-not $ResourceId.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
        $ResourceId -notmatch '^/subscriptions/[^/]+/resourceGroups/[A-Za-z0-9_.-]+(/providers/[A-Za-z0-9.]+/[^/\s]+/[^/\s]+(/[^/\s]+/[^/\s]+)*)?$') {
        throw "$Description must be a resource or resource-group ID in the explicit subscription: $ResourceId"
    }
}

function Assert-SreRunCommandResult {
    param([Parameter(Mandatory)][object]$Result)
    if ($Result -is [string]) { $Result = $Result | ConvertFrom-Json -Depth 100 }
    $properties = if ($Result.PSObject.Properties['properties']) { $Result.properties } else { $Result }
    if (-not $properties.PSObject.Properties['provisioningState'] -or $properties.provisioningState -ne 'Succeeded') {
        throw 'Arc Run Command did not report provisioningState Succeeded. Inspect the command; do not repeat a mutating guest action blindly.'
    }
    if (-not $properties.PSObject.Properties['instanceView'] -or $null -eq $properties.instanceView) {
        throw 'Arc Run Command guest completion is unverified: instanceView is missing. Inspect the saved command in Azure; do not repeat a mutating action blindly.'
    }
    $view = $properties.instanceView
    if (-not $view.PSObject.Properties['exitCode'] -or -not $view.PSObject.Properties['executionState'] -or
        $view.executionState -ne 'Succeeded' -or $view.exitCode -ne 0) {
        throw "Arc Run Command guest execution failed or remains pending: $($view | ConvertTo-Json -Compress -Depth 10)"
    }
    return $Result
}
