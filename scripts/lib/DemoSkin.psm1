function ConvertTo-DemoHashtable {
    [CmdletBinding()]
    param([AllowNull()][object]$InputObject)

    if ($null -eq $InputObject) { return @{} }
    if ($InputObject -is [string] -or $InputObject -is [ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-DemoHashtable -InputObject $InputObject[$key]
        }
        return $result
    }
    if ($InputObject -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-DemoHashtable -InputObject $property.Value
        }
        return $result
    }
    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        return ,@($InputObject | ForEach-Object { ConvertTo-DemoHashtable -InputObject $_ })
    }
    return $InputObject
}

function Get-DemoSkin {
    [CmdletBinding()]
    param(
        [string]$Path = '',
        [string]$RepoRoot = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    )

    $skinPath = if ([string]::IsNullOrWhiteSpace($Path)) {
        Join-Path $RepoRoot 'config\demo-skin.json'
    } elseif ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        Join-Path $RepoRoot $Path
    }

    if (-not (Test-Path -LiteralPath $skinPath)) {
        throw "Demo skin not found: $skinPath"
    }

    $json = Get-Content -LiteralPath $skinPath -Raw
    $schemaPath = Join-Path $RepoRoot 'config\demo-skin.schema.json'
    if (-not (Test-Json -Json $json -SchemaFile $schemaPath -ErrorAction Stop)) {
        throw "Invalid demo skin: $skinPath"
    }
    return ConvertTo-DemoHashtable -InputObject ($json | ConvertFrom-Json -Depth 30)
}

function Get-DemoSkinValue {
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Skin,
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][object]$Default
    )

    $current = $Skin
    foreach ($part in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        if ($current -is [System.Collections.IDictionary] -and $current.Contains($part)) {
            $current = $current[$part]
            continue
        }
        $property = $current.PSObject.Properties[$part]
        if ($property) {
            $current = $property.Value
            continue
        }
        return $Default
    }

    if ($null -eq $current -or ([string]$current -eq '')) { return $Default }
    return $current
}

function Merge-DemoHashtable {
    [CmdletBinding()]
    param(
        [System.Collections.IDictionary]$Defaults = @{},
        [AllowNull()][object]$Overrides
    )

    $result = [ordered]@{}
    foreach ($key in $Defaults.Keys) {
        $result[$key] = $Defaults[$key]
    }

    $overrideTable = ConvertTo-DemoHashtable -InputObject $Overrides
    if ($overrideTable -is [System.Collections.IDictionary]) {
        foreach ($key in $overrideTable.Keys) {
            if ($null -ne $overrideTable[$key] -and ([string]$overrideTable[$key] -ne '')) {
                $result[$key] = $overrideTable[$key]
            }
        }
    }

    return $result
}
