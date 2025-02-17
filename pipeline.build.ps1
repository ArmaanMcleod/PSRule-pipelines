# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

[CmdletBinding()]
param (
    [Parameter(Mandatory = $False)]
    [String]$Build = '0.0.1',

    [Parameter(Mandatory = $False)]
    [String]$Configuration = 'Debug',

    [Parameter(Mandatory = $False)]
    [String]$AssertStyle = 'AzurePipelines'
)

Write-Host -Object "[Pipeline] -- PWD: $PWD" -ForegroundColor Green;
Write-Host -Object "[Pipeline] -- BuildNumber: $($Env:BUILD_BUILDNUMBER)" -ForegroundColor Green;
Write-Host -Object "[Pipeline] -- SourceBranch: $($Env:BUILD_SOURCEBRANCH)" -ForegroundColor Green;
Write-Host -Object "[Pipeline] -- SourceBranchName: $($Env:BUILD_SOURCEBRANCHNAME)" -ForegroundColor Green;

if ($Env:SYSTEM_DEBUG -eq 'true') {
    $VerbosePreference = 'Continue';
}

if ($Env:BUILD_SOURCEBRANCH -like '*/tags/*' -and $Env:BUILD_SOURCEBRANCHNAME -like 'v1.*') {
    $Build = $Env:BUILD_SOURCEBRANCHNAME.Substring(1);
}

$version = $Build;
$versionSuffix = [String]::Empty;

if ($version -like '*-*') {
    [String[]]$versionParts = $version.Split('-', [System.StringSplitOptions]::RemoveEmptyEntries);
    $version = $versionParts[0];

    if ($versionParts.Length -eq 2) {
        $versionSuffix = $versionParts[1];
    }
}

if ($Env:QUERYAZUREDEVOPSEXTENSIONVERSION_EXTENSION_VERSION) {
    Write-Verbose -Message "[Pipeline] -- Using EXTENSION_VERSION: $Env:QUERYAZUREDEVOPSEXTENSIONVERSION_EXTENSION_VERSION";
    [String[]]$extensionParts = $Env:QUERYAZUREDEVOPSEXTENSIONVERSION_EXTENSION_VERSION.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries);
    [String[]]$versionParts = $version.Split('.', [System.StringSplitOptions]::RemoveEmptyEntries);

    if ([System.Version]::Parse($Env:QUERYAZUREDEVOPSEXTENSIONVERSION_EXTENSION_VERSION) -ge [System.Version]::Parse($version)) {
        $version = [String]::Join('.', @($versionParts[0], $versionParts[1], $extensionParts[2]));
    }
}

Write-Host -Object "[Pipeline] -- Using version: $version" -ForegroundColor Green;
Write-Host -Object "[Pipeline] -- Using versionSuffix: $versionSuffix" -ForegroundColor Green;

# A list of tasks included in the extension
$tasks = @((Get-ChildItem -Path tasks/ -Directory).Name)

# Copy the extension files to the destination path
function CopyExtensionFiles {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [String]$Path,

        [Parameter(Mandatory = $True)]
        [String]$DestinationPath
    )
    process {
        $sourcePath = Resolve-Path -Path $Path;
        Get-ChildItem -Path $sourcePath -File -Include *.ps1,*.json,*.png,*.ts -Recurse | Where-Object {
            ($_.FullName -notmatch '(\\|\/)(node_modules)')
        } | ForEach-Object {
            $filePath = $_.FullName.Replace($sourcePath, $DestinationPath);
            $parentPath = Split-Path -Path $filePath -Parent;
            if (!(Test-Path -Path $parentPath)) {
                $Null = New-Item -Path $parentPath -ItemType Directory -Force;
            }
            Copy-Item -Path $_.FullName -Destination $filePath -Force;
        };
    }
}

function Get-RepoRuleData {
    [CmdletBinding()]
    param (
        [Parameter(Position = 0, Mandatory = $False)]
        [String]$Path = $PWD
    )
    process {
        GetPathInfo -Path $Path -Verbose:$VerbosePreference;
    }
}

function GetPathInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [String]$Path
    )
    begin {
        $items = New-Object -TypeName System.Collections.ArrayList;
    }
    process {
        $Null = $items.Add((Get-Item -Path $Path));
        $files = @(Get-ChildItem -Path $Path -File -Recurse -Include *.ps1,*.ts,*.psm1,*.psd1,*.cs | Where-Object {
            !($_.FullName -like "*.Designer.cs") -and
            !($_.FullName -like "*/bin/*") -and
            !($_.FullName -like "*/obj/*") -and
            !($_.FullName -like "*\obj\*") -and
            !($_.FullName -like "*\bin\*") -and
            !($_.FullName -like "*\out\*") -and
            !($_.FullName -like "*/out/*") -and
            !($_.FullName -like "*\node_modules\*") -and
            !($_.FullName -like "*/node_modules/*")
        });
        $Null = $items.AddRange($files);
    }
    end {
        $items;
    }
}

function UpdateTaskVersion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True)]
        [String]$Path
    )
    process {
        $buildNumber = [int]::Parse($Env:BUILD_BUILDNUMBER.Split('-', [System.StringSplitOptions]::RemoveEmptyEntries)[1].Replace('B', ''));
        Get-ChildItem -Path $Path -Filter task.json -Recurse | ForEach-Object {
            $filePath = $_.FullName;
            $taskContent = Get-Content -Raw -Path $filePath | ConvertFrom-Json;
            $taskContent.version.patch = $buildNumber;
            $taskContent | ConvertTo-Json -Depth 100 | Set-Content -Path $filePath -Force;
        }
    }
}

# Synopsis: Install NuGet provider
task NuGet {
    if ($Null -eq (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser;
    }
}

# Synopsis: Install Pester module
task Pester NuGet, {
    if ($Null -eq (Get-InstalledModule -Name Pester -RequiredVersion 4.10.1 -ErrorAction SilentlyContinue)) {
        Install-Module -Name Pester -RequiredVersion 4.10.1 -Scope CurrentUser -Force -SkipPublisherCheck;
    }
    Import-Module -Name Pester -RequiredVersion 4.10.1 -Verbose:$False;
}

# Synopsis: Install PSScriptAnalyzer module
task PSScriptAnalyzer NuGet, {
    if ($Null -eq (Get-InstalledModule -Name PSScriptAnalyzer -MinimumVersion 1.18.3 -ErrorAction SilentlyContinue)) {
        Install-Module -Name PSScriptAnalyzer -MinimumVersion 1.18.3 -Scope CurrentUser -Force;
    }
    Import-Module -Name PSScriptAnalyzer -Verbose:$False;
}

# Synopsis: Install PlatyPS module
task platyPS {
    if ($Null -eq (Get-InstalledModule -Name PlatyPS -MinimumVersion 0.14.0 -ErrorAction SilentlyContinue)) {
        Install-Module -Name PlatyPS -Scope CurrentUser -MinimumVersion 0.14.0 -Force;
    }
    Import-Module -Name PlatyPS -Verbose:$False;
}

# Synopsis: Install PSRule modules
task PSRule NuGet, {
    if (!(Test-Path -Path out/dist/ps_modules)) {
        $Null = New-Item -Path out/dist/ps_modules -ItemType Directory -Force;
    }
    if ($Null -eq (Get-InstalledModule -Name PSRule -RequiredVersion 1.11.0 -ErrorAction SilentlyContinue)) {
        Install-Module -Name PSRule -Scope CurrentUser -RequiredVersion 1.11.0 -Force;
    }
    Save-Module -Name PSRule -Path out/dist/ps_modules -RequiredVersion 1.11.0;
    Import-Module -Name PSRule -Verbose:$False;
}

# Synopsis: Install VstsTaskSdk module
task VstsTaskSdk NuGet, {
    if (!(Test-Path -Path out/ps_modules)) {
        $Null = New-Item -Path out/ps_modules -ItemType Directory -Force;
    }
    Save-Module -Name VstsTaskSdk -Path out/ps_modules -RequiredVersion 0.11.0;

    foreach ($task in $tasks) {
        $taskRoot = $task.Split('V')[0];
        Copy-Item -Path out/ps_modules/VstsTaskSdk/0.11.0/* -Destination "out/dist/$taskRoot/$task/ps_modules/VstsTaskSdk/" -Recurse -Force;
    }

    Remove-Item  -Path out/ps_modules/VstsTaskSdk -Force -Recurse;
}

task PowerShellGet NuGet, {
    if (!(Test-Path -Path out/dist/ps_modules)) {
        $Null = New-Item -Path out/dist/ps_modules -ItemType Directory -Force;
    }
    Save-Module -Name PowerShellGet -Path out/dist/ps_modules -MinimumVersion 2.2.3;
}

# Synopsis: Remove temp files.
task Clean {
    Remove-Item -Path out,reports -Recurse -Force -ErrorAction SilentlyContinue;
}

task CopyExtension {

    foreach ($task in $tasks) {
        $taskRoot = $task.Split('V')[0];
        CopyExtensionFiles -Path "tasks/$task" -DestinationPath "out/dist/$taskRoot/$task/";
        Copy-Item -Path package.json -Destination "out/dist/$taskRoot/$task/";
        Copy-Item -Path images/icon128.png -Destination "out/dist/$taskRoot/$task/icon.png" -Force;
    }

    # Copy manifests
    Copy-Item -Path vss-extension.json -Destination out/dist/;

    # Copy icon
    if (!(Test-Path -Path out/dist/images)) {
        $Null = New-Item -Path out/dist/images -ItemType Directory -Force;
    }
    Copy-Item -Path images/icon128.png -Destination out/dist/images/ -Force;

    # Copy repo files
    Copy-Item -Path extension.md -Destination out/dist/;
    Copy-Item -Path CHANGELOG.md -Destination out/dist/;
    Copy-Item -Path LICENSE -Destination out/dist/;
}

task BuildExtension CopyExtension, PSRule, PowerShellGet, VstsTaskSdk, {
    Write-Host '> Building extension' -ForegroundColor Green;

    foreach ($task in $tasks) {
        $taskRoot = $task.Split('V')[0];
        try {
            Push-Location "out/dist/$taskRoot/$task/"
            exec { & npm install --only=prod }
            exec { & npm run compile }

            Remove-Item -Path *.ts -Force;
        }
        finally {
            Pop-Location;
        }
    }
}

task VersionExtension {
    $extensionPath = Join-Path -Path out/dist/ -ChildPath 'vss-extension.json';
    Write-Verbose -Message "[VersionExtension] -- Checking module path: $extensionPath";

    if (![String]::IsNullOrEmpty($Build)) {
        # Update module version
        if (![String]::IsNullOrEmpty($version)) {
            Write-Verbose -Message "[VersionExtension] -- Updating extension manifest version";
            $content = Get-Content -Path $extensionPath -Raw | ConvertFrom-Json;
            $content.version = $version;
            $content | ConvertTo-Json -Depth 100 | Set-Content -Path $extensionPath;

            # Write version info
            if (!(Test-Path -Path out/extension)) {
                $Null = New-Item -Path out/extension -ItemType Directory -Force;
            }
            $versionInfo = Join-Path -Path out/extension/ -ChildPath 'version.json';
            @{ version = $version } | ConvertTo-Json | Set-Content -Path $versionInfo;
        }
    }

    UpdateTaskVersion -Path out/dist/;
}

# Synopsis: This task reads version info if set and configures a build variable
task GetVersionInfo {
    Write-Host "[Pipeline] Using EXTENSION_VERSION: $version";
    Write-Host "`#`#vso[task.setvariable variable=EXTENSION_VERSION;]$version";
}

# Synopsis: Run validation
task Rules PSRule, {
    $assertParams = @{
        Path = './.ps-rule/'
        Style = $AssertStyle
        OutputFormat = 'NUnit3'
        ErrorAction = 'Stop'
    }
    Get-RepoRuleData -Path $PWD |
        Assert-PSRule @assertParams -OutputPath reports/ps-rule-file.xml;
}

task TestModule Pester, PSScriptAnalyzer, {
    # Run Pester tests
    $pesterParams = @{ Path = $PWD; OutputFile = 'reports/pester-unit.xml'; OutputFormat = 'NUnitXml'; PesterOption = @{ IncludeVSCodeMarker = $True }; PassThru = $True; };

    if ($CodeCoverage) {
        $pesterParams.Add('CodeCoverage', (Join-Path -Path $PWD -ChildPath 'tasks/**/*.ps1'));
        $pesterParams.Add('CodeCoverageOutputFile', (Join-Path -Path $PWD -ChildPath reports/pester-coverage.xml));
    }

    if (!(Test-Path -Path reports)) {
        $Null = New-Item -Path reports -ItemType Directory -Force;
    }

    $results = Invoke-Pester @pesterParams;

    # Throw an error if pester tests failed
    if ($Null -eq $results) {
        throw 'Failed to get Pester test results.';
    }
    elseif ($results.FailedCount -gt 0) {
        throw "$($results.FailedCount) tests failed.";
    }
}

# Synopsis: Restore NPM packages
task PackageRestore {
    exec { & npm install --no-save }
}

# Synopsis: Build and clean.
task . Test

# Synopsis: Build the project
task Build Clean, Rules, PackageRestore, BuildExtension, VersionExtension

task Test Build, TestModule
