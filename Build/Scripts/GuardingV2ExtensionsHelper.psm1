<#
.Synopsis
    Configure breaking changes check
.Description
    Configure breaking changes check by:
    - Restoring the baseline package and placing it in the app symbols folder
    - Generating an AppSourceCop.json with version and name of the extension
.Parameter AppSymbolsFolder
    Local AppSymbols folder
.Parameter AppProjectFolder
    Local AppProject folder
.Parameter BuildMode
    Build mode
#>
function Enable-BreakingChangesCheck {
    Param(
        [Parameter(Mandatory = $true)] 
        [string] $AppSymbolsFolder,
        [Parameter(Mandatory = $true)] 
        [string] $AppProjectFolder,
        [Parameter(Mandatory = $true)] 
        [string] $BuildMode
    )

    # Get name of the app from app.json
    $appJson = Join-Path $AppProjectFolder "app.json"
    $applicationName = (Get-Content -Path $appJson | ConvertFrom-Json).Name
    
    # Get the baseline version
    $baselineVersion = Get-BaselineVersion -BuildMode $BuildMode

    Write-Host "Restoring baselines for $applicationName from $baselineVersion"

    # Restore the baseline package and place it in the app symbols folder
    if ($BuildMode -eq 'Clean') {
        Write-Host "Enabling breaking changes check in Clean mode. Setting up $baselineVersion as a baseline as this is the latest version of AlAppExtensions"
        Restore-BaselinesFromNuget -AppSymbolsFolder $AppSymbolsFolder -ExtensionName $applicationName -BaselineVersion $baselineVersion
    } else {
        Write-Host "Enabling breaking changes check in Default mode. Setting up $baselineVersion version as a baseline"
        Restore-BaselinesFromArtifacts -AppSymbolsFolder $AppSymbolsFolder -ExtensionName $applicationName -BaselineVersion $baselineVersion
    }

    # Generate the app source cop json file
    Update-AppSourceCopVersion -ExtensionFolder $AppProjectFolder -ExtensionName $applicationName -BaselineVersion $baselineVersion
}

<#
.Synopsis
    Given an extension and a baseline version, it restores the baseline for an app from bcartifacts
.Parameter BaselineVersion
    Baseline version of the extension
.Parameter ExtensionName
    Name of the extension
.Parameter AppSymbolsFolder
    Local AppSymbols folder 
#>
function Restore-BaselinesFromArtifacts {
    Param(
        [Parameter(Mandatory = $true)] 
        [string] $BaselineVersion,
        [Parameter(Mandatory = $true)] 
        [string] $ExtensionName,
        [Parameter(Mandatory = $true)] 
        [string] $AppSymbolsFolder
    )
    $baselineFolder = Join-Path $([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())

    $baselineURL = Get-BCArtifactUrl -type Sandbox -country 'W1' -version $BaselineVersion
    if (-not $baselineURL) {
        throw "Unable to find URL for baseline version $BaselineVersion"
    }

    try {
        Write-Host "Downloading from $baselineURL to $baselineFolder"

        Download-Artifacts -artifactUrl $baselineURL -basePath $baselineFolder
        $baselineApp = Get-ChildItem -Path "$baselineFolder/sandbox/$BaselineVersion/W1/Extensions" -Filter "*$($ExtensionName)_$($BaselineVersion).app"

        if (-not $baselineApp) {
            throw "Unable to find baseline app for $ExtensionName in $baselineURL"
        }

        Write-Host "Copying $($baselineApp.FullName) to $AppSymbolsFolder"

        if (-not (Test-Path $AppSymbolsFolder)) {
            Write-Host "Creating folder $AppSymbolsFolder"
            New-Item -ItemType Directory -Path $AppSymbolsFolder
        }

        Copy-Item -Path $baselineApp.FullName -Destination $AppSymbolsFolder
    } finally {
        Remove-Item -Path $baselineFolder -Recurse -Force
    }
}

function Restore-BaselinesFromNuget {
    Param(
        [Parameter(Mandatory = $true)] 
        [string] $BaselineVersion,
        [Parameter(Mandatory = $true)] 
        [string] $ExtensionName,
        [Parameter(Mandatory = $true)] 
        [string] $AppSymbolsFolder
    )

    $baselineFolder = Join-Path $([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())

    try {
        Write-Host "Downloading from nuget to $baselineFolder"
    
        $packagePath = Get-PackageFromNuget -PackageId "microsoft-ALAppExtensions-Modules-preview" -Version $BaselineVersion -OutputPath $baselineFolder
        $baselineApp = Get-ChildItem -Path "$packagePath/Apps/$ExtensionName/Default/" -Filter "*.app"
    
        if (-not (Test-Path $AppSymbolsFolder)) {
            Write-Host "Creating folder $AppSymbolsFolder"
            New-Item -ItemType Directory -Path $AppSymbolsFolder
        }
    
        Write-Host "Copying $($baselineApp.FullName) to $AppSymbolsFolder"
    
        Copy-Item -Path $baselineApp.FullName -Destination $AppSymbolsFolder
    } finally {
        Remove-Item -Path $baselineFolder -Recurse -Force
    }
}

<#
.Synopsis
    Generate an AppSourceCop.json with version and name of the extension
.Parameter ExtensionFolder
    Path to the folder where AppSourceCop.json should be generated to
.Parameter Version
    Baseline version of the extension
.Parameter ExtensionName
    Name of the extension
.Parameter Publisher
    Publisher of the extension
#>
function Update-AppSourceCopVersion
(
    [Parameter(Mandatory = $true)] 
    [string] $ExtensionFolder, 
    [Parameter(Mandatory = $true)] 
    [string] $ExtensionName,
    [Parameter(Mandatory = $true)] 
    [string] $BaselineVersion,
    [Parameter(Mandatory = $false)] 
    [string] $Publisher = "Microsoft"
) {
    Import-Module $PSScriptRoot\EnlistmentHelperFunctions.psm1

    if ($BaselineVersion -match "^(\d+)\.(\d+)\.(\d+)$") {
        Write-Host "Baseline version is missing revision number. Adding revision number 0 to the baseline version" -ForegroundColor Yellow
        $BaselineVersion = $BaselineVersion + ".0"
    }

    if (-not ($BaselineVersion -and $BaselineVersion -match "^([0-9]+\.){3}[0-9]+$" )) {
        throw "Extension Compatibile Version cannot be null or invalid format. Valid format should be like '1.0.2.0'"
    }

    $appSourceCopJsonPath = Join-Path $ExtensionFolder AppSourceCop.json

    if (!(Test-Path $appSourceCopJsonPath)) {
        Write-Host "Creating AppSourceCop.json with version $BaselineVersion in path $appSourceCopJsonPath" -ForegroundColor Yellow
        New-Item $appSourceCopJsonPath -type file
        $appSourceJson = @{version = '' }
    }
    else {
        $appSourceJson = Get-Content $appSourceCopJsonPath -Raw | ConvertFrom-Json
    }

    Write-Host "Setting 'version:$BaselineVersion' in AppSourceCop.json" -ForegroundColor Yellow
    $appSourceJson["version"] = $BaselineVersion

    Write-Host "Setting 'name:$ExtensionName' value in AppSourceCop.json" -ForegroundColor Yellow
    $appSourceJson["name"] = $ExtensionName

    Write-Host "Setting 'publisher:$Publisher' value in AppSourceCop.json" -ForegroundColor Yellow
    $appSourceJson["publisher"] = $Publisher

    $buildVersion = Get-ConfigValueFromKey -Key "repoVersion"
    Write-Host "Setting 'obsoleteTagVersion:$buildVersion' value in AppSourceCop.json" -ForegroundColor Yellow
    $appSourceJson["obsoleteTagVersion"] = $buildVersion

    # All major versions greater than current but less or equal to main should be allowed
    $currentBuildVersion = [int] $buildVersion.Split('.')[0]
    $maxAllowedObsoleteVersion = [int] (Get-ConfigValueFromKey -ConfigType "BuildConfig" -Key "MaxAllowedObsoleteVersion")
    $obsoleteTagAllowedVersions = @()

    for ($i = $currentBuildVersion + 1; $i -le $maxAllowedObsoleteVersion; $i++) {
        $obsoleteTagAllowedVersions += "$i.0"
    }

    Write-Host "Setting 'obsoleteTagAllowedVersions:$obsoleteTagAllowedVersions' value in AppSourceCop.json" -ForegroundColor Yellow
    $appSourceJson["obsoleteTagAllowedVersions"] = $obsoleteTagAllowedVersions -join ','

    Write-Host "Updating AppSourceCop.json done successfully" -ForegroundColor Green
    $appSourceJson | ConvertTo-Json | Out-File $appSourceCopJsonPath -Encoding ASCII -Force

    if (-not (Test-Path $appSourceCopJsonPath)) {
        throw "AppSourceCop.json does not exist in path: $appSourceCopJsonPath"
    }

    return $appSourceCopJsonPath
}

<#
.Synopsis
    Gets the baseline version for the extension
.Parameter BuildMode
    Build mode
#>
function Get-BaselineVersion {
    Param(
        [Parameter(Mandatory = $true)] 
        [string] $BuildMode
    )
    
    Import-Module $PSScriptRoot\EnlistmentHelperFunctions.psm1

    if ($BuildMode -eq "Clean") {
        # Use latest available version from nuget if build mode is clean
        return (Find-Package -Name "microsoft-ALAppExtensions-Modules-preview" -Source "https://nuget.org/api/v2/").Version
    } else {
        return Get-ConfigValueFromKey -Key "BaselineVersion" -ConfigType "BuildConfig"
    }
}

Export-ModuleMember -Function *-*