<#
.SYNOPSIS
    Build the NEI delivery package (.cpio.Z) and its .specification, for any NEI
    project, on any machine.

.DESCRIPTION
    Replaces the manual Eclipse "Package Current Project" export. Does what the
    SDK's com.comptel.neisdk.util.ProjectPackager does, without Eclipse:

      1. mvn package                     -> populates target\ (resources, lib\)
      2. jar target\classes              -> macro_<BASE>.jar
      3. seeds target\bin\.packinglist   -> Maven's resource filter drops dotfiles
      4. validates every installfile src -> the installer skips missing ones silently
      5. stages under a short, space-free root
      6. installer.exe .packinglist      -> <PRODUCT>-<VERSION>-MSWin32.cpio
      7. compress -f                     -> the .Z the InstantLink host expects
      8. renames, drops the -MSWin32 tag -> <PRODUCT>-<VERSION>.cpio.Z
      9. writes <NEINAME>_nei.specification
     10. verifies the archive is readable and complete

    NOTHING in this script is specific to a product or a machine. The product
    name, version, macro jar name, NEI install path, ksh name and spec file name
    are all derived from the single product_title= line in .packinglist (see
    Get-NeiProduct in NeiEnv.ps1). The SDK binaries, JDK and Maven are located at
    run time (see Find-Nei* in NeiEnv.ps1). Point it at any NEI project and it
    works.

    Things that are easy to get wrong and are handled here:

    * installer.exe trips Windows' UAC installer-detection heuristic purely
      because of its filename, and refuses to start unelevated. It does not
      actually need admin. __COMPAT_LAYER=RUNASINVOKER suppresses that; this is
      exactly what the SDK itself does (ProjectPackager.executeInstaller sets the
      same variable, as does the NEI packager's PackageCpioz).

    * The installer's own compression step fails on Windows with a file-lock
      error, so it silently leaves an UNCOMPRESSED .cpio behind. Compressed here
      as a separate step.

    * `compress` refuses to write output larger than its input, and a jar-heavy
      archive does not shrink under LZW (measured: -0.31%). Without -f you get no
      .Z at all and no obvious error.

    * MAX_PATH. The installer stages into
        <bin>\<pid>.installer.tmp\<PRODUCT>_REL_<VER>\sas\bin\macro_server\java\...
      and when a path crosses 260 characters cpio prints "No such file or
      directory", DROPS THAT FILE, and the installer still exits 0 reporting
      success. This silently shipped a package missing a jsonTemplate file at a
      path length of exactly 260.

    * Spaces in the path. SDK User's Guide section 13: "Ensure that the workspace
      path does not have spaces. Otherwise, the packaging of the NEI project will
      not be successful." Nokia profiles redirect Documents into "OneDrive -
      Nokia", so nearly every project path here has spaces. Staging is therefore
      relocated to a space-free root by default.

    * target\macro_<BASE>.jar is NOT produced by the pom -- no jar-plugin
      finalName is configured, so `mvn package` yields
      <artifactId>-<version>.jar instead. Without step 2 the package ships
      whatever jar was last left in target\, i.e. stale classes.

.EXAMPLE
    .\nei-tools\make-cpioz.ps1 -ProjectDir 'C:\...\NOKIA_FILE_CR_V1'
    Full build and package.

.EXAMPLE
    .\nei-tools\make-cpioz.ps1 -ProjectDir . -Version 1.1.4
    Override the version stamped into product_title and the artifact name.

.EXAMPLE
    .\nei-tools\make-cpioz.ps1 -ShowEnv
    Print the resolved toolchain and product names, then stop. Run this first on
    a new machine.

.EXAMPLE
    .\nei-tools\make-cpioz.ps1 -ValidateOnly
    Check that every .packinglist source resolves, then stop.
#>
#requires -Version 5.1
[CmdletBinding()]
param(
    # Project root. Defaults to the current directory.
    [string] $ProjectDir = (Get-Location).Path,

    # Override the version in product_title and the artifact name. This is the
    # equivalent of the Jenkins job's cpioVersion parameter.
    [string] $Version,

    # Explicit toolchain overrides. All optional -- discovery handles the rest.
    [string] $SdkBin,
    [string] $JavaHome,
    [string] $MvnCmd,

    # Short, space-free staging root. Defaults per Get-NeiWorkRoot.
    [string] $WorkRoot,

    # Print the resolved toolchain and product names, then stop.
    [switch] $ShowEnv,

    # Validate .packinglist sources and stop.
    [switch] $ValidateOnly,

    # Skip `mvn package` and use whatever is already in target\.
    [switch] $SkipBuild,

    # Run `mvn clean package` so target\ is rebuilt from scratch.
    [switch] $Clean,

    # Do not rebuild macro_<BASE>.jar from target\classes.
    [switch] $SkipMacroJar,

    # Leave the .cpio uncompressed (useful when you only want to inspect it).
    [switch] $NoCompress,

    # Move the previous package into archive\ rather than overwriting it.
    [switch] $ArchiveOld,

    # Keep the staging directory for debugging.
    [switch] $KeepStaging,

    # Treat unresolved .packinglist sources as a hard error rather than a warning.
    # Off by default because these packinglists reference docs/pdf/*.pdf, which is
    # authored as .docx and has never been exported.
    [switch] $StrictPacking,

    # Stage in place even if the path has spaces or busts MAX_PATH.
    [switch] $NoRelocate
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\NeiEnv.ps1"

function Step { param([string] $m) Write-Host "==> $m" -ForegroundColor Cyan }
function Note { param([string] $m) Write-NeiNote $m }
function Warn { param([string] $m) Write-NeiWarn $m }

$ProjectDir = [System.IO.Path]::GetFullPath($ProjectDir)

if ($ShowEnv) { Show-NeiEnv -ProjectDir $ProjectDir; return }

# ── preflight ─────────────────────────────────────────────────────────────
Step 'Preflight'

$srcPacking = Join-Path $ProjectDir 'src\main\resources\bin\.packinglist'
if (-not (Test-Path -LiteralPath $srcPacking -PathType Leaf)) {
    # Non-Maven layout: bin\.packinglist directly under the project.
    $alt = Join-Path $ProjectDir 'bin\.packinglist'
    if (Test-Path -LiteralPath $alt -PathType Leaf) { $srcPacking = $alt }
    else { throw "No .packinglist under $ProjectDir (looked in src\main\resources\bin\ and bin\)" }
}
if (-not (Test-Path -LiteralPath (Join-Path $ProjectDir 'pom.xml') -PathType Leaf) -and -not $SkipBuild) {
    throw "No pom.xml in $ProjectDir. Pass -SkipBuild to package an already-built target\."
}

$SdkBin   = Find-NeiSdkBin   -Explicit $SdkBin
$JavaHome = Find-NeiJavaHome -Explicit $JavaHome
$WorkRoot = Get-NeiWorkRoot  -Explicit $WorkRoot
Note "project  : $ProjectDir"
Note "sdk bin  : $SdkBin"
Note "java home: $JavaHome"
Note "work root: $WorkRoot"

$installer = Join-Path $SdkBin 'installer.exe'
$jarExe    = Join-Path $JavaHome 'bin\jar.exe'
$targetDir = Join-Path $ProjectDir 'target'
$targetBin = Join-Path $targetDir 'bin'

# Stamp the requested version into the source .packinglist before reading it, so
# product_title, the artifact name and the spec all agree. Mirrors
# Utility.updateProductVersion in the NEI packager.
if ($Version) {
    Step "Stamp version $Version into .packinglist"
    $lines = Get-Content -LiteralPath $srcPacking
    $new = $lines | ForEach-Object { $_ -replace '(\bproduct_title=.*?)\s+\d+\.\d+\.\d+', ('$1 ' + $Version) }
    Set-Content -LiteralPath $srcPacking -Value $new -Encoding ASCII
    Note 'product_title updated'
}

$prod = Get-NeiProduct -PackingList $srcPacking
Note "product  : $($prod.Product) $($prod.Version)"
Note "artifact : $($prod.Artifact)"
Note "macro jar: $($prod.MacroJar)"
Note "nei path : $($prod.NeiPath)"

$finalName = $prod.Artifact
if ($NoCompress) { $finalName = $prod.CpioName }

# ── 1. build ──────────────────────────────────────────────────────────────
if ($SkipBuild) {
    Step 'Build skipped (-SkipBuild)'
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        throw 'target\ does not exist, so there is nothing to package. Drop -SkipBuild.'
    }
} else {
    $mvn = Find-NeiMaven -Explicit $MvnCmd
    $goals = @('package')
    if ($Clean) { $goals = @('clean', 'package') }
    Step "mvn $($goals -join ' ')"
    Note "using $mvn"

    Push-Location $ProjectDir
    try {
        # JAVA_HOME is scoped to this call so a machine whose global JAVA_HOME
        # points at a newer JDK still compiles Java 8 bytecode for the host.
        $prevJH = $env:JAVA_HOME
        $env:JAVA_HOME = $JavaHome
        try {
            & $mvn -q -DskipTests @goals
            if ($LASTEXITCODE -ne 0) { throw "mvn $($goals -join ' ') failed (exit $LASTEXITCODE)." }
        } finally { $env:JAVA_HOME = $prevJH }
    } finally { Pop-Location }
    Note 'build ok'
}

# ── 2. macro jar ──────────────────────────────────────────────────────────
if ($SkipMacroJar) {
    Step 'Macro jar skipped (-SkipMacroJar)'
} else {
    Step "Build $($prod.MacroJar) from target\classes"
    $classesDir = Join-Path $targetDir 'classes'
    $nClass = @(Get-ChildItem -LiteralPath $classesDir -Recurse -Filter *.class -ErrorAction SilentlyContinue).Count
    if ($nClass -eq 0) { throw "No .class files under $classesDir -- run without -SkipBuild." }

    $macroPath = Join-Path $targetDir $prod.MacroJar
    if (Test-Path -LiteralPath $macroPath) { Remove-Item -LiteralPath $macroPath -Force }
    # 'cfM' -- no manifest. The shipped macro jar has no META-INF at all; it is
    # not loaded via Main-Class anyway (the ksh launcher names MacroServer
    # explicitly and puts this jar on the classpath).
    & $jarExe cfM $macroPath -C $classesDir .
    if ($LASTEXITCODE -ne 0) { throw "jar failed (exit $LASTEXITCODE)." }
    Note ("{0}  ({1} classes, {2:N0} bytes)" -f $prod.MacroJar, $nClass, (Get-Item $macroPath).Length)
}

# ── 3. seed .packinglist ──────────────────────────────────────────────────
# Maven's resource copying omits dotfiles under some configurations, and the
# installer reads ./.packinglist from its working directory.
Step 'Seed target\bin\.packinglist'
if (-not (Test-Path -LiteralPath $targetBin -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $targetBin | Out-Null
}
Copy-Item -LiteralPath $srcPacking -Destination (Join-Path $targetBin '.packinglist') -Force
Note 'copied from source'

# ── 4. validate sources + measure path budget ─────────────────────────────
# installfile paths resolve relative to the directory holding .packinglist, i.e.
# target\bin, so '../lib/*' means target\lib\*. Anything the installer cannot
# find is skipped WITHOUT failing -- the most common cause of a package that
# installs cleanly but misbehaves.
Step 'Validate .packinglist sources'

$missing   = @()
$badNames  = @()
$entries   = 0
$maxSuffix = 0
$curTarget = ''

# installer.exe copies each file by building a `copy <src> <dst>` string and
# handing it to cmd.exe UNQUOTED. Any cmd metacharacter in a filename therefore
# terminates the command early. A real example that cost a release:
#
#   SBC_146_..._MODIFICATION_&_TG_MODIFICATION_..._validation-rules.yaml
#
# produced
#   '_TG_MODIFICATION_IN_ISBC_validation-rules.yaml' is not recognized as an
#   internal or external command
#   ERROR: Unable to copy source file to target
#
# and the installer exited 1 with no .cpio. Catch it here, where the message can
# name the file and say what to do, instead of 200 lines into an installer log.
$cmdHostile = '[&|<>^%!()"]|\s'

foreach ($raw in Get-Content -LiteralPath $srcPacking) {
    $line = $raw.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -match '^targetdir\s*=\s*(.+)$') { $curTarget = $Matches[1].Trim(); continue }
    if ($line -notmatch '^(installfile|translatefile)\s+(\S+)') { continue }

    $kind = $Matches[1]
    $src  = $Matches[2]
    $entries++

    $hits = @(Get-ChildItem -Path (Join-Path $targetBin $src) -File -ErrorAction SilentlyContinue)
    if ($hits.Count -eq 0) {
        $missing += [pscustomobject]@{ Kind = $kind; Source = $src; Target = $curTarget }
        continue
    }

    # Project each matched file to where the installer will stage it:
    #   \<pid>.installer.tmp\<REL>\<targetdir minus $basedir>\<filename>
    $sub = ($curTarget -replace '^\$basedir', '') -replace '/', '\'
    foreach ($h in $hits) {
        $suffix = '\99999.installer.tmp\' + $prod.RelName + $sub + '\' + $h.Name
        if ($suffix.Length -gt $maxSuffix) { $maxSuffix = $suffix.Length }
        if ($h.Name -match $cmdHostile) {
            $badNames += [pscustomobject]@{ Name = $h.Name; Dir = $h.DirectoryName }
        }
    }
}

if ($badNames.Count -gt 0) {
    Write-Host ''
    Write-Host "    $($badNames.Count) file(s) have a name installer.exe cannot copy:" -ForegroundColor Red
    foreach ($b in $badNames) {
        $chars = ([regex]::Matches($b.Name, $cmdHostile) | ForEach-Object { $_.Value } | Sort-Object -Unique) -join ' '
        Write-Host ("      {0}" -f $b.Name) -ForegroundColor Red
        Write-Host ("        offending: {0}" -f $chars) -ForegroundColor DarkGray
        Write-Host ("        in       : {0}" -f $b.Dir) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '    installer.exe passes each copy to cmd.exe unquoted, so these' -ForegroundColor DarkGray
    Write-Host '    characters break the command and abort the build. Rename the' -ForegroundColor DarkGray
    Write-Host '    file in src\main\resources\ (an underscore is the usual' -ForegroundColor DarkGray
    Write-Host '    substitute) and update any code that looks it up by name.' -ForegroundColor DarkGray
    Write-Host ''
    throw "$($badNames.Count) file name(s) contain characters installer.exe cannot handle."
}

if ($missing.Count -eq 0) {
    Note "$entries install/translate entries, all sources resolved"
} else {
    Note "$entries install/translate entries, $($missing.Count) unresolved"
    $colour = 'Yellow'
    if ($StrictPacking) { $colour = 'Red' }
    Write-Host ''
    Write-Host '    UNRESOLVED SOURCES - the installer drops these silently:' -ForegroundColor $colour
    foreach ($m in $missing) {
        Write-Host ("      {0,-14} {1}" -f $m.Kind, $m.Source) -ForegroundColor $colour
        Write-Host ("      {0,-14} -> {1}" -f '', $m.Target) -ForegroundColor DarkGray
    }
    Write-Host ''
    if ($StrictPacking) { throw "$($missing.Count) packinglist source(s) missing (-StrictPacking)." }
    Warn 'continuing anyway; pass -StrictPacking to make this fatal'
}

if ($ValidateOnly) {
    Step 'Stopping (-ValidateOnly)'
    Note ("longest staged path would be {0} chars from a given bin dir" -f $maxSuffix)
    return
}

# ── 5. choose a staging dir ───────────────────────────────────────────────
Step 'Staging location'
$projected  = $targetBin.Length + $maxSuffix
$hasSpace   = $targetBin -match ' '
Note ("in-place: {0} + {1} = {2} chars (MAX_PATH 260); spaces in path: {3}" -f `
      $targetBin.Length, $maxSuffix, $projected, $hasSpace)

$workBin   = $targetBin
$relocated = $false

# The SDK bin path matters as much as the project path. installer.exe copies its
# own postinstall helpers (install_release, uninstall_release) out of its
# configuration directory using the same unquoted `copy`, so a space anywhere in
# the SDK path aborts the build with
#     copy C:\Users\x\OneDrive - Nokia\...\cpiozExecuter\install_release  ...
#     failed: The filename, directory name, or volume label syntax is incorrect.
# This is why the tools must be staged somewhere space-free, not merely found.
$sdkNeedsMove = $SdkBin -match ' '

$projectNeedsMove = ($projected -ge 260 -or $hasSpace)

if (($projectNeedsMove -or $sdkNeedsMove) -and -not $NoRelocate) {
    if ($WorkRoot -match ' ') {
        throw "-WorkRoot '$WorkRoot' contains a space. Use a space-free path, e.g. C:\ilpkg."
    }
    $shortBin = Join-Path $WorkRoot 'target\bin'
    $shortProjected = $shortBin.Length + $maxSuffix
    if ($projectNeedsMove -and $shortProjected -ge 260) {
        throw "Even $WorkRoot is too long ($shortProjected chars). Pass -WorkRoot with something shorter, e.g. C:\p."
    }

    if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -Confirm:$false }
    New-Item -ItemType Directory -Force -Path $WorkRoot | Out-Null
    $relocated = $true

    if ($projectNeedsMove) {
        $why = @()
        if ($projected -ge 260) { $why += 'MAX_PATH' }
        if ($hasSpace)          { $why += 'spaces in project path' }
        Note ("staging project in {0} ({1} chars) - reason: {2}" -f $WorkRoot, $shortProjected, ($why -join ', '))

        # Copy only what the packinglist can reach. nei-run in particular is the
        # extracted output of a previously built package living inside target\.
        $skip = @('nei-run', 'test-classes', 'maven-archiver', 'maven-status', 'generated-sources')
        $dstTarget = Join-Path $WorkRoot 'target'
        New-Item -ItemType Directory -Force -Path $dstTarget | Out-Null
        $copied = 0
        foreach ($item in Get-ChildItem -LiteralPath $targetDir -Force) {
            if ($item.PSIsContainer -and $skip -contains $item.Name) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination $dstTarget -Recurse -Force
            $copied++
        }
        Note "copied $copied entries (skipped: $($skip -join ', '))"
        $workBin = $shortBin
    } else {
        Note 'project path is fine in place'
    }

    if ($sdkNeedsMove) {
        Note "staging SDK tools in $WorkRoot\sdk - reason: spaces in SDK path"
        $sdkDst = Join-Path $WorkRoot 'sdk'
        New-Item -ItemType Directory -Force -Path $sdkDst | Out-Null
        # Copy the whole bin: installer.exe needs cpio.exe, compress.exe, the two
        # DLLs and the install_release/uninstall_release helpers beside it.
        # -Path, not -LiteralPath: the wildcard has to expand.
        foreach ($item in Get-ChildItem -LiteralPath $SdkBin -Force) {
            Copy-Item -LiteralPath $item.FullName -Destination $sdkDst -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath (Join-Path $sdkDst 'installer.exe') -PathType Leaf)) {
            throw "Failed to stage the SDK tools into $sdkDst"
        }
        $SdkBin    = $sdkDst
        $installer = Join-Path $SdkBin 'installer.exe'
        Note "sdk bin -> $SdkBin"
    }
} elseif ($projectNeedsMove -or $sdkNeedsMove) {
    Warn 'staging in place despite -NoRelocate; expect the installer to fail or drop files'
} else {
    Note 'fits in place'
}

# ── 6. clear stale staging ────────────────────────────────────────────────
$stale = @(Get-ChildItem -LiteralPath $workBin -Directory -Filter '*.installer.tmp' -ErrorAction SilentlyContinue)
if ($stale.Count -gt 0) {
    Step "Remove $($stale.Count) stale staging dir(s)"
    foreach ($d in $stale) {
        try { Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction Stop }
        catch { Warn "could not remove $($d.Name): $($_.Exception.Message)" }
    }
}
# Any previous .cpio here would confuse the "which file did we just build" check.
Get-ChildItem -LiteralPath $workBin -Filter '*.cpio*' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ── 7. installer ──────────────────────────────────────────────────────────
Step 'installer.exe .packinglist'

$prevCompat = $env:__COMPAT_LAYER
$env:__COMPAT_LAYER = 'RUNASINVOKER'   # suppress UAC installer-detection

$installerLog = Join-Path $ProjectDir 'make-cpioz.install.log'
try {
    # Launch through cmd.exe with a plain file redirect, NOT Start-Process with
    # an inherited or PowerShell-owned handle.
    #
    # installer.exe shells out to `listdir | cpio -o > archive.cpio` for the
    # archive step. That nested redirect fails with
    #     The handle could not be opened during redirection of handle 1.
    #     ERROR: Unable to create the release archive ...
    # whenever cmd cannot duplicate the installer's own handle 1 -- which is the
    # case when handle 1 is a pipe or a handle owned by the PowerShell host.
    # Because whether it trips depends on how the caller was invoked, it presents
    # as an intermittent failure: the same command succeeds from one shell and
    # fails from the next.
    #
    # Neither inheriting (-NoNewWindow) nor allocating a private console
    # (-WindowStyle Hidden) fixes it; both were measured failing. Giving cmd.exe
    # a real on-disk file for handle 1 does, and it is the same shape the
    # compress step below has always used reliably.
    #
    # The installer additionally writes a verbose .install.log into its working
    # directory -- what the SDK itself reads (ProjectPackager.copyCpioPackage) --
    # which is picked up below regardless.
    $stagedLog = Join-Path $workBin '.install.log'
    Remove-Item -LiteralPath $stagedLog -Force -ErrorAction SilentlyContinue

    $conLog = Join-Path $ProjectDir 'make-cpioz.installer.out'
    $drive  = Split-Path -Qualifier $workBin
    $cmd = '{0} && cd "{1}" && "{2}" .packinglist > "{3}" 2>&1' -f $drive, $workBin, $installer, $conLog
    & "$env:SystemRoot\system32\cmd.exe" /c $cmd
    $exit = $LASTEXITCODE
    Note "installer exit $exit"

    # Surface the installer's console output, which carries the cpio lines that
    # never reach .install.log (block count, dropped files, handle errors).
    if (Test-Path -LiteralPath $conLog) {
        Get-Content -LiteralPath $conLog |
            Where-Object { $_.Trim() -and $_ -notmatch '^\s*\.+\s*$' } |
            ForEach-Object { Note ($_ -replace '\s+$', '') }
    }

    if (Test-Path -LiteralPath $stagedLog) {
        Copy-Item -LiteralPath $stagedLog -Destination $installerLog -Force
        $out = Get-Content -LiteralPath $installerLog

        $created = $out | Where-Object { $_ -match 'release archive .* has been created' } | Select-Object -First 1
        if ($created) { Note ($created -replace '^\s*INFO\s*:\s*', '' -replace '\s+$', '') }

        # -cmatch, not -match: PowerShell's -match is case-INSENSITIVE, so 'ERROR'
        # also matched the perfectly normal line
        #   INFO : installfile ../config/error_codes.txt <>error_codes.txt
        $realErrors = $out |
            Where-Object { $_ -cmatch 'ERROR' } |
            Where-Object { $_ -notmatch 'blank line ignored' } |
            Select-Object -First 3
        foreach ($f in $realErrors) { Warn ($f -replace '\s+$', '') }

        # Backstop for the MAX_PATH drop: cpio names every file it could not
        # read, and the installer exits 0 regardless.
        $dropped = @($out | Where-Object { $_ -match 'cpio: .*No such file or directory' })
        if ($dropped.Count -gt 0) {
            Write-Host ''
            Write-Host "    cpio DROPPED $($dropped.Count) file(s) from the archive:" -ForegroundColor Red
            foreach ($d in $dropped | Select-Object -First 8) {
                Write-Host ('      ' + ((($d -split ':')[-2..-1] -join ':').Trim())) -ForegroundColor Red
            }
            Write-Host ''
            throw "The archive is incomplete. Usually MAX_PATH: retry with -WorkRoot C:\p."
        }
    }
} finally { $env:__COMPAT_LAYER = $prevCompat }

$rawCpio = Get-ChildItem -LiteralPath $workBin -Filter '*.cpio' -File -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $rawCpio) {
    # Distinguish the handle failure from a genuine packaging error, because the
    # two need completely different responses.
    $handleFail = $false
    foreach ($l in @($installerLog, $conLog)) {
        if (Test-Path -LiteralPath $l) {
            if (@(Get-Content -LiteralPath $l |
                  Where-Object { $_ -match 'handle could not be opened' }).Count -gt 0) {
                $handleFail = $true
            }
        }
    }
    if ($handleFail) {
        Write-Host ''
        Write-Host '    installer.exe could not redirect its own output (handle 1).' -ForegroundColor Red
        Write-Host '    This is the environment, not the package: cmd.exe could not' -ForegroundColor DarkGray
        Write-Host '    duplicate the handle for the nested `cpio > archive` step.' -ForegroundColor DarkGray
        Write-Host '    Retrying usually succeeds. If it persists, run the script from' -ForegroundColor DarkGray
        Write-Host '    a plain cmd.exe or PowerShell console rather than an IDE or' -ForegroundColor DarkGray
        Write-Host '    agent terminal.' -ForegroundColor DarkGray
        Write-Host ''
    }
    if (Test-Path -LiteralPath $installerLog) {
        Write-Host ''
        Write-Host '    last 15 lines of the installer log:' -ForegroundColor Red
        Get-Content -LiteralPath $installerLog -Tail 15 |
            ForEach-Object { Write-Host ('      ' + ($_ -replace '\s+$', '')) -ForegroundColor DarkGray }
        Write-Host ''
    }
    throw "installer.exe produced no .cpio in $workBin. Full log: $installerLog"
}
Note ("built {0} ({1:N0} bytes)" -f $rawCpio.Name, $rawCpio.Length)

# ── 8. compress ───────────────────────────────────────────────────────────
$artifact = $rawCpio.FullName

if (-not $NoCompress) {
    Step 'compress -f'
    $prevCompat = $env:__COMPAT_LAYER
    $env:__COMPAT_LAYER = 'RUNASINVOKER'
    try {
        # -f is required: compress refuses to grow a file, and a jar-heavy
        # archive does not shrink under LZW. Without it there is no .Z and no
        # clear error. Routed through cmd.exe for the same handle reason above.
        $clog  = Join-Path $ProjectDir 'make-cpioz.compress.log'
        $drive = Split-Path -Qualifier $workBin
        $cmd = '{0} && cd "{1}" && "{2}\compress.exe" -f -v "{3}" > "{4}" 2>&1' -f `
               $drive, $workBin, $SdkBin, $rawCpio.Name, $clog
        & "$env:SystemRoot\system32\cmd.exe" /c $cmd | Out-Null
        if (Test-Path -LiteralPath $clog) {
            Get-Content -LiteralPath $clog | Where-Object { $_.Trim() } |
                ForEach-Object { Note ($_ -replace '\s+$', '') }
            Remove-Item -LiteralPath $clog -Force -ErrorAction SilentlyContinue
        }
    } finally { $env:__COMPAT_LAYER = $prevCompat }

    $z = "$($rawCpio.FullName).Z"
    if (-not (Test-Path -LiteralPath $z -PathType Leaf)) { throw "compress did not produce $z" }
    $artifact = $z
}

# ── 9. place artifact + write the solution spec ───────────────────────────
Step 'Place artifact'
$dest = Join-Path $ProjectDir $finalName

if (Test-Path -LiteralPath $dest -PathType Leaf) {
    if ($ArchiveOld) {
        $archive = Join-Path $ProjectDir 'archive'
        if (-not (Test-Path -LiteralPath $archive)) { New-Item -ItemType Directory -Force -Path $archive | Out-Null }
        $stamp = (Get-Item -LiteralPath $dest).LastWriteTime.ToString('yyyyMMdd-HHmmss')
        # Insert the stamp before the whole ".cpio.Z" suffix rather than using
        # GetFileNameWithoutExtension, which only strips ".Z".
        $suffix = [IO.Path]::GetExtension($finalName)
        if ($finalName -match '(\.cpio(\.Z)?)$') { $suffix = $Matches[1] }
        $stem = $finalName.Substring(0, $finalName.Length - $suffix.Length)
        $kept = Join-Path $archive ("{0}-{1}{2}" -f $stem, $stamp, $suffix)
        Move-Item -LiteralPath $dest -Destination $kept -Force
        Note "previous -> archive\$([IO.Path]::GetFileName($kept))"
    } else {
        Remove-Item -LiteralPath $dest -Force
        Note 'replaced previous artifact'
    }
}
Move-Item -LiteralPath $artifact -Destination $dest -Force

# The .specification is what "Deploy NEI Package" reads to find the package.
# The Eclipse export and the NEI packager both emit it; this keeps parity.
$specPath = Join-Path $ProjectDir $prod.SpecName
Set-Content -LiteralPath $specPath -Encoding ASCII -Value @(
    "[$($prod.SpecSection)]",
    "package=$finalName"
)
Note "spec -> $($prod.SpecName)"

# ── 10. verify ────────────────────────────────────────────────────────────
Step 'Verify'
$tar = Join-Path $env:SystemRoot 'system32\tar.exe'
$members = @()
if (Test-Path -LiteralPath $tar) {
    # bsdtar reads both the LZW .Z wrapper and the cpio payload, so this proves
    # the artifact is readable rather than merely present.
    $members = @(& $tar -tf $dest 2>$null)
}
if ($members.Count -eq 0) {
    Warn 'could not list the archive - verify it by hand before shipping'
} else {
    Note "$($members.Count) entries readable"

    $expected = "$($prod.RelName)/postinstall/$($prod.RelName).contents"
    if ($members -contains $expected) { Note 'install manifest (.contents) present' }
    else { Warn "expected manifest not found: $expected" }

    if (@($members | Where-Object { $_ -match ([regex]::Escape($prod.MacroJar) + '$') }).Count -gt 0) {
        Note "$($prod.MacroJar) present"
    } else { Warn "$($prod.MacroJar) NOT in the package" }

    if (@($members | Where-Object { $_ -match ([regex]::Escape($prod.KshName) + '$') }).Count -gt 0) {
        Note "$($prod.KshName) present"
    } else { Warn "$($prod.KshName) NOT in the package - the NEI cannot start without it" }

    # Content census. A zero means the packinglist pointed at an empty directory,
    # which validation cannot catch (a glob matching nothing in an existing
    # directory is not a missing source).
    $jars = @($members | Where-Object { $_ -match '\.jar$' }).Count
    Note ("jars={0}  yaml={1}  jsonTemplate={2}  html={3}" -f `
          $jars,
          @($members | Where-Object { $_ -match '/templates/yaml/' }).Count,
          @($members | Where-Object { $_ -match '/templates/jsonTemplate/.+\.' }).Count,
          @($members | Where-Object { $_ -match '/templates/html/.+\.html$' }).Count)

    # Dead weight in lib\. A packinglist shipping '../lib/*' -- everything, not
    # just jars -- puts bytes on the host that Java's classpath wildcard (which
    # expands to .jar/.JAR only) will never load. A stray
    # ciq-processor-1.0.2-cli.zip once added 18.6 MB to every package this way.
    $deadWeight = @($members | Where-Object { $_ -match '/lib/[^/]+$' -and $_ -notmatch '\.jar$' })
    if ($deadWeight.Count -gt 0) {
        Warn "$($deadWeight.Count) non-jar file(s) in lib\ - never on the classpath:"
        foreach ($d in $deadWeight) { Warn ('    ' + ($d -replace '.*/', '')) }
        Warn '    remove them from src\main\resources\lib\, or narrow the'
        Warn '    packinglist to: installfile ../lib/*.jar'
    }
}

if (-not $KeepStaging) {
    Get-ChildItem -LiteralPath $workBin -Directory -Filter '*.installer.tmp' -ErrorAction SilentlyContinue |
        ForEach-Object { try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop } catch {} }
    if ($relocated) {
        try { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -Confirm:$false -ErrorAction Stop }
        catch { Warn "could not remove $WorkRoot" }
    }
}

$final = Get-Item -LiteralPath $dest
Write-Host ''
Write-Host ("DONE  {0}  ({1:N1} MB)" -f $final.Name, ($final.Length / 1MB)) -ForegroundColor Green
Write-Host ("      $dest") -ForegroundColor DarkGray
Write-Host ("      $specPath") -ForegroundColor DarkGray
Write-Host ''
