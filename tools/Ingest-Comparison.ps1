#Requires -Version 7.0
<#
.SYNOPSIS
  Record one comparison pair: hash an image dropped into <Source>\comparisons\inbox and write
  <Source>\comparisons\<pair_id>.json, the record build-poetry-site.ps1 enumerates.

.DESCRIPTION
  Phase 2 pilot (BOARDLOG-2026-10-01-POETRY-FULL-PROJECT). Workflow:
    1. tools\Write-ComparisonPrompt.ps1 -BaseName <work>   (writes the exact local brief)
    2. paste that brief into ChatGPT by hand; save the image into comparisons\inbox
    3. tools\Ingest-Comparison.ps1 -BaseName <work> -Image <file> -Model <model> ...

  The brief stored in the record is copied from the accepted art-runs record, never typed, so the
  generator's byte-equality check holds. The image is pinned by sha256; the generator refuses to
  build if the file changes afterwards.

  The ingest FAILS, and writes nothing, if any file in the inbox would be left unreferenced by a
  comparison record. An unreferenced file is a pair nobody accounted for. Remove or ingest it.
  -CheckOnly runs only that inbox check.

  No network call. Nothing is scheduled.

.OUTPUTS  Exit 0 on success. Exit 1 on any validation failure or an unreferenced inbox file.
#>
[CmdletBinding()]
param(
    [string]$BaseName,
    [string]$Image,
    [string]$Model,
    [string]$GeneratedOn,
    [string]$RoundId,
    [string]$RoundCloses,
    [string]$PairId,
    [string]$Source = $env:C01POETRY_SOURCE,
    [switch]$Force,
    [switch]$CheckOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ComparisonCommon.ps1')
function Fail([string]$m) { Write-Host "ERROR $m"; exit 1 }

if ([string]::IsNullOrWhiteSpace($Source)) { Fail '-Source not given and C01POETRY_SOURCE is not set' }
$cmpDir = Join-Path $Source 'comparisons'
$inbox  = Join-Path $cmpDir 'inbox'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null

function Get-Referenced([string]$extraName) {
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($f in Get-ChildItem -LiteralPath $cmpDir -Filter '*.json' -File) {
        try { $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { Fail "unparseable comparison record $($f.Name)" }
        if ($r -is [System.Collections.IDictionary] -and $r.ContainsKey('chatgpt_image')) { [void]$set.Add([string]$r['chatgpt_image']) }
    }
    if ($extraName) { [void]$set.Add($extraName) }
    return ,$set
}
function Assert-InboxClean([string]$extraName) {
    $ref = Get-Referenced $extraName
    $orphans = @(Get-ChildItem -LiteralPath $inbox -Force | Where-Object { -not $ref.Contains($_.Name) } | ForEach-Object { $_.Name } | Sort-Object)
    if ($orphans.Count -gt 0) { Fail "inbox holds $($orphans.Count) file(s) no comparison record names: $($orphans -join ', '). Ingest or remove them first; nothing was written." }
}

if ($CheckOnly) { Assert-InboxClean ''; Write-Host 'OK inbox: every file is named by a comparison record'; exit 0 }

foreach ($p in 'BaseName', 'Image', 'Model', 'GeneratedOn', 'RoundId', 'RoundCloses') {
    if ([string]::IsNullOrWhiteSpace((Get-Variable -Name $p -ValueOnly))) { Fail "-$p is required" }
}
if (-not $PairId) { $PairId = "$RoundId-$BaseName" }
if ($PairId  -notmatch '^[a-z0-9][a-z0-9\-]*$') { Fail "pair_id '$PairId' must be a lowercase slug" }
if ($RoundId -notmatch '^[a-z0-9][a-z0-9\-]*$') { Fail "-RoundId '$RoundId' must be a lowercase slug" }
foreach ($d in @(@('GeneratedOn', $GeneratedOn), @('RoundCloses', $RoundCloses))) {
    $parsed = [DateTime]::MinValue
    if ($d[1] -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [DateTime]::TryParseExact($d[1], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$parsed)) { Fail "-$($d[0]) must be a date only, yyyy-MM-dd" }
}
if ($Image -match '[\\/:]' -or $Image -notmatch '\.(png|jpg|jpeg|webp)$' -or $Image.StartsWith('.')) { Fail "-Image must be a plain .png/.jpg/.jpeg/.webp file name inside comparisons\inbox" }
$imgPath = Join-Path $inbox $Image
if (-not (Test-Path -LiteralPath $imgPath -PathType Leaf)) { Fail "comparisons\inbox\$Image does not exist" }

$rec = Find-AcceptedRecord -Source $Source -BaseName $BaseName
if (-not $rec) { Fail "no accepted art-runs record has base_name '$BaseName'" }
$brief = if ($rec.ContainsKey('image_prompt') -and $rec['image_prompt'] -is [string]) { $rec['image_prompt'] } else { '' }
if ([string]::IsNullOrWhiteSpace($brief)) { Fail "accepted record for '$BaseName' has no image_prompt" }

$outPath = Join-Path $cmpDir "$PairId.json"
if ((Test-Path -LiteralPath $outPath) -and -not $Force) { Fail "comparisons\$PairId.json already exists (use -Force to replace it)" }
# One image per pair: refuse an image another record already claims.
foreach ($f in Get-ChildItem -LiteralPath $cmpDir -Filter '*.json' -File) {
    if ($f.Name -eq "$PairId.json") { continue }
    $o = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($o -is [System.Collections.IDictionary] -and $o.ContainsKey('chatgpt_image') -and [string]$o['chatgpt_image'] -eq $Image) { Fail "$Image is already named by $($f.Name)" }
}

Assert-InboxClean $Image

$sha = (Get-FileHash -LiteralPath $imgPath -Algorithm SHA256).Hash.ToLowerInvariant()
$out = [ordered]@{
    pair_id        = $PairId
    base_name      = $BaseName
    brief          = $brief
    chatgpt_image  = $Image
    chatgpt_sha256 = $sha
    chatgpt_model  = $Model
    generated_on   = $GeneratedOn
    round_id       = $RoundId
    round_closes   = $RoundCloses
}
[System.IO.File]::WriteAllText($outPath, ((ConvertTo-Json -InputObject $out -Depth 3).Replace("`r`n", "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Host "WROTE comparisons\$PairId.json sha256=$sha round=$RoundId closes=$RoundCloses"
exit 0
