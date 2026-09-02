# NEI packaging — concepts and a portable toolchain

Builds the `.cpio.Z` delivery package for any InstantLink Java NEI project, on
any machine, without Eclipse.

```powershell
# what did it find on this PC?
.\nei-tools\make-cpioz.ps1 -ProjectDir <project> -ShowEnv

# build the package
.\nei-tools\make-cpioz.ps1 -ProjectDir <project>
```

Close any Word document that lives under `src\main\resources\` before building —
Word takes an exclusive lock and Maven's resource copy cannot read the file. See
[Known failure modes](#known-failure-modes).

---

## 1. The vocabulary

### Java Macro Server

The InstantLink component that actually talks to network elements. It is a
long-running Java process that:

1. reads provisioning tasks from Task Engine,
2. loads the right **NEI** for the task and calls the named method,
3. the NEI turns task parameters into NE-specific commands and runs them,
4. the NEI returns task/connection status, which the macro server hands back to
   Task Engine.

Your project is *not* a standalone program. It is a bundle of classes the macro
server loads. `com.comptel.mds.sas.java_macroserver.MacroServer` is the entry
point — always, for every NEI.

### NEI (Network Element Interface)

The per-network-element module. `FILECR` and `CLICR` are two of them. One NEI =
one macro jar + its libs + its templates + a launcher script.

### `.ksh`

The Korn-shell launcher the macro server is started with, one per NEI. It is
tiny and almost entirely boilerplate — it sets heap sizes, points `JAVA_HOME` at
the JRE 8 shipped with InstantLink, builds a `CLASSPATH`, and `exec`s the macro
server:

```ksh
installdir=__BASEDIR__
jmsdir=${installdir}/sas/bin/macro_server/java
export JAVA_HOME=${installdir}/java_jre/current
jms_jar=${jmsdir}/java_macroserver-JDK8.jar

CLASSPATH=${jmsdir}/FILECR/ANY/V1/macro_FILECR_ANY_V1.jar:${jms_jar}
## REMARK: This section will be updated by SDK from "Update Dependencies to NEI Package" option. ##
CLASSPATH=$CLASSPATH:${jmsdir}/FILECR/ANY/V1/lib/*
## END REMARK ##

exec $JAVA_HOME/bin/java -Xms$MIN_HEAP_SIZE -Xmx$MAX_HEAP_SIZE $1 $2 \
     -cp $CLASSPATH com.comptel.mds.sas.java_macroserver.MacroServer
```

Two things worth knowing:

- **`__BASEDIR__` is a placeholder.** The `.packinglist` uses `translatefile`
  (not `installfile`) for the `.ksh`, so the installer rewrites `__BASEDIR__` to
  the real install root at install time. That is why the file is not directly
  runnable as-is.
- **`lib/*` is a Java classpath wildcard**, which expands to `.jar`/`.JAR`
  **only**. Anything else shipped into `lib/` is bytes on the host that are
  never loaded. A stray `ciq-processor-1.0.2-cli.zip` once added 18.6 MB to
  every package this way.

The naming convention is `java_<netype>_<productname>_<productversion>.ksh` —
i.e. exactly the lower-cased `product_title`.

### `.packinglist`

The build manifest, at `src/main/resources/bin/.packinglist` for a Maven
project. It tells the Nokia **Installer** what to package, where each file lands
on the target host, and with what permissions.

```
product_title=JAVA_FILECR_ANY_V1 1.0.0     <- name + release; drives everything

filemode=0550                              <- default perms from here down
targetdir=$basedir/sas/bin/macro_server/java
translatefile java_filecr_any_v1.ksh ~mds $basedir $basedir/.../java_filecr_any_v1.ksh

targetdir=$basedir/sas/bin/macro_server/java/FILECR/ANY/V1/lib
installfile ../lib/*.jar
```

- `product_title` — product name and version, in capitals. **Everything else is
  derived from this line** (see below).
- `targetdir` — where subsequent files install to. `$basedir` is substituted
  with the install root at install time.
- `filemode` / `dirmode` — UNIX octal permissions applied from that point on.
- `installfile <src> [target] [mode]` — copy a file.
- `translatefile <src> <searchlist> <replacelist> [target]` — copy *and*
  substitute. This is how `__BASEDIR__` and `~mds` get resolved.

Source paths are relative to the directory holding `.packinglist` — which at
build time is `target\bin\`, so `../lib/*.jar` means `target\lib\*.jar`.

> **A source the installer cannot find is skipped silently, and the build still
> reports success.** This is the most common cause of a package that installs
> cleanly but misbehaves. `make-cpioz.ps1` validates every entry up front for
> exactly this reason.

### `.cpio.Z` ("cpioz")

The delivery artifact. Two old-school UNIX formats stacked:

- **cpio** — an archive format like tar. `installer.exe` stages the whole
  install tree into a temp directory and runs `cpio -o` over it.
- **`.Z`** — LZW compression (`compress(1)`, predates gzip). This is what the
  InstantLink host expects.

So `JAVA_FILECR_ANY_V1-1.0.0.cpio.Z` is *an LZW-compressed cpio archive of a
directory tree that gets unpacked onto the InstantLink server*. Inspect one with
Windows' bundled bsdtar, which reads both layers:

```powershell
tar -tf JAVA_FILECR_ANY_V1-1.0.0.cpio.Z
```

Inside:

```
JAVA_FILECR_ANY_V1_REL_1.0.0/                        <- release root
├── bill_of_materials.txt
├── meta/{validate,configure}                         <- pre-install hooks
├── postinstall/
│   ├── install_release, uninstall_release            <- from the SDK bin
│   ├── JAVA_FILECR_ANY_V1_REL_1.0.0.contents         <- install manifest
│   ├── .snippets/, .translate/                       <- deferred edits
└── sas/
    ├── bin/macro_server/java/
    │   ├── java_filecr_any_v1.ksh                    <- launcher
    │   ├── {supp,phase,error}_codes.txt
    │   └── FILECR/ANY/V1/                            <- the NEI itself
    │       ├── macro_FILECR_ANY_V1.jar
    │       ├── lib/*.jar
    │       ├── script/*.ksh                          <- nemo setup/teardown
    │       └── templates/{yaml,jsonTemplate,html}/
    └── ui/webapps/sas5/docs/FILECR/                  <- customer PDFs
```

### `_nei.specification`

A two-line pointer file the SDK's *Deploy NEI Package* reads to find the
artifact:

```ini
[JAVA_FILECR_ANY_V1]
package=JAVA_FILECR_ANY_V1-1.0.0.cpio.Z
```

### `nemo` scripts

`nemo_setup.ksh`, `drop_nemo.ksh`, `il_nemo_functions.ksh` set up and tear down
the **network model** in InstantLink. They are SDK boilerplate — byte-identical
across all six NEI projects here — and only `bin/java_<product>.ksh` differs per
project.

---

## 2. Everything is derived from one line

`product_title=JAVA_FILECR_ANY_V1 1.0.0` determines every other name. There is
no per-project configuration anywhere in this toolchain:

| Derived | Value | Rule |
|---|---|---|
| Product | `JAVA_FILECR_ANY_V1` | first token |
| Version | `1.0.0` | second token |
| Release root | `JAVA_FILECR_ANY_V1_REL_1.0.0` | `<product>_REL_<version>` |
| Macro jar | `macro_FILECR_ANY_V1.jar` | drop `JAVA_`, prefix `macro_` |
| Install path | `FILECR/ANY/V1` | drop `JAVA_`, `_` → `/` |
| Launcher | `java_filecr_any_v1.ksh` | lower-case the product |
| Spec file | `FILECR_ANY_V1_nei.specification` | drop the first `_` segment |
| Artifact | `JAVA_FILECR_ANY_V1-1.0.0.cpio.Z` | `<product>-<version>.cpio.Z` |

This mirrors `Naming.java` and `Utility.jarFileNameFromProductTitle` in the NEI
packager, and `generateSolutionSpec` in the SDK. Verified against real built
packages for both `FILECR` and `CLICR`.

---

## 3. What the build actually does

`mvn package` populates `target\` — but **it does not build the macro jar**. No
`finalName` is configured, so Maven produces `<artifactId>-<version>.jar`, not
`macro_FILECR_ANY_V1.jar`. The SDK builds that separately in
`packageClassFiles()`. Skip that step and you ship whatever stale jar was last
left in `target\`.

```
mvn package                 -> target\{classes,lib,bin,script,templates,config,docs}
jar cfM macro_<BASE>.jar    -> from target\classes  (no manifest, matching the SDK)
copy .packinglist           -> target\bin\  (Maven's resource filter drops dotfiles)
validate every source       -> missing ones are skipped SILENTLY by the installer
installer.exe .packinglist  -> <PRODUCT>-<VERSION>-MSWin32.cpio
compress -f                 -> .cpio.Z
rename, drop -MSWin32       -> <PRODUCT>-<VERSION>.cpio.Z
write <NEINAME>_nei.specification
tar -tf to verify           -> manifest, macro jar, ksh, template census
```

---

## 4. Portability: why paths were the whole problem

The old `make-cpioz.ps1` hard-coded three machine-specific paths. Worse, one of
them was *load-bearing by accident*:

```powershell
$SdkBin  = 'C:\Users\parmahaj\Documents\InstantLinkNEISDK19\bin'    # no spaces
$jarExe  = 'C:\Program Files\Eclipse Adoptium\jdk-8.0.332.9-hotspot\bin\jar.exe'
```

That SDK path has **no spaces in it**, which turns out to matter enormously.

`installer.exe` builds shell command strings and hands them to `cmd.exe`
**unquoted** — both for copying your files and for copying its own
`install_release` helper out of the SDK directory. So a space anywhere in the
SDK path produces:

```
copy C:\Users\x\OneDrive - Nokia\...\cpiozExecuter\install_release  C:\...
failed: The filename, directory name, or volume label syntax is incorrect.
```

Nokia laptops redirect Documents into `OneDrive - Nokia`, so *any* colleague
cloning this repo hits that immediately. The SDK User's Guide (§13) states the
constraint for the project path — "Ensure that the workspace path does not have
spaces" — but it applies to the tools directory just as hard.

`NeiEnv.ps1` therefore resolves each tool at run time, and `make-cpioz.ps1`
**stages both the project and the SDK binaries into a space-free root**
(`C:\ilpkg` by default) whenever either path has a space or would bust MAX_PATH.

Resolution order, all overridable:

| Tool | Order |
|---|---|
| SDK bin | `-SdkBin` → `$env:NEISDK_BIN` → `<repo>\cpiozExecuter` → `%JENKINS_HOME%\..\cpiozExecuter` → `*NEISDK*\bin` under the profile / OneDrive / `C:\` |
| JDK | `-JavaHome` → `$env:NEI_JAVA_HOME` → `$env:JAVA_HOME` → `<repo>\java\jdk-8*` → Adoptium/Java/Corretto → `jar.exe` on PATH |
| Maven | `-MvnCmd` → `$env:NEI_MVN` → `mvn` on PATH → `<repo>\maven\apache-maven-*` → `MAVEN_HOME` |
| Work root | `-WorkRoot` → `$env:NEI_WORK_ROOT` → `C:\ilpkg` |

**A colleague needs no SDK install.** `cpiozExecuter\` — the eight files the
packaging actually uses — is committed to this repo, and is a byte-for-byte copy
of the SDK's `bin\`. A JDK 8 and Maven are the only real prerequisites.

### This machine, for reference

```
SDK          C:\Users\parmahaj\OneDrive - Nokia\Documents\InstantLinkNEISDK19
SDK bin      ...\InstantLinkNEISDK19\bin           (or <repo>\cpiozExecuter)
Eclipse      ...\InstantLinkNEISDK19\eclipse\eclipse.exe
SDK plugin   ...\eclipse\dropins\com.comptel.neisdk\plugins\com.comptel.neisdk-19.0.0.jar
JDK 8        C:\Program Files\Eclipse Adoptium\jdk-8.0.332.9-hotspot
Maven        C:\Program Files\apache-maven-3.0.5\bin\mvn.bat
```

Nothing above is baked into the scripts — `-ShowEnv` prints whatever the current
machine resolves to.

---

## Known failure modes

Each of these was hit and diagnosed while building this toolchain.

**`&` (or space, `|`, `<`, `>`, `^`, `%`) in a packaged filename — fatal.**
`installer.exe` copies unquoted via `cmd.exe`, so `&` splits the command:

```
'_TG_MODIFICATION_IN_ISBC_validation-rules.yaml' is not recognized as an
internal or external command
ERROR: Unable to copy source file to target
```

Caught in preflight now, naming the file. Fix by renaming in
`src\main\resources\` and updating whatever looks it up by name.

**`The handle could not be opened during redirection of handle 1.`**
`installer.exe` shells out to `listdir | cpio -o > archive.cpio` for the archive
step, and that nested redirect fails whenever `cmd` cannot duplicate the
installer's own handle 1:

```
The handle could not be opened during redirection of handle 1.
ERROR: Unable to create the release archive ...
```

It presents as maddeningly intermittent — the same command succeeds from one
shell and fails from the next. Measured on this SDK: launching via
`Start-Process -NoNewWindow` (inherited handle) fails sometimes; launching with
a private console (`-WindowStyle Hidden`) fails *and* swallows the diagnostic,
which is worse. Launching through `cmd.exe` with a plain on-disk file redirect
is reliable, and is what the script now does — the same shape the compress step
has always used.

**A Word document open under `src\main\resources\` — fatal to `mvn`.**
Word takes an exclusive lock that blocks even shared reads, so the
maven-resources plugin aborts:

```
Failed to execute goal ...:resources ... SBC_19_..._FunctionalSpec.docx
(The process cannot access the file because it is being used by another process)
```

Note `mvn clean` has already emptied `target\` by then, so the project is left
un-built. Close the document and re-run. Authoring `.docx` specs *inside*
`src\main\resources\templates\` is the underlying smell — they are not packaged
(the packinglist installs `*.yaml`), so they only exist to break builds.

**MAX_PATH — silent data loss.** The installer stages into
`<bin>\<pid>.installer.tmp\<REL>\sas\bin\macro_server\java\...`. Past 260
characters `cpio` prints `No such file or directory`, **drops that file**, and
the installer still exits 0. This once shipped a package missing a jsonTemplate
at a path length of exactly 260. The script measures the worst case up front,
relocates, and greps the installer log for drops as a backstop.

**`compress` without `-f` produces nothing.** It refuses to write output larger
than its input, and a jar-heavy archive does not shrink under LZW (measured
−0.31% on FILECR). Without `-f`: no `.Z`, no clear error.

**UAC.** `installer.exe` trips Windows' installer-detection heuristic purely
because of its filename and refuses to start unelevated. It does not need admin.
`__COMPAT_LAYER=RUNASINVOKER` suppresses it — the same thing the SDK's
`ProjectPackager.executeInstaller` and the NEI packager's `PackageCpioz` do.

**Benign noise in the installer log, safely ignored:**
- `cpio: blank line ignored` — trailing newlines in `.packinglist`
- `JAVA_F~1.0 - The process cannot access the file` — the installer's own
  compression step failing, which is why compression is done as a separate step
- `Staging area removal failed!`
- `INFO : installfile ../config/error_codes.txt` — matches a naive
  case-insensitive `ERROR` grep; the script uses `-cmatch`

---

## Relationship to the Jenkins pipeline

The Jenkins jobs call a Java equivalent, `nei-packager-cli`:

```bat
java -jar <packager>.jar --PROJECT_ROOT "%WORKSPACE%" ^
     --NEI_SDK_BIN "%JENKINS_HOME%\..\cpiozExecuter" ^
     --cpioVersion "%cpioVersion%" --scriptName package
```

That already takes its paths as arguments, so it is portable in the same sense.
It is the leaner of the two: it does not validate packinglist sources, does not
check MAX_PATH or filename characters, and does not verify the finished archive.
`make-cpioz.ps1 -Version <v>` is equivalent to `--cpioVersion <v>` and adds all
of the above, so it is the better choice for a developer working locally and a
reasonable replacement for the Jenkins build step.
