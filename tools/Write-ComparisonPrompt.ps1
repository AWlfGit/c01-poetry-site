#Requires -Version 7.0
<#
.SYNOPSIS
  Write <Source>\comparisons\prompts\<base_name>.txt holding exactly the local image brief of one
  accepted work, ready to paste into ChatGPT for a comparison round.

.DESCRIPTION
  Phase 2 pilot (BOARDLOG-2026-10-01-POETRY-FULL-PROJECT). The brief is the `image_prompt` field of
  the work's accepted art-runs record, copied byte for byte: UTF-8 without BOM, no trailing newline,
  nothing added. This script makes no network call and schedules nothing. A person pastes the file
  into ChatGPT by hand, when they choose to run a batch.

.PARAMETER Source    Corpus root. Defaults to the C01POETRY_SOURCE environment variable.
.PARAMETER BaseName  base_name of an accepted work (an art-runs record with accepted_at).

.OUTPUTS  Exit 0 and the written path on success. Exit 1 if the work is not accepted or has no brief.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaseName,
    [string]$Source = $env:C01POETRY_SOURCE
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ComparisonCommon.ps1')

if ([string]::IsNullOrWhiteSpace($Source)) { Write-Host 'ERROR -Source not given and C01POETRY_SOURCE is not set'; exit 1 }
$rec = Find-AcceptedRecord -Source $Source -BaseName $BaseName
if (-not $rec) { Write-Host "ERROR no accepted art-runs record has base_name '$BaseName'"; exit 1 }
$brief = if ($rec.ContainsKey('image_prompt') -and $rec['image_prompt'] -is [string]) { $rec['image_prompt'] } else { '' }
if ([string]::IsNullOrWhiteSpace($brief)) { Write-Host "ERROR accepted record for '$BaseName' has no image_prompt"; exit 1 }

$dir = Join-Path (Join-Path $Source 'comparisons') 'prompts'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$out = Join-Path $dir "$BaseName.txt"
[System.IO.File]::WriteAllText($out, $brief, [System.Text.UTF8Encoding]::new($false))
Write-Host "WROTE comparisons\prompts\$BaseName.txt chars=$($brief.Length)"
exit 0
