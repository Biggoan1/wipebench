<#
.SYNOPSIS
    Resolve (and optionally download) Panasonic Toughbook Enterprise CAB driver packs.

.DESCRIPTION
    The Panasonic counterpart to Get-SurfaceDriverPacks.ps1. Neither Dell's catalog nor
    Microsoft's covers Toughbooks, so there is no machine-readable feed at all - the only
    source is Panasonic's own driver-pack page, which is why this scrapes.

    Two stages:
      1. The driver-pack page lists one card per model. Each card holds BOTH an
         "Enterprise CAB" and a "One-Click Bundle" set of links inside a single <dd>,
         separated only by <hr /><strong>One-Click Bundle</strong>. Position decides which
         set a link belongs to, so the parser walks fragments in order rather than pattern
         matching - the same thing a DOM walker does, without needing HtmlAgilityPack.
      2. Each link goes to a /dldocs/<id> page carrying the detail table (Index No, release
         date, OS) and the actual archive URL on na.panasonic.com.

.NOTES
    MODEL NAMING - the point that makes this usable.
    The page says          CF-33[Y/8/9/0] (mk4)
    Win32_BaseBoard.Product says   CF33-4        <- no inner hyphen, mk becomes a suffix
    The asset system says  HW - Panasonic - CF-33-4
    Toughbooks report NOTHING useful in Win32_ComputerSystem.Model, which is why the SCCM
    driver-apply steps match on Win32_BaseBoard.Product. Folders are therefore named in the
    BOARD form (CF33-4) so WinPE's baseboard fallback can find them.

    STILL NEEDED AFTER THIS: the SCCM conditions match with wildcards - `LIKE '%CF33-4%'`,
    `LIKE 'FZ55-2%'` - because the real Product strings carry affixes. WipeBench's baseboard
    fallback is EXACT match only, so a machine reporting e.g. "CF33-4ABC" will not resolve to
    a folder named CF33-4 even once the pack is present. That needs the match-rules layer.

.EXAMPLE
    .\Get-PanasonicDriverPacks.ps1 -ListCatalog
.EXAMPLE
    .\Get-PanasonicDriverPacks.ps1 -Models CF33-4,FZ55-3
.EXAMPLE
    .\Get-PanasonicDriverPacks.ps1 -Models CF33-2,CF33-3,CF33-4,FZ55-1,FZ55-2,FZ55-3 `
        -Destination C:\WipeBenchImages\payload\Drivers -Download -Expand
#>
[CmdletBinding()]
param(
    # Board-style names, as Win32_BaseBoard.Product reports them: CF33-4, FZ55-3, ...
    [string[]]$Models,
    [string]$ModelsJson,
    [ValidateSet('Windows 11','Windows 10')]
    [string]$OsCode = 'Windows 11',
    [string]$Destination = ".\PanasonicDriverPacks",
    [switch]$Download,
    [switch]$Expand,
    [switch]$ListCatalog,
    [string]$PageUrl = "https://global-pc-support.connect.panasonic.com/driver/deployment-support-tools/driver-pack"
)
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# "CF-33[Y/8/9/0] (mk4)" -> "CF33-4".  Take everything before the first [ or (, drop
# hyphens, then append the mk number. Deliberately not a family whitelist: CF-FV4S and
# CF-XZ6[R] broke an earlier regex that assumed <letters><digits>.
function Get-BoardName([string]$model) {
    $fam = ([regex]::Match($model, '^([^\[\(]+)')).Groups[1].Value.Trim() -replace '-',''
    $mk  = ([regex]::Match($model, '\(mk([0-9A-Za-z.]+)\)')).Groups[1].Value
    if ($fam -and $mk) { "$fam-$mk" } elseif ($fam) { $fam } else { $null }
}

function Get-PanasonicCatalog {
    Say "  fetching the driver-pack page ..."
    $r = Invoke-WebRequest -Uri $PageUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = $UA }
    if ($r.RawContent.Length -lt 20000) { Say "  page returned only $($r.RawContent.Length) bytes - likely a block page" Yellow }
    $out = @()
    foreach ($card in ([regex]::Split($r.RawContent, '<div\s+class="bg"') | Select-Object -Skip 1)) {
        $h4 = [regex]::Match($card, '(?s)<h4[^>]*>(.*?)</h4>')
        if (-not $h4.Success) { continue }
        $model = ($h4.Groups[1].Value -replace '<[^>]+>','').Trim()
        $board = Get-BoardName $model
        $type = $null
        foreach ($frag in [regex]::Split($card, '(?=<strong)')) {
            $st = [regex]::Match($frag, '(?s)<strong[^>]*>(.*?)</strong>')
            if ($st.Success) {
                $t = ($st.Groups[1].Value -replace '<[^>]+>','').Trim()
                if     ($t -match 'Enterprise\s*CAB') { $type = 'Enterprise CAB' }
                elseif ($t -match 'One-Click')        { $type = 'One-Click Bundle' }
                else                                  { $type = $t }
            }
            foreach ($m in [regex]::Matches($frag, '(?s)<a\s+class="ic_link"\s+href="([^"]+)"[^>]*>(.*?)</a>')) {
                $out += [pscustomobject]@{
                    Model = $model; Board = $board; PackageType = $type
                    LinkText = ($m.Groups[2].Value -replace '<[^>]+>','').Trim()
                    DetailUrl = $m.Groups[1].Value
                }
            }
        }
    }
    $out
}

function Resolve-PanasonicPack {
    param([object]$Entry)
    $r = Invoke-WebRequest -Uri $Entry.DetailUrl -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = $UA }
    $c = $r.RawContent
    $info = @{}
    foreach ($m in [regex]::Matches($c, '(?s)<tr>\s*<th[^>]*>(.*?)</th>\s*<td[^>]*>(.*?)</td>')) {
        $k = ($m.Groups[1].Value -replace '<[^>]+>','').Trim()
        $v = ($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
        if ($k) { $info[$k] = $v }
    }
    # the archive lives in the section that talks about download files
    $url = $null
    $sec = [regex]::Matches($c, '(?s)<section.*?</section>') | Where-Object { $_.Value -match '(?i)download file' } | Select-Object -First 1
    if ($sec) { $url = ([regex]::Match($sec.Value, '(?s)<a[^>]+href="([^"]+)"')).Groups[1].Value }
    if (-not $url) {
        $url = ([regex]::Match($c, 'https://na\.panasonic\.com/computer/cab/[^"'' <>]+')).Value
    }
    [pscustomobject]@{
        Board = $Entry.Board; Model = $Entry.Model; Os = $Entry.LinkText
        IndexNo = $info['Index No']; Released = $info['Release Date']
        Url = $url; File = $(if ($url) { Split-Path $url -Leaf } else { $null })
        DetailUrl = $Entry.DetailUrl
    }
}

# ------------------------------------------------------------------ main ----
Say "`nPanasonic Enterprise CAB packs - target OS: $OsCode" Cyan
$cat = Get-PanasonicCatalog
$ent = @($cat | Where-Object { $_.PackageType -eq 'Enterprise CAB' })
Say ("  {0} links parsed, {1} Enterprise CAB" -f $cat.Count, $ent.Count)

if ($ListCatalog) {
    $ent | Where-Object { $_.LinkText -like "$OsCode*" } |
        Select-Object Board, Model, LinkText | Sort-Object Board | Format-Table -AutoSize
    return
}
if ($ModelsJson) {
    $j = Get-Content $ModelsJson -Raw | ConvertFrom-Json
    $src = if ($j.panasonic) { $j.panasonic } elseif ($j.models) { $j.models } else { $j }
    $Models = @($src | ForEach-Object { if ($_.board) { $_.board } elseif ($_.name) { $_.name } else { $_ } })
}
if (-not $Models) { throw "Give me -Models (board names like CF33-4) or -ModelsJson. Use -ListCatalog to see them." }

$results = @()
foreach ($want in $Models) {
    Say "`n== $want ==" Cyan
    $cands = @($ent | Where-Object { $_.Board -eq $want -and $_.LinkText -like "$OsCode*" })
    if (-not $cands.Count) {
        # Two very different failures, and conflating them is useless: the model may be on
        # the page with no Windows 11 pack YET, or the name may just be wrong.
        $anyForBoard = @($cat | Where-Object { $_.Board -eq $want })
        if ($anyForBoard.Count) {
            Say "  '$want' IS on the page, but has no $OsCode Enterprise CAB yet." Yellow
            $have = @($anyForBoard | Where-Object { $_.PackageType -eq 'Enterprise CAB' } |
                      Select-Object -Expand LinkText -Unique | Sort-Object -Descending)
            if ($have) { Say "  Enterprise CABs it DOES offer: $($have -join '; ')" Gray }
            else       { Say "  it offers no Enterprise CAB at all (One-Click Bundle only)" Gray }
            # NOT the same as "never" - these models are still in production, so a Win11 pack
            # may appear later, and STAGING can take delivery of them whatever today's fleet
            # export shows. Re-check periodically rather than writing them off.
            Say "  Still in production, so re-run this periodically rather than assuming never." Gray
        }
        else {
            $near = @($ent | Where-Object { $_.Board -like "*$want*" -or $want -like "*$($_.Board)*" } |
                      Select-Object -Expand Board -Unique)
            Say "  '$want' is not on the page at all." Red
            if ($near) { Say "  did you mean: $($near -join ', ')" Yellow }
            else { Say "  run with -ListCatalog to see the board names it publishes." Yellow }
        }
        continue
    }
    # newest OS revision first: "Windows 11 64bit Ver.25H2" sorts above Ver.24H2
    $pick = $cands | Sort-Object LinkText -Descending | Select-Object -First 1
    Say "  $($pick.Model)  ->  $($pick.LinkText)"
    $p = Resolve-PanasonicPack -Entry $pick
    if (-not $p.Url) { Say "  could not find a download URL on $($pick.DetailUrl)" Red; continue }
    Say "  index $($p.IndexNo), released $($p.Released)"
    Say "  $($p.File)" Green
    foreach ($alt in ($cands | Where-Object { $_.LinkText -ne $pick.LinkText })) { Say "    also offered: $($alt.LinkText)" DarkGray }

    if ($Download) {
        # folder named in the BOARD form, because that is what WinPE reads off the machine
        $dir = Join-Path $Destination $p.Board
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $dst = Join-Path $dir $p.File
        if (Test-Path $dst) { Say "    already downloaded" }
        else {
            Say "    downloading ..."
            & curl.exe -L --fail --retry 2 -s -o $dst $p.Url
            if ($LASTEXITCODE -ne 0) { Say "    download FAILED (curl $LASTEXITCODE)" Red; continue }
        }
        Say ("    {0:N2} GB" -f ((Get-Item $dst).Length/1GB))
        if ($Expand) {
            $ex = Join-Path $dir "Win11"
            New-Item -ItemType Directory -Force -Path $ex | Out-Null
            Say "    expanding ..."
            # Prefer bsdtar (shipped with Windows 10 1803+). Expand-Archive died on two of the
            # six packs with "the process cannot access the file ... .appx because it is being
            # used by another process" - something grabs the .appx files under drivers\me\
            # IMSS_Store as they land, and Expand-Archive has no retry, then its own rollback
            # emitted thousands of Remove-Item errors on top. bsdtar streams the archive and
            # does not trip over it, and is faster on a 3 GB zip besides.
            $expanded = $false
            if (Get-Command tar.exe -ErrorAction SilentlyContinue) {
                & tar.exe -x -f $dst -C $ex 2>$null
                if ($LASTEXITCODE -eq 0) { $expanded = $true }
                else { Say "    tar returned $LASTEXITCODE - falling back to Expand-Archive" Yellow }
            }
            if (-not $expanded) {
                try { Expand-Archive -Path $dst -DestinationPath $ex -Force; $expanded = $true }
                catch { Say "    expand failed: $($_.Exception.Message)" Red; continue }
            }
            $infs = @(Get-ChildItem $ex -Recurse -File | Where-Object { $_.Extension -eq '.inf' }).Count
            Say "    expanded: $infs INFs" $(if ($infs) { 'Green' } else { 'Red' })
            # Drop the archive once it has expanded successfully. It is ~3 GB per model and
            # this folder gets copied verbatim to every stick, so keeping it would waste
            # ~18 GB per stick across the six Toughbook models for no benefit - the pack is
            # re-fetchable from the index number recorded above. Only delete on success.
            if ($infs -gt 0) {
                $zb = (Get-Item $dst).Length
                Remove-Item $dst -Force -ErrorAction SilentlyContinue
                Say ("    removed the {0:N2} GB archive (expanded copy is what ships)" -f ($zb/1GB)) DarkGray
            }
            else { Say "    keeping the archive - expansion produced no INFs, so something is wrong" Yellow }
        }
        $p | Add-Member NoteProperty LocalPath $dst -Force
    }
    $results += $p
}

Say "`n---- summary ----" Cyan
$results | Select-Object Board, IndexNo, Released, File | Format-Table -AutoSize
if (-not $Download) { Say "Resolve only. Re-run with -Download (and -Expand) to fetch." Gray }
