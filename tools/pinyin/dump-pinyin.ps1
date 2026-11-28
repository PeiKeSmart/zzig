# Dump preferred pinyin of CJK Unified Ideographs (U+4E00..U+9FA5) via EzPinyin
# (local NuGet cache, BSD-3.0) to a text file, then generate the Zig table with
# `tools/gen-pinyin-data.py`.
#
# Why a NuGet DLL: the data must come from somewhere authoritative and reproducible.
# EzPinyin is the same library the C# site (`GongJu/PinYinController`) uses, so the
# Zig port matches the C# behaviour for single characters. Its BSD-3.0 licence text is
# embedded verbatim in the generated `src/text/pinyin_data.zig` header (licence condition 1/2).
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 as ANSI unless the
# file has a UTF-8 BOM, which turns Chinese comments into parser errors.
$ErrorActionPreference = 'Continue'

$dll = Join-Path $env:USERPROFILE '.nuget\packages\ezpinyin\1.1.2\lib\netstandard2.0\EzPinyin.dll'
if (-not (Test-Path $dll)) {
    throw "EzPinyin.dll not found: $dll (restore the GongJu project first: dotnet restore src\GongJu)"
}
Add-Type -Path $dll

$start = 0x4E00
$end = 0x9FA5
$sb = New-Object System.Text.StringBuilder
for ($i = $start; $i -le $end; $i++) { [void]$sb.Append([char]$i) }
$chars = $sb.ToString()

$sw = [Diagnostics.Stopwatch]::StartNew()
$arr = [EzPinyin.PinyinHelper]::GetArray($chars)
$sw.Stop()
if ($arr.Length -ne $chars.Length) { throw "length mismatch $($arr.Length) vs $($chars.Length)" }

$out = New-Object System.Text.StringBuilder
for ($i = 0; $i -lt $arr.Length; $i++) {
    $code = $start + $i
    # Single-quoted strings do NOT expand `t / `n; build separators from chars.
    [void]$out.Append(('{0:X4}' -f $code) + [char]9 + $arr[$i] + [char]10)
}

$target = Join-Path $PSScriptRoot 'pinyin_raw.txt'
[IO.File]::WriteAllText($target, $out.ToString(), (New-Object System.Text.UTF8Encoding($false)))

$distinct = ($arr | Where-Object { $_ -match '^[a-z]+$' } | Sort-Object -Unique)
$maxLen = ($distinct | Measure-Object -Property Length -Maximum).Maximum
"elapsed=$([math]::Round($sw.Elapsed.TotalSeconds,2))s chars=$($arr.Length) distinct=$($distinct.Count) maxlen=$maxLen"
"dumped=$target"
"next: python tools/gen-pinyin-data.py"
