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

function Get-SreAzInvocation {
    param([Parameter(Mandatory)][object]$Command)
    if ($Command.CommandType -eq 'Application' -and [IO.Path]::GetExtension($Command.Source) -in @('.cmd', '.bat')) {
        $python = [IO.Path]::GetFullPath((Join-Path (Split-Path $Command.Source -Parent) '..\python.exe'))
        if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
            throw 'Windows Azure CLI launcher requires its bundled python.exe. Repair the Azure CLI installation; unsafe cmd.exe argument forwarding is not used.'
        }
        # Match the MSI launcher without cmd.exe interpreting query/guest arguments.
        return @{ command = $python; prefix = @('-IBm', 'azure.cli'); installer = 'MSI' }
    }
    return @{ command = 'az'; prefix = @(); installer = $null }
}

function Get-SreAzWarningText {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # An Azure CLI extension's help text can trigger a Python SyntaxWarning (two lines per hit) on every call; it is harmless noise.
    return [regex]::Replace($Text, '(?m)^[^\r\n]*\.py:\d+: SyntaxWarning: [^\r\n]*(?:\r?\n[ \t]+[^\r\n]*)?(?:\r?\n|\z)', '')
}

function Invoke-SreAz {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$SubscriptionId)
    $az = Get-Command az -ErrorAction SilentlyContinue
    if (-not $az) { throw 'Azure CLI (az) is required.' }
    $invocation = Get-SreAzInvocation -Command $az
    $prefix = $invocation.prefix
    $previousInstaller = [Environment]::GetEnvironmentVariable('AZ_INSTALLER', 'Process')
    $stderrPath = [IO.Path]::GetTempFileName()
    try {
        if ($invocation.installer) { [Environment]::SetEnvironmentVariable('AZ_INSTALLER', $invocation.installer, 'Process') }
        $output = & $invocation.command @prefix @Arguments --subscription $SubscriptionId --only-show-errors 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stderrText = Get-Content -LiteralPath $stderrPath -Raw
        if ($exitCode -ne 0) { throw "az $($Arguments -join ' ') failed ($exitCode): $stderrText" }
        $warningText = Get-SreAzWarningText -Text $stderrText
        if (-not [string]::IsNullOrWhiteSpace($warningText)) { Write-Warning $warningText.Trim() }
        return ($output | Out-String).Trim()
    } finally {
        if ($invocation.installer) { [Environment]::SetEnvironmentVariable('AZ_INSTALLER', $previousInstaller, 'Process') }
        Remove-Item -LiteralPath $stderrPath -Force -WhatIf:$false
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
