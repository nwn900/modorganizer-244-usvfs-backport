[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetVersion,

    [Parameter(Mandatory = $true)]
    [string]$MobRef,

    [Parameter(Mandatory = $true)]
    [string]$MoBranch,

    [Parameter(Mandatory = $true)]
    [string]$UserBranch,

    [Parameter(Mandatory = $true)]
    [string]$UserOrg,

    [Parameter(Mandatory = $true)]
    [string]$UsvfsRef
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host "[build-backport] $Message"
}

function Set-AsciiContent([string]$Path, [string]$Content) {
    Set-Content -LiteralPath $Path -Value $Content -Encoding ascii
}

function Replace-InFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Needle,

        [Parameter(Mandatory = $true)]
        [string]$Replacement
    )

    $content = Get-Content -LiteralPath $Path -Raw
    if (-not $content.Contains($Needle)) {
        throw "Failed to patch $Path"
    }

    $content = $content.Replace($Needle, $Replacement)
    Set-AsciiContent -Path $Path -Content $content
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Script,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & $Script
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage (exit code $LASTEXITCODE)"
    }
}

function Invoke-Mob {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MobExe,

        [Parameter(Mandatory = $true)]
        [string]$IniPath,

        [Parameter(Mandatory = $true)]
        [string]$Prefix,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $MobExe --ini $IniPath --destination $Prefix @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "mob failed while running: $($Arguments -join ' ')"
    }
}

function Find-ModOrganizerExe([string]$InstallRoot) {
    $candidates = @(
        (Join-Path $InstallRoot "bin\ModOrganizer.exe"),
        (Join-Path $InstallRoot "ModOrganizer.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $fallback = Get-ChildItem -LiteralPath $InstallRoot -Filter "ModOrganizer.exe" -Recurse -File |
        Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    throw "ModOrganizer.exe not found under $InstallRoot"
}

function New-ChecksumsFile([string]$Root, [string]$ZipPath, [string]$OutFile) {
    $lines = New-Object System.Collections.Generic.List[string]

    Get-ChildItem -LiteralPath $Root -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($Root.Length + 1).Replace("\", "/")
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $lines.Add("$hash *$relative")
        }

    $zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines.Add("$zipHash *$([System.IO.Path]::GetFileName($ZipPath))")

    Set-AsciiContent -Path $OutFile -Content ($lines -join "`r`n")
}

function Get-ArchiveWithFallback {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutFile,

        [Parameter(Mandatory = $true)]
        [string[]]$Urls
    )

    $validate = {
        param([string]$Path)
        if (-not (Test-Path -LiteralPath $Path)) {
            return $false
        }

        & 7z.exe t -bd $Path *> $null
        return ($LASTEXITCODE -eq 0)
    }

    if (Test-Path -LiteralPath $OutFile) {
        if (& $validate $OutFile) {
            return
        }

        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }

    foreach ($url in $Urls) {
        try {
            Invoke-WebRequest -Uri $url -MaximumRedirection 5 -OutFile $OutFile
            if ((Get-Item -LiteralPath $OutFile).Length -gt 0 -and (& $validate $OutFile)) {
                return
            }
        } catch {
            Write-Warning ("Failed to download {0}: {1}" -f $url, $_.Exception.Message)
        }

        if (Test-Path -LiteralPath $OutFile) {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        }
    }

    throw "Unable to seed archive $OutFile"
}

$workspace = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$runnerTemp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { Join-Path $workspace ".runner-temp" }
$vsPath = if ($env:MO2_VS) { $env:MO2_VS } else { throw "MO2_VS is not set" }
$sdkVersion = if ($env:MO2_SDK) { $env:MO2_SDK } else { throw "MO2_SDK is not set" }
$qtInstall = if ($env:MO2_QT_INSTALL) { $env:MO2_QT_INSTALL } else { throw "MO2_QT_INSTALL is not set" }

$prefix = Join-Path $runnerTemp ("mo2-prefix-" + $TargetVersion.Replace(".", ""))
$mobRoot = Join-Path $runnerTemp ("mob-" + $TargetVersion.Replace(".", ""))
$iniPath = Join-Path $runnerTemp ("ci-" + $TargetVersion.Replace(".", "") + ".mob.ini")
$outputDir = Join-Path $workspace "ci-output"
$overlayDir = Join-Path $outputDir "MO2 compiled"
$zipName = "ModOrganizer-$TargetVersion-backport-usvfs-fixes-overlay.zip"
$zipPath = Join-Path $outputDir $zipName
$smokePath = Join-Path $outputDir "SMOKE_TEST_RESULTS.txt"
$shaPath = Join-Path $outputDir "SHA256SUMS.txt"
$mobLogPath = Join-Path $prefix "mob-ci.log"
$msbuild = Join-Path $vsPath "MSBuild\Current\Bin\MSBuild.exe"

Write-Step "Preparing output directories"
foreach ($path in @($prefix, $mobRoot, $outputDir)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}
New-Item -ItemType Directory -Path $prefix -Force | Out-Null
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Write-Step "Cloning mob at $MobRef"
Invoke-Checked -FailureMessage "failed to clone mob" -Script {
    git clone https://github.com/ModOrganizer2/mob $mobRoot
}
Invoke-Checked -FailureMessage "failed to checkout mob ref" -Script {
    git -C $mobRoot checkout $MobRef
}

$modTask = Join-Path $mobRoot "src\tasks\modorganizer.cpp"
$modTaskContent = Get-Content -LiteralPath $modTask -Raw
if ($modTaskContent -notmatch 'BUILD_TESTING') {
    $line = ($modTaskContent -split "`r?`n" | Where-Object { $_ -like '*.root(root));*' } | Select-Object -First 1)
    if (-not $line) {
        throw "Could not locate cmake chain terminator in $modTask"
    }

    $replacement = @(
        '                .def("BUILD_TESTING", "OFF")'
        $line
    ) -join "`r`n"
    Replace-InFile -Path $modTask -Needle $line -Replacement $replacement
}

Write-Step "Bootstrapping mob"
Push-Location $mobRoot
try {
    Invoke-Checked -FailureMessage "mob bootstrap failed" -Script {
        & (Join-Path $mobRoot "bootstrap.ps1")
    }
} finally {
    Pop-Location
}

$mobExe = Join-Path $mobRoot "mob.exe"
if (-not (Test-Path -LiteralPath $mobExe)) {
    throw "mob.exe not found at $mobExe"
}

$ini = @(
    "[global]"
    "output_log_level   = 4"
    "file_log_level     = 5"
    "log_file           = $mobLogPath"
    "ignore_uncommitted = true"
    ""
    "[task]"
    "mo_org        = ModOrganizer2"
    "mo_branch     = $MoBranch"
    "mo_fallback   = master"
    "no_pull       = false"
    "ignore_ts     = false"
    "revert_ts     = false"
    "git_shallow   = true"
    ""
    "[modorganizer:task]"
    "mo_org    = $UserOrg"
    "mo_branch = $UserBranch"
    ""
    "[organizer:task]"
    "mo_org    = $UserOrg"
    "mo_branch = $UserBranch"
    ""
    "[installer:task]"
    "enabled = false"
    ""
    "[translations:task]"
    "enabled = false"
    ""
    "[versions]"
    "sdk   = $sdkVersion"
    "usvfs = $UsvfsRef"
    ""
    "[paths]"
    "prefix     = $prefix"
    "qt_install = $qtInstall"
    "vs         = $vsPath"
) -join "`r`n"
Set-AsciiContent -Path $iniPath -Content $ini

$downloadsDir = Join-Path $prefix "downloads"
New-Item -ItemType Directory -Path $downloadsDir -Force | Out-Null

$sevenZipSeed = switch ($TargetVersion) {
    "2.5.2" {
        @{
            Name = "7z2405-src.7z"
            Urls = @(
                "https://master.dl.sourceforge.net/project/sevenzip/7-Zip/24.05/7z2405-src.7z?viasf=1",
                "https://downloads.sourceforge.net/project/sevenzip/7-Zip/24.05/7z2405-src.7z",
                "https://sourceforge.net/projects/sevenzip/files/7-Zip/24.05/7z2405-src.7z/download"
            )
        }
    }
    default {
        @{
            Name = "7z2301-src.7z"
            Urls = @(
                "https://master.dl.sourceforge.net/project/sevenzip/7-Zip/23.01/7z2301-src.7z?viasf=1",
                "https://www.7-zip.org/a/7z2301-src.7z",
                "https://downloads.sourceforge.net/project/sevenzip/7-Zip/23.01/7z2301-src.7z",
                "https://sourceforge.net/projects/sevenzip/files/7-Zip/23.01/7z2301-src.7z/download"
            )
        }
    }
}

Write-Step "Seeding archived 7-Zip source package"
Get-ArchiveWithFallback -OutFile (Join-Path $downloadsDir $sevenZipSeed.Name) -Urls $sevenZipSeed.Urls

Write-Step "Fetching full build workspace with mob"
Invoke-Mob -MobExe $mobExe -IniPath $iniPath -Prefix $prefix -Arguments @("build", "--no-build-task")

$usvfsRoot = Join-Path $prefix "build\usvfs"
if (-not (Test-Path -LiteralPath $usvfsRoot)) {
    throw "usvfs source not found at $usvfsRoot"
}

Write-Step "Patching usvfs source for $TargetVersion"
Invoke-Checked -FailureMessage "prepare-usvfs-source.ps1 failed" -Script {
    & (Join-Path $workspace "ASSEMBLER\prepare-usvfs-source.ps1") `
        -MO2Version $TargetVersion `
        -SourceDir $usvfsRoot
}

Write-Step "Building all enabled tasks with mob"
Invoke-Mob -MobExe $mobExe -IniPath $iniPath -Prefix $prefix -Arguments @("build", "--no-fetch-task")

$installRoot = Join-Path $prefix "install"
$modOrganizerExe = Find-ModOrganizerExe -InstallRoot $installRoot
Write-Step "Found ModOrganizer.exe at $modOrganizerExe"

$env:QTWEBENGINE_DISABLE_SANDBOX = "1"
$launchSummary = "FAIL"

Write-Step "Running Mod Organizer launch smoke test"
$moProcess = $null
try {
    $moProcess = Start-Process -FilePath $modOrganizerExe -ArgumentList "--pick", "--multiple" `
        -WorkingDirectory (Split-Path -Path $modOrganizerExe -Parent) -PassThru
    Start-Sleep -Seconds 20

    if ($moProcess.HasExited) {
        throw "ModOrganizer exited early with code $($moProcess.ExitCode)"
    }

    $launchSummary = "PASS (process stayed alive for 20s)"
} finally {
    if ($moProcess -and -not $moProcess.HasExited) {
        Stop-Process -Id $moProcess.Id -Force -ErrorAction SilentlyContinue
        Wait-Process -Id $moProcess.Id -ErrorAction SilentlyContinue
    }
}

$buildRoot = Join-Path $prefix "build"
$boostRoot = Get-ChildItem -LiteralPath $buildRoot -Directory -Filter "boost_*" | Select-Object -First 1
if ($boostRoot) {
    $env:BOOST_PATH = $boostRoot.FullName
}
$gtestRoot = Join-Path $buildRoot "googletest"
if (Test-Path -LiteralPath $gtestRoot) {
    $env:GTEST_PATH = $gtestRoot
}

$usvfsSolution = Join-Path $usvfsRoot "vsbuild\usvfs.sln"
if (-not (Test-Path -LiteralPath $msbuild)) {
    throw "MSBuild.exe not found at $msbuild"
}

Write-Step "Building usvfs ReleaseTest binaries for x86"
& $msbuild $usvfsSolution -m -noLogo `
    -p:Configuration=ReleaseTest `
    -p:Platform=x86 `
    -p:UseMultiToolTask=true `
    -p:EnforceProcessCountAcrossBuilds=true
if ($LASTEXITCODE -ne 0) {
    throw "usvfs ReleaseTest x86 build failed"
}

Write-Step "Building usvfs ReleaseTest binaries for x64"
& $msbuild $usvfsSolution -m -noLogo `
    -p:Configuration=ReleaseTest `
    -p:Platform=x64 `
    -p:UseMultiToolTask=true `
    -p:EnforceProcessCountAcrossBuilds=true
if ($LASTEXITCODE -ne 0) {
    throw "usvfs ReleaseTest x64 build failed"
}

$testBin = Join-Path $usvfsRoot "test\bin"
$tvfsExe = Join-Path $testBin "tvfs_test_x64.exe"
$runnerExe = Join-Path $testBin "usvfs_test_runner_x64.exe"
if (-not (Test-Path -LiteralPath $tvfsExe)) {
    throw "tvfs_test_x64.exe not found at $tvfsExe"
}
if (-not (Test-Path -LiteralPath $runnerExe)) {
    throw "usvfs_test_runner_x64.exe not found at $runnerExe"
}

Write-Step "Running tvfs_test_x64.exe"
& $tvfsExe
if ($LASTEXITCODE -ne 0) {
    throw "tvfs_test_x64.exe failed"
}

Write-Step "Running usvfs_test_runner_x64.exe"
& $runnerExe
if ($LASTEXITCODE -ne 0) {
    throw "usvfs_test_runner_x64.exe failed"
}

Write-Step "Preparing release-style overlay artifact"
New-Item -ItemType Directory -Path $overlayDir -Force | Out-Null
Copy-Item -Path (Join-Path $installRoot "*") -Destination $overlayDir -Recurse

if (Test-Path -LiteralPath $zipPath) {
    Remove-Item -LiteralPath $zipPath -Force
}

Push-Location $overlayDir
try {
    & 7z.exe a -tzip $zipPath .\* | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "7z failed to create overlay zip"
    }
} finally {
    Pop-Location
}

New-ChecksumsFile -Root $overlayDir -ZipPath $zipPath -OutFile $shaPath

$report = @(
    "Target version: $TargetVersion"
    "Repository: $UserOrg/modorganizer-244-usvfs-backport"
    "Branch: $UserBranch"
    "Sibling branch: $MoBranch"
    "mob ref: $MobRef"
    "usvfs ref: $UsvfsRef"
    "Commit: $env:GITHUB_SHA"
    "Launch smoke: $launchSummary"
    "tvfs_test_x64.exe: PASS"
    "usvfs_test_runner_x64.exe: PASS"
)

if ($env:GITHUB_SERVER_URL -and $env:GITHUB_REPOSITORY -and $env:GITHUB_RUN_ID) {
    $report += "Workflow run: $($env:GITHUB_SERVER_URL)/$($env:GITHUB_REPOSITORY)/actions/runs/$($env:GITHUB_RUN_ID)"
}

Set-AsciiContent -Path $smokePath -Content ($report -join "`r`n")

if (Test-Path -LiteralPath $mobLogPath) {
    Copy-Item -LiteralPath $mobLogPath -Destination (Join-Path $outputDir "mob-ci.log") -Force
}

$usvfsLogs = Get-ChildItem -LiteralPath $testBin -Filter "*.log" -File -ErrorAction SilentlyContinue
if ($usvfsLogs) {
    $logOutDir = Join-Path $outputDir "usvfs-test-logs"
    New-Item -ItemType Directory -Path $logOutDir -Force | Out-Null
    foreach ($log in $usvfsLogs) {
        Copy-Item -LiteralPath $log.FullName -Destination (Join-Path $logOutDir $log.Name) -Force
    }
}

Write-Step "Build, smoke, and packaging flow completed"
