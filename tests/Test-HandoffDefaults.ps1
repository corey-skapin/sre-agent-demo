#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$count = 0
function Check([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "Handoff assertion failed: $Message" }
    $script:count++
}
$files = @(& git -C $root ls-files)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate tracked handoff files.' }
$publicRoleIds = @(
    '73c42c96-874c-492b-b04d-ab87d138a893', '749f88d5-cbae-40b8-bcfc-e573ddc772fa',
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293', 'acdd72a7-3385-48ef-bd42-f606fba81ae7',
    'b24988ac-6180-42a0-ab88-20f7382dd24c', 'e79298df-d852-4c6d-84f9-5d13249d1e55'
)
foreach ($file in $files) {
    $text = Get-Content -LiteralPath (Join-Path $root $file) -Raw
    $unknownIds = @([regex]::Matches($text, '(?i)\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b') | Where-Object {
        $_.Value -notin $publicRoleIds -and $_.Value -notmatch '^00000000-0000-0000-0000-0000000000[0-9]{2}$'
    })
    Check ($unknownIds.Count -eq 0) "$file contains only approved public role IDs or synthetic test UUIDs; review unexpected identifiers privately"
    $contacts = @([regex]::Matches($text, '(?i)[a-z0-9._%+-]+@(?<domain>[a-z0-9.-]+\.[a-z]{2,})') | Where-Object {
        $_.Groups['domain'].Value -notmatch '(?i)(^|\.)(example\.(com|net|org)|[^.]+\.invalid|[^.]+\.test)$'
    })
    Check ($contacts.Count -eq 0) "$file contains no real contact email"
    Check ($text -notmatch '(?i)[a-z]:[\\/](Users|src)[\\/][^\\/\s"'']+') "$file contains no workstation home or checkout path"
    $owners = @([regex]::Matches($text, '(?i)https://github\.com/(?<owner>[^/\s<>()"''`]+)') | Where-Object {
        $_.Groups['owner'].Value -notin @('microsoft', 'Azure')
    })
    Check ($owners.Count -eq 0) "$file source links contain only reviewed public upstream organizations, not operator-owned defaults"
}
foreach ($name in @('demo-skin.json', 'dummy-customer.demo-skin.json')) {
    $skin = Get-DemoSkin -Path (Join-Path $root "config\$name")
    Check ($skin.customer.name -in @('Contoso', 'Fabrikam')) "$name is explicitly fictional"
    Check ($skin.codeContext.lobRepositoryUrl -eq '' -and $skin.codeContext.lobSourceCommit -eq '') "$name does not imply external repository ownership or access"
}
$manifest = Get-Content (Join-Path $root 'samples\lob-arc-app\source-context.example.json') -Raw | ConvertFrom-Json
Check ($manifest.repositoryUrl -eq '' -and $manifest.commit -eq '') 'Sample manifest requires operator-supplied external source context'
$docsRoot = Join-Path $root 'docs'
$instructions = Get-Content -LiteralPath (Join-Path $root 'AGENTS.md')
Check ($instructions.Count -le 130) 'Assistant instructions stay within 130 lines'
Check (($instructions -join "`n") -notmatch '\b20\d\d-\d\d-\d\d\b') 'Dated run diaries stay out of loaded assistant instructions'
Check (($instructions -join "`n").Contains('docs/ai-deploy-handbook.md#post-activation-incident-offer')) 'Instructions preserve the canonical conversational offer'
$docsIndex = Get-Content -LiteralPath (Join-Path $docsRoot 'README.md') -Raw
foreach ($document in $files | Where-Object { $_.StartsWith('docs/') -and $_.EndsWith('.md') }) {
    $link = $document.Substring('docs/'.Length)
    Check ($docsIndex.Contains("]($link)")) "Docs index links every Markdown document: $link"
}
Write-Host "$count handoff assertions passed across $($files.Count) tracked files. This checks reusable defaults, not all possible identifying text or secrets."
