# Dump EzPinyin's lexicon (multi-character phrases WITH disambiguation) to a text file.
#
# Why: `PinyinHelper.GetPinyin` already resolves polyphones inside words
# ("重庆" -> chong qing) using an internal lexicon. The Zig port only had the
# single-character table, so it produced "zhong qing". This dumps the same
# lexicon the C# site uses, so the Zig side can match it byte for byte.
#
# Output: tools/pinyin/pinyin_phrases_raw.txt  (one line per phrase:  <word>\t<pinyin syllables space separated>)
# Then:   python tools/gen-pinyin-phrases.py
#
# NOTE: keep this file ASCII-only (Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM).
$ErrorActionPreference = 'Continue'

$dll = Join-Path $env:USERPROFILE '.nuget\packages\ezpinyin\1.1.2\lib\netstandard2.0\EzPinyin.dll'
if (-not (Test-Path $dll)) {
    throw "EzPinyin.dll not found: $dll (restore the GongJu project first: dotnet restore src\GongJu)"
}
$asm = [System.Reflection.Assembly]::LoadFrom($dll)

# Force the lexicon to load (lazy static init happens on first use).
[void][EzPinyin.PinyinHelper]::GetPinyin('重庆')

$flags = [System.Reflection.BindingFlags]'Public,NonPublic,Static'
$loader = $asm.GetType('EzPinyin.LexiconLoader')

$seen = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$chains = 0
$nodes = 0

foreach ($fname in @('basic2', 'basic3', 'basic4', 'basicX')) {
    $f = $loader.GetField($fname, $flags)
    if ($null -eq $f) { continue }
    $head = $f.GetValue($null)
    $guard = 0
    while ($null -ne $head) {
        $chains++
        $node = $head
        while ($null -ne $node) {
            $nodes++
            $t = $node.GetType()
            $word = $t.GetField('Word', [System.Reflection.BindingFlags]'Public,NonPublic,Instance').GetValue($node)
            if ($word -and -not $seen.ContainsKey($word)) {
                # pinyin0..N are declared on the concrete node type (LinkNode2/3/4) or as string[] on LinkNodeX.
                $arrField = $t.GetField('pinyin', [System.Reflection.BindingFlags]'Public,NonPublic,Instance')
                $syllables = $null
                if ($arrField) {
                    $syllables = ($arrField.GetValue($node) -join ' ')
                } else {
                    $parts = New-Object System.Collections.Generic.List[string]
                    for ($i = 0; $i -lt 8; $i++) {
                        $pf = $t.GetField(('pinyin' + $i), [System.Reflection.BindingFlags]'Public,NonPublic,Instance')
                        if (-not $pf) { break }
                        $pv = $pf.GetValue($node)
                        if ($null -eq $pv) { break }
                        $parts.Add($pv)
                    }
                    $syllables = ($parts -join ' ')
                }
                if ($syllables -and $syllables.Length -gt 0) {
                    $seen[$word] = $syllables
                }
            }
            $node = $t.GetField('Next', [System.Reflection.BindingFlags]'Public,NonPublic,Instance').GetValue($node)
            if (($nodes % 200000) -eq 0) { Write-Output ("  ..$nodes nodes, $($seen.Count) words") }
        }
        $head = $head.GetType().GetField('Next', [System.Reflection.BindingFlags]'Public,NonPublic,Instance').GetValue($head)
        # The outer loop above already walked Next; re-reading it here would double-walk.
        # basicN 字段本身就是链表头，内层已走完 -> 直接结束该字段。
        break
    }
}

$out = New-Object System.Text.StringBuilder
foreach ($kv in $seen.GetEnumerator()) {
    [void]$out.Append($kv.Key + [char]9 + $kv.Value + [char]10)
}
$target = Join-Path $PSScriptRoot 'pinyin_phrases_raw.txt'
[IO.File]::WriteAllText($target, $out.ToString(), (New-Object System.Text.UTF8Encoding($false)))

"chains=$chains nodes=$nodes words=$($seen.Count)"
"dumped=$target"
"next: python tools/gen-pinyin-phrases.py"
