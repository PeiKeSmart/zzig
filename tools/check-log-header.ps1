# Verify the zzig log file header matches DH.NCore `Logger.WriteHead` field-by-field.
# Exit 0 = every required field present AND the body line matches the declared columns.
# Pure ASCII source; log file is read as UTF-8.
param(
    [string]$Root = 'E:\Code\Zig\zzig'
)

$ErrorActionPreference = 'Stop'
Set-Location $Root

$zig = 'E:\Soft\zig-x86_64-windows-0.17.1\zig.exe'
if (-not (Test-Path $zig)) { Write-Host "FAIL: zig not found: $zig"; exit 1 }

Remove-Item -Recurse -Force 'LogCheck' -ErrorAction SilentlyContinue

& $zig run --dep zzig '-Mroot=tools/log_header_dump.zig' '-Mzzig=src/zzig.zig' 2>&1 | Out-String | Write-Host
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL: dump exited $LASTEXITCODE"; exit 1 }

$files = Get-ChildItem 'LogCheck' -Filter '*.log' -ErrorAction SilentlyContinue
if (-not $files) { Write-Host "FAIL: no log file produced in LogCheck/"; exit 1 }

$lines = [IO.File]::ReadAllLines($files[0].FullName, [Text.Encoding]::UTF8)

# 与 C# NewLife.Log.Logger.WriteHead 对齐的必现字段
$required = @(
    '#Software: ', '#ProcessID: ', '#AppDomain: ', '#ApplicationType: ',
    '#CLR: ', '#OS: ', '#CPU: ', '#Date: ',
    '#详解：', '#字段: ', '#Fields: '
)
# 依赖平台/宿主、可缺席（缺席不算错，出现则必须非空）
$optional = @('#FileName: ', '#BaseDirectory: ', '#CurrentDirectory: ', '#TempPath: ', '#SystemStarted: ')

$missing = @()
foreach ($f in $required) {
    $hit = $lines | Where-Object { $_.StartsWith($f) } | Select-Object -First 1
    if (-not $hit) { $missing += $f }
    elseif ($hit.Trim() -eq $f.Trim()) { Write-Host ("WARN: field present but empty: {0}" -f $f) }
}

# `#Date` 必须是 yyyy-MM-dd（C# 格式），不是文件名的 yyyy_MM_dd
$dateLine = $lines | Where-Object { $_.StartsWith('#Date: ') } | Select-Object -First 1
if ($dateLine -and ($dateLine.Trim() -notmatch '^#Date: \d{4}-\d{2}-\d{2}$')) {
    Write-Host ("FAIL: #Date format wrong (expect yyyy-MM-dd): {0}" -f $dateLine)
    exit 1
}

# `#Fields` 必须与配置的 LogLineFormat 一致（这里是 DateTime ThreadId Kind Name Message Level）
$fieldsLine = $lines | Where-Object { $_.StartsWith('#Fields: ') } | Select-Object -First 1
if ($fieldsLine -and ($fieldsLine.Trim() -ne '#Fields: DateTime ThreadId Kind Name Message Level')) {
    Write-Host ("FAIL: #Fields mismatch: {0}" -f $fieldsLine)
    exit 1
}

# 正文行：必须是完整日期时间 + 数字 ThreadId + N/Y + Name + [Level]
$body = $lines | Where-Object { $_ -match 'header check' } | Select-Object -First 1
if (-not $body) { Write-Host "FAIL: body line missing"; exit 1 }
if ($body -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \d+ [NY] \S+ \[(Info|Debug|Warn|Error|Fatal)\] ') {
    Write-Host ("FAIL: body line shape unexpected: {0}" -f $body)
    exit 1
}

if ($missing.Count -gt 0) {
    Write-Host ("FAIL: missing required header fields: {0}" -f ($missing -join ', '))
    exit 1
}

Write-Host "PASS: log header matches DH.NCore WriteHead ($($required.Count) required fields; $($optional.Count) optional)"
Write-Host "---- actual header ----"
$lines | Select-Object -First 20 | ForEach-Object { Write-Host $_ }
exit 0
