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

function Find-BoostRoot([string]$BuildRoot) {
    $candidates = @(
        Get-ChildItem -LiteralPath $BuildRoot -Directory -Filter "boost_*" -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
    )
    if ($candidates.Count -eq 0) {
        return $null
    }

    $best = $candidates |
        ForEach-Object {
            $has32 = @(Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "lib32-msvc-*" -ErrorAction SilentlyContinue).Count -gt 0
            $has64 = @(Get-ChildItem -LiteralPath $_.FullName -Directory -Filter "lib64-msvc-*" -ErrorAction SilentlyContinue).Count -gt 0
            [PSCustomObject]@{
                Root  = $_
                Score = [int]$has32 + [int]$has64
            }
        } |
        Sort-Object @{ Expression = "Score"; Descending = $true }, @{ Expression = { $_.Root.Name }; Descending = $true } |
        Select-Object -First 1

    return $best.Root
}

function Install-FmtDependency([string]$BuildRoot) {
    $fmtRoot = Join-Path $BuildRoot "fmt"
    $fmtSource = Join-Path $BuildRoot "fmt-src"
    $fmtBuild = Join-Path $fmtRoot "vsbuild"
    $fmtInstall = Join-Path $fmtRoot "build"

    if (Test-Path -LiteralPath (Join-Path $fmtInstall "lib\cmake\fmt\fmt-config.cmake")) {
        return $fmtRoot
    }

    Remove-Item -LiteralPath $fmtRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fmtSource -Recurse -Force -ErrorAction SilentlyContinue

    Write-Step "Cloning fmt 11.1.4"
    Invoke-Checked -FailureMessage "failed to clone fmt" -Script {
        git clone --branch 11.1.4 --depth 1 https://github.com/fmtlib/fmt $fmtSource
    }

    Write-Step "Configuring fmt"
    Invoke-Checked -FailureMessage "failed to configure fmt" -Script {
        & cmake.exe -S $fmtSource -B $fmtBuild `
            -G "Visual Studio 17 2022" `
            -A x64 `
            -DCMAKE_INSTALL_PREFIX="$fmtInstall" `
            -DFMT_DOC=OFF `
            -DFMT_TEST=OFF
    }

    Write-Step "Building and installing fmt"
    Invoke-Checked -FailureMessage "failed to build/install fmt" -Script {
        & cmake.exe --build $fmtBuild --config Release --target install -- /m
    }

    return $fmtRoot
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

function Find-BuildPythonExe([string]$Prefix) {
    $preferred = Get-ChildItem -LiteralPath (Join-Path $Prefix "build") -Filter "python.exe" -Recurse -File |
        Where-Object { $_.FullName -like '*PCBuild\amd64\python.exe' } |
        Select-Object -First 1
    if ($preferred) {
        return $preferred.FullName
    }

    $fallback = Get-ChildItem -LiteralPath (Join-Path $Prefix "build") -Filter "python.exe" -Recurse -File |
        Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    throw "Unable to locate fetched python.exe under $Prefix"
}

function Ensure-BuildPythonPip([string]$Prefix, [string]$RunnerTemp) {
    $pythonExe = Find-BuildPythonExe -Prefix $Prefix
    & $pythonExe -m pip --version *> $null
    if ($LASTEXITCODE -eq 0) {
        return
    }

    $getPip = Join-Path $RunnerTemp "get-pip.py"
    Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $getPip
    & $pythonExe $getPip
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install pip into $pythonExe"
    }
}

function Find-UibaseLogPath([string]$Prefix) {
    $candidates = @(
        (Join-Path $Prefix "build\modorganizer_super\uibase\src\log.cpp"),
        (Join-Path $Prefix "build\uibase\src\log.cpp")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $fallback = Get-ChildItem -LiteralPath (Join-Path $Prefix "build") -Filter "log.cpp" -Recurse -File |
        Where-Object { $_.FullName -like '*\uibase\src\log.cpp' } |
        Select-Object -First 1
    if ($fallback) {
        return $fallback.FullName
    }

    return $null
}

function Patch-UibaseLoggingCompatibility([string]$Prefix) {
    $logPath = Find-UibaseLogPath -Prefix $Prefix
    if (-not $logPath) {
        return
    }

    $content = Get-Content -LiteralPath $logPath -Raw
    $updated = $content
    $updated = [regex]::Replace(
        $updated,
        '(?m)^(\s*)e\.message\s*=\s*std::string\(m\.payload\);\s*$',
        '$1e.message.assign(m.payload.data(), m.payload.size());')
    $updated = [regex]::Replace(
        $updated,
        '(?m)^(\s*)e\.formattedMessage\s*=\s*std::string\(formatted\);\s*$',
        '$1e.formattedMessage.assign(formatted.begin(), formatted.end());')

    if ($updated -ne $content) {
        Set-AsciiContent -Path $logPath -Content $updated
        Write-Step "Patched uibase logging compatibility"
    }
}

function Patch-MobInterruptCleanup([string]$MobRoot) {
    $fsUtil = Join-Path $MobRoot "src\utility\fs.cpp"
    $content = Get-Content -LiteralPath $fsUtil -Raw
    if ($content -match 'Sleep\(100\)') {
        return
    }

    $needle = @'
    void interruption_file::remove()
    {
        cx_.trace(context::interruption, "removing interrupt file {}", file());
        op::delete_file(cx_, file());
    }
'@

    $replacement = @'
    void interruption_file::remove()
    {
        cx_.trace(context::interruption, "removing interrupt file {}", file());

        std::error_code ec;
        for (int attempt = 0; attempt < 10; ++attempt) {
            if (!fs::exists(file())) {
                return;
            }

            fs::remove(file(), ec);
            if (!ec) {
                return;
            }

            if (attempt == 9) {
                break;
            }

            cx_.trace(context::fs,
                      "delete of interrupt file {} failed on attempt {}, {}; retrying",
                      file(), attempt + 1, ec.message());

            ec.clear();
            Sleep(100);
        }

        cx_.warning(context::fs,
                    "can't delete interrupt file {}; leaving it in place",
                    file());
    }
'@

    Replace-InFile -Path $fsUtil -Needle $needle -Replacement $replacement
}

function Get-DependencySnapshots([string]$Version) {
    switch ($Version) {
        "2.5.0" {
            return [ordered]@{
                "cmake_common"                   = "46fe31997a7afd182a40c2e98b5d5813ac8ffce3"
                "uibase"                         = "e1b3012c241a573d04447201c0241dab3d97474d"
                "archive"                        = "8c3834a8f905f266c01e199657ab66d7073d5b1b"
                "lootcli"                        = "987eed53c41fb1c26ac949ded9da4e84d042b1b0"
                "esptk"                          = "1857c566a5c54e88fd0e00ec3578cb1f3f8fcde7"
                "bsatk"                          = "37052a8c321d402edf0b21321c36e2fb900857e8"
                "nxmhandler"                     = "9876f57cd508c56028ec16ba0967ef1ead6fc47d"
                "helper"                         = "ce072e46a781bfb3b1e3ba20b32df81f7486cdb4"
                "githubpp"                       = "308c00967d1237e1ff8589f8aa36ad8b016a662a"
                "game_gamebryo"                  = "de53b9256d0e82d179812c138d04979ad7d471ce"
                "bsapacker"                      = "70eca305d817f392c276bf5f25c9a82a4d4ac272"
                "preview_bsa"                    = "c4f79927bcad35106860fa57ae4ac869ec4f8e29"
                "game_oblivion"                  = "e0a1ea31124b472277f9e55ea012848c9c7a9d7b"
                "game_nehrim"                    = "19a57cd3c0688c3ae0d90a4bc85d6fc54d24294e"
                "game_fallout3"                  = "662f6993ad94395c8259a8e75cf80900a16909da"
                "game_fallout4"                  = "33e09cae135515c70c3bb079a56bd4984e78632e"
                "game_fallout4vr"                = "76e285cddb9512f027dfec49d7e31fa6d6b33a03"
                "game_fallout76"                 = "41cd9409d1c654bdc95a1ed7bc1403f42c137d7a"
                "game_falloutnv"                 = "41b906539739c1306909f425d586dd04be184980"
                "game_morrowind"                 = "257a1032f38f979b526dee6dd18eb67422c8394e"
                "game_skyrim"                    = "c01f48e22a0419f2d468467b8afe14a4953f6431"
                "game_skyrimse"                  = "0dbe98bbb2deddaf8f97e831b485c96d0026cc2a"
                "game_skyrimvr"                  = "c5946daee7a561477669efbeef71cb66ef669120"
                "game_starfield"                 = "6e72e7c0f5216f96abbdb45cdd024e4d2145524e"
                "game_ttw"                       = "9227a6e914714336634beb329cfbfbbcb428bc18"
                "game_enderal"                   = "e48bb7595922ca4295ca7c539eb8d6917a0bd798"
                "game_enderalse"                 = "b7ba2bf7f6036eba5fc2d357d74ac1efc5f89b26"
                "tool_inieditor"                 = "acd9dae0a3e855493bef29aa64e2e39362d107c8"
                "tool_inibakery"                 = "09a15e37170639f038ac81f7555ab3f2b39407e8"
                "preview_base"                   = "1bfa64842e018f912c4627a48bd545067e5d4310"
                "diagnose_basic"                 = "51099bed28f2cf33b70fc0d4d93ca3742129634e"
                "check_fnis"                     = "e68b6b77f0485a2b4d4d9a53b8616877548ba812"
                "installer_bain"                 = "3c673c171e5b8992801ef369a4cacc311e8998e2"
                "installer_manual"               = "a9f97dd619751cbc67e5a3fa6ee2c70f0bb4b23a"
                "installer_bundle"               = "6d89f9da86134ad16a42872da71091f6d1ffc702"
                "installer_quick"                = "74c2338de92b8f7a3e134cba89b7ce5adbf971d7"
                "installer_fomod"                = "66b7e50eed1d1a1a8e896ece1d5befd7cdfff4eb"
                "installer_fomod_csharp"         = "280ee55e9935d600bf1ea66fbe6bf23037da7119"
                "installer_omod"                 = "c1895b0eab285ff1f1290159f942dfb292e626b6"
                "installer_wizard"               = "a0ca112ed0dddde50793afc011a0d462606b4636"
                "bsa_extractor"                  = "767a305e66b63b57fafc9e327eaf70ff860e4db3"
                "plugin_python"                  = "ebede37865f252ead84ffbcc8a0d6a3063a5da6b"
                "tool_configurator"              = "0587e54455a59234f4bfecd9f6c9acad1443233c"
                "fnistool"                       = "c676913a34fcfe1a8741fdaf3569adc8bf95dcbc"
                "basic_games"                    = "4d7a7cc280ca84a6040f30ee4be602d280cfed1a"
                "script_extender_plugin_checker" = "d2c028d240643ba1955cc01f3955311711695ad3"
                "form43_checker"                 = "a0b03094f52d5ff44bb85f1f0ab536c1a783ca60"
                "preview_dds"                    = "eb0d408b1d694cd0f3a1eb367713613268d0630a"
            }
        }
        "2.5.2" {
            return [ordered]@{
                "cmake_common"                   = "8abcb29e0810e07f9a464458264b904e9017e633"
                "uibase"                         = "44201d70f7c1a6cda55da86458dc5b8b4665c47b"
                "archive"                        = "a13e224c17fb0f2210305cb3dcc442f25f2fd58c"
                "lootcli"                        = "460a29d3fa4c260db192c18741ac8dd21a549ae3"
                "esptk"                          = "9d9708bc827fdfa9019e24e0bdd3ed7d35d1553e"
                "bsatk"                          = "2882fd352bdd97d4bc67bedafeba6d55c269cdeb"
                "nxmhandler"                     = "9876f57cd508c56028ec16ba0967ef1ead6fc47d"
                "helper"                         = "ce072e46a781bfb3b1e3ba20b32df81f7486cdb4"
                "githubpp"                       = "308c00967d1237e1ff8589f8aa36ad8b016a662a"
                "game_gamebryo"                  = "0076e5431bd7fffb4977c724a92027e6e4f11f2e"
                "bsapacker"                      = "f78080df28b63801f608edc1f130d399a8110125"
                "preview_bsa"                    = "567d8ac549824cff3d9122b671b62f7471bd02a4"
                "game_oblivion"                  = "c4589dd80a89b23aff9501c845991dacb3e454b5"
                "game_nehrim"                    = "53800b4c32525579729493e532d65f2f487c0d43"
                "game_fallout3"                  = "825995cbb74e8cdafde3686a478585dfa5bf32f5"
                "game_fallout4"                  = "1e1371792a357deef6f7699625a849bc808a1806"
                "game_fallout4vr"                = "50282b37fd0c9ce8f457a4212ca4b688a97e78b6"
                "game_fallout76"                 = "960493fc41a1b78824ea25c203fbc532749b579e"
                "game_falloutnv"                 = "52ea004207cd3834d65290b2b0e34f7132858982"
                "game_morrowind"                 = "e94c25703a07a13a45565a4c80672572f5a14e51"
                "game_skyrim"                    = "9eb2ef88eedc5a8bc65ee7d060af4bd84ebd63aa"
                "game_skyrimse"                  = "82ac42f83f717b4884c8c551cb67b545e15177bc"
                "game_skyrimvr"                  = "5c6fd594a46b81f12d348d8e45571387babfd6b8"
                "game_starfield"                 = "14a5cc3817eee727437d7f84c0ff01148a576d23"
                "game_ttw"                       = "6cae291a4693fd206c456a2fad1d3808f2e87dfb"
                "game_enderal"                   = "7ad95a082d216adf92d99c501f38cc8c8b286261"
                "game_enderalse"                 = "ba9e90fb7182d0d72c2c2537b4cedac36fc9db6b"
                "tool_inieditor"                 = "acd9dae0a3e855493bef29aa64e2e39362d107c8"
                "tool_inibakery"                 = "de678f72ea8bf13c72456644d81da5b93c82274d"
                "preview_base"                   = "f6c7a516d342e09da48f07d8d6203a0576ad583a"
                "diagnose_basic"                 = "7fc98c5d4e2f35baceb98f19ded145b89fbd68a3"
                "check_fnis"                     = "e68b6b77f0485a2b4d4d9a53b8616877548ba812"
                "installer_bain"                 = "d5442056f812121fb62f680214687064cffba7b9"
                "installer_manual"               = "52d81792fa2f22a9fa9711b5d502263f5f4531cd"
                "installer_bundle"               = "eeef5840df81a971795ec7a1442555c1459aa627"
                "installer_quick"                = "ff7e4cb91754669a7f3c42d8aa7ae9913f8c7255"
                "installer_fomod"                = "fc263f2d923c704b4853c11ed4f8b8cf3920f30d"
                "installer_fomod_csharp"         = "4928105afc480e105bbd2318e8d1a63a641b8e45"
                "installer_omod"                 = "9d59d545126d26bb10b36760c86029d859575f28"
                "installer_wizard"               = "e510e1c3eda48086e44dcd9185da2d4abd9a5701"
                "bsa_extractor"                  = "8acaabb3c11562979a9dba10c5d18b7a33452ff9"
                "plugin_python"                  = "e11d5ec00d45d971f65d13b1d48b08397a2b4ff9"
                "tool_configurator"              = "0587e54455a59234f4bfecd9f6c9acad1443233c"
                "fnistool"                       = "c676913a34fcfe1a8741fdaf3569adc8bf95dcbc"
                "basic_games"                    = "e88d2d2d1546619cd2e6f17d071cdb50bab99866"
                "script_extender_plugin_checker" = "d2c028d240643ba1955cc01f3955311711695ad3"
                "form43_checker"                 = "2b1e37535326c9a688075ffbed59c4d2cb01a77a"
                "preview_dds"                    = "028af7e9a1cba5a7cdca4181be547e137b8cf621"
            }
        }
        default {
            return [ordered]@{}
        }
    }
}

function Pin-DependencySnapshots([string]$Prefix, [string]$Version) {
    $snapshots = Get-DependencySnapshots -Version $Version
    if ($snapshots.Count -eq 0) {
        return
    }

    $superRoot = Join-Path $Prefix "build\modorganizer_super"
    foreach ($entry in $snapshots.GetEnumerator()) {
        $repoPath = Join-Path $superRoot $entry.Key
        if (-not (Test-Path -LiteralPath $repoPath)) {
            throw "Expected dependency repository at $repoPath"
        }

        Write-Step ("Pinning {0} to {1}" -f $entry.Key, $entry.Value.Substring(0, 12))
        & git -C $repoPath checkout --detach $entry.Value
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to pin $($entry.Key) to $($entry.Value)"
        }
    }
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
if (($modTaskContent -notmatch 'BUILD_TESTING') -or ($modTaskContent -notmatch 'FMT_ROOT')) {
    $line = ($modTaskContent -split "`r?`n" | Where-Object { $_ -like '*.root(root));*' } | Select-Object -First 1)
    if (-not $line) {
        throw "Could not locate cmake chain terminator in $modTask"
    }

    $injections = New-Object System.Collections.Generic.List[string]
    if ($modTaskContent -notmatch 'BUILD_TESTING') {
        $injections.Add('                .def("BUILD_TESTING", "OFF")')
    }
    if ($modTaskContent -notmatch 'FMT_ROOT') {
        $injections.Add('                .def("FMT_ROOT", conf().path().build() / "fmt")')
    }

    $replacement = @(
        $injections
        $line
    ) -join "`r`n"
    Replace-InFile -Path $modTask -Needle $line -Replacement $replacement
}

Write-Step "Patching mob interrupt cleanup for archive extraction races"
Patch-MobInterruptCleanup -MobRoot $mobRoot

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
    "git_shallow   = false"
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

$useModernMobSeeds = ($TargetVersion -eq "2.5.2") -or ($MobRef -eq "eba5bf4")

$sevenZipSeed = if ($useModernMobSeeds) {
    @{
        Name = "7z2405-src.7z"
        Urls = @(
            "https://master.dl.sourceforge.net/project/sevenzip/7-Zip/24.05/7z2405-src.7z?viasf=1",
            "https://downloads.sourceforge.net/project/sevenzip/7-Zip/24.05/7z2405-src.7z",
            "https://sourceforge.net/projects/sevenzip/files/7-Zip/24.05/7z2405-src.7z/download"
        )
    }
} else {
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

$explorerppSeed = if ($useModernMobSeeds) {
        @{
            Name = "explorerpp_x64.zip"
            Urls = @(
                "https://download.explorerplusplus.com/stable/1.4.0/explorerpp_x64.zip"
            )
        }
} else {
        @{
            Name = "explorer++_1.3.5_x64.zip"
            Urls = @(
                "https://master.dl.sourceforge.net/project/explorerplus/Explorer++/1.3.5/explorer++_1.3.5_x64.zip?viasf=1",
                "https://downloads.sourceforge.net/project/explorerplus/Explorer++/1.3.5/explorer++_1.3.5_x64.zip"
            )
        }
}

$bzip2Seed = @{
    Name = "bzip2-1.0.8.tar.gz"
    Urls = @(
        "https://gstreamer.freedesktop.org/src/mirror/bzip2/bzip2-1.0.8.tar.gz",
        "https://pub.sortix.org/mirror/bzip2/bzip2-1.0.8.tar.gz",
        "https://sourceware.mirror.garr.it/bzip2/bzip2-1.0.8.tar.gz",
        "https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz"
    )
}

Write-Step "Seeding archived 7-Zip source package"
Get-ArchiveWithFallback -OutFile (Join-Path $downloadsDir $sevenZipSeed.Name) -Urls $sevenZipSeed.Urls

Write-Step "Seeding archived Explorer++ package"
Get-ArchiveWithFallback -OutFile (Join-Path $downloadsDir $explorerppSeed.Name) -Urls $explorerppSeed.Urls

Write-Step "Seeding archived bzip2 source package"
Get-ArchiveWithFallback -OutFile (Join-Path $downloadsDir $bzip2Seed.Name) -Urls $bzip2Seed.Urls

Write-Step "Fetching python toolchain first"
Invoke-Mob -MobExe $mobExe -IniPath $iniPath -Prefix $prefix -Arguments @("build", "python", "--no-build-task")

Write-Step "Injecting pip into fetched python toolchain"
Ensure-BuildPythonPip -Prefix $prefix -RunnerTemp $runnerTemp

Write-Step "Fetching full build workspace with mob"
Invoke-Mob -MobExe $mobExe -IniPath $iniPath -Prefix $prefix -Arguments @("build", "--no-build-task")

Write-Step "Pinning Mod Organizer dependency snapshots"
Pin-DependencySnapshots -Prefix $prefix -Version $TargetVersion

Write-Step "Patching fetched uibase sources"
Patch-UibaseLoggingCompatibility -Prefix $prefix

$buildRoot = Join-Path $prefix "build"
$fmtRoot = Install-FmtDependency -BuildRoot $buildRoot
Write-Step "Using fmt root $fmtRoot"

$usvfsRoot = Join-Path $prefix "build\usvfs"
if (-not (Test-Path -LiteralPath $usvfsRoot)) {
    throw "usvfs source not found at $usvfsRoot"
}

$prepareUsvfsArgs = @{
    MO2Version = $TargetVersion
    SourceDir = $usvfsRoot
    Commit = $UsvfsRef
}
if ($TargetVersion -eq "2.5.0") {
    $boostRoot = Find-BoostRoot -BuildRoot (Join-Path $prefix "build")
    if (-not $boostRoot) {
        throw "Boost root not found under $prefix\build"
    }

    Write-Step "Using Boost root $($boostRoot.FullName) for usvfs preparation"
    $prepareUsvfsArgs.BoostPath = $boostRoot.FullName
}

Write-Step "Patching usvfs source for $TargetVersion"
Invoke-Checked -FailureMessage "prepare-usvfs-source.ps1 failed" -Script {
    & (Join-Path $workspace "ASSEMBLER\prepare-usvfs-source.ps1") @prepareUsvfsArgs
}

Write-Step "Building all enabled tasks with mob"
try {
    Invoke-Mob -MobExe $mobExe -IniPath $iniPath -Prefix $prefix -Arguments @("build", "--no-fetch-task")
} catch {
    $bsatkSln = Join-Path $prefix "build\modorganizer_super\bsatk\vsbuild\bsatk.sln"
    $previewBsaSln = Join-Path $prefix "build\modorganizer_super\preview_bsa\vsbuild\preview_bsa.sln"
    $bsatkLib = Join-Path $prefix "install\libs\bsatk.lib"
    $mobRecovered = $false

    if ((Test-Path -LiteralPath $bsatkSln) -and
        (Test-Path -LiteralPath $previewBsaSln) -and
        -not (Test-Path -LiteralPath $bsatkLib)) {
        Write-Step "bsatk.lib missing after mob failure; building bsatk.sln directly"
        & $msbuild $bsatkSln -m -noLogo -verbosity:minimal `
            -p:Configuration=RelWithDebInfo `
            -p:Platform=x64 `
            -p:PlatformToolset=v143 `
            -p:WindowsTargetPlatformVersion=$sdkVersion
        if (($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $bsatkLib)) {
            try {
                Write-Step "Retrying mob build after direct bsatk build"
                Invoke-Mob -MobExe $mobExe -IniPath $iniPath -Prefix $prefix -Arguments @("build", "--no-fetch-task")
                $mobRecovered = $true
            } catch {
                Write-Step "Mob retry after direct bsatk build still failed"
            }
        } else {
            Write-Step "Direct bsatk build exited with code $LASTEXITCODE"
        }
    }

    if (-not $mobRecovered -and (Test-Path -LiteralPath $previewBsaSln)) {
        Write-Step "Re-running preview_bsa.sln directly for diagnostics"
        & $msbuild $previewBsaSln -m -noLogo -verbosity:minimal `
            -p:Configuration=RelWithDebInfo `
            -p:Platform=x64 `
            -p:PlatformToolset=v143 `
            -p:WindowsTargetPlatformVersion=$sdkVersion
        Write-Step "Direct preview_bsa diagnostic build exited with code $LASTEXITCODE"
    }

    if (-not $mobRecovered) {
        throw
    }
}

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

$boostRoot = Find-BoostRoot -BuildRoot $buildRoot
if ($boostRoot) {
    $env:BOOST_PATH = $boostRoot.FullName
    Write-Step "Using Boost root $($boostRoot.FullName) for usvfs test builds"
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
