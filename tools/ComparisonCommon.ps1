# Shared helpers for the comparison tools. Dot-sourced; defines functions only.

function Find-AcceptedRecord([string]$Source, [string]$BaseName) {
    if ($BaseName -notmatch '^[a-z0-9][a-z0-9\-]*$') { throw "base_name '$BaseName' is not a plain slug" }
    $runs = Join-Path $Source 'art-runs'
    if (-not (Test-Path -LiteralPath $runs -PathType Container)) { throw "art-runs directory not found under the corpus" }
    $hit = $null
    foreach ($f in Get-ChildItem -LiteralPath $runs -Filter '*.json' -File | Sort-Object -Property Name) {
        $r = $null
        try { $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { continue }
        if ($r -isnot [System.Collections.IDictionary]) { continue }
        if (-not $r.ContainsKey('base_name') -or [string]$r['base_name'] -cne $BaseName) { continue }
        if (-not $r.ContainsKey('accepted_at') -or [string]::IsNullOrWhiteSpace([string]$r['accepted_at'])) { continue }
        if ($hit) { throw "two accepted art-runs records name '$BaseName'" }
        $hit = $r
    }
    return $hit
}
