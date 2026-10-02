#Requires -Version 7.0
<#
.SYNOPSIS
  Acceptance-gate harness for build-poetry-site.ps1 -- the nine items from the design thread
  (corp-docs/comms/2026-09-18-engineering-vp-poetry-art-publishing-mechanism.md § Acceptance gate)
  plus Bible Rule 2 (no mojibake) and Rule 3 (version reaches the artifact).

  Runs against the REAL corpus for content/byte gates and against an ADVERSARIAL FIXTURE for the
  leak gate. Every canary is proven present in the source before and after the generator run, and
  the detector is proven to see each canary in the source (positive control) before its zero on the
  output is believed.

  Exit 0 = every gate passed. Exit 1 = at least one FAIL. Prints one row per gate with evidence.
  Never prints private-file content -- only counts and line numbers.
#>
[CmdletBinding()]
param(
    [string]$Source = $env:C01POETRY_SOURCE,
    [switch]$SkipLayout
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repo    = Split-Path -Parent $PSScriptRoot
$Gen     = Join-Path $Repo 'build-poetry-site.ps1'
$Enc     = Join-Path $Repo 'tools\encode_webp.py'
$Layout  = Join-Path $PSScriptRoot 'check_layout.py'
$Scratch = Join-Path $PSScriptRoot '_scratch'
$Site    = Join-Path $Repo '_site'
$Build   = Join-Path $Repo '_build'
$Utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)

if (Test-Path -LiteralPath $Scratch) { Remove-Item -LiteralPath $Scratch -Recurse -Force }
New-Item -ItemType Directory -Force -Path $Scratch | Out-Null

$Results = [System.Collections.Generic.List[object]]::new()
function Gate([string]$id, [string]$name, [bool]$pass, [string]$evidence) {
    $Results.Add([pscustomobject]@{ gate = $id; name = $name; result = $(if ($pass) { 'PASS' } else { 'FAIL' }); evidence = $evidence })
    Write-Host ("[{0}] {1,-6} {2} -- {3}" -f $(if ($pass) { 'PASS' } else { 'FAIL' }), $id, $name, $evidence)
}
function Read-Tree([string]$dir) {
    # Returns @{ path -> decoded text }. Text files as UTF-8; binaries as Latin-1 so ASCII needles survive.
    $m = @{}
    foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $isText = $f.Extension -in '.html', '.css', '.txt', '.md', '.json'
        $m[$f.FullName] = if ($isText) { [System.Text.Encoding]::UTF8.GetString($bytes) } else { [System.Text.Encoding]::Latin1.GetString($bytes) }
    }
    return $m
}
function Scan([hashtable]$tree, [string[]]$needles) {
    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($needle in $needles) {
        foreach ($k in $tree.Keys) {
            if ($tree[$k].Contains($needle, [System.StringComparison]::Ordinal)) { $hits.Add("$needle @ $k") }
        }
    }
    # Comma keeps the List intact through PowerShell's return-unrolling (an empty List would
    # otherwise arrive as $null and StrictMode would reject .Count on it).
    return ,$hits
}
function Run-Gen([string]$src, [string]$out, [string]$build) {
    $o = & pwsh -NoProfile -File $Gen -Source $src -Out $out -BuildDir $build 2>&1
    return @{ exit = $LASTEXITCODE; output = ($o | Out-String) }
}
function Chunks([string]$path) { return ,@((& python $Enc chunks $path | ConvertFrom-Json).chunks) }

# =============================================================================================
# GATE 1 -- enumeration path is art-runs\*.json only (read the code, not the output)
# =============================================================================================
$genLines = Get-Content -LiteralPath $Gen
# Command-position matches only: a directory-listing cmdlet/alias at line start or after ( | = @( ;
# plus the .NET directory APIs anywhere. Block comments <# ... #> and # lines are skipped.
$enumPattern = '(^|[\s(|=;])(Get-ChildItem|gci|ls|dir|Get-Item)\s|EnumerateFiles|EnumerateFileSystem|GetFiles\(|GetDirectories\(|IO\.Directory\]|IO\.DirectoryInfo\]'
$inBlock = $false
$enumHits = @(for ($i = 0; $i -lt $genLines.Count; $i++) {
    $ln = $genLines[$i]
    if ($ln -match '<#') { $inBlock = $true }
    if ($inBlock) { if ($ln -match '#>') { $inBlock = $false }; continue }
    if ($ln -match '^\s*#') { continue }
    if ($ln -match $enumPattern) { "L$($i+1): $($ln.Trim())" }
})
$g1ok = ($enumHits.Count -eq 1) -and ($enumHits[0] -match "art-runs") -and ($enumHits[0] -match "\*\.json")
$pyLines = Get-Content -LiteralPath $Enc
$pyEnum = @(for ($i = 0; $i -lt $pyLines.Count; $i++) { if ($pyLines[$i] -match '\bglob\b|listdir|os\.walk|scandir|iterdir|rglob' -and $pyLines[$i] -notmatch '^\s*#') { "L$($i+1)" } })
Gate '1' 'enumerator is art-runs\*.json only' ($g1ok -and $pyEnum.Count -eq 0) "generator directory reads: $($enumHits.Count) [$($enumHits -join '; ')]; encoder directory reads: $($pyEnum.Count)"

# =============================================================================================
# GATE 2 -- adversarial fixture: canaries present in source, zero in output, detector proven
# =============================================================================================
$fx = Join-Path $Scratch 'fixture'
foreach ($d in 'art-runs', 'scratchpad', 'art-candidates', 'ReferenceArt') { New-Item -ItemType Directory -Force -Path (Join-Path $fx $d) | Out-Null }
$realNames = '2026-08-16-an-infinity', '2026-09-07-moonbounce', '2026-09-19-front-swings'
foreach ($n in $realNames) {
    Copy-Item -LiteralPath (Join-Path $Source "$n.md")  -Destination (Join-Path $fx "$n.md")
    Copy-Item -LiteralPath (Join-Path $Source "$n.png") -Destination (Join-Path $fx "$n.png")
    Copy-Item -LiteralPath (Join-Path $Source "art-runs\$n.json") -Destination (Join-Path $fx "art-runs\$n.json")
}
$tok = 'CANARY-' + (Get-Random -Minimum 100000 -Maximum 999999)
$canary = [ordered]@{
    'PREFERENCES.md'        = "$tok-PREF the founder's private reactions live here and must never publish"
    'PREFERENCES-2.md'      = "$tok-PREF2 a second preferences file the denylist never heard of"
    'notes.private.md'      = "$tok-NOTES private notes beside the poems"
    'INDEX.md'              = "$tok-INDEX the poem index"
    'ART_INDEX.md'          = "$tok-ARTINDEX the art tracker"
    'scratchpad\secret.md'  = "$tok-SCRATCH a scratch file in a subdirectory"
    'art-candidates\poemart_x_a1.txt' = "$tok-CAND a candidate-dir file"
    '2026-08-16-the-observer-effect-TEST.md' = "---`ntitle: test`ndate: 2026-08-16`n---`n`n# test poem`n`n$tok-TEST the pre-calibration test poem`n"
    '2026-01-01-orphan.md'  = "---`ntitle: orphan`ndate: 2026-01-01`n---`n`n# orphan`n`n$tok-ORPHAN a well-formed poem file that no accepted run record names`n"
}
foreach ($k in $canary.Keys) {
    $p = Join-Path $fx $k
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [System.IO.File]::WriteAllText($p, $canary[$k], [System.Text.UTF8Encoding]::new($false))
}
# an orphan PNG beside the orphan poem, and a non-accepted record that NAMES the orphan (accepted_at required, not just a record)
Copy-Item -LiteralPath (Join-Path $Source '2026-09-07-moonbounce.png') -Destination (Join-Path $fx '2026-01-01-orphan.png')
[System.IO.File]::WriteAllText((Join-Path $fx 'art-runs\2026-01-01-orphan.experiment.json'), "{`"base_name`": `"2026-01-01-orphan`", `"experiment`": `"$tok-EXPREC`", `"promoted`": false}", [System.Text.UTF8Encoding]::new($false))
# a -card variant carrying a canary tEXt chunk (never named by any record: base_name.png only)
& python $Enc plant (Join-Path $Source '2026-09-07-moonbounce-card.png') (Join-Path $fx '2026-09-07-moonbounce-card.png') 'prompt' "$tok-CARD" | Out-Null
# a NAMED record's PNG re-planted with a canary tEXt chunk -- the chunk-strip must remove it
& python $Enc plant (Join-Path $Source '2026-09-19-front-swings.png') (Join-Path $fx '2026-09-19-front-swings.png') 'prompt' "$tok-CHUNK" | Out-Null
# a NAMED record's poem file with canaries in the roast and in a losing draft
$fsMd = Join-Path $fx '2026-09-19-front-swings.md'
$t = [System.IO.File]::ReadAllText($fsMd, $Utf8Strict)
$t = $t.Replace('## The roast that chose it', "## The roast that chose it`n`n$tok-ROAST the judge's critique")
$t = $t.Replace('<summary>All candidates this run</summary>', "<summary>All candidates this run</summary>`n`n$tok-DRAFT a losing draft line")
[System.IO.File]::WriteAllText($fsMd, $t, [System.Text.UTF8Encoding]::new($false))
# a NAMED record's run JSON with an unlisted field -- the field allowlist must drop it
$fsJson = Join-Path $fx 'art-runs\2026-09-19-front-swings.json'
$j = Get-Content -LiteralPath $fsJson -Raw | ConvertFrom-Json -AsHashtable
$j['secret_note'] = "$tok-RUNFIELD an unlisted run-record field"
[System.IO.File]::WriteAllText($fsJson, (ConvertTo-Json $j -Depth 8), [System.Text.UTF8Encoding]::new($false))

# Positive-control needles must exist in the source BYTES as written: JSON stores the local path as
# C:\\Users (escaped), so that form is what the source scan can see. The output scan adds the
# unescaped C:\Users, which is what a leak through ConvertFrom-Json would look like.
$needles = @("$tok-PREF ", "$tok-PREF2", "$tok-NOTES", "$tok-INDEX", "$tok-ARTINDEX", "$tok-SCRATCH", "$tok-CAND", "$tok-TEST", "$tok-ORPHAN", "$tok-EXPREC", "$tok-CARD", "$tok-CHUNK", "$tok-ROAST", "$tok-DRAFT", "$tok-RUNFIELD", 'C01Corp', 'C:\\Users', 'C:/Users', 'Dropbox')
$needlesOut = $needles + @('C:\Users')
$canaryFiles = @($canary.Keys) + @('2026-01-01-orphan.png', '2026-09-07-moonbounce-card.png', 'art-runs\2026-01-01-orphan.experiment.json')
$log = [System.Collections.Generic.List[string]]::new()
$log.Add("fixture=$fx token=$tok")
$preMissing = @(foreach ($c in $canaryFiles) { $ok = Test-Path -LiteralPath (Join-Path $fx $c); $log.Add("PRE  present=$ok $c"); if (-not $ok) { $c } })
$srcChunks = Chunks (Join-Path $fx '2026-09-19-front-swings.png')
$log.Add("PRE  front-swings.png chunks=$($srcChunks -join ',')")
# positive control: the detector must see every canary in the SOURCE
$srcTree = Read-Tree $fx
$posHits = Scan $srcTree $needles
$unseen = @(foreach ($n in $needles) { if (@($posHits | Where-Object { $_.StartsWith("$n @") }).Count -eq 0) { $n } })
$log.Add("POSITIVE-CONTROL needles=$($needles.Count) seen_in_source=$($needles.Count - $unseen.Count) unseen=[$($unseen -join ', ')]")

$fxRun = Run-Gen $fx (Join-Path $Scratch 'fx-site') (Join-Path $Scratch 'fx-build')
$log.Add("RUN exit=$($fxRun.exit)")
$postMissing = @(foreach ($c in $canaryFiles) { $ok = Test-Path -LiteralPath (Join-Path $fx $c); $log.Add("POST present=$ok $c"); if (-not $ok) { $c } })
$outTree = Read-Tree (Join-Path $Scratch 'fx-site')
$negHits = Scan $outTree $needlesOut
foreach ($h in $negHits) { $log.Add("LEAK $h") }
$outFiles = @(Get-ChildItem -LiteralPath (Join-Path $Scratch 'fx-site') -Recurse -File | ForEach-Object { $_.FullName.Substring((Join-Path $Scratch 'fx-site').Length + 1) } | Sort-Object)
$expected = @('index.html', 'experiment.html', 'evolution.html', 'robots.txt', 'style.css') + @(foreach ($n in $realNames) { "p\$n.html"; "img\$n.webp"; "img\$n-t.webp" }) | Sort-Object
$fileSetOk = (($outFiles -join '|') -eq ($expected -join '|'))
$log.Add("OUTPUT files=$($outFiles.Count) expected=$($expected.Count) exact_match=$fileSetOk")
$log.Add("OUTPUT list: $($outFiles -join ', ')")
[System.IO.File]::WriteAllText((Join-Path $Scratch 'gate2-run.log'), (($log -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
$g2ok = ($fxRun.exit -eq 0) -and ($preMissing.Count -eq 0) -and ($postMissing.Count -eq 0) -and ($unseen.Count -eq 0) -and ($negHits.Count -eq 0) -and $fileSetOk -and ($srcChunks -contains 'tEXt') -and ($fxRun.output -match 'works=3')
Gate '2' 'adversarial fixture: zero canary leak, canaries proven present, detector proven' $g2ok "exit=$($fxRun.exit); canary files present before/after: $($canaryFiles.Count - $preMissing.Count)/$($canaryFiles.Count) and $($canaryFiles.Count - $postMissing.Count)/$($canaryFiles.Count); detector saw $($needles.Count - $unseen.Count)/$($needles.Count) needles in source; leaks in output: $($negHits.Count); output file set exact: $fileSetOk; source tEXt chunk present: $($srcChunks -contains 'tEXt'); log: tests\_scratch\gate2-run.log"

# GATE 2b -- fail closed on a record naming a missing pair (nothing partial is emitted)
$fx2 = Join-Path $Scratch 'fixture-missing'
Copy-Item -LiteralPath $fx -Destination $fx2 -Recurse
[System.IO.File]::WriteAllText((Join-Path $fx2 'art-runs\2026-02-02-missing.json'), '{"base_name": "2026-02-02-missing", "accepted_at": "2026-02-02 08:00"}', [System.Text.UTF8Encoding]::new($false))
$fx2Run = Run-Gen $fx2 (Join-Path $Scratch 'fx2-site') (Join-Path $Scratch 'fx2-build')
$g2bok = ($fx2Run.exit -eq 1) -and ($fx2Run.output -match '2026-02-02-missing\.md does not exist') -and (-not (Test-Path -LiteralPath (Join-Path $Scratch 'fx2-site')))
Gate '2b' 'fail closed: record naming a missing pair aborts before any output' $g2bok "exit=$($fx2Run.exit); error names the file: $($fx2Run.output -match '2026-02-02-missing\.md does not exist'); output dir created: $(Test-Path -LiteralPath (Join-Path $Scratch 'fx2-site'))"

# =============================================================================================
# REAL CORPUS BUILD (run A) -- gates 3,4,5,7,8,9 read this; gate 6 compares it with run B
# =============================================================================================
$runA = Run-Gen $Source $Site $Build
if ($runA.exit -ne 0) { Gate 'A' 'real corpus build' $false "exit=$($runA.exit): $($runA.output.Substring([Math]::Max(0, $runA.output.Length - 400)))"; }
$worksA = if ($runA.output -match 'works=(\d+)') { [int]$Matches[1] } else { -1 }
$siteTree = Read-Tree $Site
$htmlKeys = @($siteTree.Keys | Where-Object { $_ -like '*.html' })
$buildLog = Get-Content -LiteralPath (Join-Path $Build 'build.log')
$published = @($buildLog | Where-Object { $_ -match '^PAIR\s+base_name=(\S+)' } | ForEach-Object { $Matches[1] })

# =============================================================================================
# GATE 3 -- private files appear nowhere in _site, by CONTENT (lines >= 30 chars), plus PD#2 paths
# =============================================================================================
$privateFiles = @('PREFERENCES.md', 'INDEX.md', 'ART_INDEX.md', '2026-08-16-the-observer-effect-TEST.md')
$g3parts = [System.Collections.Generic.List[string]]::new(); $g3ok = $true
foreach ($pf in $privateFiles) {
    $pp = Join-Path $Source $pf
    if (-not (Test-Path -LiteralPath $pp)) { $g3parts.Add("$pf=ABSENT"); continue }
    $lines = @([System.IO.File]::ReadAllText($pp, $Utf8Strict).Replace("`r`n", "`n") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -ge 30 } | Select-Object -Unique)
    $hits = Scan $siteTree $lines
    if ($hits.Count -gt 0) { $g3ok = $false }
    $g3parts.Add("$pf lines=$($lines.Count) hits=$($hits.Count)")   # counts only -- never content
}
$pathHits = Scan $siteTree @('C:\Users', 'C:/Users', 'C01Corp', 'Dropbox', 'poemart_', 'art-candidates', 'candidate_source')
if ($pathHits.Count -gt 0) { $g3ok = $false }
$g3parts.Add("local-path/PD#2 needles hits=$($pathHits.Count)")
Gate '3' 'PREFERENCES/INDEX/ART_INDEX/-TEST absent by content; no local paths' $g3ok ($g3parts -join '; ')

# =============================================================================================
# GATE 4 -- no ancillary text/metadata chunk in any output image; asserted on bytes
# =============================================================================================
$imgFiles = @(Get-ChildItem -LiteralPath (Join-Path $Site 'img') -File)
$nonWebp = @($imgFiles | Where-Object { $_.Extension -ne '.webp' })
$pngAnywhere = @(Get-ChildItem -LiteralPath $Site -Recurse -File -Filter '*.png')
$allowed = @('VP8', 'VP8L', 'VP8X', 'ALPH')
$badChunks = [System.Collections.Generic.List[string]]::new(); $chunkHist = @{}
foreach ($f in $imgFiles) {
    $c = Chunks $f.FullName
    foreach ($ch in $c) { $chunkHist[$ch] = 1 + $(if ($chunkHist.ContainsKey($ch)) { $chunkHist[$ch] } else { 0 }); if ($ch -notin $allowed) { $badChunks.Add("$($f.Name):$ch") } }
}
$srcWithText = @($buildLog | Where-Object { $_ -match '^ENCODE .* src_chunks=(\S+) ' -and $Matches[1] -ne '' }).Count
$g4ok = ($nonWebp.Count -eq 0) -and ($pngAnywhere.Count -eq 0) -and ($badChunks.Count -eq 0) -and ($imgFiles.Count -eq 2 * $worksA)
Gate '4' 'no metadata chunk in any output image (bytes)' $g4ok "images=$($imgFiles.Count) (2 x $worksA works); non-webp=$($nonWebp.Count); png in _site=$($pngAnywhere.Count); chunk histogram={$(($chunkHist.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')}; forbidden chunks=$($badChunks.Count); sources that carried a text chunk (stripped): $srcWithText"

# =============================================================================================
# GATE 5 -- no roast / draft text on any page
# =============================================================================================
$roastHits = Scan $siteTree @('The roast that chose it', '<details', '</details>', 'All candidates this run', '"roast"', '"fix":', 'Round 1 -', '**Round')
Gate '5' 'no roast or losing-draft text in output' ($roastHits.Count -eq 0) "needles=8 hits=$($roastHits.Count) over $($htmlKeys.Count) pages"

# =============================================================================================
# GATE 6 -- regenerable from scratch, byte-stable across two runs; no unnamed file reachable
# =============================================================================================
$siteB = Join-Path $Scratch 'siteB'
$runB = Run-Gen $Source $siteB (Join-Path $Scratch 'buildB')
function Hashes([string]$root) {
    $h = @{}
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File) { $h[$f.FullName.Substring($root.Length + 1)] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
    return $h
}
$hA = Hashes $Site; $hB = Hashes $siteB
$diff = @(foreach ($k in ($hA.Keys + $hB.Keys | Select-Object -Unique)) { if (-not $hA.ContainsKey($k) -or -not $hB.ContainsKey($k) -or $hA[$k] -ne $hB[$k]) { $k } })
$unnamed = @(foreach ($k in $hA.Keys) {
    if ($k -in 'index.html', 'experiment.html', 'evolution.html', 'style.css', 'robots.txt') { continue }
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($k) -replace '-t$', ''
    if ($stem -notin $published) { $k }
})
$g6ok = ($runB.exit -eq 0) -and ($diff.Count -eq 0) -and ($hA.Count -gt 0) -and ($unnamed.Count -eq 0) -and ($published.Count -eq $worksA)
Gate '6' 'byte-stable across two fresh runs; every output file named by a run record' $g6ok "files=$($hA.Count) vs $($hB.Count); sha256 differences=$($diff.Count); published base_names=$($published.Count); output files not derived from a published base_name=$($unnamed.Count)"

# =============================================================================================
# GATE 7 -- Rule 1: every page, 6 viewports x 2 font scales, no horizontal overflow
# =============================================================================================
if ($SkipLayout) {
    Gate '7' 'Rule 1 reactive layout (Playwright/Edge)' $false 'SKIPPED by -SkipLayout'
} else {
    # positive control first: a page that overflows by construction MUST make the probe fail
    $badSite = Join-Path $Scratch 'bad-layout'
    New-Item -ItemType Directory -Force -Path (Join-Path $badSite 'p') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $badSite 'index.html'), '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"></head><body><div style="width:3000px;height:10px;background:red"></div><ul><li style="display:block;height:20px;overflow:visible"><figure style="margin:0;height:20px"><figcaption style="display:block;height:60px">caption that spills out of its item</figcaption></figure></li></ul></body></html>', [System.Text.UTF8Encoding]::new($false))
    $badOut = & python $Layout $badSite (Join-Path $Scratch 'bad-layout-build') 2>&1
    $badExit = $LASTEXITCODE
    $badJson = try { (($badOut | Where-Object { $_ -notmatch '^\s*$' }) -join "`n") | ConvertFrom-Json } catch { $null }
    $probeCanFail = ($badExit -eq 1) -and $null -ne $badJson -and ($badJson.failures.Count -eq 12)
    Gate '7a' 'layout probe positive control: known-bad page trips every viewport' $probeCanFail "exit=$badExit failures=$(if ($badJson) { $badJson.failures.Count } else { '?' })/12"

    $lo = & python $Layout $Site $Build 2>&1
    $loExit = $LASTEXITCODE
    $loJson = ($lo | Where-Object { $_ -notmatch '^\s*$' }) -join "`n"
    $summary = try { $loJson | ConvertFrom-Json } catch { $null }
    $ev = if ($summary) { "pages=$($summary.pages) viewports=$($summary.viewports) scales=$($summary.scales -join '/') checks=$($summary.checks) failures=$($summary.failures.Count)$(if ($summary.failures.Count) { ' first=' + ($summary.failures[0] | ConvertTo-Json -Compress) }); screenshots in _build\shots" } else { "probe did not return JSON: $($loJson.Substring(0, [Math]::Min(300, $loJson.Length)))" }
    Gate '7' 'Rule 1 reactive layout (Playwright/Edge)' ($loExit -eq 0 -and $null -ne $summary -and $summary.failures.Count -eq 0) $ev
}

# =============================================================================================
# GATE 8 -- Rule 6: real empty state; every image has alt/width/height and a defined frame
# =============================================================================================
$empty = Join-Path $Scratch 'empty'
New-Item -ItemType Directory -Force -Path (Join-Path $empty 'art-runs') | Out-Null
$emptyRun = Run-Gen $empty (Join-Path $Scratch 'empty-site') (Join-Path $Scratch 'empty-build')
$emptyIndex = if (Test-Path -LiteralPath (Join-Path $Scratch 'empty-site\index.html')) { [System.IO.File]::ReadAllText((Join-Path $Scratch 'empty-site\index.html'), $Utf8Strict) } else { '' }
$emptyOk = ($emptyRun.exit -eq 0) -and $emptyIndex.Contains('No works have been published yet.') -and (-not $emptyIndex.Contains('<li>'))
$imgTags = @(foreach ($k in $htmlKeys) { [regex]::Matches($siteTree[$k], '<img [^>]*>') | ForEach-Object { $_.Value } })
$badImg = @($imgTags | Where-Object { $_ -notmatch ' alt="[^"]+"' -or $_ -notmatch ' width="\d+"' -or $_ -notmatch ' height="\d+"' })
$css = $siteTree[(Join-Path $Site 'style.css')]
$frameOk = ($css -match '\.frame\{[^}]*background:') -and ($css -match '\.frame\{[^}]*aspect-ratio:') -and (@($imgTags).Count -gt 0) -and -not ($htmlKeys | Where-Object { $siteTree[$_] -match '<figure class="art"><img' })
$realIndex = $siteTree[(Join-Path $Site 'index.html')]
$g8ok = $emptyOk -and ($badImg.Count -eq 0) -and $frameOk -and (-not $realIndex.Contains('No works have been published yet.')) -and ($imgTags.Count -eq 2 * $worksA + 1)   # +1 = the latest work's full image in the index hero (0.2.0)
Gate '8' 'Rule 6: empty state real; every img has alt+width+height; framed failure path' $g8ok "empty-corpus run exit=$($emptyRun.exit) shows empty state=$($emptyIndex.Contains('No works have been published yet.')); img tags=$($imgTags.Count) missing alt/width/height=$($badImg.Count); figure.art has background+aspect-ratio=$frameOk; real index shows empty state=$($realIndex.Contains('No works have been published yet.'))"

# =============================================================================================
# GATE 9 -- robots.txt Disallow: /, no sitemap, noindex on every page
# =============================================================================================
$robots = [System.IO.File]::ReadAllBytes((Join-Path $Site 'robots.txt'))
$robotsOk = ([System.Text.Encoding]::ASCII.GetString($robots) -eq "User-agent: *`nDisallow: /`n")
$sitemaps = @(Get-ChildItem -LiteralPath $Site -Recurse -File | Where-Object { $_.Name -like 'sitemap*' })
$noNoindex = @($htmlKeys | Where-Object { -not $siteTree[$_].Contains('<meta name="robots" content="noindex, nofollow">') })
Gate '9' 'robots.txt Disallow: /; no sitemap; noindex meta on every page' ($robotsOk -and $sitemaps.Count -eq 0 -and $noNoindex.Count -eq 0) "robots.txt exact bytes=$robotsOk ($($robots.Length)B); sitemap files=$($sitemaps.Count); pages without noindex=$($noNoindex.Count)/$($htmlKeys.Count)"

# =============================================================================================
# Bible Rule 2 (no mojibake, valid UTF-8) and Rule 3 (version reaches the artifact)
# =============================================================================================
$badUtf8 = @(foreach ($k in $htmlKeys + @((Join-Path $Site 'style.css'))) { try { [void]$Utf8Strict.GetString([System.IO.File]::ReadAllBytes($k)) } catch { $k } })
# Text files only: the Latin-1 view of a WebP binary contains every high byte and would hit by chance.
$textTree = @{}; foreach ($k in $siteTree.Keys) { if ($k -match '\.(html|css|txt)$') { $textTree[$k] = $siteTree[$k] } }
$moji = Scan $textTree @('Ã', 'â€', 'Â ', [string][char]0xFFFD)
$bom = @(foreach ($k in $htmlKeys) { $b = [System.IO.File]::ReadAllBytes($k); if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { $k } })
Gate 'R2' 'Bible Rule 2: valid UTF-8, no BOM, no mojibake signatures' ($badUtf8.Count -eq 0 -and $moji.Count -eq 0 -and $bom.Count -eq 0) "invalid-utf8 files=$($badUtf8.Count); mojibake hits=$($moji.Count); BOM files=$($bom.Count)"
$genVer = if ((Get-Content -LiteralPath $Gen -Raw) -match "\`$Script:Version\s*=\s*'([^']+)'") { $Matches[1] } else { '?' }
$noVer = @($htmlKeys | Where-Object { -not $siteTree[$_].Contains("build-poetry-site/$genVer") })
Gate 'R3' 'Bible Rule 3: generator version in every page' ($noVer.Count -eq 0 -and $genVer -ne '?') "version=$genVer; pages without it=$($noVer.Count)/$($htmlKeys.Count)"

# =============================================================================================
Write-Host ''
Write-Host ("works published into _site: {0}" -f $worksA)
$fails = @($Results | Where-Object { $_.result -eq 'FAIL' })
Write-Host ("gates: {0} PASS / {1} FAIL" -f (@($Results | Where-Object { $_.result -eq 'PASS' }).Count), $fails.Count)
[System.IO.File]::WriteAllText((Join-Path $Build 'gates.json'), (ConvertTo-Json -InputObject @{ works = $worksA; results = $Results } -Depth 5), [System.Text.UTF8Encoding]::new($false))
exit $(if ($fails.Count -eq 0) { 0 } else { 1 })
