# Verify candidate phrases with EzPinyin (the SAME library the C# site uses).
#
# Input : tools/pinyin/pinyin_candidates.txt   (one word per line, from gen-pinyin-candidates.py)
# Output: tools/pinyin/pinyin_phrases_checked.txt  (<word>\t<pinyin syllables space separated>)
#
# Why batch: `GetPinyin` keeps separators as-is ("重庆|银行" -> "chong qing|yin hang"),
# so 40k+ phrases need only a few dozen calls instead of one per word.
#
# NOTE: keep this file ASCII-only (PowerShell 5.1 reads .ps1 as ANSI without a BOM).
$ErrorActionPreference = 'Continue'

$dll = Join-Path $env:USERPROFILE '.nuget\packages\ezpinyin\1.1.2\lib\netstandard2.0\EzPinyin.dll'
if (-not (Test-Path $dll)) {
    throw "EzPinyin.dll not found: $dll (restore the GongJu project first: dotnet restore src\GongJu)"
}
Add-Type -Path $dll

$inPath = Join-Path $PSScriptRoot 'pinyin_candidates.txt'
$outPath = Join-Path $PSScriptRoot 'pinyin_phrases_checked.txt'
if (-not (Test-Path $inPath)) { throw "missing $inPath (run: python tools/gen-pinyin-candidates.py)" }

$words = [IO.File]::ReadAllLines($inPath, [Text.Encoding]::UTF8) | Where-Object { $_.Trim().Length -gt 0 }
"candidates=$($words.Count)"

$sb = New-Object System.Text.StringBuilder
$batch = 1500
$done = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $words.Count; $i += $batch) {
    $end = [Math]::Min($i + $batch, $words.Count)
    $chunk = $words[$i..($end - 1)]
    $joined = ($chunk -join '|')
    $py = [EzPinyin.PinyinHelper]::GetPinyin($joined)
    $parts = $py.Split([char]'|')
    if ($parts.Length -ne $chunk.Length) {
        throw "split mismatch at batch $i : parts=$($parts.Length) words=$($chunk.Length)"
    }
    for ($k = 0; $k -lt $chunk.Length; $k++) {
        $p = ($parts[$k].Trim() -replace '\s+', ' ')
        if ($p.Length -gt 0 -and $p -match '^[a-z ]+$') {
            [void]$sb.Append($chunk[$k] + [char]9 + $p + [char]10)
        }
        $done++
    }
    if (($i % 15000) -eq 0) { "  ..$done / $($words.Count)" }
}
$sw.Stop()

[IO.File]::WriteAllText($outPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
"checked=$done elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,1))s"
"out=$outPath"
