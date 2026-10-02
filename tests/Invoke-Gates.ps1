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
# 0.3.0: exactly two enumerators -- art-runs\*.json and comparisons\*.json. Nothing else is listed
# (in particular, never comparisons\inbox: each record names its one image).
$g1ok = ($enumHits.Count -eq 2) -and ($enumHits[0] -match "'art-runs'") -and ($enumHits[0] -match "\*\.json") -and ($enumHits[1] -match "'comparisons'\)") -and ($enumHits[1] -match "\*\.json") -and ($enumHits[1] -notmatch 'inbox')
$pyLines = Get-Content -LiteralPath $Enc
$pyEnum = @(for ($i = 0; $i -lt $pyLines.Count; $i++) { if ($pyLines[$i] -match '\bglob\b|listdir|os\.walk|scandir|iterdir|rglob' -and $pyLines[$i] -notmatch '^\s*#') { "L$($i+1)" } })
Gate '1' 'enumerators are art-runs\*.json and comparisons\*.json only' ($g1ok -and $pyEnum.Count -eq 0) "generator directory reads: $($enumHits.Count) [$($enumHits -join '; ')]; encoder directory reads: $($pyEnum.Count)"

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
$expected = @('index.html', 'experiment.html', 'evolution.html', 'comparisons.html', 'robots.txt', 'style.css') + @(foreach ($n in $realNames) { "p\$n.html"; "img\$n.webp"; "img\$n-t.webp" }) | Sort-Object
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
# GATE 14 -- blind comparison (0.3.0). An open round's served assets name no model and carry no
# metadata; an unreferenced inbox file never reaches output; both images of a pair are not
# trivially distinguishable; the closed round reveals with the exact credit line.
# Fixture: a ChatGPT-like PNG with planted C2PA (caBX) / EXIF / XMP / ICC / tEXt and a planted
# label string, a ChatGPT-style download file name, and a stray inbox file carrying a canary.
# Positive controls: every detector is shown to fire on the source (and on the revealed page).
# =============================================================================================
$ModelRx   = '(?i)(chatgpt|openai|gpt|dall|flux|schnell|sdxl|qwen|claude)'
$ModelRxBin = '(?i)(chatgpt|openai|dall|flux|schnell|sdxl|qwen|claude|c2pa|jumb|exif|xmpmeta|adobe)'   # binaries: needles >= 4 chars, so random compressed bytes cannot match by chance
$PyInfo = Join-Path $Scratch 'imginfo.py'
[System.IO.File]::WriteAllText($PyInfo, "import sys, json`nfrom PIL import Image`nfor p in sys.argv[1:]:`n    im = Image.open(p)`n    print(json.dumps({'f': p, 'fmt': im.format, 'w': im.size[0], 'h': im.size[1], 'mode': im.mode, 'info': sorted(str(k) for k in im.info.keys())}))`n", [System.Text.UTF8Encoding]::new($false))
function Img-Info([string[]]$paths) { return @(& python $PyInfo @paths | ForEach-Object { $_ | ConvertFrom-Json }) }

$fx14 = Join-Path $Scratch 'fixture-cmp'
New-Item -ItemType Directory -Force -Path (Join-Path $fx14 'art-runs') | Out-Null
# Only works accepted with an image_prompt (2026-09-16 onward) can be compared: the brief is the experiment.
$cmpWorks = '2026-09-19-front-swings', '2026-09-20-great-tree'
foreach ($n in $cmpWorks + '2026-09-07-moonbounce') {
    Copy-Item -LiteralPath (Join-Path $Source "$n.md")  -Destination (Join-Path $fx14 "$n.md")
    Copy-Item -LiteralPath (Join-Path $Source "$n.png") -Destination (Join-Path $fx14 "$n.png")
    Copy-Item -LiteralPath (Join-Path $Source "art-runs\$n.json") -Destination (Join-Path $fx14 "art-runs\$n.json")
}
$inbox = Join-Path $fx14 'comparisons\inbox'
New-Item -ItemType Directory -Force -Path $inbox | Out-Null
$label = "$tok-LABEL ChatGPT gpt-image-1 OpenAI DALL-E"
$img1 = 'ChatGPT Image Oct 1, 2026, 09_14_02 AM.png'
$img2 = 'ChatGPT Image Oct 1, 2026, 09_20_40 AM.png'
& python $Enc plant-provenance (Join-Path $Source '2026-09-07-moonbounce.png') (Join-Path $inbox $img1) 1024 1536 $label | Out-Null
$stray = Join-Path $Scratch "stray-$tok.png"
& python $Enc plant (Join-Path $Source '2026-08-16-an-infinity.png') $stray 'prompt' "$tok-STRAY" | Out-Null
$g14 = [System.Collections.Generic.List[string]]::new(); $g14ok = $true
function Check([string]$what, [bool]$ok) { if (-not $ok) { $script:g14ok = $false; $g14.Add("FAIL:$what") } else { $g14.Add("ok:$what") } }

# -- prompt emitter: exactly the accepted brief, byte for byte
$ingest = Join-Path $Repo 'tools\Ingest-Comparison.ps1'; $emit = Join-Path $Repo 'tools\Write-ComparisonPrompt.ps1'
& pwsh -NoProfile -File $emit -Source $fx14 -BaseName $cmpWorks[0] | Out-Null
$brief0 = (Get-Content -LiteralPath (Join-Path $fx14 "art-runs\$($cmpWorks[0]).json") -Raw | ConvertFrom-Json -AsHashtable)['image_prompt']
$promptBytes = [System.IO.File]::ReadAllBytes((Join-Path $fx14 "comparisons\prompts\$($cmpWorks[0]).txt"))
Check 'prompt-file==brief' ([System.Linq.Enumerable]::SequenceEqual($promptBytes, [System.Text.UTF8Encoding]::new($false).GetBytes($brief0)))
& pwsh -NoProfile -File $emit -Source $fx14 -BaseName '2099-01-01-not-a-work' | Out-Null
Check 'prompt-emitter refuses unknown work' ($LASTEXITCODE -eq 1)
# prompts\ is beside the records; it must not count as an inbox file or a record
$common = @('-Source', $fx14, '-Model', 'gpt-image-1', '-GeneratedOn', '2026-10-01', '-RoundId', 'r1', '-RoundCloses', '2026-10-08')
& pwsh -NoProfile -File $ingest @common -BaseName $cmpWorks[0] -Image $img1 | Out-Null
Check 'ingest pair 1' ($LASTEXITCODE -eq 0)
# workflow: drop ONE image, ingest it, then drop the next
& python $Enc plant-provenance (Join-Path $Source '2026-08-16-an-infinity.png') (Join-Path $inbox $img2) 1536 1024 $label | Out-Null
# stray file in the inbox: ingest must refuse and write nothing
Copy-Item -LiteralPath $stray -Destination (Join-Path $inbox (Split-Path -Leaf $stray))
& pwsh -NoProfile -File $ingest @common -BaseName $cmpWorks[1] -Image $img2 | Out-Null
Check 'ingest refuses with unreferenced inbox file' (($LASTEXITCODE -eq 1) -and -not (Test-Path -LiteralPath (Join-Path $fx14 "comparisons\r1-$($cmpWorks[1]).json")))
Move-Item -LiteralPath (Join-Path $inbox (Split-Path -Leaf $stray)) -Destination "$stray.held"
& pwsh -NoProfile -File $ingest @common -BaseName $cmpWorks[1] -Image $img2 | Out-Null
Check 'ingest pair 2' ($LASTEXITCODE -eq 0)
Move-Item -LiteralPath "$stray.held" -Destination (Join-Path $inbox (Split-Path -Leaf $stray))   # stray present for the build
$recs = @(foreach ($n in $cmpWorks) { Get-Content -LiteralPath (Join-Path $fx14 "comparisons\r1-$n.json") -Raw | ConvertFrom-Json -AsHashtable })
Check 'records carry the exact brief + sha' (@($recs | Where-Object { $_['brief'] -ceq (Get-Content -LiteralPath (Join-Path $fx14 "art-runs\$($_['base_name']).json") -Raw | ConvertFrom-Json -AsHashtable)['image_prompt'] -and $_['chatgpt_sha256'] -eq (Get-FileHash -LiteralPath (Join-Path $inbox $_['chatgpt_image'])).Hash.ToLowerInvariant() }).Count -eq 2)
New-Item -ItemType Directory -Force -Path (Join-Path $fx14 'comparisons\rounds') | Out-Null
[System.IO.File]::WriteAllText((Join-Path $fx14 'comparisons\rounds\r1.json'), '{"round_id": "r1", "vote_url": ""}', [System.Text.UTF8Encoding]::new($false))

# -- positive controls on the SOURCE: the detectors see the planted model names, label and metadata
$srcPng = Join-Path $inbox $img1
$srcLatin = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($srcPng))
$srcCh = Chunks $srcPng
Check "PC source chunks caBX+eXIf+iTXt+iCCP+tEXt [$($srcCh | Select-Object -Unique)]" (@(@('caBX', 'eXIf', 'iTXt', 'iCCP', 'tEXt') | Where-Object { $srcCh -notcontains $_ }).Count -eq 0)
Check 'PC source binary model/C2PA needles seen' ([regex]::Matches($srcLatin, $ModelRxBin).Count -ge 4)
Check 'PC source label canary seen' ($srcLatin.Contains($tok))
Check 'PC source file name carries a model name' ($img1 -match $ModelRx)
Check 'PC stray canary seen in source' ([System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $inbox (Split-Path -Leaf $stray)))).Contains("$tok-STRAY"))

# -- OPEN build
$openSite = Join-Path $Scratch 'cmp-open-site'; $closedSite = Join-Path $Scratch 'cmp-closed-site'
$o14 = & pwsh -NoProfile -File $Gen -Source $fx14 -Out $openSite -BuildDir (Join-Path $Scratch 'cmp-open-build') -Today 2026-10-08 2>&1; $oExit = $LASTEXITCODE
Check 'open build exit 0' ($oExit -eq 0)
$oLog = Get-Content -LiteralPath (Join-Path $Scratch 'cmp-open-build\build.log')
$ph = @($oLog | Where-Object { $_ -match '^PAIRENC\s+([0-9a-f]{16})' } | ForEach-Object { $Matches[1] })
$openAssets = @('comparisons.html', 'c\r1.html') + @(foreach ($h in $ph) { "cmp\$h-a.webp"; "cmp\$h-b.webp" })
$openFiles = @(Get-ChildItem -LiteralPath $openSite -Recurse -File | ForEach-Object { $_.FullName.Substring($openSite.Length + 1) })
$cmpOut = @($openFiles | Where-Object { $_ -like 'cmp\*' -or $_ -like 'c\*' } | Sort-Object)
Check "open output cmp set exact ($($cmpOut.Count) files, 2 pairs)" ($ph.Count -eq 2 -and (($cmpOut -join '|') -eq ((@($openAssets | Where-Object { $_ -ne 'comparisons.html' }) | Sort-Object) -join '|')))
$leakHits = [System.Collections.Generic.List[string]]::new()
foreach ($a in $openAssets) {
    $fp = Join-Path $openSite $a
    if ($a -match $ModelRx) { $leakHits.Add("name:$a") }
    if ($a -like '*.html') {
        $t = [System.IO.File]::ReadAllText($fp)
        foreach ($m in [regex]::Matches($t, "\b$ModelRx")) { $leakHits.Add("text:$a=$($m.Value)") }
        if ($t -match '(?i)<script') { $leakHits.Add("script:$a") }
        foreach ($m in [regex]::Matches($t, ' alt="([^"]*)"')) { if ($m.Groups[1].Value -notmatch '^Image [AB] for the poem ') { $leakHits.Add("alt:$a") } }
        if ($t -match '(?i)\b(local|locally|renderer A|renderer B)\b.{0,40}\bImage [AB]\b|\bImage [AB]\b.{0,40}\b(local|locally)\b') { $leakHits.Add("label:$a") }
    } else {
        $b = [System.Text.Encoding]::Latin1.GetString([System.IO.File]::ReadAllBytes($fp))
        foreach ($m in [regex]::Matches($b, $ModelRxBin)) { $leakHits.Add("bin:$a=$($m.Value)") }
        foreach ($ch in (Chunks $fp)) { if ($ch -notin 'VP8', 'VP8L') { $leakHits.Add("chunk:$a=$ch") } }
    }
}
$anyTok = Scan (Read-Tree $openSite) @($tok)
Check "open assets: model names/metadata/labels/script=$($leakHits.Count)$(if ($leakHits.Count) { ' [' + (($leakHits | Select-Object -First 4) -join '; ') + ']' })" ($leakHits.Count -eq 0)
Check "canary (label/stray) anywhere in open output=$($anyTok.Count)" ($anyTok.Count -eq 0)
Check 'no ChatGPT original published while open' (-not (Test-Path -LiteralPath (Join-Path $openSite 'cmp\orig')))
$openPage = [System.IO.File]::ReadAllText((Join-Path $openSite 'c\r1.html'))
Check 'open page: framing + Voting opens soon' ($openPage.Contains('One brief, two renderers. Informal, one sample each.') -and $openPage.Contains('Voting opens soon.'))
# size sanity: same format, same dimensions, same chunk list, bytes within 4x
$sizeNotes = [System.Collections.Generic.List[string]]::new()
foreach ($h in $ph) {
    $ia = Join-Path $openSite "cmp\$h-a.webp"; $ib = Join-Path $openSite "cmp\$h-b.webp"
    $ii = Img-Info @($ia, $ib)
    $ba = (Get-Item -LiteralPath $ia).Length; $bb = (Get-Item -LiteralPath $ib).Length
    $ratio = [Math]::Round([Math]::Max($ba, $bb) / [double][Math]::Max(1, [Math]::Min($ba, $bb)), 2)
    $same = ($ii[0].fmt -eq 'WEBP' -and $ii[1].fmt -eq 'WEBP' -and $ii[0].w -eq $ii[1].w -and $ii[0].h -eq $ii[1].h -and $ii[0].mode -eq $ii[1].mode -and ((Chunks $ia) -join ',') -eq ((Chunks $ib) -join ',') -and (@($ii[0].info) -join ',') -eq (@($ii[1].info) -join ',') -and @(@($ii[0].info) + @($ii[1].info) | Where-Object { $_ -in 'icc_profile', 'exif', 'xmp', 'dpi' }).Count -eq 0)   # Pillow reports decoder defaults (background, loop); only real metadata keys are forbidden
    $sizeNotes.Add("$($ii[0].w)x$($ii[0].h)/$($ii[1].w)x$($ii[1].h) ${ba}B/${bb}B x$ratio")
    Check "pair $h indistinguishable by format/dims/chunks, bytes x$ratio" ($same -and $ratio -le 4)
}
# a/b is chosen by hash: across the fixture both orders may occur; assert it is NOT a constant of the model
$order = @(foreach ($h in $ph) { $ob = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes("$h|order")); (($ob[0] -band 1) -eq 0) })

# -- CLOSED build (same inputs, day after round_closes): reveal + exact credit line, same image bytes
$c14 = & pwsh -NoProfile -File $Gen -Source $fx14 -Out $closedSite -BuildDir (Join-Path $Scratch 'cmp-closed-build') -Today 2026-10-09 2>&1
Check 'closed build exit 0' ($LASTEXITCODE -eq 0)
$closedPage = [System.IO.File]::ReadAllText((Join-Path $closedSite 'c\r1.html'))
$credit = "Generated by gpt-image-1, 2026-10-01, via ChatGPT; not covered by this site's CC0 dedication."
Check 'closed page: exact credit line x2' (([regex]::Matches($closedPage, [regex]::Escape($credit))).Count -eq 2)
Check 'PC text detector fires on the revealed page' ([regex]::Matches($closedPage, "\b$ModelRx").Count -ge 2)
Check 'closed page: framing, no winner banner' ($closedPage.Contains('One brief, two renderers. Informal, one sample each.') -and $closedPage -notmatch '(?i)winner|won\b')
$sameImgs = @(foreach ($h in $ph) { foreach ($s in 'a', 'b') { (Get-FileHash -LiteralPath (Join-Path $openSite "cmp\$h-$s.webp")).Hash -eq (Get-FileHash -LiteralPath (Join-Path $closedSite "cmp\$h-$s.webp")).Hash } })
Check 'served images identical open vs closed' (@($sameImgs | Where-Object { -not $_ }).Count -eq 0)
$origs = @(Get-ChildItem -LiteralPath (Join-Path $closedSite 'cmp\orig') -File -ErrorAction SilentlyContinue)
Check "closed: C2PA originals published unmodified ($($origs.Count))" ($origs.Count -eq 2 -and @($origs | Where-Object { (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() -notin @($recs | ForEach-Object { $_['chatgpt_sha256'] }) }).Count -eq 0)
Check 'stray never reaches closed output' ((Scan (Read-Tree $closedSite) @("$tok-STRAY")).Count -eq 0)

# -- fail closed: an inbox image changed after ingest aborts the build
$fx14b = Join-Path $Scratch 'fixture-cmp-tamper'
Copy-Item -LiteralPath $fx14 -Destination $fx14b -Recurse
[System.IO.File]::AppendAllText((Join-Path $fx14b "comparisons\inbox\$img1"), 'x')
$t14 = & pwsh -NoProfile -File $Gen -Source $fx14b -Out (Join-Path $Scratch 'cmp-tamper-site') -BuildDir (Join-Path $Scratch 'cmp-tamper-build') -Today 2026-10-01 2>&1
Check 'tampered inbox image aborts before output' (($LASTEXITCODE -eq 1) -and -not (Test-Path -LiteralPath (Join-Path $Scratch 'cmp-tamper-site')))

[System.IO.File]::WriteAllText((Join-Path $Scratch 'gate14-run.log'), (($g14 + $sizeNotes + @("order local_is_a=$($order -join ',')")) -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
Gate '14' 'blind comparison: open round leaks no model/metadata/label; stray inbox file never served; pair not trivially distinguishable; reveal exact' $g14ok "$(@($g14 | Where-Object { $_ -like 'ok:*' }).Count)/$($g14.Count) checks ok; $(($g14 | Where-Object { $_ -like 'FAIL:*' }) -join '; '); pairs: $($sizeNotes -join ' | '); log: tests\_scratch\gate14-run.log"

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
$cmpRounds = @($buildLog | Where-Object { $_ -match '^ROUND\s+(\S+)' } | ForEach-Object { $Matches[1] })
$cmpPairs  = @($buildLog | Where-Object { $_ -match '^PAIRENC\s+([0-9a-f]{16})' } | ForEach-Object { $Matches[1] })

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
# cmp\orig holds a closed round's ChatGPT original, published on purpose with its C2PA credentials.
$pngAnywhere = @(Get-ChildItem -LiteralPath $Site -Recurse -File -Filter '*.png' | Where-Object { $_.FullName -notlike "*\cmp\orig\*" })
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
    if ($k -in 'index.html', 'experiment.html', 'evolution.html', 'comparisons.html', 'style.css', 'robots.txt') { continue }
    # comparison assets must be named by the build log (a ROUND line for pages, a PAIRENC line for images)
    if ($k -match '^c\\([a-z0-9\-]+)\.html$') { if ($cmpRounds -notcontains $Matches[1]) { $k }; continue }
    if ($k -match '^cmp\\(orig\\)?([0-9a-f]{16})-') { if ($cmpPairs -notcontains $Matches[2]) { $k }; continue }
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
    # 0.3.0: the real corpus has no rounds yet, so also probe the Gate 14 fixture's open and closed round pages.
    $cmpLayoutOk = $true; $cmpEv = @()
    foreach ($cs in @(@('open', $openSite), @('closed', $closedSite))) {
        $clo = & python $Layout $cs[1] (Join-Path $Scratch "cmp-$($cs[0])-layout") 2>&1; $cloExit = $LASTEXITCODE
        $cls = try { (($clo | Where-Object { $_ -notmatch '^\s*$' }) -join "`n") | ConvertFrom-Json } catch { $null }
        if ($cloExit -ne 0 -or $null -eq $cls -or $cls.failures.Count -ne 0) { $cmpLayoutOk = $false }
        $cmpEv += "$($cs[0]) round fixture pages=$(if ($cls) { $cls.pages } else { '?' }) checks=$(if ($cls) { $cls.checks } else { '?' }) failures=$(if ($cls) { $cls.failures.Count } else { '?' })$(if ($cls -and $cls.failures.Count) { ' first=' + ($cls.failures[0] | ConvertTo-Json -Compress) })"
    }
    $ev = "$ev; $($cmpEv -join '; ')"
    Gate '7' 'Rule 1 reactive layout (Playwright/Edge)' ($loExit -eq 0 -and $null -ne $summary -and $summary.failures.Count -eq 0 -and $cmpLayoutOk) $ev
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
$cmpEmptyOk = $emptyRun.exit -eq 0 -and (Test-Path -LiteralPath (Join-Path $Scratch 'empty-site\comparisons.html')) -and [System.IO.File]::ReadAllText((Join-Path $Scratch 'empty-site\comparisons.html')).Contains('No comparison rounds yet.')
$g8ok = $cmpEmptyOk -and $emptyOk -and ($badImg.Count -eq 0) -and $frameOk -and (-not $realIndex.Contains('No works have been published yet.')) -and ($imgTags.Count -eq 2 * $worksA + 1)   # +1 = the latest work's full image in the index hero (0.2.0)
Gate '8' 'Rule 6: empty state real; every img has alt+width+height; framed failure path' $g8ok "empty-corpus run exit=$($emptyRun.exit) shows empty state=$($emptyIndex.Contains('No works have been published yet.')); img tags=$($imgTags.Count) missing alt/width/height=$($badImg.Count); figure.art has background+aspect-ratio=$frameOk; real index shows empty state=$($realIndex.Contains('No works have been published yet.')); comparisons empty state (no rounds)=$cmpEmptyOk"

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
