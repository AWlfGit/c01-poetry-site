#Requires -Version 7.0
<#
.SYNOPSIS
  Generate the C01 Poetry static site from the C01Poetry corpus into a disposable _site/.

.DESCRIPTION
  Design: corp-docs/comms/2026-09-18-engineering-vp-poetry-art-publishing-mechanism.md
  Decision: BOARD_LOG [BOARDLOG-2026-09-19-DECK-WALKTHROUGH] item 20 -- BUILD, HOLD PUBLISH.

  THE ONLY ENUMERATOR IS <Source>\art-runs\*.json. For each record carrying `base_name` AND
  `accepted_at`, the generator reads exactly <Source>\<base_name>.md and <Source>\<base_name>.png
  and nothing else. A file no run record names is structurally unreachable -- there is no
  directory walk over the source tree, and there is no filename denylist to get wrong.

  From the poem file only the front matter and the poem body (everything before the first `---`
  horizontal rule after the front matter) are read. The roast JSON and the losing drafts that
  follow that rule are never emitted unless -IncludeRoast is passed (default: off).

  Every image is re-rasterised from pixels into a fresh RGB buffer and encoded as WebP, so no
  PNG ancillary chunk (tEXt/iTXt/zTXt, ICC, EXIF) can survive into the output.

  Output is byte-stable across runs: no timestamps, ordinal sort, LF line endings, UTF-8 no BOM.

.PARAMETER Source        Corpus root. Defaults to the C01POETRY_SOURCE environment variable. Read-only.
.PARAMETER Out           Output directory. Emptied and regenerated on every run.
.PARAMETER BuildDir      Scratch dir for the run log and encoder job file (never published).
.PARAMETER IncludeRoast  Emit the roast + losing drafts on each piece page. Default off.
.PARAMETER Today         yyyy-MM-dd that decides whether a comparison round is open or closed.
                         Defaults to today's UTC date; the gate harness passes it for byte-stable runs.

  COMPARISONS (0.3.0, BOARDLOG-2026-10-01-POETRY-FULL-PROJECT Phase 2 pilot). A second enumerated
  source, <Source>\comparisons\*.json, one record per pair. Each record names exactly one file in
  <Source>\comparisons\inbox and pins it by sha256, and names one accepted base_name whose brief it
  must repeat byte for byte. The generator never lists the inbox. Both images of a pair go through
  one identical re-encode. Served names are a pair hash plus a/b, and the hash picks the a/b order.
  While a round is open (Today <= round_closes) its page carries no model name, label, alt text or
  script that says which image is which. After it closes, the page reveals.

.OUTPUTS
  Exit 0 on success. Exit 1 on any record that names a missing pair, a duplicate base_name,
  or an encoder failure -- the build fails closed rather than publishing a partial set.
#>
[CmdletBinding()]
param(
    [string]$Source   = $env:C01POETRY_SOURCE,
    [string]$Out      = (Join-Path $PSScriptRoot '_site'),
    [string]$BuildDir = (Join-Path $PSScriptRoot '_build'),
    [switch]$IncludeRoast,
    [string]$Today    = ([DateTime]::UtcNow.ToString('yyyy-MM-dd'))
)

Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($Source)) { Write-Host 'ERROR -Source not given and C01POETRY_SOURCE is not set'; exit 1 }
if ($Today -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Host "ERROR -Today must be yyyy-MM-dd, got '$Today'"; exit 1 }
$ErrorActionPreference = 'Stop'

$Script:Version   = '0.3.0'
$Script:SiteTitle = 'C01 Poetry & Illustration'
$Script:Entity    = 'c0rw1n innovative inc'
$Script:HomeUrl   = 'https://c0rw1n.com/'
$Script:Utf8      = [System.Text.UTF8Encoding]::new($false)
$Script:Encoder   = Join-Path $PSScriptRoot 'tools\encode_webp.py'
$Script:DefaultSeries = 'Memory Storage of a Modern System'   # INDEX.md H1 of the pre-First-Light series
$Script:LogLines  = [System.Collections.Generic.List[string]]::new()

function Log([string]$line) { $Script:LogLines.Add($line); Write-Host $line }
function Fail([string]$msg) { Log "ERROR $msg"; Flush-Log; exit 1 }
function Flush-Log {
    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $BuildDir 'build.log'), (($Script:LogLines -join "`n") + "`n"), $Script:Utf8)
}
function Write-Text([string]$path, [string]$text) {
    $dir = Split-Path -Parent $path
    if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($path, $text.Replace("`r`n", "`n"), $Script:Utf8)
}
# Named Esc, not H: `h` is a built-in alias for Get-History and aliases outrank functions.
function Esc([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }

# ---------------------------------------------------------------------------------------------
# 1. Enumerate -- ONLY art-runs\*.json. This is the single directory read in the whole script.
# ---------------------------------------------------------------------------------------------
$runsDir = Join-Path $Source 'art-runs'
if (-not (Test-Path -LiteralPath $runsDir -PathType Container)) { Fail "art-runs directory not found: $runsDir" }
$runFiles = @(Get-ChildItem -LiteralPath (Join-Path $Source 'art-runs') -Filter '*.json' -File | Sort-Object -Property Name)
Log "ENUMERATE dir=$runsDir records=$($runFiles.Count) include_roast=$($IncludeRoast.IsPresent) version=$Script:Version"

$records = @{}   # base_name -> @{ run=<obj>; runFile=<name> }
foreach ($f in $runFiles) {
    $run = $null
    try { $run = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable }
    catch { Fail "unparseable run record $($f.Name): $($_.Exception.Message)" }
    $bn  = if ($run.ContainsKey('base_name'))   { [string]$run['base_name'] }   else { '' }
    $acc = if ($run.ContainsKey('accepted_at')) { [string]$run['accepted_at'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($bn))  { Log "SKIP   $($f.Name) reason=no-base_name"; continue }
    if ([string]::IsNullOrWhiteSpace($acc)) { Log "SKIP   $($f.Name) base_name=$bn reason=no-accepted_at (not an accepted work)"; continue }
    if ($bn -notmatch '^[a-z0-9][a-z0-9\-]*$') { Fail "base_name '$bn' in $($f.Name) is not a plain slug; refusing to derive a path from it" }
    if ($records.ContainsKey($bn)) { Fail "duplicate accepted record for base_name '$bn' ($($records[$bn].runFile) and $($f.Name))" }
    $records[$bn] = @{ run = $run; runFile = $f.Name }
    Log "RECORD $($f.Name) base_name=$bn accepted_at=$acc"
}

# ---------------------------------------------------------------------------------------------
# 2. Read exactly <base_name>.md and <base_name>.png for each record. Fail closed on a miss.
# ---------------------------------------------------------------------------------------------
function Parse-Poem([string]$path) {
    $text  = [System.IO.File]::ReadAllText($path, $Script:Utf8).Replace("`r`n", "`n")
    $lines = $text -split "`n"
    if ($lines.Count -lt 3 -or $lines[0] -ne '---') { throw "no front matter in $path" }
    $fm = [ordered]@{}
    $i = 1
    while ($i -lt $lines.Count -and $lines[$i] -ne '---') {
        $ln = $lines[$i]
        $k  = $ln.IndexOf(':')
        if ($k -gt 0) { $fm[$ln.Substring(0, $k).Trim()] = $ln.Substring($k + 1).Trim() }
        $i++
    }
    if ($i -ge $lines.Count) { throw "unterminated front matter in $path" }
    $i++   # past closing ---
    # Body = up to the first horizontal rule AFTER the front matter. Everything after it
    # (the roast, the losing drafts, any footnote) is the remainder and is NOT the poem.
    $body = [System.Collections.Generic.List[string]]::new()
    $rest = [System.Collections.Generic.List[string]]::new()
    $inRest = $false
    for (; $i -lt $lines.Count; $i++) {
        if (-not $inRest -and $lines[$i] -match '^---\s*$') { $inRest = $true; continue }
        if ($inRest) { $rest.Add($lines[$i]) } else { $body.Add($lines[$i]) }
    }
    $title = ''
    $poem  = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in $body) {
        if ($title -eq '' -and $ln -match '^#\s+(.+)$') { $title = $Matches[1].Trim(); continue }
        $poem.Add($ln)
    }
    # trim leading/trailing blank lines
    while ($poem.Count -gt 0 -and $poem[0].Trim() -eq '')                { $poem.RemoveAt(0) }
    while ($poem.Count -gt 0 -and $poem[$poem.Count - 1].Trim() -eq '') { $poem.RemoveAt($poem.Count - 1) }
    return @{ fm = $fm; title = $title; poem = $poem; rest = $rest }
}

$works = [System.Collections.Generic.List[hashtable]]::new()
foreach ($bn in $records.Keys) {
    $mdPath  = Join-Path $Source "$bn.md"
    $pngPath = Join-Path $Source "$bn.png"
    if (-not (Test-Path -LiteralPath $mdPath  -PathType Leaf)) { Fail "record names '$bn' but $mdPath does not exist" }
    if (-not (Test-Path -LiteralPath $pngPath -PathType Leaf)) { Fail "record names '$bn' but $pngPath does not exist" }
    $p = $null
    try { $p = Parse-Poem $mdPath } catch { Fail $_.Exception.Message }
    $run = $records[$bn].run
    $series = if ($p.fm.Contains('series') -and $p.fm['series']) { $p.fm['series'] } else { $Script:DefaultSeries }
    $title  = if ($p.title) { $p.title } elseif ($p.fm.Contains('title')) { $p.fm['title'] } else { $bn }
    $works.Add(@{
        base_name = $bn
        title     = $title
        series    = $series
        date      = $(if ($p.fm.Contains('date')) { $p.fm['date'] } else { $bn.Substring(0, 10) })
        theme     = $(if ($p.fm.Contains('theme')) { $p.fm['theme'] } else { '' })
        model     = $(if ($p.fm.Contains('model')) { $p.fm['model'] } else { '' })
        rounds    = $(if ($p.fm.Contains('rounds_run')) { $p.fm['rounds_run'] } else { '' })
        score     = $(if ($p.fm.Contains('winning_score')) { $p.fm['winning_score'] } elseif ($p.fm.Contains('score')) { $p.fm['score'] } else { '' })
        poem      = $p.poem
        rest      = $p.rest
        # art-runs fields -- an explicit allowlist. candidate_source / candidates / theme_coverage
        # carry local paths and judge internals and are never read past this point.
        art_tier   = $(if ($run.ContainsKey('tier'))         { [string]$run['tier'] }    else { '' })
        art_rounds = $(if ($run.ContainsKey('rounds'))       { [string]$run['rounds'] }  else { '' })
        art_score  = $(if ($run.ContainsKey('overall'))      { [string]$run['overall'] } else { '' })
        art_prompt = $(if ($run.ContainsKey('image_prompt')) { [string]$run['image_prompt'] } else { '' })
        png        = $pngPath
        family     = $(if ($p.fm.Contains('family')) { $p.fm['family'] } else { '' })
        poem_scores= $(if ($p.fm.Contains('scores')) { $p.fm['scores'] } else { '' })
        accepted_at= [string]$run['accepted_at']
        # `models` is an explicit allowlisted block written by the art pipeline's accept step from
        # 2026-09-26. Only its five named string fields are read; nothing else in it is emitted.
        rec_models = $(if ($run.ContainsKey('models') -and $run['models'] -is [System.Collections.IDictionary]) { $mm = [ordered]@{}; foreach ($mk in 'poem_writer', 'prompt_writer', 'renderer', 'judge_model') { if ($run['models'].Contains($mk) -and $run['models'][$mk] -is [string]) { $mm[$mk] = $run['models'][$mk] } }; $mm } else { $null })
    })
    Log "PAIR   base_name=$bn md=$($bn).md png=$($bn).png poem_lines=$($p.poem.Count) remainder_lines_dropped=$($p.rest.Count)"
}

# Ordinal sort, newest first. Culture-independent so two hosts produce identical bytes.
$keys = [System.Collections.Generic.List[string]]::new()
foreach ($w in $works) { $keys.Add($w.base_name) }
$keys.Sort([System.StringComparer]::Ordinal)
$keys.Reverse()
$byName = @{}; foreach ($w in $works) { $byName[$w.base_name] = $w }
$ordered = @(foreach ($k in $keys) { $byName[$k] })

# ---------------------------------------------------------------------------------------------
# 2b. Comparisons -- the SECOND and last enumerator: <Source>\comparisons\*.json (records only).
#     The inbox is never listed here; each record names its one image and pins it by sha256.
# ---------------------------------------------------------------------------------------------
$Script:CmpFields = 'pair_id', 'base_name', 'brief', 'chatgpt_image', 'chatgpt_sha256', 'chatgpt_model', 'generated_on', 'round_id', 'round_closes'
$cmpDir = Join-Path $Source 'comparisons'
$pairs  = [System.Collections.Generic.List[hashtable]]::new()
$rounds = @{}   # round_id -> @{ id; closes; vote_url; open; pairs }
if (Test-Path -LiteralPath $cmpDir -PathType Container) {
    $cmpFiles = @(Get-ChildItem -LiteralPath (Join-Path $Source 'comparisons') -Filter '*.json' -File | Sort-Object -Property Name)
    Log "ENUMERATE dir=comparisons records=$($cmpFiles.Count) today=$Today"
    $seenPair = @{}; $seenImg = @{}
    foreach ($f in $cmpFiles) {
        $c = $null
        try { $c = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { Fail "unparseable comparison record $($f.Name): $($_.Exception.Message)" }
        foreach ($k in $Script:CmpFields) { if (-not $c.ContainsKey($k) -or $c[$k] -isnot [string] -or [string]::IsNullOrWhiteSpace($c[$k])) { Fail "comparison record $($f.Name) lacks string field '$k'" } }
        $pairId = $c['pair_id']; $bn = $c['base_name']; $rid = $c['round_id']; $img = $c['chatgpt_image']
        if ($pairId -notmatch '^[a-z0-9][a-z0-9\-]*$') { Fail "pair_id '$pairId' in $($f.Name) is not a plain slug" }
        if ($rid    -notmatch '^[a-z0-9][a-z0-9\-]*$') { Fail "round_id '$rid' in $($f.Name) is not a plain slug" }
        if ($img -notmatch '^[^\\/:*?"<>|]+\.(png|jpg|jpeg|webp)$' -or $img.StartsWith('.')) { Fail "chatgpt_image '$img' in $($f.Name) is not a plain image file name" }
        foreach ($dk in 'generated_on', 'round_closes') { if ($c[$dk] -notmatch '^\d{4}-\d{2}-\d{2}$') { Fail "$dk in $($f.Name) must be a date only (yyyy-MM-dd)" } }
        if ($c['chatgpt_sha256'] -cnotmatch '^[0-9a-f]{64}$') { Fail "chatgpt_sha256 in $($f.Name) is not a lowercase sha256" }
        if ($seenPair.ContainsKey($pairId)) { Fail "duplicate pair_id '$pairId' ($($seenPair[$pairId]) and $($f.Name))" }
        if ($seenImg.ContainsKey($img))     { Fail "inbox image '$img' named by two records ($($seenImg[$img]) and $($f.Name))" }
        $seenPair[$pairId] = $f.Name; $seenImg[$img] = $f.Name
        if (-not $byName.ContainsKey($bn)) { Fail "comparison $($f.Name) names base_name '$bn', which is not an accepted art-runs record" }
        $w = $byName[$bn]
        if ($c['brief'] -cne $w.art_prompt) { Fail "comparison $($f.Name): brief differs from the accepted record's image_prompt for '$bn' (one brief for both renderers is the experiment)" }
        $imgPath = Join-Path (Join-Path $cmpDir 'inbox') $img
        if (-not (Test-Path -LiteralPath $imgPath -PathType Leaf)) { Fail "comparison $($f.Name) names inbox image '$img', which does not exist" }
        $sha = (Get-FileHash -LiteralPath $imgPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($sha -ne $c['chatgpt_sha256']) { Fail "comparison $($f.Name): inbox image '$img' does not match the record's sha256 (re-run tools\Ingest-Comparison.ps1)" }
        # Pair hash names the served files. Nothing shown while the round is open lets a reader derive it.
        $ph = ([System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($Script:Utf8.GetBytes("c01poetry-cmp|$pairId|$sha")))).ToLowerInvariant().Substring(0, 16)
        $ob = [System.Security.Cryptography.SHA256]::HashData($Script:Utf8.GetBytes("$ph|order"))
        $localIsA = (($ob[0] -band 1) -eq 0)
        if (-not $rounds.ContainsKey($rid)) { $rounds[$rid] = @{ id = $rid; closes = $c['round_closes']; vote_url = ''; open = $true; pairs = [System.Collections.Generic.List[hashtable]]::new() } }
        elseif ($rounds[$rid].closes -ne $c['round_closes']) { Fail "round '$rid' has two round_closes dates ($($rounds[$rid].closes), and $($c['round_closes']) in $($f.Name))" }
        $pr = @{ pair_id = $pairId; hash = $ph; local_is_a = $localIsA; work = $w; img = $imgPath; ext = [System.IO.Path]::GetExtension($img).ToLowerInvariant()
                 model = $c['chatgpt_model']; generated_on = $c['generated_on']; round = $rid }
        $rounds[$rid].pairs.Add($pr); $pairs.Add($pr)
        Log "CMP    $($f.Name) pair=$ph round=$rid base_name=$bn"
    }
    # Round records: <Source>\comparisons\rounds\<round_id>.json, read by exact name. Optional.
    foreach ($rid in @($rounds.Keys)) {
        $rp = Join-Path (Join-Path $cmpDir 'rounds') "$rid.json"
        if (Test-Path -LiteralPath $rp -PathType Leaf) {
            $rr = $null
            try { $rr = Get-Content -LiteralPath $rp -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable } catch { Fail "unparseable round record $rid.json: $($_.Exception.Message)" }
            $vu = if ($rr.ContainsKey('vote_url') -and $rr['vote_url'] -is [string]) { $rr['vote_url'].Trim() } else { '' }
            if ($vu -and $vu -notmatch '^https://[^\s"<>]+$') { Fail "round $rid vote_url must be an https URL or empty" }
            $rounds[$rid].vote_url = $vu
        }
        # Closes at the end of round_closes: open on that date, revealed from the next day.
        $rounds[$rid].open = ([string]::CompareOrdinal($Today, $rounds[$rid].closes) -le 0)
        $rounds[$rid].pairs.Sort([System.Comparison[hashtable]] { param($x, $y) [string]::CompareOrdinal($x.hash, $y.hash) })
        Log "ROUND  $rid closes=$($rounds[$rid].closes) state=$(if ($rounds[$rid].open) { 'open' } else { 'closed' }) pairs=$($rounds[$rid].pairs.Count) vote_url=$(if ($rounds[$rid].vote_url) { 'set' } else { 'empty' })"
    }
}
$roundKeys = [System.Collections.Generic.List[string]]::new(); foreach ($k in $rounds.Keys) { $roundKeys.Add($k) }
$roundKeys.Sort([System.StringComparer]::Ordinal); $roundKeys.Reverse()

# ---------------------------------------------------------------------------------------------
# 3. Fresh output directory.
# ---------------------------------------------------------------------------------------------
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'p')   | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Out 'img') | Out-Null
New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
if ($pairs.Count -gt 0) { New-Item -ItemType Directory -Force -Path (Join-Path $Out 'cmp') | Out-Null }

# ---------------------------------------------------------------------------------------------
# 4. Images -- one batch through the encoder. Pixels only; no chunk is copied.
# ---------------------------------------------------------------------------------------------
$jobs = @(foreach ($w in $ordered) {
    @{ src = $w.png; full = (Join-Path $Out "img\$($w.base_name).webp"); thumb = (Join-Path $Out "img\$($w.base_name)-t.webp"); max_full = 1024; max_thumb = 512; quality = 82 }
})
$jobFile = Join-Path $BuildDir 'encode-jobs.json'
Write-Text $jobFile (ConvertTo-Json -InputObject $jobs -Depth 4)
$dims = @{}
if ($jobs.Count -gt 0) {
    $encOut = & python $Script:Encoder encode --jobs $jobFile 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "encoder failed: $($encOut -join ' | ')" }
    foreach ($line in $encOut) {
        if ($line -notmatch '^\{') { Log "ENCODER $line"; continue }
        $r = $line | ConvertFrom-Json -AsHashtable
        $dims[$r['base']] = $r
        Log "ENCODE $($r['base']) src=$($r['src_w'])x$($r['src_h']) src_chunks=$($r['src_text_chunks']) full=$($r['full_w'])x$($r['full_h']) $($r['full_bytes'])B thumb=$($r['thumb_w'])x$($r['thumb_h']) $($r['thumb_bytes'])B"
    }
}

# 4b. Comparison pairs: both images through ONE identical pipeline (encode_webp.py pair).
$cmpDims = @{}
if ($pairs.Count -gt 0) {
    $pjobs = @(foreach ($pr in $pairs) {
        @{ pair = $pr.hash; local = $pr.work.png; remote = $pr.img; out_a = (Join-Path $Out "cmp\$($pr.hash)-a.webp"); out_b = (Join-Path $Out "cmp\$($pr.hash)-b.webp"); local_is_a = $pr.local_is_a; max_side = 1024; quality = 82 }
    })
    $pjobFile = Join-Path $BuildDir 'pair-jobs.json'
    Write-Text $pjobFile (ConvertTo-Json -InputObject $pjobs -Depth 4)
    $pOut = & python $Script:Encoder pair --jobs $pjobFile 2>&1
    if ($LASTEXITCODE -ne 0) { Fail "pair encoder failed: $($pOut -join ' | ')" }
    foreach ($line in $pOut) {
        if ($line -notmatch '^\{') { Log "ENCODER $line"; continue }
        $r = $line | ConvertFrom-Json -AsHashtable
        $cmpDims[$r['pair']] = $r
        Log "PAIRENC $($r['pair']) out=$($r['w'])x$($r['h']) a=$($r['a_bytes'])B b=$($r['b_bytes'])B remote_src=$($r['remote_src'] -join 'x') remote_meta_keys=$(@($r['remote_info_keys']).Count) icc_to_srgb=$($r['remote_icc_converted'])"
    }
    foreach ($pr in $pairs) { if (-not $cmpDims.ContainsKey($pr.hash)) { Fail "pair encoder returned no result for a pair in round $($pr.round)" } }
    # The C2PA original names its model, so it is published only after its round has closed.
    foreach ($pr in $pairs) {
        if (-not $rounds[$pr.round].open) {
            New-Item -ItemType Directory -Force -Path (Join-Path $Out 'cmp\orig') | Out-Null
            Copy-Item -LiteralPath $pr.img -Destination (Join-Path $Out "cmp\orig\$($pr.hash)-original$($pr.ext)")
        }
    }
}

# ---------------------------------------------------------------------------------------------
# 5. Provenance -- which model held each role for each work.
#    Preference order: the work's own recorded `models` block (from 2026-09-26), then the poem's
#    own front-matter `model:` line, then provenance-timeline.json (dated commits). Every credit
#    carries its source so a reader can tell recorded from reconstructed.
# ---------------------------------------------------------------------------------------------
$tlPath = Join-Path $PSScriptRoot 'provenance-timeline.json'
if (-not (Test-Path -LiteralPath $tlPath -PathType Leaf)) { Fail "provenance-timeline.json not found beside the generator" }
$Script:TL = Get-Content -LiteralPath $tlPath -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable

function Pretty([string]$m) {
    if ([string]::IsNullOrWhiteSpace($m)) { return '' }
    $k = ($m -replace '\s*\(.*$', '').Trim()
    if ($Script:TL['names'].ContainsKey($k)) { return $Script:TL['names'][$k] }
    return $k
}
function Era-At([string]$role, [string]$when) {
    $pick = $null
    foreach ($e in $Script:TL['roles'][$role]['eras']) {
        if ([string]::CompareOrdinal([string]$e['from'], $when) -le 0) { $pick = $e['model'] }
    }
    return $pick
}
function Resolve-Credits($w) {
    $rm = $w.rec_models
    $get = { param($k) if ($rm -and $rm.Contains($k) -and $rm[$k]) { [string]$rm[$k] } else { $null } }
    $c = [ordered]@{}
    # poem writer
    $pw = & $get 'poem_writer'
    if ($pw)          { $c.poem   = @{ model = (Pretty $pw);      src = 'recorded' } }
    elseif ($w.model) { $c.poem   = @{ model = (Pretty $w.model); src = 'recorded' } }
    # image prompt writer
    $pr = & $get 'prompt_writer'
    if ($pr) { $c.prompt = @{ model = (Pretty $pr); src = 'recorded' } }
    else     { $c.prompt = @{ model = (Pretty (Era-At 'prompt_writer' $w.accepted_at)); src = 'reconstructed' } }
    # renderer
    $rd = & $get 'renderer'
    if ($rd) { $c.render = @{ model = (Pretty $rd); src = 'recorded' } }
    else {
        $era = $null
        foreach ($e in $Script:TL['roles']['renderer']['eras']) { if ($e['series'] -eq $w.series) { $era = $e['model'] } }
        if ($era) { $c.render = @{ model = (Pretty $era); src = 'reconstructed' } }
    }
    # judge
    $jm = & $get 'judge_model'
    if ($jm) { $c.judge = @{ model = (Pretty $jm); src = 'recorded' } }
    else     { $c.judge = @{ model = (Pretty (Era-At 'judge_model' $w.accepted_at)); src = 'reconstructed' } }
    return $c
}
foreach ($w in $ordered) { $w.credits = Resolve-Credits $w }

# ---------------------------------------------------------------------------------------------
# 6. HTML
# ---------------------------------------------------------------------------------------------
$Script:FamilyHue = @{
    'CURRENT' = @('#1b2a55', '#f2c230'); 'HEAT'   = @('#0f7d7a', '#ff5a2a'); 'FLOW'   = @('#c9a063', '#1f4fd1')
    'LIFT'    = @('#2a8ec9', '#e0243a'); 'SIGNAL' = @('#4a2a7a', '#29e6f0'); 'GROWTH' = @('#5a2350', '#5cf07a')
}
function Tint($w) {
    if ($w.family -and $Script:FamilyHue.ContainsKey($w.family)) { $h = $Script:FamilyHue[$w.family]; return " style=`"--f:$($h[0]);--a:$($h[1])`"" }
    return ''
}
function Page-Head([string]$title, [string]$root, [string]$active, [string]$desc) {
    $nav = @(
        @('index.html', 'Gallery', 'gallery'), @('experiment.html', 'The experiment', 'experiment'), @('evolution.html', 'Evolution', 'evolution'), @('comparisons.html', 'Compare', 'compare')
    ) | ForEach-Object {
        $cur = if ($_[2] -eq $active) { ' aria-current="page"' } else { '' }
        "<a href=`"$root$($_[0])`"$cur>$($_[1])</a>"
    }
@"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="generator" content="build-poetry-site/$Script:Version">
<meta name="description" content="$(Esc $desc)">
<title>$(Esc $title)</title>
<link rel="stylesheet" href="${root}style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="bar"><a class="mark" href="${root}index.html"><span class="glyph" aria-hidden="true">&#10022;</span> C01 <em>Poetry &amp; Illustration</em></a><nav aria-label="Site">$($nav -join '')<a href="$Script:HomeUrl">c0rw1n.com &#8599;</a></nav></header>
"@
}
# Comparison pages use this footer: it names no model, so an open round's page carries none.
function Page-Foot-Neutral {
@"
<footer><p>An experiment by <a href="$Script:HomeUrl">$(Esc $Script:Entity)</a> (c01corp). <a href="$Script:HomeUrl">Visit c0rw1n.com</a>.</p><p>Code MIT. Each image's credit and licence are shown on its round's page once the round closes. Build $Script:Version.</p></footer>
</body>
</html>
"@
}
function Page-Foot {
@"
<footer><p>An experiment by <a href="$Script:HomeUrl">$(Esc $Script:Entity)</a> (c01corp). <a href="$Script:HomeUrl">Visit c0rw1n.com</a>.</p><p>Code MIT. Poems and images dedicated to the public domain (CC0 1.0). Made by local open-weight models; Claude judges the images. Not affiliated with or endorsed by Anthropic, Alibaba Cloud, Stability AI or Black Forest Labs. Build $Script:Version.</p></footer>
</body>
</html>
"@
}
function Poem-Html([System.Collections.Generic.List[string]]$lines) {
    $sb = [System.Text.StringBuilder]::new()
    $stanza = [System.Collections.Generic.List[string]]::new()
    $flush = {
        if ($stanza.Count -gt 0) {
            [void]$sb.Append('<p>').Append((($stanza | ForEach-Object { Esc $_ }) -join "`n")).Append("</p>`n")
            $stanza.Clear()
        }
    }
    foreach ($ln in $lines) { if ($ln.Trim() -eq '') { & $flush } else { $stanza.Add($ln) } }
    & $flush
    return $sb.ToString()
}
function Credit-Line($w) {
    $c = $w.credits; $parts = @()
    foreach ($k in 'poem', 'render', 'judge') { if ($c.Contains($k) -and $c[$k].model) { $parts += (Esc $c[$k].model) } }
    return ($parts -join ' &middot; ')
}
function Credits-Html($w) {
    $c = $w.credits
    $rows = @(
        @('poem',   'Poem written by',         'Local model on one RTX 3070 Ti. It also critiques its own drafts and rewrites up to five times.'),
        @('prompt', 'Image prompt written by', 'Local model. It reads the poem and writes the picture brief.'),
        @('render', 'Image rendered by',       'Local diffusion model on the same GPU. Several candidates per poem.'),
        @('judge',  'Image chosen by',         'Claude, running as the corporation''s blind art-critic. It scores every candidate and never writes a prompt.')
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<ol class=`"credits`">`n")
    $n = 1
    foreach ($r in $rows) {
        if (-not $c.Contains($r[0]) -or -not $c[$r[0]].model) { continue }
        $src = $c[$r[0]].src
        $badge = if ($src -eq 'recorded') { '<span class="src rec" title="Written into this work''s own record when it was made">recorded</span>' } else { '<span class="src rcn" title="Derived from the dated pipeline history on the Evolution page">from pipeline history</span>' }
        $model = Esc $c[$r[0]].model
        if ($r[0] -eq 'judge' -and $w.art_tier -eq 'founder-pick') { $model = "Founder&rsquo;s pick, judged by $model" }
        [void]$sb.Append("<li><span class=`"step`">0$n</span><div><span class=`"role`">$($r[1])</span><strong>$model</strong> $badge<p>$($r[2])</p></div></li>`n")
        $n++
    }
    [void]$sb.Append("</ol>`n")
    return $sb.ToString()
}
function Tier-Text($w) {
    switch ($w.art_tier) {
        'founder-pick' { 'Founder&rsquo;s pick from the candidates' }
        'best-of-n'    { 'Highest-scoring on-subject candidate (did not clear the judge&rsquo;s bar outright)' }
        default        { 'Cleared the judge&rsquo;s bar' }
    }
}

# Piece pages, with previous / next in gallery order.
for ($i = 0; $i -lt $ordered.Count; $i++) {
    $w = $ordered[$i]; $bn = $w.base_name; $d = $dims[$bn]
    $alt = if ($w.theme) { "Illustration for the poem: $($w.theme)" } else { "Illustration for the poem $($w.title)" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((Page-Head "$($w.title) - $Script:SiteTitle" '../' 'gallery' "$($w.title): a poem and illustration made by local AI models and judged by Claude."))
    [void]$sb.Append("<main id=`"main`" class=`"piece`"$(Tint $w)>`n<article>`n")
    [void]$sb.Append("<figure class=`"art hero-art`"><span class=`"frame`"><img src=`"../img/$bn.webp`" width=`"$($d['full_w'])`" height=`"$($d['full_h'])`" alt=`"$(Esc $alt)`"></span></figure>`n")
    [void]$sb.Append("<div class=`"text`">`n<p class=`"eyebrow`">$(Esc $w.series) &middot; <time datetime=`"$(Esc $w.date)`">$(Esc $w.date)</time></p>`n<h1>$(Esc $w.title)</h1>`n")
    if ($w.theme -and ($w.theme -replace ' -> ', ', ').Trim() -ne $w.title.Trim()) { [void]$sb.Append("<p class=`"theme`">$(Esc ($w.theme -replace ' -> ', (' ' + [char]0x2192 + ' ')))</p>`n") }
    [void]$sb.Append("<div class=`"poem`">`n").Append((Poem-Html $w.poem)).Append("</div>`n</div>`n")
    [void]$sb.Append("<section class=`"method`" aria-labelledby=`"made-$bn`">`n<h2 id=`"made-$bn`">How this piece was made</h2>`n").Append((Credits-Html $w))
    [void]$sb.Append("<dl class=`"facts`">`n")
    if ($w.rounds) { [void]$sb.Append("<div><dt>Poem drafts</dt><dd>$(Esc $w.rounds)</dd></div>`n") }
    if ($w.score)  { [void]$sb.Append("<div><dt>Poem self-score</dt><dd>$(Esc $w.score)/10</dd></div>`n") }
    if ($w.art_rounds) { [void]$sb.Append("<div><dt>Image candidates</dt><dd>$(Esc $w.art_rounds)</dd></div>`n") }
    if ($w.art_score -and $w.art_score -ne '-1') { [void]$sb.Append("<div><dt>Judge&rsquo;s score</dt><dd>$(Esc $w.art_score)/10</dd></div>`n") }
    if ($w.art_tier) { [void]$sb.Append("<div class=`"wide`"><dt>Selection</dt><dd>$(Tier-Text $w)</dd></div>`n") }
    [void]$sb.Append("</dl>`n")
    if ($w.art_prompt) { [void]$sb.Append("<div class=`"prompt`"><h3>The image brief the local model wrote</h3><p>$(Esc $w.art_prompt)</p></div>`n") }
    [void]$sb.Append("</section>`n")
    if ($IncludeRoast -and $w.rest.Count -gt 0) {
        [void]$sb.Append("<section class=`"roast`">`n<h2>Roast and drafts</h2>`n<pre>").Append((Esc ($w.rest -join "`n"))).Append("</pre>`n</section>`n")
    }
    [void]$sb.Append("<nav class=`"pn`" aria-label=`"More works`">")
    if ($i -gt 0) { $n = $ordered[$i - 1]; [void]$sb.Append("<a rel=`"prev`" href=`"$($n.base_name).html`"><span>Newer</span>$(Esc $n.title)</a>") } else { [void]$sb.Append('<span></span>') }
    if ($i -lt $ordered.Count - 1) { $n = $ordered[$i + 1]; [void]$sb.Append("<a rel=`"next`" href=`"$($n.base_name).html`"><span>Older</span>$(Esc $n.title)</a>") }
    [void]$sb.Append("</nav>`n</article>`n</main>`n").Append((Page-Foot))
    Write-Text (Join-Path $Out "p\$bn.html") $sb.ToString()
}

# Current lineup = the newest work's credits.
$latest = if ($ordered.Count -gt 0) { $ordered[0] } else { $null }
$seriesCount = @($ordered | ForEach-Object { $_.series } | Select-Object -Unique).Count
$modelSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($w in $ordered) { foreach ($k in $w.credits.Keys) { if ($w.credits[$k].model) { [void]$modelSet.Add($w.credits[$k].model) } } }

# Index
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append((Page-Head $Script:SiteTitle '' 'gallery' 'A daily poem and illustration, written and drawn by local open-weight AI models and judged by Claude. An open experiment in machine creativity by c01corp.'))
[void]$sb.Append("<main id=`"main`">`n")
if (-not $latest) {
    [void]$sb.Append("<section class=`"intro`"><h1>An experiment in machine creativity</h1></section>`n<p class=`"empty`">No works have been published yet.</p>`n")
} else {
    $d = $dims[$latest.base_name]
    $excerpt = [System.Collections.Generic.List[string]]::new()
    foreach ($ln in $latest.poem) { if ($ln.Trim() -eq '' -and $excerpt.Count -gt 0) { break }; if ($ln.Trim() -ne '') { $excerpt.Add($ln) } }
    [void]$sb.Append("<section class=`"intro`">`n<p class=`"eyebrow`">An open experiment in machine creativity</p>`n<h1>Most days, a machine writes a poem, <em>draws it</em>, and another machine scores it, in public.</h1>`n<p class=`"lede`">Small open-weight models running on one home GPU write each poem and render its illustration. Claude, working inside our AI corporation, judges every image blind. Images are published as rendered, only resized and re-encoded for the web. Most pieces score 3 to 5 out of 10, and we publish them anyway. Each piece names the exact models that made it. <a href=`"experiment.html`">How the experiment works</a>.</p>`n</section>`n")
    [void]$sb.Append("<section class=`"today`"$(Tint $latest) aria-labelledby=`"latest-h`">`n<a class=`"today-art`" href=`"p/$($latest.base_name).html`"><span class=`"frame`"><img src=`"img/$($latest.base_name).webp`" width=`"$($d['full_w'])`" height=`"$($d['full_h'])`" alt=`"$(Esc ("Illustration for the poem: " + $latest.theme))`"></span></a>`n<div class=`"today-text`"><p class=`"eyebrow`">Latest &middot; $(Esc $latest.date)</p><h2 id=`"latest-h`"><a href=`"p/$($latest.base_name).html`">$(Esc $latest.title)</a></h2>`n<div class=`"poem`">").Append((Poem-Html $excerpt)).Append("</div>`n").Append((Credits-Html $latest)).Append("</div>`n</section>`n")
    [void]$sb.Append("<ul class=`"stats`" aria-label=`"The experiment in numbers`"><li><strong>$($ordered.Count)</strong><span>published works</span></li><li><strong>$seriesCount</strong><span>series so far</span></li><li><strong>$($modelSet.Count)</strong><span>models credited</span></li><li><strong>1</strong><span>home GPU</span></li></ul>`n")
    $seriesOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($w in $ordered) { if (-not $seriesOrder.Contains($w.series)) { $seriesOrder.Add($w.series) } }
    foreach ($s in $seriesOrder) {
        $inS = @($ordered | Where-Object { $_.series -eq $s })
        $span = "$($inS[-1].date) to $($inS[0].date)"
        [void]$sb.Append("<section class=`"series`">`n<div class=`"series-head`"><h2>$(Esc $s)</h2><p>$($inS.Count) works &middot; $(Esc $span)</p></div>`n<ul class=`"grid`">`n")
        foreach ($w in $inS) {
            $bn = $w.base_name; $d = $dims[$bn]
            $alt = if ($w.theme) { "Illustration for the poem: $($w.theme)" } else { "Illustration for the poem $($w.title)" }
            [void]$sb.Append("<li$(Tint $w)><a href=`"p/$bn.html`"><figure class=`"art`"><span class=`"frame`"><img src=`"img/$bn-t.webp`" width=`"$($d['thumb_w'])`" height=`"$($d['thumb_h'])`" alt=`"$(Esc $alt)`" loading=`"lazy`"></span><figcaption><span class=`"date`">$(Esc $w.date)</span><span class=`"t`">$(Esc $w.title)</span><span class=`"by`">$(Credit-Line $w)</span></figcaption></figure></a></li>`n")
        }
        [void]$sb.Append("</ul>`n</section>`n")
    }
}
[void]$sb.Append("</main>`n").Append((Page-Foot))
Write-Text (Join-Path $Out 'index.html') $sb.ToString()

# The experiment
function Last-Era([string]$role) { $e = @($Script:TL['roles'][$role]['eras']); if ($e.Count) { return (Pretty $e[-1]['model']) }; return '' }
$lineup = [ordered]@{ poem = @{ model = (Last-Era 'poem_writer') }; prompt = @{ model = (Last-Era 'prompt_writer') }; render = @{ model = (Last-Era 'renderer') }; judge = @{ model = (Last-Era 'judge_model') } }
function Lineup-Row([string]$k, [string]$label) {
    if ($lineup -and $lineup.Contains($k) -and $lineup[$k].model) { return "<li><span class=`"role`">$label</span><strong>$(Esc $lineup[$k].model)</strong></li>" }
    return ''
}
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append((Page-Head "The experiment - $Script:SiteTitle" '' 'experiment' 'How an AI corporation runs a daily poem and illustration experiment on local models, with Claude as the judge.'))
[void]$sb.Append(@"
<main id="main" class="prose">
<p class="eyebrow">The experiment</p>
<h1>Can small machines make something worth keeping, day after day?</h1>
<p class="lede">c01corp is a company run as a corporation of AI agents: departments with vice-presidents and staff, all of them Claude, working for one human founder. This gallery is one of its standing experiments. It asks what three small open-weight models can make on a single home graphics card, and what it takes to hold them to a standard.</p>

<h2>Today&rsquo;s lineup</h2>
<ul class="lineup">
$(Lineup-Row 'poem' 'Writes the poem')
$(Lineup-Row 'prompt' 'Writes the image brief')
$(Lineup-Row 'render' 'Draws the image')
$(Lineup-Row 'judge' 'Judges the image')
</ul>
<p class="note">Model names are trademarks of their owners, and this experiment is not affiliated with or endorsed by them. Every published piece lists the exact models that made it. A credit marked <span class="src rec">recorded</span> was written into the work&rsquo;s own record at the time. One marked <span class="src rcn">from pipeline history</span> predates that record and comes from the dated history on the <a href="evolution.html">Evolution</a> page.</p>

<h2>One day in the studio</h2>
<ol class="flow">
<li><span class="step">06:00</span><div><h3>A local model writes the poem</h3><p>The poem model gets the day&rsquo;s theme and writes a draft. A second pass of the same model then critiques the draft and scores it. The poem is rewritten up to five times, and the best-scoring draft is kept. No cloud model touches the words.</p></div></li>
<li><span class="step">08:00</span><div><h3>A local model writes the picture brief</h3><p>A second local model reads the poem and writes the image prompt. Claude is not allowed to write or rescue that prompt. If the brief is weak, the weak brief is the result.</p></div></li>
<li><span class="step">08:05</span><div><h3>The GPU draws candidates</h3><p>A local diffusion model renders several candidates on the same home graphics card. Each has no API cost and never leaves the machine.</p></div></li>
<li><span class="step">08:20</span><div><h3>Claude judges each one blind</h3><p>The corporation&rsquo;s art-critic agent scores every candidate on craft and on fit to the series style, from zero to ten. It checks each image at full resolution for defects. It cannot see the other candidates or earlier verdicts. An image that misses the poem&rsquo;s subject can never be chosen.</p></div></li>
<li><span class="step">08:30</span><div><h3>The best candidate is kept, with its real score</h3><p>A candidate that clears the bar is published as a pass. If none does, the best on-subject candidate is published and marked as best-of-N, with its real score. Some days the founder picks a different candidate, and that piece says so.</p></div></li>
</ol>

<h2>How the corporation chose the style</h2>
<p>The first series, <em>Memory Storage of a Modern System</em>, ran from 16 August to 6 September 2026. Each poem paired a mystical image with a real idea from physics, and each picture was a dense engraving in the manner of old architectural etchings. It produced some striking pieces. The founder retired it, and the corporation was asked to choose a new direction.</p>
<p>He handed the choice of what came next to the corporation. The CEO convened four departments: visual effects, marketing, product, and a psychology lens on how the work makes people feel. Their proposal went through four rounds of an adversarial critique panel before anything was built. The result is <em>First Light</em>, which began on 7 September.</p>
<p>In First Light, each poem starts with a small maker&rsquo;s spark on a workbench, such as a match, a solder joint or a kettle. It follows the same force up to something vast doing the same thing, and most days it comes back to the bench. The pictures are flat two-colour screen-prints. Six colour families rotate so that two days in a row never share a palette, and the accent colour marks only the things doing the poem&rsquo;s verb.</p>

<h2>What we are watching for</h2>
<ul class="watch">
<li><strong>Does a small model get better at a style?</strong> The judge&rsquo;s scores are published for every piece, and the <a href="evolution.html">Evolution</a> page charts them.</li>
<li><strong>What changes when a model changes?</strong> Every swap of a writer, renderer or judge is dated, so you can compare work across the boundary.</li>
<li><strong>Can the judge be trusted?</strong> Each founder&rsquo;s pick where he disagreed with the judge becomes a written rule. The judge is recalibrated against it.</li>
</ul>

<h2>The rules we hold ourselves to</h2>
<ul class="rules">
<li>The poem and the image are made by local open-weight models. Claude judges and orchestrates. It never writes the poem or the picture brief.</li>
<li>Scores are shown as the judge gave them. A piece that did not clear the bar says so.</li>
<li>Published images are re-encoded from pixels, so no generation metadata travels with them.</li>
</ul>
</main>
"@)
[void]$sb.Append((Page-Foot))
Write-Text (Join-Path $Out 'experiment.html') $sb.ToString()

# Evolution: model eras + a score chart.
$chrono = @($ordered); [array]::Reverse($chrono)
$pts = @(); $i = 0
foreach ($w in $chrono) {
    $v = $null; if ($w.art_score -and $w.art_score -ne '-1') { $v = [double]$w.art_score }
    $pts += @{ i = $i; v = $v; w = $w }; $i++
}
$W = 720; $Hh = 260; $L = 40; $R = 12; $T = 14; $B = 34
$n = [Math]::Max(1, $chrono.Count - 1)
$X = { param($k) [Math]::Round($L + ($W - $L - $R) * $k / $n, 1) }
$Y = { param($v) [Math]::Round($T + ($Hh - $T - $B) * (1 - $v / 10), 1) }
$svg = [System.Text.StringBuilder]::new()
[void]$svg.Append("<svg class=`"chart`" viewBox=`"0 0 $W $Hh`" role=`"img`" aria-labelledby=`"ch-t ch-d`"><title id=`"ch-t`">Judge&rsquo;s image score for every published work</title><desc id=`"ch-d`">Scores from 0 to 10 in date order. Founder picks without a score are shown as open circles at the baseline. The shaded band marks the First Light series.</desc>`n")
$fl = @($pts | Where-Object { $_.w.series -eq 'First Light' })
if ($fl.Count -gt 0) {
    $x0 = & $X ([Math]::Max(0, $fl[0].i - 0.5)); $x1 = & $X ([Math]::Min($n, $fl[-1].i + 0.5))
    [void]$svg.Append("<rect class=`"band`" x=`"$x0`" y=`"$T`" width=`"$([Math]::Round($x1 - $x0, 1))`" height=`"$($Hh - $T - $B)`"/><text class=`"lbl`" x=`"$($x0 + 6)`" y=`"$($T + 14)`">First Light</text>`n")
}
foreach ($g in 0, 5, 10) { $gy = & $Y $g; [void]$svg.Append("<line class=`"grid`" x1=`"$L`" x2=`"$($W - $R)`" y1=`"$gy`" y2=`"$gy`"/><text class=`"ax`" x=`"$($L - 8)`" y=`"$($gy + 4)`" text-anchor=`"end`">$g</text>`n") }
$path = @(); foreach ($p in $pts) { if ($null -ne $p.v) { $path += "$(& $X $p.i),$(& $Y $p.v)" } }
if ($path.Count -gt 1) { [void]$svg.Append("<polyline class=`"line`" points=`"$($path -join ' ')`"/>`n") }
foreach ($p in $pts) {
    $cx = & $X $p.i
    if ($null -ne $p.v) { [void]$svg.Append("<a href=`"p/$($p.w.base_name).html`"><circle class=`"dot`" cx=`"$cx`" cy=`"$(& $Y $p.v)`" r=`"4.5`"><title>$(Esc $p.w.date) $(Esc $p.w.title): $($p.v)/10</title></circle></a>") }
    else { [void]$svg.Append("<a href=`"p/$($p.w.base_name).html`"><circle class=`"dot open`" cx=`"$cx`" cy=`"$(& $Y 0)`" r=`"4.5`"><title>$(Esc $p.w.date) $(Esc $p.w.title): founder&rsquo;s pick, unscored</title></circle></a>") }
}
[void]$svg.Append("`n")
if ($chrono.Count -gt 0) { [void]$svg.Append("<text class=`"ax`" x=`"$L`" y=`"$($Hh - 10)`">$(Esc $chrono[0].date)</text><text class=`"ax`" x=`"$($W - $R)`" y=`"$($Hh - 10)`" text-anchor=`"end`">$(Esc $chrono[-1].date)</text>") }
[void]$svg.Append("</svg>")

$eraHtml = [System.Text.StringBuilder]::new()
foreach ($role in 'poem_writer', 'prompt_writer', 'renderer', 'judge_model') {
    $r = $Script:TL['roles'][$role]
    [void]$eraHtml.Append("<section class=`"era`"><h3>$(Esc $r['label'])</h3><ol>")
    foreach ($e in $r['eras']) {
        $when = if ($e.ContainsKey('from')) { $(if ($e.ContainsKey('bound') -and $e['bound'] -eq 'no-later-than') { 'By ' } else { 'From ' }) + ([string]$e['from']).Substring(0, 10) } else { Esc $e['series'] }
        $extra = if ($role -eq 'judge_model' -and $e['model'] -eq 'opus') { ' <span class="fine">Exact release not recorded</span>' } else { '' }
        [void]$eraHtml.Append("<li><span class=`"when`">$when</span><strong>$(Esc (Pretty $e['model']))</strong>$extra</li>")
    }
    [void]$eraHtml.Append("</ol></section>`n")
}

$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append((Page-Head "Evolution - $Script:SiteTitle" '' 'evolution' 'How the models, the style and the scores of the C01 poetry and illustration experiment have changed over time.'))
[void]$sb.Append("<main id=`"main`" class=`"prose wide`">`n<p class=`"eyebrow`">Evolution</p>`n<h1>Watch the experiment change</h1>`n<p class=`"lede`">Every model swap, style change and judge upgrade is dated here. Click any point to open that piece.</p>`n<figure class=`"chart-wrap`">$($svg.ToString())<figcaption>Judge&rsquo;s score, 0 to 10, for every published image. Open circles are founder&rsquo;s picks that were not scored.</figcaption></figure>`n<h2>Who held each role, and when</h2>`n<div class=`"eras`">`n$($eraHtml.ToString())</div>`n<h2>Milestones</h2>`n<ol class=`"milestones`">`n<li><time>2026-08-16</time>The seed poem, <em>An Infinity</em>, sets the first series&rsquo; formula.</li>`n<li><time>2026-08-17</time>Claude joins as the blind art judge.</li>`n<li><time>2026-08-20</time>An installer update removes the first local model. The pipeline moves to Qwen3.5 9B for poems and Qwen3 8B for image briefs.</li>`n<li><time>2026-09-03</time>By this date the judge has moved to Claude Fable 5.1.</li>`n<li><time>2026-09-06</time>The founder retires the etching series, and the corporation is asked to choose what comes next.</li>`n<li><time>2026-09-07</time><em>First Light</em> begins. The renderer changes from Stable Diffusion XL to FLUX.1 [schnell].</li>`n<li><time>2026-09-25</time>The judge moves to Claude Opus 5.5.</li>`n<li><time>2026-09-26</time>Each new work starts recording its own models at the moment it is accepted.</li>`n</ol>`n</main>`n")
[void]$sb.Append((Page-Foot))
Write-Text (Join-Path $Out 'evolution.html') $sb.ToString()

# Comparisons: an index page plus one page per round. Open rounds are blind; closed rounds reveal.
$Script:Framing = 'One brief, two renderers. Informal, one sample each.'
$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append((Page-Head "Compare - $Script:SiteTitle" '' 'compare' 'One brief, two renderers: unlabelled side-by-side illustrations of the same poem.'))
[void]$sb.Append("<main id=`"main`" class=`"prose`">`n<p class=`"eyebrow`">Compare</p>`n<h1>Which picture fits the poem?</h1>`n<p class=`"lede`">$Script:Framing Each round shows the same brief drawn twice, unlabelled. Which renderer made which image is revealed after the round closes.</p>`n")
if ($roundKeys.Count -eq 0) {
    [void]$sb.Append("<p class=`"empty`">No comparison rounds yet. When one opens, it will appear here.</p>`n")
} else {
    [void]$sb.Append("<ul class=`"rounds`">`n")
    foreach ($rid in $roundKeys) {
        $r = $rounds[$rid]
        $state = if ($r.open) { "open until $(Esc $r.closes)" } else { "closed $(Esc $r.closes), renderers revealed" }
        [void]$sb.Append("<li><a href=`"c/$rid.html`">Round $(Esc $rid)</a><span>$($r.pairs.Count) $(if ($r.pairs.Count -eq 1) { 'poem' } else { 'poems' }) &middot; $state</span></li>`n")
    }
    [void]$sb.Append("</ul>`n")
}
[void]$sb.Append("</main>`n").Append((Page-Foot-Neutral))
Write-Text (Join-Path $Out 'comparisons.html') $sb.ToString()

foreach ($rid in $roundKeys) {
    $r = $rounds[$rid]
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append((Page-Head "Round $rid - $Script:SiteTitle" '../' 'compare' 'One brief, two renderers: an unlabelled side-by-side comparison round.'))
    [void]$sb.Append("<main id=`"main`" class=`"cmp`">`n<p class=`"eyebrow`">Compare &middot; Round $(Esc $rid)</p>`n<h1>One brief, two renderers</h1>`n<p class=`"lede`">$Script:Framing</p>`n")
    if ($r.open) {
        [void]$sb.Append("<p class=`"status`">This round is open until $(Esc $r.closes). Which renderer made which image is revealed after it closes.</p>`n")
        if ($r.vote_url) { [void]$sb.Append("<p class=`"vote`"><a href=`"$(Esc $r.vote_url)`" rel=`"noopener`">Vote for the image that fits each poem better</a></p>`n") }
        else             { [void]$sb.Append("<p class=`"vote`">Voting opens soon.</p>`n") }
    } else {
        [void]$sb.Append("<p class=`"status`">This round closed on $(Esc $r.closes). The renderers are revealed below.</p>`n")
    }
    $n = 0
    foreach ($pr in $r.pairs) {
        $n++; $w = $pr.work; $d = $cmpDims[$pr.hash]
        [void]$sb.Append("<section class=`"pair`" aria-labelledby=`"pr-$n`">`n<h2 id=`"pr-$n`">$(Esc $w.title)</h2>`n<div class=`"duo`">")
        foreach ($side in 'a', 'b') {
            $isLocal = (($side -eq 'a') -eq $pr.local_is_a)
            $L = $side.ToUpperInvariant()
            [void]$sb.Append("<figure class=`"art`"><span class=`"frame`"><img src=`"../cmp/$($pr.hash)-$side.webp`" width=`"$($d['w'])`" height=`"$($d['h'])`" alt=`"$(Esc "Image $L for the poem $($w.title)")`"></span><figcaption><span class=`"t`">Image $L</span>")
            if (-not $r.open) {
                if ($isLocal) {
                    $rm = if ($w.credits.Contains('render') -and $w.credits['render'].model) { $w.credits['render'].model } else { 'a local diffusion model' }
                    [void]$sb.Append("<span class=`"by`">Rendered locally by $(Esc $rm) on one home GPU. Dedicated to the public domain (CC0 1.0), like the rest of this site.</span>")
                } else {
                    [void]$sb.Append("<span class=`"by`">Generated by $(Esc $pr.model), $(Esc $pr.generated_on), via ChatGPT; not covered by this site's CC0 dedication. <a href=`"../cmp/orig/$($pr.hash)-original$($pr.ext)`">Original file, with its content credentials</a>.</span>")
                }
            }
            [void]$sb.Append("</figcaption></figure>")
        }
        [void]$sb.Append("</div>`n<div class=`"poem`">").Append((Poem-Html $w.poem)).Append("</div>`n")
        [void]$sb.Append("<div class=`"prompt`"><h3>The brief both renderers were given</h3><p>$(Esc $w.art_prompt)</p></div>`n</section>`n")
    }
    [void]$sb.Append("<p class=`"note`">Both images were re-encoded the same way for this page: same size, same format, metadata removed. The second renderer's image was centre-cropped to the shape of the local image.</p>`n")
    [void]$sb.Append("<p><a href=`"../comparisons.html`">All rounds</a></p>`n</main>`n").Append((Page-Foot-Neutral))
    Write-Text (Join-Path $Out "c\$rid.html") $sb.ToString()
}

# CSS -- rem units, no fixed pixel widths, grids collapse by content, dark by default.
$css = @'
:root{color-scheme:dark light;--bg:#0d0c0b;--panel:#171513;--fg:#efe9dd;--mute:#a59e90;--line:#2c2925;--gold:#e8b24c;--f:#1f1d1a;--a:#e8b24c;--serif:"Iowan Old Style","Palatino Linotype",Palatino,Georgia,serif;--sans:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
@media (prefers-color-scheme:light){:root{--bg:#f5f1e8;--panel:#ebe5d8;--fg:#1a1815;--mute:#5f594f;--line:#d6cfc0;--gold:#9a6a10}}
*{box-sizing:border-box}
html{font-size:100%}
body{margin:0;font:1.0625rem/1.6 var(--serif);color:var(--fg);background:var(--bg);overflow-wrap:anywhere}
a{color:var(--gold)}
a:focus-visible{outline:3px solid var(--gold);outline-offset:3px;border-radius:2px}
.skip{position:absolute;left:-999rem;top:0}
.skip:focus{left:1rem;top:1rem;background:var(--bg);color:var(--fg);padding:.5rem 1rem;z-index:2}
.bar{position:sticky;top:0;z-index:1;display:flex;flex-wrap:wrap;gap:.5rem 1.5rem;align-items:center;justify-content:space-between;padding:.85rem clamp(1rem,4vw,2.5rem);background:color-mix(in srgb,var(--bg) 88%,transparent);backdrop-filter:blur(10px);border-bottom:1px solid var(--line);font-family:var(--sans)}
.mark{color:var(--fg);text-decoration:none;font-weight:700;letter-spacing:.02em}
.mark em{font-style:normal;font-weight:400;color:var(--mute)}
.mark .glyph{color:var(--gold)}
.bar nav{display:flex;flex-wrap:wrap;gap:.25rem 1.25rem;font-size:.9rem}
.bar nav a{color:var(--mute);text-decoration:none;padding:.25rem 0;border-bottom:2px solid transparent}
.bar nav a:hover,.bar nav a[aria-current]{color:var(--fg);border-bottom-color:var(--gold)}
main{max-width:76rem;margin:0 auto;padding:clamp(1.25rem,4vw,3rem) clamp(1rem,4vw,2.5rem)}
h1,h2,h3{line-height:1.15;font-weight:600;letter-spacing:-.01em}
h1{font-size:clamp(1.9rem,1.2rem + 3vw,3.4rem);margin:.25rem 0 1rem}
h1 em{color:var(--gold)}
h2{font-size:clamp(1.3rem,1rem + 1.2vw,1.9rem);margin:3rem 0 1rem}
h3{font-size:1.1rem;margin:0 0 .35rem}
.eyebrow{font-family:var(--sans);text-transform:uppercase;letter-spacing:.14em;font-size:.75rem;color:var(--gold);margin:0}
.lede{font-size:clamp(1.05rem,1rem + .4vw,1.3rem);color:var(--mute);max-width:46rem}
.intro{max-width:56rem;margin-bottom:2.5rem}
figure{margin:0}
.frame{display:block;background:var(--f);aspect-ratio:1/1;min-height:4rem;overflow:hidden;color:#ddd}
img{display:block;width:100%;height:auto;max-width:100%}
.today{display:grid;gap:clamp(1.25rem,3vw,3rem);grid-template-columns:repeat(auto-fit,minmax(min(100%,22rem),1fr));align-items:start;padding:clamp(1rem,2.5vw,2rem);background:linear-gradient(135deg,color-mix(in srgb,var(--f) 55%,var(--panel)),var(--panel));border:1px solid var(--line);border-radius:1rem}
.today-art .frame{border-radius:.6rem;box-shadow:0 1.5rem 3rem -1rem rgba(0,0,0,.6),0 0 0 1px color-mix(in srgb,var(--a) 35%,transparent)}
.today h2{margin:.35rem 0 1rem}
.today h2 a{color:var(--fg);text-decoration:none}
.today h2 a:hover{color:var(--a)}
.poem p{white-space:pre-line;margin:0 0 1.2rem;font-size:1.12rem;line-height:1.7}
.credits{list-style:none;margin:1.25rem 0 0;padding:0;display:grid;gap:.6rem;font-family:var(--sans)}
.credits li{display:grid;grid-template-columns:auto minmax(0,1fr);gap:.9rem;align-items:start;padding:.75rem .9rem;background:color-mix(in srgb,var(--bg) 55%,transparent);border:1px solid var(--line);border-radius:.6rem}
.credits .step{font-variant-numeric:tabular-nums;color:var(--a);font-weight:700;font-size:.85rem;padding-top:.1rem}
.credits .role{display:block;font-size:.72rem;letter-spacing:.1em;text-transform:uppercase;color:var(--mute)}
.credits strong{font-size:1rem}
.credits p{margin:.2rem 0 0;font-size:.85rem;color:var(--mute);line-height:1.45}
.src{display:inline-block;font:600 .66rem/1 var(--sans);letter-spacing:.06em;text-transform:uppercase;padding:.28rem .45rem;border-radius:99rem;vertical-align:.12rem;margin-left:.35rem;border:1px solid}
.src.rec{color:#7fd6a0;border-color:#2f6b47}
.src.rcn{color:#d9b56a;border-color:#6b5a2f}
@media (prefers-color-scheme:light){.src.rec{color:#1d6b3d;border-color:#8cc3a1}.src.rcn{color:#7a5a12;border-color:#d2b77a}}
.stats{list-style:none;padding:0;margin:2.5rem 0 0;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,10rem),1fr));gap:1px;background:var(--line);border:1px solid var(--line);border-radius:.8rem;overflow:hidden}
.stats li{background:var(--bg);padding:1.1rem 1.25rem;font-family:var(--sans)}
.stats strong{display:block;font:600 clamp(1.8rem,1.4rem + 1.5vw,2.6rem)/1 var(--serif);color:var(--gold)}
.stats span{font-size:.85rem;color:var(--mute)}
.series-head{display:flex;flex-wrap:wrap;align-items:baseline;justify-content:space-between;gap:.25rem 1rem;border-bottom:1px solid var(--line);margin:3.5rem 0 1.25rem;padding-bottom:.6rem}
.series-head h2{margin:0}
.series-head p{margin:0;color:var(--mute);font-family:var(--sans);font-size:.85rem}
.grid{list-style:none;margin:0;padding:0;display:grid;gap:clamp(1rem,2vw,1.75rem);grid-template-columns:repeat(auto-fill,minmax(min(100%,15rem),1fr))}
.grid a{color:inherit;text-decoration:none;display:block}
.grid .frame{border-radius:.5rem;transition:transform .35s ease,box-shadow .35s ease}
.grid a:hover .frame,.grid a:focus-visible .frame{transform:translateY(-4px);box-shadow:0 1rem 2rem -1rem rgba(0,0,0,.7),0 0 0 2px var(--a)}
figcaption{padding:.65rem 0 0;display:grid;gap:.15rem}
figcaption .date{font:500 .75rem var(--sans);color:var(--mute);font-variant-numeric:tabular-nums}
figcaption .t{font-size:1rem;line-height:1.3}
figcaption .by{font:.72rem/1.4 var(--sans);color:var(--mute)}
@media (prefers-reduced-motion:reduce){.grid .frame{transition:none}.grid a:hover .frame{transform:none}}
.piece article{display:grid;gap:clamp(1.25rem,3vw,3rem);grid-template-columns:repeat(auto-fit,minmax(min(100%,24rem),1fr));align-items:start}
.piece .hero-art .frame{border-radius:.8rem;box-shadow:0 2rem 4rem -1.5rem rgba(0,0,0,.7),0 0 0 1px color-mix(in srgb,var(--a) 40%,transparent)}
.piece .theme{font-family:var(--sans);font-size:.9rem;color:var(--mute);margin:0 0 1.5rem}
.piece .method,.piece .pn,.piece .roast{grid-column:1/-1}
.method{border-top:1px solid var(--line);padding-top:1rem}
.method h2{margin-top:.5rem}
.method .credits{grid-template-columns:repeat(auto-fit,minmax(min(100%,16rem),1fr))}
.facts{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,11rem),1fr));gap:.75rem;margin:1.25rem 0 0;font-family:var(--sans)}
.facts div{padding:.7rem .9rem;border:1px solid var(--line);border-radius:.6rem}
.facts .wide{grid-column:1/-1}
.facts dt{font-size:.72rem;letter-spacing:.1em;text-transform:uppercase;color:var(--mute)}
.facts dd{margin:.15rem 0 0}
div.prompt{margin-top:1.25rem;font-family:var(--sans);font-size:.9rem;color:var(--mute);border:1px solid var(--line);border-radius:.6rem;padding:.75rem .9rem}
div.prompt h3{color:var(--fg);font-size:.8rem;letter-spacing:.08em;text-transform:uppercase}
.pn{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,14rem),1fr));gap:1rem;border-top:1px solid var(--line);padding-top:1.25rem}
.pn a{display:grid;text-decoration:none;color:var(--fg)}
.pn a[rel=next]{text-align:end}
.pn span{font:.72rem var(--sans);letter-spacing:.1em;text-transform:uppercase;color:var(--gold)}
.prose{max-width:50rem}
.prose.wide{max-width:64rem}
.lineup{list-style:none;padding:0;margin:0;display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,11rem),1fr));gap:.75rem;font-family:var(--sans)}
.lineup li{padding:1rem;border:1px solid var(--line);border-radius:.7rem;background:var(--panel)}
.lineup .role{display:block;font-size:.72rem;letter-spacing:.1em;text-transform:uppercase;color:var(--mute);margin-bottom:.3rem}
.note{font-size:.95rem;color:var(--mute)}
.flow{list-style:none;padding:0;margin:0;display:grid;gap:1rem}
.flow li{display:grid;grid-template-columns:minmax(3.5rem,auto) minmax(0,1fr);gap:1rem;padding:1rem 1.1rem;border-left:3px solid var(--gold);background:var(--panel);border-radius:0 .6rem .6rem 0}
.flow .step{font:600 .85rem var(--sans);color:var(--gold);font-variant-numeric:tabular-nums;padding-top:.15rem}
.flow p{margin:0;color:var(--mute)}
.watch,.rules{padding-left:1.25rem}
.watch li,.rules li{margin:.5rem 0}
.chart-wrap{margin:2rem 0;padding:1rem;border:1px solid var(--line);border-radius:.8rem;background:var(--panel)}
.chart{width:100%;height:auto;display:block;font-family:var(--sans)}
.chart .band{fill:var(--gold);opacity:.08}
.chart .lbl{fill:var(--gold);font-size:12px}
.chart .grid{stroke:var(--line);stroke-width:1}
.chart .ax{fill:var(--mute);font-size:11px}
.chart .line{fill:none;stroke:var(--gold);stroke-width:2;stroke-linejoin:round;opacity:.85}
.chart .dot{fill:var(--gold);stroke:var(--bg);stroke-width:2}
.chart .dot.open{fill:var(--bg);stroke:var(--gold)}
.chart-wrap figcaption{font:.85rem var(--sans);color:var(--mute)}
.eras{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,14rem),1fr));gap:1rem}
.era{padding:1rem;border:1px solid var(--line);border-radius:.7rem;font-family:var(--sans)}
.era h3{font-size:.75rem;letter-spacing:.1em;text-transform:uppercase;color:var(--mute)}
.era ol{list-style:none;margin:0;padding:0;display:grid;gap:.6rem}
.era .when{display:block;font-size:.75rem;color:var(--gold)}
.fine{display:block;font-size:.72rem;color:var(--mute)}
.milestones{list-style:none;padding:0;margin:0;border-left:2px solid var(--line)}
.milestones li{position:relative;padding:.1rem 0 1.1rem 1.25rem}
.milestones li::before{content:"";position:absolute;left:-.4rem;top:.45rem;width:.7rem;height:.7rem;border-radius:50%;background:var(--gold)}
.milestones time{display:block;font:600 .8rem var(--sans);color:var(--gold)}
.empty{padding:3rem 1rem;text-align:center;color:var(--mute)}
.rounds{list-style:none;padding:0;margin:1.5rem 0;display:grid;gap:.75rem;font-family:var(--sans)}
.rounds li{display:grid;gap:.2rem;padding:1rem;border:1px solid var(--line);border-radius:.7rem;background:var(--panel)}
.rounds span{font-size:.85rem;color:var(--mute)}
.cmp .status,.cmp .vote{font-family:var(--sans)}
.cmp .vote{font-size:1.05rem}
.pair{margin:2.5rem 0;padding-top:1rem;border-top:1px solid var(--line)}
.duo{list-style:none;display:grid;gap:clamp(1rem,2vw,1.75rem);grid-template-columns:repeat(auto-fit,minmax(min(100%,18rem),1fr));margin-bottom:1.5rem}
.duo .frame{border-radius:.6rem}
.duo figcaption .t{font-family:var(--sans);font-weight:600}
.roast pre{white-space:pre-wrap;overflow-wrap:anywhere;font-size:.85rem}
.piece h1{font-size:clamp(1.6rem,1rem + 2vw,2.5rem)}
h1,h2,h3,figcaption .t{text-wrap:balance}
figcaption .t{display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.frame{background:radial-gradient(120% 90% at 30% 20%,color-mix(in srgb,var(--gold) 10%,var(--f)),var(--f));box-shadow:inset 0 0 0 1px color-mix(in srgb,var(--fg) 6%,transparent)}
.frame img{height:100%;object-fit:cover}
body{background:radial-gradient(60rem 40rem at 15% -10%,color-mix(in srgb,var(--gold) 9%,transparent),transparent 70%),var(--bg);background-attachment:fixed}
.pn a{padding:1rem 1.25rem;border:1px solid var(--line);border-radius:.8rem;background:var(--panel);transition:border-color .25s}
.pn a:hover,.pn a:focus-visible{border-color:var(--gold)}
.stats li{background:linear-gradient(180deg,var(--panel),var(--bg))}
.series-head{border-bottom:0;background:linear-gradient(90deg,var(--gold),transparent) bottom/100% 1px no-repeat}
.series-head h2::before{content:"\2726  ";color:var(--gold);font-size:.7em;vertical-align:.15em}
footer p{margin:.25rem 0}
footer{max-width:76rem;margin:3rem auto 0;padding:1.5rem clamp(1rem,4vw,2.5rem) 2.5rem;border-top:1px solid var(--line);color:var(--mute);font:.85rem/1.5 var(--sans)}
'@
Write-Text (Join-Path $Out 'style.css') $css

# robots.txt: private-preview posture until the canonical URL is settled (design gate item 9).
Write-Text (Join-Path $Out 'robots.txt') "User-agent: *`nDisallow: /`n"

Log "DONE   works=$($ordered.Count) out=$Out"
Flush-Log
exit 0
