[CmdletBinding()]
param(
    [string]$MO2Version = '2.4.4',
    [string]$SourceDir,
    [string]$RepoUrl = 'https://github.com/ModOrganizer2/usvfs.git',
    [string]$Commit,
    [string]$BoostPath,
    [switch]$UseVcpkgBoost,
    [string]$VcpkgRoot = 'C:\vcpkg',
    [string]$Triplet = 'x64-windows-static'
)

if ([string]::IsNullOrWhiteSpace($SourceDir)) {
    $SourceDir = (Join-Path $PSScriptRoot "..\external\usvfs-mo2-v$MO2Version")
}
if ([string]::IsNullOrWhiteSpace($Commit)) {
    if ($MO2Version -eq '2.5.2') { $Commit = 'v0.5.0' }
    elseif ($MO2Version -eq '2.5.0') { $Commit = 'v0.5.0' }
    else { $Commit = '7368b25' }
}

$ErrorActionPreference = 'Stop'

function Write-Info([string]$Message) {
    Write-Host "[prepare-usvfs] $Message"
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Replace-RequiredText([string]$Text, [string]$Needle, [string]$Replacement, [string]$Description) {
    if (-not $Text.Contains($Needle)) {
        throw "Failed to patch $Description"
    }

    return $Text.Replace($Needle, $Replacement)
}

function Wrap-PreprocessorBlock([string]$Text, [string]$Block, [string]$Macro, [string]$NewLine) {
    $guarded = "#ifndef $Macro$NewLine$Block$NewLine#endif  // $Macro"
    if ($Text.Contains($guarded)) {
        return $Text
    }

    if (!$Text.Contains($Block)) {
        Write-Info "Warning: Expected block not found while wrapping with $Macro. Maybe removed in this version."
        return $Text
    }

    return $Text.Replace($Block, $guarded)
}

function Ensure-WholeFileMacroGuard([string]$Path, [string]$Macro) {
    $text = Get-Content -LiteralPath $Path -Raw
    if ($text -match "(?s)^\#ifndef $Macro\b") {
        return $text
    }

    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $text = "#ifndef $Macro$nl$nl$text$nl#endif  // $Macro$nl"
    Write-Utf8NoBom $Path $text
    return $text
}

function Get-AssemblyDefName([string]$Arch, [string]$MO2Version) {
    return "usvfs_{0}_v{1}.def" -f $Arch, $MO2Version.Replace('.', '')
}

function Get-AssemblerSourcePath([string]$ChildPath) {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "src\$ChildPath"))
}

function Get-VcpkgTripletForPlatform([string]$BaseTriplet, [string]$Platform) {
    $archPrefix = if ($Platform -eq 'x64') { 'x64' } else { 'x86' }

    if ($BaseTriplet -match '^(x86|x64)-') {
        return ($BaseTriplet -replace '^(x86|x64)-', "$archPrefix-")
    }

    return $BaseTriplet
}

function Get-BoostCompatLibRootName([string]$Platform, [string]$MO2Version) {
    $libSuffix = if ($Platform -eq 'x64') { '64' } else { '32' }
    $msvcVersion = if ($MO2Version -eq '2.4.4') { '14.2' } else { '14.3' }
    return "lib$($libSuffix)-msvc-$msvcVersion"
}

function Get-BoostLinkLibraries([string]$LibDir, [switch]$PreferStaticRuntime) {
    if (!(Test-Path $LibDir)) {
        return @()
    }

    $libraries = @(
        Get-ChildItem -LiteralPath $LibDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'boost_*.lib' -or $_.Name -like 'libboost_*.lib' } |
            Sort-Object Name -Unique |
            Select-Object -ExpandProperty Name
    )
    if ($libraries.Count -eq 0) {
        return @()
    }

    $bestByComponent = @{}
    foreach ($name in $libraries) {
        if ($name -match '^(?:lib)?boost_(.+?)-vc') {
            $component = $Matches[1].ToLowerInvariant()
        } else {
            $component = $name.ToLowerInvariant()
        }

        $priority = 4
        if ($name -like 'libboost_*.lib' -and $name -notmatch '-(?:s)?gd-') {
            if ($name -match '-s-') {
                $priority = if ($PreferStaticRuntime) { 0 } else { 1 }
            } else {
                $priority = if ($PreferStaticRuntime) { 1 } else { 0 }
            }
        } elseif ($name -like 'boost_*.lib' -and $name -notmatch '-(?:s)?gd-') {
            $priority = 2
        } elseif ($name -like 'libboost_*.lib') {
            $priority = 3
        }

        $current = $bestByComponent[$component]
        if (($null -eq $current) -or
            ($priority -lt $current.Priority) -or
            ($priority -eq $current.Priority -and $name -lt $current.Name)) {
            $bestByComponent[$component] = [PSCustomObject]@{
                Name = $name
                Priority = $priority
            }
        }
    }

    return @(
        $bestByComponent.Values |
            Sort-Object Name |
            Select-Object -ExpandProperty Name
    )
}

function Invoke-GitProcess([string[]]$Arguments, [switch]$Quiet) {
    $stdoutPath = [System.IO.Path]::GetTempFileName()

    try {
        $oldEA = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & git @Arguments *> $stdoutPath
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $oldEA

        $stdout = Get-Content -LiteralPath $stdoutPath -Raw

        if (!$Quiet) {
            if ($stdout) {
                Write-Host -NoNewline $stdout
            }
        }

        return @{
            ExitCode = $exitCode
            StdOut = $stdout
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-LegacyUsvfsCompatTree([string]$LegacyRoot, [string]$RepoUrl) {
    $requiredDirs = @('asmjit', 'spdlog', 'udis86')
    $missingDirs = @($requiredDirs | Where-Object { -not (Test-Path (Join-Path $LegacyRoot $_)) })
    if ($missingDirs.Count -eq 0) {
        return
    }

    $parent = Split-Path -Parent $LegacyRoot
    if (!(Test-Path $LegacyRoot)) {
        if (!(Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent | Out-Null
        }

        Write-Info "Cloning legacy usvfs source into $LegacyRoot"
        $cloneResult = Invoke-GitProcess @('clone', $RepoUrl, $LegacyRoot)
        if ($cloneResult.ExitCode -ne 0) {
            throw "Failed to clone legacy usvfs source into $LegacyRoot"
        }
    }

    Write-Info "Preparing legacy usvfs source at $LegacyRoot"
    foreach ($gitArgs in @(
        @('-C', $LegacyRoot, 'fetch', '--all', '--tags'),
        @('-C', $LegacyRoot, 'checkout', '--force', 'v0.5.0'),
        @('-C', $LegacyRoot, 'submodule', 'update', '--init', '--recursive')
    )) {
        $result = Invoke-GitProcess -Arguments $gitArgs
        if ($result.ExitCode -ne 0) {
            throw "Failed to prepare legacy usvfs source at $LegacyRoot"
        }
    }

    $missingDirs = @($requiredDirs | Where-Object { -not (Test-Path (Join-Path $LegacyRoot $_)) })
    if ($missingDirs.Count -gt 0) {
        throw "Legacy usvfs source is missing required directories: $($missingDirs -join ', ')"
    }
}

function Ensure-Udis86OpcodeTables([string]$PatchedSourceDir) {
    $udis86Root = Join-Path $PatchedSourceDir 'udis86'
    $itabCPath = Join-Path $udis86Root 'libudis86\itab.c'
    $itabHPath = Join-Path $udis86Root 'libudis86\itab.h'
    if ((Test-Path $itabCPath) -and (Test-Path $itabHPath)) {
        return
    }

    $generatorPath = Join-Path $udis86Root 'scripts\ud_itab.py'
    $optablePath = Join-Path $udis86Root 'docs\x86\optable.xml'
    $outputDir = Join-Path $udis86Root 'libudis86'
    if (!(Test-Path $generatorPath) -or !(Test-Path $optablePath) -or !(Test-Path $outputDir)) {
        throw "Unable to locate udis86 generator inputs under $udis86Root"
    }

    $pythonCommand = Get-Command python -ErrorAction SilentlyContinue
    if (-not $pythonCommand) {
        throw "python was not found in PATH while generating udis86 opcode tables"
    }

    Write-Info "Generating udis86 opcode tables"
    & $pythonCommand.Source $generatorPath $optablePath $outputDir
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to generate udis86 opcode tables"
    }

    if (!(Test-Path $itabCPath) -or !(Test-Path $itabHPath)) {
        throw "udis86 opcode table generation did not produce itab.c/itab.h"
    }
}

function Apply-UsvfsPatchFallback([string]$PatchedSourceDir, [string]$MO2Version) {
    if ($MO2Version -eq '2.4.4') {
        $assemblyMacro = 'USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS;USVFS_TARGET_V244'
    } else {
        $assemblyMacro = 'USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS;USVFS_TARGET_V25X'
        if ($MO2Version -eq '2.5.2') {
            $assemblyMacro += ';USVFS_TARGET_V252'
        }
    }
    # Create a sanitized version of the macro for use in #ifndef guards (no semicolons)
    $guardMacro = $assemblyMacro.Replace(';', '_')

    $parametersPath = Join-Path $PatchedSourceDir 'src\usvfs_dll\usvfsparameters.cpp'
    Ensure-WholeFileMacroGuard $parametersPath $guardMacro | Out-Null

    $projectPath = Join-Path $PatchedSourceDir 'vsbuild\usvfs_dll.vcxproj'
    Write-Host "[patch-xml] Patching project file $projectPath"
    $xml = [xml](Get-Content -LiteralPath $projectPath)
    $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    $ns.AddNamespace('ms', 'http://schemas.microsoft.com/developer/msbuild/2003')

    # 1. Update PreprocessorDefinitions
    $groups = $xml.SelectNodes("//ms:ItemDefinitionGroup", $ns)
    Write-Host "[patch-xml] Found $($groups.Count) ItemDefinitionGroups"
    foreach ($group in $groups) {
        $condition = $group.Condition
        
        $clCompile = $group.ClCompile
        if ($clCompile) {
            $existing = $clCompile.PreprocessorDefinitions
            if ($existing -and ($existing -notmatch [regex]::Escape($assemblyMacro))) {
                Write-Host "[patch-xml]   Applying preprocessor patch to $condition"
                $clCompile.PreprocessorDefinitions = "BUILDING_USVFS_DLL;BOOST_ALL_NO_LIB;$assemblyMacro;" + $existing
            }
        }
    }

    # 3. Update ModuleDefinitionFile
    $defX64 = Get-AssemblyDefName 'x64' $MO2Version
    $defX86 = Get-AssemblyDefName 'x86' $MO2Version
    
    $linkGroups = $xml.SelectNodes("//ms:ItemDefinitionGroup/ms:Link", $ns)
    foreach ($link in $linkGroups) {
        $parent = $link.ParentNode
        $condition = $parent.Condition
        $defFile = if ($condition -match 'x64') { Get-AssemblerSourcePath $defX64 } else { Get-AssemblerSourcePath $defX86 }
        
        if (!$link.ModuleDefinitionFile) {
            $node = $xml.CreateElement('ModuleDefinitionFile', $ns.LookupNamespace('ms'))
            $node.InnerText = $defFile
            $link.AppendChild($node) | Out-Null
        } else {
            $link.ModuleDefinitionFile = $defFile
        }

        # Disable SAFESEH for 32-bit
        if ($condition -notmatch 'x64') {
            if (!$link.ImageHasSafeExceptionHandlers) {
                $node = $xml.CreateElement('ImageHasSafeExceptionHandlers', $ns.LookupNamespace('ms'))
                $link.AppendChild($node) | Out-Null
            }
            $link.ImageHasSafeExceptionHandlers = 'false'
        }
    }

    # 4. Add MASM and Bridge files
    $itemGroups = $xml.SelectNodes("//ms:ItemGroup", $ns)
    
    $bridgeFileMap = [ordered]@{
        'usvfs_exports_bridge.cpp'  = (Get-AssemblerSourcePath 'usvfs_exports_bridge.cpp')
        'usvfs_context_bridge.cpp'  = (Get-AssemblerSourcePath 'usvfs_context_bridge.cpp')
        'usvfs_kernel32_bridge.cpp' = (Get-AssemblerSourcePath 'usvfs_kernel32_bridge.cpp')
        'usvfs_ntdll_bridge.cpp'    = (Get-AssemblerSourcePath 'usvfs_ntdll_bridge.cpp')
    }

    # Check if files are already added
    $bridgeAdded = $xml.SelectSingleNode("//ms:ClCompile[contains(@Include, 'usvfs_context_bridge.cpp')]", $ns)
    if (!$bridgeAdded) {
        $ig = $xml.CreateElement('ItemGroup', $ns.LookupNamespace('ms'))
        foreach ($f in $bridgeFileMap.Values) {
            $node = $xml.CreateElement('ClCompile', $ns.LookupNamespace('ms'))
            $node.SetAttribute('Include', $f)
            $ig.AppendChild($node) | Out-Null
        }
        $xml.Project.AppendChild($ig) | Out-Null
    }

    foreach ($name in $bridgeFileMap.Keys) {
        $nodes = $xml.SelectNodes("//ms:ClCompile[contains(@Include, '$name')]", $ns)
        foreach ($node in $nodes) {
            $node.SetAttribute('Include', $bridgeFileMap[$name])
        }
    }

    $asmPathMap = [ordered]@{
        'usvfs_parameter_exports_x86.asm' = (Get-AssemblerSourcePath 'usvfs_parameter_exports_x86.asm')
        'usvfs_exports_x86.asm'           = (Get-AssemblerSourcePath 'usvfs_exports_x86.asm')
        'usvfs_runtime_x86.asm'           = (Get-AssemblerSourcePath 'usvfs_runtime_x86.asm')
        'usvfs_context_x86.asm'           = (Get-AssemblerSourcePath 'usvfs_context_x86.asm')
        'usvfs_parameter_exports_x64.asm' = (Get-AssemblerSourcePath 'usvfs_parameter_exports_x64.asm')
        'usvfs_exports_x64.asm'           = (Get-AssemblerSourcePath 'usvfs_exports_x64.asm')
        'usvfs_runtime_x64.asm'           = (Get-AssemblerSourcePath 'usvfs_runtime_x64.asm')
        'usvfs_context_x64.asm'           = (Get-AssemblerSourcePath 'usvfs_context_x64.asm')
    }

    $masmAdded = $xml.SelectSingleNode("//ms:MASM[contains(@Include, 'usvfs_context_x86.asm')]", $ns)
    if (!$masmAdded) {
        $ig = $xml.CreateElement('ItemGroup', $ns.LookupNamespace('ms'))
        $asmX86 = @(
            $asmPathMap['usvfs_parameter_exports_x86.asm'],
            $asmPathMap['usvfs_exports_x86.asm'],
            $asmPathMap['usvfs_runtime_x86.asm'],
            $asmPathMap['usvfs_context_x86.asm']
        )
        foreach ($f in $asmX86) {
            $node = $xml.CreateElement('MASM', $ns.LookupNamespace('ms'))
            $node.SetAttribute('Include', $f)
            $excl = $xml.CreateElement('ExcludedFromBuild', $ns.LookupNamespace('ms'))
            $excl.SetAttribute('Condition', "'`$(Platform)'=='x64'")
            $excl.InnerText = 'true'
            $node.AppendChild($excl) | Out-Null
            $ig.AppendChild($node) | Out-Null
        }
        
        $asmX64 = @(
            $asmPathMap['usvfs_parameter_exports_x64.asm'],
            $asmPathMap['usvfs_exports_x64.asm'],
            $asmPathMap['usvfs_runtime_x64.asm'],
            $asmPathMap['usvfs_context_x64.asm']
        )
        foreach ($f in $asmX64) {
            $node = $xml.CreateElement('MASM', $ns.LookupNamespace('ms'))
            $node.SetAttribute('Include', $f)
            $excl = $xml.CreateElement('ExcludedFromBuild', $ns.LookupNamespace('ms'))
            $excl.SetAttribute('Condition', "'`$(Platform)'=='Win32'")
            $excl.InnerText = 'true'
            $node.AppendChild($excl) | Out-Null
            $ig.AppendChild($node) | Out-Null
        }
        $xml.Project.AppendChild($ig) | Out-Null
    }

    foreach ($name in $asmPathMap.Keys) {
        $nodes = $xml.SelectNodes("//ms:MASM[contains(@Include, '$name')]", $ns)
        foreach ($node in $nodes) {
            $node.SetAttribute('Include', $asmPathMap[$name])
        }
    }

    # 5. Remove original files that are replaced by bridge
    $toRemove = @(
        'hookcallcontext.cpp', 'hookcontext.cpp', 'hookmanager.cpp',
        'kernel32.cpp', 'ntdll.cpp', 'redirectiontree.cpp',
        'semaphore.cpp', 'sharedparameters.cpp', 'usvfs.cpp', 'usvfsparameters.cpp'
    )
    foreach ($name in $toRemove) {
        $nodes = $xml.SelectNodes("//ms:ClCompile[contains(@Include, '$name')]", $ns)
        foreach ($node in $nodes) {
            $node.ParentNode.RemoveChild($node) | Out-Null
        }
    }

    # 6. Enable MASM in project
    if ($xml.SelectSingleNode("//ms:Import[contains(@Project, 'masm.props')]", $ns) -eq $null) {
        $ig = $xml.SelectSingleNode("//ms:ImportGroup[@Label='ExtensionSettings']", $ns)
        if ($ig) {
            $imp = $xml.CreateElement('Import', $ns.LookupNamespace('ms'))
            $imp.SetAttribute('Project', '$(VCTargetsPath)\BuildCustomizations\masm.props')
            $ig.AppendChild($imp) | Out-Null
        }
    }
    if ($xml.SelectSingleNode("//ms:Import[contains(@Project, 'masm.targets')]", $ns) -eq $null) {
        $ig = $xml.SelectSingleNode("//ms:ImportGroup[@Label='ExtensionTargets']", $ns)
        if ($ig) {
            $imp = $xml.CreateElement('Import', $ns.LookupNamespace('ms'))
            $imp.SetAttribute('Project', '$(VCTargetsPath)\BuildCustomizations\masm.targets')
            $ig.AppendChild($imp) | Out-Null
        }
    }

    $xml.Save($projectPath)

    $commonPropsPath = Join-Path $PatchedSourceDir 'vsbuild\usvfs_common.props'
    $commonPropsText = Get-Content -LiteralPath $commonPropsPath -Raw
    if ($commonPropsText -notmatch '\.\.\\src\\usvfs_dll;') {
        $commonPropsText = $commonPropsText.Replace(
            '..\src\shared;..\src\thooklib;..\src\tinjectlib;..\src\usvfs_helper;..\asmjit\src\asmjit;..\udis86;%(AdditionalIncludeDirectories)',
            '..\src\shared;..\src\thooklib;..\src\tinjectlib;..\src\usvfs_helper;..\src\usvfs_dll;..\asmjit\src\asmjit;..\udis86;%(AdditionalIncludeDirectories)')
        Write-Utf8NoBom $commonPropsPath $commonPropsText
    }

    $usvfsPath = Join-Path $PatchedSourceDir 'src\usvfs_dll\usvfs.cpp'
    $usvfsText = Ensure-WholeFileMacroGuard $usvfsPath $guardMacro

    # Patch the header to declare destructors so we can define them in our bridge
    $possibleHeaderPaths = @(
        'include\sharedparameters.h',
        'include\usvfs\sharedparameters.h'
    )
    $sharedParametersHeaderPath = $null
    foreach ($p in $possibleHeaderPaths) {
        $candidate = Join-Path $PatchedSourceDir $p
        if (Test-Path $candidate) {
            $sharedParametersHeaderPath = $candidate
            break
        }
    }

    if ($sharedParametersHeaderPath) {
        Write-Info "Checking header for destructor injection: $sharedParametersHeaderPath"
        $hContent = Get-Content $sharedParametersHeaderPath -Raw
        
        $hasForcedLibraryDestructor = $hContent -match '\~ForcedLibrary\s*\(\s*\)\s*;'
        $hasSharedParametersDestructor = $hContent -match '\~SharedParameters\s*\(\s*\)\s*;'

        if ($hasForcedLibraryDestructor -and $hasSharedParametersDestructor) {
            Write-Host "[prepare-usvfs] Header already patched (both destructors found); skipping injection."
        } else {
            $originalHContent = $hContent

            if (-not $hasForcedLibraryDestructor) {
                $hContent = [regex]::Replace(
                    $hContent,
                    '(std::string\s+libraryPath\(\)\s+const\s*;)(?!\s*\~ForcedLibrary\s*\(\s*\)\s*;)',
                    '$1 ~ForcedLibrary();')
            }

            if (-not $hasSharedParametersDestructor) {
                $hContent = [regex]::Replace(
                    $hContent,
                    '(usvfsParameters\s+makeLocal\(\)\s+const\s*;)(?!\s*\~SharedParameters\s*\(\s*\)\s*;)',
                    '$1 ~SharedParameters();')
            }

            if ($hContent -ne $originalHContent) {
                Write-Host "[prepare-usvfs] Successfully patched sharedparameters.h declarations."
                Write-Utf8NoBom $sharedParametersHeaderPath $hContent
            } else {
                Write-Warning "[prepare-usvfs] Failed to find target signatures in sharedparameters.h - destructors NOT declared!"
            }
        }
    } else {
        Write-Error "[prepare-usvfs] SharedParameters header NOT FOUND in any expected location!"
    }

    $compatHeaders = @(
        @{ Path = 'include\sharedparameters.h'; Target = 'usvfs/sharedparameters.h' },
        @{ Path = 'include\usvfsparameters.h'; Target = 'usvfs/usvfsparameters.h' }
    )
    foreach ($compatHeader in $compatHeaders) {
        $compatPath = Join-Path $PatchedSourceDir $compatHeader.Path
        if (-not (Test-Path $compatPath)) {
            Write-Utf8NoBom $compatPath ("#pragma once`n#include `"" + $compatHeader.Target + "`"`n")
            Write-Info "Created compatibility header: $compatPath"
        }
    }

    $nestedIncludeDir = Join-Path $PatchedSourceDir 'include\usvfs'
    if (Test-Path $nestedIncludeDir) {
        Get-ChildItem -LiteralPath $nestedIncludeDir -Filter '*.h' -File | ForEach-Object {
            $compatPath = Join-Path $PatchedSourceDir ('include\' + $_.Name)
            if (-not (Test-Path $compatPath)) {
                Write-Utf8NoBom $compatPath ("#pragma once`n#include `"usvfs/" + $_.Name + "`"`n")
                Write-Info "Created compatibility header: $compatPath"
            }
        }
    }

    # Now we can safely guard the whole sharedparameters.cpp
    $sharedParametersPath = Join-Path $PatchedSourceDir 'src\usvfs_dll\sharedparameters.cpp'
    if (Test-Path $sharedParametersPath) {
        Ensure-WholeFileMacroGuard $sharedParametersPath $guardMacro | Out-Null
    }

    $hookCallContextPath = Join-Path $PatchedSourceDir 'src\usvfs_dll\hookcallcontext.cpp'
    Ensure-WholeFileMacroGuard $hookCallContextPath $guardMacro | Out-Null

    $hookContextPath = Join-Path $PatchedSourceDir 'src\usvfs_dll\hookcontext.cpp'
    Ensure-WholeFileMacroGuard $hookContextPath $guardMacro | Out-Null

    $hookManagerPath = Join-Path $PatchedSourceDir 'src\usvfs_dll\hookmanager.cpp'
    Ensure-WholeFileMacroGuard $hookManagerPath $guardMacro | Out-Null
    $initLoggingBlock = @"
void WINAPI InitLogging(bool toConsole)
{
  InitLoggingInternal(toConsole, false);
}

extern "C" DLLEXPORT bool WINAPI GetLogMessages(LPSTR buffer, size_t size,
                                                bool blocking)
{
  buffer[0] = '\0';
  try {
    if (blocking) {
      SHMLogger::instance().get(buffer, size);
      return true;
    } else {
      return SHMLogger::instance().tryGet(buffer, size);
    }
  } catch (const std::exception &e) {
    _snprintf_s(buffer, size, _TRUNCATE, "Failed to retrieve log messages: %s",
               e.what());
    return false;
  }
}
"@ -replace "`n", $projectNl
    $updateParamsBlock = @"
void WINAPI USVFSUpdateParams(LogLevel level, CrashDumpsType type)
{
  auto* p = usvfsCreateParameters();

  usvfsSetLogLevel(p, level);
  usvfsSetCrashDumpType(p, type);

  usvfsUpdateParameters(p);
  usvfsFreeParameters(p);
}

void WINAPI usvfsUpdateParameters(usvfsParameters* p)
{
  spdlog::get("usvfs")->info(
    "updating parameters:\n"
    " . debugMode: {}\n"
    " . log level: {}\n"
    " . dump type: {}\n"
    " . dump path: {}\n"
    " . delay process: {}ms",
    p->debugMode, usvfsLogLevelToString(p->logLevel),
    usvfsCrashDumpTypeToString(p->crashDumpsType), p->crashDumpsPath,
    p->delayProcessMs);

  // update actual values used:
  usvfs_dump_type = p->crashDumpsType;
  usvfs_dump_path = ush::string_cast<std::wstring>(
    p->crashDumpsPath, ush::CodePage::UTF8);
  SetLogLevel(p->logLevel);

  // update parameters in context so spawned process will inherit changes:
  context->setDebugParameters(
    p->logLevel, p->crashDumpsType, p->crashDumpsPath,
    std::chrono::milliseconds(p->delayProcessMs));
}
"@ -replace "`n", $projectNl
    $createVfsBlock = @"
void WINAPI GetCurrentVFSName(char *buffer, size_t size)
{
  ush::strncpy_sz(buffer, context->callParameters().currentSHMName, size);
}


// deprecated
//
BOOL WINAPI CreateVFS(const USVFSParameters *oldParams)
{
  const usvfsParameters p(*oldParams);
  const auto r = usvfsCreateVFS(&p);

  return r;
}

BOOL WINAPI usvfsCreateVFS(const usvfsParameters* p)
{
  usvfs::HookContext::remove(p->instanceName);
  return usvfsConnectVFS(p);
}
"@ -replace "`n", $projectNl
    $connectVfsBlock = @"
BOOL WINAPI ConnectVFS(const USVFSParameters *oldParams)
{
  const usvfsParameters p(*oldParams);
  const auto r = usvfsConnectVFS(&p);

  return r;
}

BOOL WINAPI usvfsConnectVFS(const usvfsParameters* params)
{
  if (spdlog::get("usvfs").get() == nullptr) {
    // create temporary logger so we don't get null-pointer exceptions
    spdlog::create<spdlog::sinks::null_sink>("usvfs");
  }

  try {
    DisconnectVFS();
    context = new usvfs::HookContext(*params, dllModule);

    return TRUE;
  } catch (const std::exception &e) {
    spdlog::get("usvfs")->debug("failed to connect to vfs: {}", e.what());
    return FALSE;
  }
}
"@ -replace "`n", $projectNl
    $disconnectVfsBlock = @"
void WINAPI DisconnectVFS()
{
  if (spdlog::get("usvfs").get() == nullptr) {
    // create temporary logger so we don't get null-pointer exceptions
    spdlog::create<spdlog::sinks::null_sink>("usvfs");
  }

  spdlog::get("usvfs")->debug("remove from process {}", GetCurrentProcessId());

  if (manager != nullptr) {
    delete manager;
    manager = nullptr;
  }

  if (context != nullptr) {
    delete context;
    context = nullptr;
    spdlog::get("usvfs")->debug("vfs unloaded");
  }
}
"@ -replace "`n", $projectNl
    $clearMappingsBlock = @"
void WINAPI ClearVirtualMappings()
{
  context->redirectionTable()->clear();
  context->inverseTable()->clear();
}
"@ -replace "`n", $projectNl
    $processListBlock = @"
BOOL WINAPI GetVFSProcessList(size_t *count, LPDWORD processIDs)
{
  if (count == nullptr) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }

  if (context == nullptr) {
    *count = 0;
  } else {
    std::vector<DWORD> pids = context->registeredProcesses();
    size_t realCount = 0;
    for (DWORD pid : pids) {
      if (processStillActive(pid)) {
        if ((realCount < *count) && (processIDs != nullptr)) {
          processIDs[realCount] = pid;
        }

        ++realCount;
      } // else the process has already ended
    }
    *count = realCount;
  }
  return TRUE;
}

BOOL WINAPI GetVFSProcessList2(size_t* count, DWORD** buffer)
{
  if (!count || !buffer) {
    SetLastError(ERROR_INVALID_PARAMETER);
    return FALSE;
  }

  *count = 0;
  *buffer = nullptr;

  std::vector<DWORD> pids = context->registeredProcesses();
  auto last = std::remove_if(pids.begin(), pids.end(), [](DWORD id) {
    return !processStillActive(id);
  });

  pids.erase(last, pids.end());

  if (pids.empty()) {
    return TRUE;
  }

  *count = pids.size();
  *buffer = static_cast<DWORD*>(std::calloc(pids.size(), sizeof(DWORD)));

  std::copy(pids.begin(), pids.end(), *buffer);

  return TRUE;
}
"@ -replace "`n", $projectNl
    $tailExportsBlock = @"
BOOL WINAPI CreateVFSDump(LPSTR buffer, size_t *size)
{
  assert(size != nullptr);
  std::ostringstream output;
  usvfs::shared::dumpTree(output, *context->redirectionTable().get());
  std::string str = output.str();
  if ((buffer != NULL) && (*size > 0)) {
    strncpy_s(buffer, *size, str.c_str(), _TRUNCATE);
  }
  bool success = *size >= str.length();
  *size = str.length();
  return success ? TRUE : FALSE;
}


VOID WINAPI BlacklistExecutable(LPWSTR executableName)
{
  context->blacklistExecutable(executableName);
}


VOID WINAPI ClearExecutableBlacklist()
{
  context->clearExecutableBlacklist();
}


VOID WINAPI ForceLoadLibrary(LPWSTR processName, LPWSTR libraryPath)
{
  context->forceLoadLibrary(processName, libraryPath);
}


VOID WINAPI ClearLibraryForceLoads()
{
  context->clearLibraryForceLoads();
}


VOID WINAPI PrintDebugInfo()
{
  spdlog::get("usvfs")
      ->warn("===== debug {} =====", context->redirectionTable().shmName());
  void *buffer = nullptr;
  size_t bufferSize = 0;
  context->redirectionTable().getBuffer(buffer, bufferSize);
  std::ostringstream temp;
  for (size_t i = 0; i < bufferSize; ++i) {
    temp << std::hex << std::setfill('0') << std::setw(2) << (unsigned)reinterpret_cast<char*>(buffer)[i] << " ";
    if ((i % 16) == 15) {
      spdlog::get("usvfs")->info("{}", temp.str());
      temp.str("");
      temp.clear();
    }
  }
  if (!temp.str().empty()) {
    spdlog::get("usvfs")->info("{}", temp.str());
  }
  spdlog::get("usvfs")
      ->warn("===== / debug {} =====", context->redirectionTable().shmName());
}


// deprecated
//
void WINAPI USVFSInitParameters(USVFSParameters *parameters,
                                const char *instanceName, bool debugMode,
                                LogLevel logLevel,
                                CrashDumpsType crashDumpsType,
                                const char *crashDumpsPath)
{
  parameters->debugMode = debugMode;
  parameters->logLevel = logLevel;
  parameters->crashDumpsType = crashDumpsType;

  strncpy_s(parameters->instanceName, instanceName, _TRUNCATE);
  if (crashDumpsPath && *crashDumpsPath && strlen(crashDumpsPath) < _countof(parameters->crashDumpsPath)) {
    memcpy(parameters->crashDumpsPath, crashDumpsPath, strlen(crashDumpsPath)+1);
    parameters->crashDumpsType = crashDumpsType;
  }
  else {
    // crashDumpsPath invalid or overflow of USVFSParameters variable so disable crash dumps:
    parameters->crashDumpsPath[0] = 0;
    parameters->crashDumpsType = CrashDumpsType::None;
  }
  // we can't use the whole buffer as we need a few bytes to store a running
  // counter
  strncpy_s(parameters->currentSHMName, 60, instanceName, _TRUNCATE);
  memset(parameters->currentInverseSHMName, '\0', _countof(parameters->currentInverseSHMName));
  _snprintf(parameters->currentInverseSHMName, 60, "inv_%s", instanceName);
}


const char* WINAPI USVFSVersionString()
{
  return USVFS_VERSION_STRING;
}
"@ -replace "`n", $projectNl

    $usvfsText = Wrap-PreprocessorBlock $usvfsText $initLoggingBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $updateParamsBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $createVfsBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $connectVfsBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $disconnectVfsBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $processListBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $clearMappingsBlock $guardMacro $projectNl
    $usvfsText = Wrap-PreprocessorBlock $usvfsText $tailExportsBlock $guardMacro $projectNl
    Write-Utf8NoBom $usvfsPath $usvfsText

    $loggerPath = Join-Path $PatchedSourceDir 'src\shared\shmlogger.cpp'
    $loggerText = Get-Content -LiteralPath $loggerPath -Raw
    $loggerNl = if ($loggerText.Contains("`r`n")) { "`r`n" } else { "`n" }

    if ($loggerText -notmatch '<boost/date_time/posix_time/posix_time\.hpp>') {
        $loggerText = $loggerText.Replace(
            '#include "shmlogger.h"' + $loggerNl,
            '#include "shmlogger.h"' + $loggerNl + '#include <boost/date_time/posix_time/posix_time.hpp>' + $loggerNl)
    }

    if ($loggerText -match 'microsec_clock::universal_time\(\)' -and
        $loggerText -notmatch 'boost::posix_time::microsec_clock::universal_time\(\)') {
        $loggerText = $loggerText.Replace(
            'microsec_clock::universal_time()',
            'boost::posix_time::microsec_clock::universal_time()')
    }

    if ($loggerText.Contains('message_queue::remove(queueName.c_str());')) {
        $loggerText = $loggerText.Replace(
            'message_queue::remove(queueName.c_str());',
            'message_queue_interop::remove(queueName.c_str());')
    }

    Write-Utf8NoBom $loggerPath $loggerText
}

function Copy-CompatFileIfMissing([string]$Source, [string]$Destination) {
    if (!(Test-Path $Source) -or (Test-Path $Destination)) {
        return
    }

    $parent = Split-Path -Parent $Destination
    if ($parent -and !(Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Write-Info "Created compatibility file: $Destination"
}

function Copy-CompatTreeIfMissing([string]$Source, [string]$Destination) {
    if (!(Test-Path $Source) -or (Test-Path $Destination)) {
        return
    }

    $parent = Split-Path -Parent $Destination
    if ($parent -and !(Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    Write-Info "Created compatibility tree: $Destination"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([System.IO.Path]::IsPathRooted($SourceDir)) {
    $sourceDir = [System.IO.Path]::GetFullPath($SourceDir)
} else {
    $sourceDir = [System.IO.Path]::GetFullPath((Join-Path $repoRoot $SourceDir))
}
$patchPath = Join-Path $PSScriptRoot 'patches\usvfs-0.5.6.0-asm-parameter-exports.patch'
$boostLinkLibrariesByPlatform = [ordered]@{
    'Win32' = @()
    'x64' = @()
}
$boostLibDirByPlatform = [ordered]@{
    'Win32' = $null
    'x64' = $null
}

if (!(Test-Path $sourceDir)) {
    $parent = Split-Path -Parent $sourceDir
    if (!(Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }

    Write-Info "Cloning usvfs into $sourceDir"
    Invoke-GitProcess @('clone', $RepoUrl, $sourceDir) | Out-Null
}

Write-Info "Checking out commit $Commit"
Invoke-GitProcess @('-C', $sourceDir, 'fetch', '--all', '--tags') | Out-Null
Invoke-GitProcess @('-C', $sourceDir, 'checkout', '--force', $Commit) | Out-Null
Invoke-GitProcess @('-C', $sourceDir, 'submodule', 'update', '--init', '--recursive') | Out-Null

$compatTreeNames = @('asmjit', 'spdlog', 'udis86')
$missingCompatTrees = @($compatTreeNames | Where-Object {
    -not (Test-Path (Join-Path $sourceDir $_))
})
if ($missingCompatTrees.Count -gt 0) {
    Write-Info "Backfilling legacy vsbuild compatibility trees: $($missingCompatTrees -join ', ')"
    $v250Path = Join-Path $repoRoot 'external\usvfs-mo2-v2.5.0'
    Ensure-LegacyUsvfsCompatTree -LegacyRoot $v250Path -RepoUrl $RepoUrl

    foreach ($treeName in $missingCompatTrees) {
        $legacyTree = Join-Path $v250Path $treeName
        $targetTree = Join-Path $sourceDir $treeName
        if (!(Test-Path $legacyTree)) {
            throw "Legacy compatibility tree missing at $legacyTree"
        }

        Copy-Item $legacyTree -Destination $targetTree -Recurse -Force
    }
}

Write-Info "Applying assembler patch"
$applyCheck = Invoke-GitProcess @('-C', $sourceDir, 'apply', '--check', $patchPath) -Quiet
if ($applyCheck.ExitCode -eq 0) {
    $applyResult = Invoke-GitProcess @('-C', $sourceDir, 'apply', $patchPath)
    if ($applyResult.ExitCode -ne 0) {
        throw "Failed to apply $patchPath"
    }
} else {
    $reverseCheck = Invoke-GitProcess @('-C', $sourceDir, 'apply', '--reverse', '--check', $patchPath) -Quiet
    if ($reverseCheck.ExitCode -eq 0) {
        Write-Info "Patch already present; continuing"
    } else {
        Write-Info "Git patch did not apply cleanly; using scripted fallback"
        Apply-UsvfsPatchFallback $sourceDir $MO2Version
    }
}

if ($MO2Version -ne '2.4.4') {
    Write-Info "Backfilling legacy usvfs test layout for vsbuild compatibility..."
    Copy-CompatFileIfMissing (Join-Path $sourceDir 'test\test_utils\test_helpers.cpp') (Join-Path $sourceDir 'src\shared\test_helpers.cpp')
    Copy-CompatFileIfMissing (Join-Path $sourceDir 'test\test_utils\test_helpers.h') (Join-Path $sourceDir 'src\shared\test_helpers.h')
    Copy-CompatTreeIfMissing (Join-Path $sourceDir 'test\tinjectlib_test\testinject_bin') (Join-Path $sourceDir 'test\testinject_bin')
    Copy-CompatTreeIfMissing (Join-Path $sourceDir 'test\tinjectlib_test\testinject_dll') (Join-Path $sourceDir 'test\testinject_dll')
    Copy-CompatTreeIfMissing (Join-Path $sourceDir 'test\usvfs_test_runner\test_file_operations') (Join-Path $sourceDir 'test\test_file_operations')
    Copy-CompatTreeIfMissing (Join-Path $sourceDir 'test\usvfs_test_runner\usvfs_test') (Join-Path $sourceDir 'test\usvfs_test')
}

$usvfsTestBasePath = Join-Path $sourceDir 'test\usvfs_test\usvfs_test_base.cpp'
if (Test-Path $usvfsTestBasePath) {
    $usvfsTestBaseText = Get-Content -LiteralPath $usvfsTestBasePath -Raw
    $testNl = if ($usvfsTestBaseText.Contains("`r`n")) { "`r`n" } else { "`n" }

    if ($usvfsTestBaseText -notmatch '(?m)^#include <cstdlib>$') {
        $usvfsTestBaseText = Replace-RequiredText `
            -Text $usvfsTestBaseText `
            -Needle ("#include <cerrno>" + $testNl) `
            -Replacement ("#include <cerrno>" + $testNl + "#include <cstdlib>" + $testNl) `
            -Description $usvfsTestBasePath
    }

    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ("        usvfsCreateParameters(), &usvfsFreeParameters };" + $testNl) `
        -Replacement ("        usvfsCreateParameters(), &usvfsFreeParameters };" + $testNl +
            "    if (!parameters) {" + $testNl +
            '      throw_testWinFuncFailed("usvfsCreateParameters", "", ERROR_OUTOFMEMORY);' + $testNl +
            "    }" + $testNl +
            '    std::cout << "trace: usvfsCreateParameters ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsSetInstanceName(parameters.get(), "usvfs_test");' + $testNl) `
        -Replacement ('    usvfsSetInstanceName(parameters.get(), "usvfs_test");' + $testNl +
            '    std::cout << "trace: usvfsSetInstanceName ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsSetDebugMode(parameters.get(), false);' + $testNl) `
        -Replacement ('    usvfsSetDebugMode(parameters.get(), false);' + $testNl +
            '    std::cout << "trace: usvfsSetDebugMode ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsSetLogLevel(parameters.get(), LogLevel::Debug);' + $testNl) `
        -Replacement ('    usvfsSetLogLevel(parameters.get(), LogLevel::Debug);' + $testNl +
            '    std::cout << "trace: usvfsSetLogLevel ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsSetCrashDumpType(parameters.get(), CrashDumpsType::None);' + $testNl) `
        -Replacement ('    usvfsSetCrashDumpType(parameters.get(), CrashDumpsType::None);' + $testNl +
            '    std::cout << "trace: usvfsSetCrashDumpType ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsSetCrashDumpPath(parameters.get(), "");' + $testNl) `
        -Replacement ((@"
    const char* crashDumpPath = std::getenv("USVFS_TEST_CRASH_DUMP_PATH");
    if (crashDumpPath && *crashDumpPath) {
      usvfsSetCrashDumpPath(parameters.get(), crashDumpPath);
      std::cout << "trace: usvfsSetCrashDumpPath ok" << std::endl;
    } else {
      std::cout << "trace: usvfsSetCrashDumpPath skipped" << std::endl;
    }
"@) -replace "`n", $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsInitLogging(false);' + $testNl) `
        -Replacement ('    usvfsInitLogging(false);' + $testNl +
            '    std::cout << "trace: usvfsInitLogging ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    $usvfsTestBaseText = Replace-RequiredText `
        -Text $usvfsTestBaseText `
        -Needle ('    usvfsCreateVFS(parameters.get());' + $testNl) `
        -Replacement ('    usvfsCreateVFS(parameters.get());' + $testNl +
            '    std::cout << "trace: usvfsCreateVFS ok" << std::endl;' + $testNl) `
        -Description $usvfsTestBasePath
    Write-Utf8NoBom $usvfsTestBasePath $usvfsTestBaseText
}

$vcxPath = Join-Path $sourceDir "vsbuild\usvfs_dll.vcxproj"
if (Test-Path $vcxPath) {
    $vcxText = Get-Content -LiteralPath $vcxPath -Raw
    if ($MO2Version -eq '2.4.4') {
        $aMacro = 'USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS;USVFS_TARGET_V244'
    } else {
        $aMacro = 'USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS;USVFS_TARGET_V25X'
        if ($MO2Version -eq '2.5.2') { $aMacro += ';USVFS_TARGET_V252' }
    }
    
    if ($vcxText -match 'USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS' -and $vcxText -notmatch 'USVFS_TARGET_V244' -and $vcxText -notmatch 'USVFS_TARGET_V25X') {
        $vcxText = [regex]::Replace($vcxText, '(?i)(<PreprocessorDefinitions>.*?)USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS', '${1}' + $aMacro)
        Write-Utf8NoBom $vcxPath $vcxText
    }
}

$parametersText = Get-Content -LiteralPath (Join-Path $sourceDir 'src\usvfs_dll\usvfsparameters.cpp') -Raw
$sharedParametersText = Get-Content -LiteralPath (Join-Path $sourceDir 'src\usvfs_dll\sharedparameters.cpp') -Raw
$hookContextText = Get-Content -LiteralPath (Join-Path $sourceDir 'src\usvfs_dll\hookcontext.cpp') -Raw
$hookManagerText = Get-Content -LiteralPath (Join-Path $sourceDir 'src\usvfs_dll\hookmanager.cpp') -Raw
$usvfsText = Get-Content -LiteralPath (Join-Path $sourceDir 'src\usvfs_dll\usvfs.cpp') -Raw
$projectText = Get-Content -LiteralPath (Join-Path $sourceDir 'vsbuild\usvfs_dll.vcxproj') -Raw
$commonPropsText = Get-Content -LiteralPath (Join-Path $sourceDir 'vsbuild\usvfs_common.props') -Raw
$loggerText = Get-Content -LiteralPath (Join-Path $sourceDir 'src\shared\shmlogger.cpp') -Raw
if (($parametersText -notmatch '#ifndef USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS') -or
    ($sharedParametersText -notmatch '#ifndef USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS') -or
    ($hookContextText -notmatch '#ifndef USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS') -or
    ($hookManagerText -notmatch '#ifndef USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS') -or
    ($usvfsText -notmatch '#ifndef USVFS_USE_ASSEMBLY_PARAMETER_EXPORTS') -or
    ($projectText -notmatch 'usvfs_parameter_exports_x64\.asm') -or
    ($projectText -notmatch 'usvfs_exports_x64\.asm') -or
    ($projectText -notmatch 'usvfs_runtime_x64\.asm') -or
    ($projectText -notmatch 'usvfs_context_x64\.asm') -or
    ($projectText -notmatch 'usvfs_exports_bridge\.cpp') -or
    ($projectText -notmatch 'usvfs_context_bridge\.cpp') -or
    ($projectText -notmatch 'usvfs_kernel32_bridge\.cpp') -or
    ($projectText -notmatch 'usvfs_ntdll_bridge\.cpp') -or
    ($projectText -match 'usvfs_parameter_exports_bridge\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\hookcallcontext\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\hookcontext\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\hookmanager\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\hooks\\kernel32\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\hooks\\ntdll\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\redirectiontree\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\semaphore\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\sharedparameters\.cpp') -or
    ($projectText -match '\.\.\\src\\usvfs_dll\\usvfs\.cpp') -or
    ([regex]::Matches($projectText, 'USVFS_TARGET_V2').Count -lt 4) -or
    ($projectText -notmatch 'BuildCustomizations\\masm.props') -or
    ($commonPropsText -notmatch '\.\.\\src\\usvfs_dll;') -or
    ($loggerText -notmatch '<boost/date_time/posix_time/posix_time\.hpp>') -or
    ($loggerText -notmatch 'boost::posix_time::microsec_clock::universal_time\(\)')) {
    Write-Info "Patch markers missing or incomplete after git apply; enforcing scripted fallback"
    Apply-UsvfsPatchFallback $sourceDir $MO2Version
}

Ensure-Udis86OpcodeTables -PatchedSourceDir $sourceDir

if (!$BoostPath -and $UseVcpkgBoost) {
    $compatRoot = Join-Path $PSScriptRoot "boost-compat-$MO2Version-$Triplet"
    $tripletsByPlatform = [ordered]@{
        'Win32' = (Get-VcpkgTripletForPlatform $Triplet 'Win32')
        'x64' = (Get-VcpkgTripletForPlatform $Triplet 'x64')
    }
    $primaryPlatform = if ($Triplet -match '^x64-') { 'x64' } else { 'Win32' }
    $primaryLibDir = $null
    $primaryIncludeDir = $null

    if (Test-Path $compatRoot) {
        Remove-Item -LiteralPath $compatRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $compatRoot | Out-Null

    foreach ($platform in $tripletsByPlatform.Keys) {
        $platformTriplet = $tripletsByPlatform[$platform]
        $vcpkgInclude = Join-Path $VcpkgRoot "installed\$platformTriplet\include\boost"
        $vcpkgLib = Join-Path $VcpkgRoot "installed\$platformTriplet\lib"

        if (!(Test-Path $vcpkgInclude) -or !(Test-Path $vcpkgLib)) {
            throw "Vcpkg Boost was not found under $VcpkgRoot for triplet $platformTriplet"
        }

        if ($platform -eq $primaryPlatform) {
            $primaryIncludeDir = $vcpkgInclude
            $primaryLibDir = $vcpkgLib
        }

        $boostLinkLibrariesByPlatform[$platform] = Get-BoostLinkLibraries $vcpkgLib -PreferStaticRuntime:($MO2Version -eq '2.5.0')
        $boostLibDirByPlatform[$platform] = $vcpkgLib

        $compatLibRootName = Get-BoostCompatLibRootName $platform $MO2Version
        $compatLibRoot = Join-Path $compatRoot $compatLibRootName
        New-Item -ItemType Directory -Path $compatLibRoot | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $compatLibRoot 'lib') -Target $vcpkgLib | Out-Null
    }

    if ($null -eq $primaryIncludeDir -or $null -eq $primaryLibDir) {
        throw "Unable to determine primary Boost paths for triplet $Triplet"
    }

    New-Item -ItemType Junction -Path (Join-Path $compatRoot 'boost') -Target $primaryIncludeDir | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $compatRoot 'lib') -Target $primaryLibDir | Out-Null

    $BoostPath = $compatRoot
}

if ($BoostPath) {
    $BoostPath = (Resolve-Path -LiteralPath $BoostPath).Path

    $propsPath = Join-Path $sourceDir 'vsbuild\external_dependencies_local.props'
    $escapedBoostPath = $BoostPath.Replace('&', '&amp;')
    $boostLinkXml = ''

    foreach ($platform in @($boostLinkLibrariesByPlatform.Keys)) {
        if ($boostLinkLibrariesByPlatform[$platform].Count -eq 0) {
            $compatLibRootName = Get-BoostCompatLibRootName $platform $MO2Version
            $candidateLibDirs = @(
                (Join-Path $BoostPath "$compatLibRootName\lib"),
                (Join-Path $BoostPath 'lib')
            ) | Where-Object { Test-Path $_ } | Select-Object -Unique

            foreach ($libDir in $candidateLibDirs) {
                $boostLibraries = Get-BoostLinkLibraries $libDir -PreferStaticRuntime:($MO2Version -eq '2.5.0')
                if ($boostLibraries.Count -gt 0) {
                    $boostLinkLibrariesByPlatform[$platform] = $boostLibraries
                    $boostLibDirByPlatform[$platform] = $libDir
                    break
                }
            }
        }

        if ($boostLinkLibrariesByPlatform[$platform].Count -gt 0) {
            if ($MO2Version -eq '2.5.0' -and $platform -eq 'x64' -and $boostLibDirByPlatform[$platform]) {
                $x64ReleaseBoostLibraries = $boostLinkLibrariesByPlatform[$platform]
                $x64ReleaseTestBoostLibraries = Get-BoostLinkLibraries $boostLibDirByPlatform[$platform]
                if ($x64ReleaseTestBoostLibraries.Count -eq 0) {
                    throw "Dynamic-runtime Boost libraries were not found for x64 ReleaseTest under $($boostLibDirByPlatform[$platform])"
                }

                foreach ($boostConfig in @(
                    @{
                        Condition = "'`$(Platform)'=='x64' and '`$(Configuration)'=='ReleaseTest'"
                        Libraries = $x64ReleaseTestBoostLibraries
                    },
                    @{
                        Condition = "'`$(Platform)'=='x64' and '`$(Configuration)'!='ReleaseTest'"
                        Libraries = $x64ReleaseBoostLibraries
                    }
                )) {
                    $escapedBoostLibraries = (($boostConfig.Libraries -join ';') + ';%(AdditionalDependencies)').Replace('&', '&amp;')
                    $boostLinkXml += @"
  <ItemDefinitionGroup Condition="$($boostConfig.Condition)">
    <Link>
      <AdditionalDependencies>$escapedBoostLibraries</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
"@
                }
            } else {
                $escapedBoostLibraries = (($boostLinkLibrariesByPlatform[$platform] -join ';') + ';%(AdditionalDependencies)').Replace('&', '&amp;')
                $boostLinkXml += @"
  <ItemDefinitionGroup Condition="'`$(Platform)'=='$platform'">
    <Link>
      <AdditionalDependencies>$escapedBoostLibraries</AdditionalDependencies>
    </Link>
  </ItemDefinitionGroup>
"@
            }
        }
    }

    Write-Info "Writing $propsPath"
    @"
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup Label="UserMacros">
    <BOOST_PATH>$escapedBoostPath</BOOST_PATH>
    <STAGING_PATH_32>..\..\..\install\v$MO2Version\x86</STAGING_PATH_32>
    <STAGING_PATH_64>..\..\..\install\v$MO2Version\x64</STAGING_PATH_64>
    <STAGING_DLL_32>`$(STAGING_PATH_32)\bin</STAGING_DLL_32>
    <STAGING_LIB_32>`$(STAGING_PATH_32)\libs</STAGING_LIB_32>
    <STAGING_PDB_32>`$(STAGING_PATH_32)\pdb</STAGING_PDB_32>
    <STAGING_DLL_64>`$(STAGING_PATH_64)\bin</STAGING_DLL_64>
    <STAGING_LIB_64>`$(STAGING_PATH_64)\libs</STAGING_LIB_64>
    <STAGING_PDB_64>`$(STAGING_PATH_64)\pdb</STAGING_PDB_64>
  </PropertyGroup>
$boostLinkXml
</Project>
"@ | Set-Content -LiteralPath $propsPath -Encoding ASCII
}

$projectPathObj = Join-Path $sourceDir 'vsbuild\usvfs_dll.vcxproj'
if (Test-Path $projectPathObj) {
    $projectTextObj = Get-Content -LiteralPath $projectPathObj -Raw
    $defNameObj = Get-AssemblyDefName 'x64' $MO2Version
    $projectTextObj = [regex]::Replace($projectTextObj, 'usvfs_x64(?:_v\d+)?\.def', $defNameObj)
    Write-Utf8NoBom $projectPathObj $projectTextObj
}

Get-ChildItem -Path $sourceDir -Include '*.vcxproj', '*.props' -Recurse | ForEach-Object {
    $vcxTextOrig = Get-Content -LiteralPath $_.FullName -Raw
    $vcxText = $vcxTextOrig

    if ($vcxText -match '/external:I\$\(BOOST_PATH\)') {
        $vcxText = [regex]::Replace($vcxText, '/external:I\$\(BOOST_PATH\)', '/external:I"$(BOOST_PATH)"')
    }

    if ($MO2Version -eq '2.5.2') {
        if ($vcxText -match 'ud_itab\.py') {
            $vcxText = [regex]::Replace($vcxText, '(?s)<CustomBuildStep>[^<]*<Command>[^<]*python \.\.\\udis86\\scripts\\ud_itab\.py.*?</Command>[^<]*</CustomBuildStep>', '')
        }
        if ($vcxText -match '<AdditionalIncludeDirectories>' -and $vcxText -notmatch '\.\.\\include\\usvfs') {
            $vcxText = [regex]::Replace($vcxText, '(?i)(<AdditionalIncludeDirectories>)', '${1}..\include\usvfs;')
        }
        if ($vcxText -match '\\asmjit\\src\\asmjit;') {
            $vcxText = [regex]::Replace($vcxText, '\\asmjit\\src\\asmjit;', '\asmjit\src;')
        }
        if ($vcxText -match '\\udis86;(%\(AdditionalIncludeDirectories\)|<)') {
            $vcxText = [regex]::Replace($vcxText, '\\udis86;(%\(AdditionalIncludeDirectories\)|<)', '\udis86;..\udis86\libudis86;$1')
        }
    }

    if ($MO2Version -eq '2.5.0') {
        # v0.5.0 ships Release with static CRT but ReleaseTest with DLL CRT.
        # Normalize only Win32 ReleaseTest to static CRT so the x86 support
        # binaries match the shipped Boost flavor without breaking x64 gtests.
        $releaseTestStaticCrtPattern = @'
(?s)(<ItemDefinitionGroup Condition="'\$\((?:Configuration)\)\|\$\((?:Platform)\)'=='ReleaseTest\|Win32'">.*?<RuntimeLibrary>)MultiThreadedDLL(</RuntimeLibrary>)
'@.Trim()
        $vcxText = [regex]::Replace(
            $vcxText,
            $releaseTestStaticCrtPattern,
            '$1MultiThreaded$2')
    }

    if ($vcxText -ne $vcxTextOrig) {
        Write-Utf8NoBom $_.FullName $vcxText
    }
}

Write-Info "Prepared source tree at $sourceDir"

$global:LASTEXITCODE = 0
exit 0
