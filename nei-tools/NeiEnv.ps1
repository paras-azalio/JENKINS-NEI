<#
.SYNOPSIS
    Machine-independent discovery of everything needed to build a NEI .cpio.Z.

.DESCRIPTION
    Dot-source this from a packaging script:

        . "$PSScriptRoot\NeiEnv.ps1"

    Nothing here is specific to a machine, a user, or a product. Every path is
    resolved at run time in this order:

        1. an explicit parameter                 (CI passes these)
        2. an environment variable               (per-developer override)
        3. tools vendored in this repository     (works with no SDK installed)
        4. well-known install locations          (a normal SDK install)
        5. PATH / registry

    The point is that a colleague clones the repo and runs the script. If they
    have the SDK installed it is found; if they do not, the vendored
    cpiozExecuter\ is used instead, because the four binaries the packaging
    actually needs (installer.exe, cpio.exe, compress.exe + their two DLLs) are
    committed here.

    Do not add a hard-coded C:\Users\<someone>\... path to this file. That is
    the specific bug this file exists to remove.
#>

Set-StrictMode -Version 2.0

# Repo root = parent of nei-tools\.
$script:NeiRepoRoot = Split-Path -Parent $PSScriptRoot

function Write-NeiNote { param([string] $m) Write-Host "    $m" -ForegroundColor DarkGray }
function Write-NeiWarn { param([string] $m) Write-Host "    ! $m" -ForegroundColor Yellow }


function Find-NeiSdkBin {
    <#
    .SYNOPSIS
        Locate the directory holding installer.exe, cpio.exe and compress.exe.
    .DESCRIPTION
        Returns the first candidate that actually contains all three binaries --
        existence of the directory is not enough, because a partial SDK copy
        fails much later and much more confusingly (installer.exe runs, exits 0,
        and leaves no .cpio).
    #>
    [CmdletBinding()]
    param([string] $Explicit)

    $needed = @('installer.exe', 'cpio.exe', 'compress.exe')

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Explicit)          { $candidates.Add($Explicit) }
    if ($env:NEISDK_BIN)    { $candidates.Add($env:NEISDK_BIN) }

    # Vendored in this repo -- the reason a colleague needs no SDK install.
    $candidates.Add((Join-Path $script:NeiRepoRoot 'cpiozExecuter'))

    # Jenkins agents: JENKINS_HOME is <repo>\jenkins_home, so ..\cpiozExecuter.
    if ($env:JENKINS_HOME) {
        $candidates.Add((Join-Path (Split-Path -Parent $env:JENKINS_HOME) 'cpiozExecuter'))
    }

    # A normal SDK install. Search the user's profile and OneDrive-redirected
    # Documents, then fixed roots. Nokia laptops redirect Documents into
    # "OneDrive - Nokia", so the literal Documents path is not reliable.
    $roots = New-Object System.Collections.Generic.List[string]
    if ($env:USERPROFILE) {
        $roots.Add((Join-Path $env:USERPROFILE 'Documents'))
        foreach ($od in @(Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue)) {
            $roots.Add((Join-Path $od.FullName 'Documents'))
            $roots.Add($od.FullName)
        }
        $roots.Add($env:USERPROFILE)
    }
    foreach ($fixed in @('C:\', 'C:\Nokia', 'C:\Comptel', 'D:\')) { $roots.Add($fixed) }

    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -Filter '*NEISDK*' -ErrorAction SilentlyContinue)) {
            $candidates.Add((Join-Path $d.FullName 'bin'))
        }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (-not (Test-Path -LiteralPath $c -PathType Container)) { continue }
        $ok = $true
        foreach ($n in $needed) {
            if (-not (Test-Path -LiteralPath (Join-Path $c $n) -PathType Leaf)) { $ok = $false; break }
        }
        if ($ok) { return [System.IO.Path]::GetFullPath($c) }
    }

    throw @"
Could not locate the NEI SDK binaries (installer.exe, cpio.exe, compress.exe).

Fix by any one of:
  * set NEISDK_BIN to the SDK's bin directory, e.g.
      `$env:NEISDK_BIN = 'C:\InstantLinkNEISDK19\bin'
  * pass -SdkBin <path> to the packaging script
  * make sure <repo>\cpiozExecuter\ is present (it is committed to this repo)
"@
}


function Find-NeiJavaHome {
    <#
    .SYNOPSIS
        Locate a JDK (not a JRE) -- jar.exe is required to build the macro jar.
    .DESCRIPTION
        Prefers Java 8: the NEI ksh launcher runs the macro server under the
        host's JRE 8, so classes compiled by a newer JDK would fail at load
        time with UnsupportedClassVersionError on the InstantLink host.
    #>
    [CmdletBinding()]
    param([string] $Explicit)

    $candidates = New-Object System.Collections.Generic.List[string]

    if ($Explicit)                    { $candidates.Add($Explicit) }
    if ($env:NEI_JAVA_HOME)           { $candidates.Add($env:NEI_JAVA_HOME) }
    if ($env:JAVA_HOME)               { $candidates.Add($env:JAVA_HOME) }

    # JDKs bundled with this repo (what the Jenkins controller uses).
    $repoJava = Join-Path $script:NeiRepoRoot 'java'
    if (Test-Path -LiteralPath $repoJava -PathType Container) {
        foreach ($d in @(Get-ChildItem -LiteralPath $repoJava -Directory -Filter 'jdk-8*' -ErrorAction SilentlyContinue)) {
            $candidates.Add($d.FullName)
        }
        foreach ($d in @(Get-ChildItem -LiteralPath $repoJava -Directory -Filter 'jdk*' -ErrorAction SilentlyContinue)) {
            $candidates.Add($d.FullName)
        }
    }

    # Common install roots. jdk-8 first, then anything.
    foreach ($root in @('C:\Program Files\Eclipse Adoptium',
                        'C:\Program Files\Java',
                        'C:\Program Files\Microsoft',
                        'C:\Program Files\Amazon Corretto',
                        'C:\Program Files (x86)\Java')) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($pat in @('jdk-8*', 'jdk1.8*', 'jdk*')) {
            foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Filter $pat -ErrorAction SilentlyContinue)) {
                $candidates.Add($d.FullName)
            }
        }
    }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (Test-Path -LiteralPath (Join-Path $c 'bin\jar.exe') -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($c)
        }
    }

    # Last resort: jar.exe on PATH -> its JDK is two levels up.
    $jar = Get-Command jar.exe -ErrorAction SilentlyContinue
    if ($jar) { return (Split-Path -Parent (Split-Path -Parent $jar.Source)) }

    throw @"
Could not locate a JDK. A JRE is not enough -- jar.exe is needed to build the
macro jar, and only a JDK ships it.

Fix by any one of:
  * set JAVA_HOME to a JDK 8 install
  * set NEI_JAVA_HOME to override just this toolchain
  * pass -JavaHome <path> to the packaging script
"@
}


function Find-NeiMaven {
    <#
    .SYNOPSIS
        Locate the mvn launcher.
    #>
    [CmdletBinding()]
    param([string] $Explicit)

    if ($Explicit -and (Test-Path -LiteralPath $Explicit -PathType Leaf)) {
        return [System.IO.Path]::GetFullPath($Explicit)
    }

    if ($env:NEI_MVN -and (Test-Path -LiteralPath $env:NEI_MVN -PathType Leaf)) { return $env:NEI_MVN }

    $onPath = Get-Command mvn -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Join-Path $script:NeiRepoRoot 'maven'))
    if ($env:MAVEN_HOME) { $roots.Add($env:MAVEN_HOME) }
    if ($env:M2_HOME)    { $roots.Add($env:M2_HOME) }
    $roots.Add('C:\Program Files')
    $roots.Add('C:\')

    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
        # $r may itself be a Maven home, or a directory containing one.
        foreach ($cand in @($r) + @(Get-ChildItem -LiteralPath $r -Directory -Filter 'apache-maven*' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
            foreach ($exe in @('bin\mvn.cmd', 'bin\mvn.bat')) {
                $p = Join-Path $cand $exe
                if (Test-Path -LiteralPath $p -PathType Leaf) { return [System.IO.Path]::GetFullPath($p) }
            }
        }
    }

    throw @"
Could not locate Maven.

Fix by any one of:
  * put mvn on PATH
  * set MAVEN_HOME (or NEI_MVN to the mvn.cmd itself)
  * pass -MvnCmd <path> to the packaging script
  * pass -SkipBuild if target\ is already populated
"@
}


function Get-NeiProduct {
    <#
    .SYNOPSIS
        Derive every product-specific name from a .packinglist.
    .DESCRIPTION
        The single line

            product_title=JAVA_FILECR_ANY_V1 1.0.0

        determines all of these, so nothing downstream needs to be told the
        product name. Verified against a real built package:

            Product     JAVA_FILECR_ANY_V1
            Version     1.0.0
            RelName     JAVA_FILECR_ANY_V1_REL_1.0.0          (archive root dir)
            MacroJar    macro_FILECR_ANY_V1.jar               (JAVA_ prefix dropped)
            NeiPath     FILECR/ANY/V1                         (underscores -> slashes)
            KshName     java_filecr_any_v1.ksh                (lower-cased product)
            SpecName    FILECR_ANY_V1_nei.specification       (first _ segment dropped)
            Artifact    JAVA_FILECR_ANY_V1-1.0.0.cpio.Z

        This mirrors Naming.java / Utility.jarFileNameFromProductTitle in the
        NEI packager, and generateSolutionSpec in the SDK.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $PackingList,
        [string] $VersionOverride
    )

    if (-not (Test-Path -LiteralPath $PackingList -PathType Leaf)) {
        throw "No .packinglist at $PackingList"
    }

    $titleLine = Get-Content -LiteralPath $PackingList |
                 Where-Object { $_ -match '^\s*product_title\s*=' } |
                 Select-Object -First 1
    if (-not $titleLine) { throw "No product_title= line in $PackingList" }

    $parts   = ($titleLine -replace '^\s*product_title\s*=\s*', '').Trim() -split '\s+'
    $product = $parts[0]
    $version = '1.0.0'
    if ($parts.Count -gt 1) { $version = $parts[1] }
    if ($VersionOverride)   { $version = $VersionOverride }

    # Strip the JAVA_ prefix once; everything below is derived from the remainder.
    $base = $product -replace '^JAVA_', ''

    # NEINAME per the SDK: PACKAGENAME.split("_", 2)[1] -- drop the first
    # underscore-separated segment, not the JAVA_ prefix specifically.
    $idx = $product.IndexOf('_')
    if ($idx -lt 0 -or $idx + 1 -ge $product.Length) {
        throw "product_title '$product' has no underscore; cannot derive the NEI name."
    }
    $neiName = $product.Substring($idx + 1)

    [pscustomobject]@{
        Product     = $product
        Version     = $version
        RelName     = "${product}_REL_${version}"
        MacroJar    = "macro_$base.jar"
        NeiPath     = ($base -replace '_', '/')
        NeiPathWin  = ($base -replace '_', '\')
        # The launcher is just the lower-cased product_title. The SDK states the
        # convention as java_<netype>_<productname>_<productversion>.ksh, and
        # product_title is JAVA_<netype>_<productname>_<productversion>, so
        # lower-casing it already yields the leading "java_".
        KshName     = ($product.ToLowerInvariant() + '.ksh')
        SpecName    = "${neiName}_nei.specification"
        SpecSection = $product
        CpioName    = "$product-$version.cpio"
        Artifact    = "$product-$version.cpio.Z"
    }
}


function Get-NeiWorkRoot {
    <#
    .SYNOPSIS
        Pick a short, space-free staging directory.
    .DESCRIPTION
        Two independent reasons the build cannot always stage in place:

        MAX_PATH. installer.exe stages into
            <bin>\<pid>.installer.tmp\<PRODUCT>_REL_<VER>\sas\bin\macro_server\java\...
        and when a path crosses 260 characters cpio prints "No such file or
        directory", DROPS THAT FILE, and the installer still exits 0 reporting
        success.

        Spaces. The SDK User's Guide, section 13 "Packaging NEI Projects":
        "Ensure that the workspace path does not have spaces. Otherwise, the
        packaging of the NEI project will not be successful." Nokia laptops
        redirect Documents into "OneDrive - Nokia", so essentially every project
        path here contains spaces. In practice installer.exe has tolerated them
        in this configuration, but the documented contract says otherwise and a
        space-free staging root costs one copy.

        Preference order is fixed roots first because %TEMP% under a redirected
        profile is itself long and may contain spaces.
    #>
    [CmdletBinding()]
    param([string] $Explicit)

    if ($Explicit) { return $Explicit }
    if ($env:NEI_WORK_ROOT) { return $env:NEI_WORK_ROOT }

    foreach ($root in @('C:\ilpkg', 'D:\ilpkg')) {
        $drive = Split-Path -Qualifier $root
        if (Test-Path -LiteralPath ($drive + '\')) { return $root }
    }

    # Fall back to TEMP, but only if it is itself space-free.
    if ($env:TEMP -and $env:TEMP -notmatch ' ') { return (Join-Path $env:TEMP 'ilpkg') }

    return 'C:\ilpkg'
}


function Show-NeiEnv {
    <#
    .SYNOPSIS
        Print the resolved toolchain. Run this first when a colleague's machine
        misbehaves -- it answers "what did it actually pick up" in one shot.
    #>
    [CmdletBinding()]
    param([string] $ProjectDir = (Get-Location).Path)

    Write-Host ''
    Write-Host 'NEI toolchain' -ForegroundColor Cyan
    Write-Host ('-' * 60) -ForegroundColor DarkGray

    foreach ($probe in @(
        @{ Name = 'repo root'; Value = { $script:NeiRepoRoot } },
        @{ Name = 'sdk bin';   Value = { Find-NeiSdkBin } },
        @{ Name = 'java home'; Value = { Find-NeiJavaHome } },
        @{ Name = 'maven';     Value = { Find-NeiMaven } },
        @{ Name = 'work root'; Value = { Get-NeiWorkRoot } }
    )) {
        try {
            $v = & $probe.Value
            Write-Host ("  {0,-10} {1}" -f $probe.Name, $v) -ForegroundColor Gray
        } catch {
            Write-Host ("  {0,-10} NOT FOUND" -f $probe.Name) -ForegroundColor Red
            foreach ($l in ($_.Exception.Message -split "`n")) {
                if ($l.Trim()) { Write-Host ("             " + $l.TrimEnd()) -ForegroundColor DarkGray }
            }
        }
    }

    $pl = Join-Path $ProjectDir 'src\main\resources\bin\.packinglist'
    if (Test-Path -LiteralPath $pl -PathType Leaf) {
        $p = Get-NeiProduct -PackingList $pl
        Write-Host ''
        Write-Host '  product (from .packinglist)' -ForegroundColor Cyan
        foreach ($n in @('Product','Version','RelName','MacroJar','NeiPath','KshName','SpecName','Artifact')) {
            Write-Host ("    {0,-10} {1}" -f $n, $p.$n) -ForegroundColor Gray
        }
    } else {
        Write-Host ''
        Write-Host "  no .packinglist under $ProjectDir" -ForegroundColor DarkGray
    }
    Write-Host ''
}
