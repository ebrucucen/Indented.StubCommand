#Requires -Module Configuration, Pester

using namespace System.Collections.Generic
using namespace System.Diagnostics
using namespace System.IO
using namespace System.Management.Automation
using namespace System.Management.Automation.Language

[CmdletBinding(DefaultParameterSetName = 'RunBuild')]
param(
    # The build type. Cannot use enum yet, it's not declared until this has executed.
    [Parameter(Position = 1)]
    [String[]]$Steps = ('Build', 'Test'),

    # The release type.
    [Parameter(Position = 2)]
    [ValidateSet('Build', 'Minor', 'Major')]
    [String]$ReleaseType = 'Build',

    # Return each the results of each build step as an object.
    [Parameter(ParameterSetName = 'RunBuild')]
    [Switch]$PassThru,

    # Return the BuildInfo object but do not run the build.
    [Parameter(ParameterSetName = 'GetInfo')]
    [Switch]$GetBuildInfo,

    # Suppress messages written by Write-Host.
    [Switch]$Quiet
)

function Build {
    'Setup'
    'Clean'
    'TestSyntax'
    'Merge'
    'ImportDependencies'
    'BuildVSSolution'
    'UpdateMetadata'
}

function Test {
    'VSUnitTest'
    'PSUnitTest'
}

function Release {
    'UpdateVersion'
}

class BuildOptions {
    [Boolean]$UseCommonBuildDirectory = $false

    [Double]$CodeCoverageThreshold = 0.9
}

class BuildInfo {
    # The name of the module being built.
    [String]$ModuleName = (Get-Item $pwd).Parent.GetDirectories((Split-Path $pwd -Leaf)).Name

    # The build steps.
    [String[]]$Steps

    # The release type.
    [ValidateSet('Build', 'Minor', 'Major')]
    [String]$ReleaseType = 'Build'

    [Version]$Version

    # The root of this repository.
    [String]$ProjectRoot = ((git rev-parse --show-toplevel) -replace '/', ([Path]::DirectorySeparatorChar))

    # The root of the item which is being built.
    [DirectoryInfo]$Source = $pwd.Path

    # The package generated by the build process.
    [DirectoryInfo]$Package

    # An output directory which stores files created by tools like Pester.
    [DirectoryInfo]$Output

    # The manifest associated with the package.
    [String]$ReleaseManifest

    # The root module associated with the package.
    [String]$ReleaseRootModule

    [BuildOptions]$BuildOptions = ([BuildOptions]::new())

    # Constructors

    BuildInfo($Steps, $ReleaseType) {
        $this.Steps = $Steps
        $this.ReleaseType = $ReleaseType

        $this.Version = $this.GetVersion()

        $this.Package = Join-Path $pwd $this.Version
        $this.Output = Join-Path $pwd 'output'
        if ($pwd.Path -ne $this.ProjectRoot) {
            if ($this.BuildOptions.UseCommonBuildDirectory) {
                $this.Package = [Path]::Combine($this.ProjectRoot, 'build', $this.ModuleName, $this.Version)
                $this.Output = [Path]::Combine($this.ProjectRoot, 'build', 'output', $this.ModuleName)
            }
        }
        $this.ReleaseManifest = Join-Path $this.Package ('{0}.psd1' -f $this.ModuleName)
        $this.ReleaseRootModule = Join-Path $this.Package ('{0}.psm1' -f $this.ModuleName)
    }

    # Private methods

    hidden [Version] GetVersion() {
        # Prefer to use version numbers from git.
        $packageVersion = [Version]'1.0.0.0'
        try {
            [String]$gitVersion = (git describe --tags 2> $null) -replace '^v'
            if ([Version]::TryParse($gitVersion, [Ref]$packageVersion)) {
                return $this.IncrementVersion($packageVersion)
            }
        } catch {
            # Do nothing.
        }

        # Fall back to version numbers in the manifest.
        $sourceManifest = [Path]::Combine($this.Source, 'source', ('{0}.psd1' -f $this.ModuleName))
        if (Test-Path $sourceManifest) {
            $manifestVersion = Get-Metadata -Path $sourceManifest -PropertyName ModuleVersion
            if ([Version]::TryParse($manifestVersion, [Ref]$packageVersion)) {
                return $this.IncrementVersion($packageVersion)
            }
        }

        return $packageVersion
    }

    hidden [Version] IncrementVersion($version) {
        $ctorArgs = switch ($this.ReleaseType) {
            'Major' { ($version.Major + 1), 0, 0, 0 }
            'Minor' { $version.Major, ($version.Minor + 1), 0, 0 }
            'Build' { $version.Major, $version.Minor, ($version.Build + 1), 0 }
        }
        return New-Object Version($ctorArgs)
    }
}

# Supporting functions

function Enable-Metadata {
    # .SYNOPSIS
    #   Enable a metadata property which has been commented out.
    # .DESCRIPTION
    #   This function is derived Get and Update-Metadata from PoshCode\Configuration.
    #
    #   A boolean value is returned indicating if the property is available in the metadata file.
    # .PARAMETER Path
    #   A valid metadata file or string containing the metadata.
    # .PARAMETER PropertyName
    #   The property to enable.
    # .INPUTS
    #   System.String
    # .OUTPUTS
    #   System.Boolean
    # .NOTES
    #   Author: Chris Dent
    #
    #   Change log:
    #     04/08/2016 - Chris Dent - Created.

    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param(
        [Parameter(ValueFromPipelineByPropertyName = $true, Position = 0)]
        [ValidateScript( { Test-Path $_ -PathType Leaf } )]
        [Alias("PSPath")]
        [String]$Path,

        [String]$PropertyName
    )

    process {
        # If the element can be found using Get-Metadata leave it alone and return true
        $shouldCreate = $false
        try {
            $null = Get-Metadata @psboundparameters -ErrorAction Stop
        } catch [ItemNotFoundException] {
            # The function will only execute where the requested value is not present
            $shouldCreate = $true
        } catch {
            # Ignore other errors which may be raised by Get-Metadata except path not found.
            if ($_.Exception.Message -eq 'Path must point to a .psd1 file') {
                $pscmdlet.ThrowTerminatingError($_)
            }
        }
        if (-not $shouldCreate) {
            return $true
        }

        $manifestContent = Get-Content $Path -Raw
    
        $tokens = $parseErrors = $null
        $ast = [Parser]::ParseInput(
            $manifestContent,
            $Path,
            [Ref]$tokens,
            [Ref]$parseErrors
        )

        # Attempt to find a comment which matches the requested property
        $regex = '^ *# *({0}) *=' -f $PropertyName
        $existingValue = @($tokens | Where-Object { $_.Kind -eq 'Comment' -and $_.Text -match $regex })
        if ($existingValue.Count -eq 1) {
            $manifestContent = $ast.Extent.Text.Remove(
                $existingValue.Extent.StartOffset,
                $existingValue.Extent.EndOffset - $existingValue.Extent.StartOffset
            ).Insert(
                $existingValue.Extent.StartOffset,
                $existingValue.Extent.Text -replace '^# *'
            )

            try {
                Set-Content -Path $Path -Value $manifestContent -NoNewline -ErrorAction Stop
            } catch {
                return $false
            }
            return $true
        } elseif ($existingValue.Count -eq 0) {
            # Item not found
            Write-Verbose "Can't find disabled property '$PropertyName' in $Path"
            return $false
        } else {
            # Ambiguous match
            Write-Verbose "Found more than one '$PropertyName' in $Path"
            return $false
        }
    }
}

function Invoke-Step {
    # .SYNOPSIS
    #   Invoke a build step.
    # .DESCRIPTION
    #   An output display wrapper to show progress through a build.
    # .INPUTS
    #   System.String
    # .OUTPUTS
    #   System.Object
    # .NOTES
    #   Author: Chris Dent
    #
    #   Change log:
    #     01/02/2017 - Chris Dent - Added help.
    
    param(
        [Parameter(ValueFromPipeline = $true)]
        $StepName,

        [Ref]$StepInfo
    )

    begin {
        $stopWatch = New-Object StopWatch
    }
    
    process {
        $progressParams = @{
            Activity = 'Building {0} ({1})' -f $this.ModuleName, $this.Version
            Status   = 'Executing {0}' -f $StepName
        }
        Write-Progress @progressParams

        $StepInfo.Value = [PSCustomObject]@{
            Name      = $StepName
            Result    = 'Success'
            StartTime = [DateTime]::Now
            TimeTaken = $null
            Errors    = $null
        }
        $messageColour = 'Green'
        
        $stopWatch = New-Object System.Diagnostics.StopWatch
        $stopWatch.Start()

        try {
            if (Get-Command $StepName -ErrorAction SilentlyContinue) {
                & $StepName
            } else {
                $StepInfo.Value.Errors = 'InvalidStep'
            }
        } catch {
            $StepInfo.Value.Result = 'Failed'
            $StepInfo.Value.Errors = $_
            $messageColour = 'Red'
        }

        $stopWatch.Stop()
        $stepInfo.Value.TimeTaken = $stopWatch.Elapsed

        if (-not $Quiet) {
            Write-Host $StepName.PadRight(30) -ForegroundColor Cyan -NoNewline
            Write-Host -ForegroundColor $messageColour -Object $stepInfo.Value.Result.PadRight(10) -NoNewline
            Write-Host $StepInfo.Value.StartTime.ToString('t').PadRight(10) -ForegroundColor Gray -NoNewLine
            Write-Host $StepInfo.Value.TimeTaken -ForegroundColor Gray
        }
    }
}

function Write-Message {
    param(
        [String]$Object,

        [ConsoleColor]$ForegroundColor
    )

    $null = $psboundparameters.Remove('Quiet')
    if (-not $Script:Quiet) {
        Write-Host
        Write-Host @psboundparameters
        Write-Host
    }
}

# Steps

function Setup {
    Set-Alias msbuild "C:\Program Files (x86)\MSBuild\14.0\bin\MSBuild.exe" -Scope Script
}

function Clean {
    # .SYNOPSIS
    #   Clean the last build of this module from the build directory.
    # .NOTES
    #   Author: Chris Dent
    #
    #   Change log:
    #     01/02/2017 - Chris Dent - Added help.

    if (Get-Module $buildInfo.ModuleName) {
        Remove-Module $buildInfo.ModuleName
    }

    if (Test-Path (Split-Path $buildInfo.Package -Parent)) {
        Get-ChildItem (Split-Path $buildInfo.Package -Parent) -Directory |
            Where-Object { $_.Name -eq 'Output' -or [Version]::TryParse($_.Name, [Ref]$null) } |
            Remove-Item -Recurse -Force
    }

    $null = New-Item $buildInfo.Output -ItemType Directory -Force
    $null = New-Item $buildInfo.Package -ItemType Directory -Force
}

function TestSyntax {
    # .SYNOPSIS
    #   Test for syntax errors in .ps1 files.
    # .DESCRIPTION
    #   Test for syntax errors in InitializeModule and all .ps1 files (recursively) beneath:
    #
    #     * pwd\source\public
    #     * pwd\source\private
    #
    # .NOTES
    #   Author: Chris Dent
    #
    #   Change log:
    #     01/02/2017 - Chris Dent - Added help.

    $hasSyntaxErrors = $false
    foreach ($path in 'public', 'private', 'InitializeModule.ps1') {
        $path = Join-Path 'source' $path
        if (Test-Path $path) {
            Get-ChildItem $path -Filter *.ps1 -File -Recurse | Where-Object { $_.Length -gt 0 -and $_.Extension -eq '.ps1' } | ForEach-Object {
                $tokens = $null
                [ParseError[]]$parseErrors = @()
                $ast = [Parser]::ParseInput(
                    (Get-Content $_.FullName -Raw),
                    $_.FullName,
                    [Ref]$tokens,
                    [Ref]$parseErrors
                )
                if ($parseErrors.Count -gt 0) {
                    $parseErrors | Write-Error

                    $hasSyntaxErrors = $true
                }
            }
        }
    }
    if ($hasSyntaxErrors) {
        throw 'TestSyntax failed'
    }
}

function Merge {
    # .SYNOPSIS
    #   Merge source files into a module.
    # .DESCRIPTION
    #   Merge the files which represent a module in development into a single psm1 file.
    #
    #   If an InitializeModule script (containing an InitializeModule function) is present it will be called at the end of the .psm1.
    #
    #   "using" statements are merged and added to the top of the root module.
    # .NOTES
    #   Author: Chris Dent
    #
    #   Change log:
    #     01/02/2017 - Chris Dent - Added help.
    
    $mergeItems = 'enumerations', 'classes', 'private', 'public', 'InitializeModule.ps1'

    Get-ChildItem 'source' -Exclude $mergeItems |
        Copy-Item -Destination $buildInfo.Package -Recurse

    $fileStream = [System.IO.File]::Create($buildInfo.ReleaseRootModule)
    $writer = New-Object System.IO.StreamWriter($fileStream)

    $usingStatements = New-Object List[String]

    foreach ($item in $mergeItems) {
        $path = Join-Path 'source' $item

        Get-ChildItem $path -Filter *.ps1 -File -Recurse | Where-Object { $_.Length -gt 0 -and $_.Extension -eq '.ps1' } | ForEach-Object {
            $functionDefinition = Get-Content $_.FullName | ForEach-Object {
                if ($_ -match '^using') {
                    $usingStatements.Add($_)
                } else {
                    $_.TrimEnd()
                }
            } | Out-String

            $writer.WriteLine($functionDefinition.Trim())
            $writer.WriteLine()
        }
    }

    if (Test-Path 'source\InitializeModule.ps1') {
        $writer.WriteLine('InitializeModule')
    }

    $writer.Close()

    $rootModule = (Get-Content $buildInfo.ReleaseRootModule -Raw).Trim()
    if ($usingStatements.Count -gt 0) {
        # Add "using" statements to be start of the psm1
        $rootModule = $rootModule.Insert(0, "`r`n`r`n").Insert(
            0,
            (($usingStatements.ToArray() | Sort-Object | Get-Unique) -join "`r`n")
        )
    }
    Set-Content -Path $buildInfo.ReleaseRootModule -Value $rootModule -NoNewline
}

function ImportDependencies {
    if (Test-Path 'modules.config') {
        $libPath = Join-Path $buildInfo.Package 'lib'
        if (-not (Test-Path $libPath)) {
            $null = New-Item $libPath -ItemType Directory
        }
        foreach ($module in ([Xml](Get-Content 'modules.config' -Raw)).modules.module) {
            Find-Module -Name $module.Name | Save-Module -Path $libPath
        }
    }
}

function BuildVSSolution {
    if (Test-Path 'source\classes\*.sln') {
        Push-Location 'source\classes'

        # nuget restore

        msbuild /t:Clean /t:Build /p:DebugSymbols=false /p:DebugType=None
        if ($lastexitcode -ne 0) {
            throw 'msbuild failed'
        }

        $path = (Join-Path $buildInfo.Package 'lib')
        if (-not (Test-Path $path)) {
            $null = New-Item $path -ItemType Directory -Force
        }
        Get-Item * -Exclude *.tests, packages | Where-Object PsIsContainer | ForEach-Object {
            Get-ChildItem $_.FullName -Filter *.dll -Recurse |
                Where-Object FullName -like '*bin*' |
                Copy-Item -Destination $path
        }

        Pop-Location
    }
}

function UpdateMetadata {
    # .SYNOPSIS
    #   Update the module manifest.
    # .DESCRIPTION
    #   Update the module manifest with:
    #
    #     * RootModule
    #     * FunctionsToExport
    #     * RequiredAssemblies
    #     * FormatsToProcess
    #     * LicenseUri
    #     * ProjectUri
    #
    # .NOTES
    #   Author: Chris Dent
    #
    #   Change log:
    #     01/02/2017 - Chris Dent - Added help.

    # Version
    Update-Metadata $buildInfo.ReleaseManifest -PropertyName ModuleVersion -Value $buildInfo.Version

    # RootModule
    if (Enable-Metadata $buildInfo.ReleaseManifest -PropertyName RootModule) {
        Update-Metadata $buildInfo.ReleaseManifest -PropertyName RootModule -Value (Split-Path $buildInfo.ReleaseRootModule -Leaf)
    }

    # FunctionsToExport
    if (Enable-Metadata $buildInfo.ReleaseManifest -PropertyName FunctionsToExport) {
        Update-Metadata $buildInfo.ReleaseManifest -PropertyName FunctionsToExport -Value (
            (Get-ChildItem 'source\public' -Filter '*.ps1' -File -Recurse).BaseName
        )
    }

    # RequiredAssemblies
    if (Test-Path (Join-Path $buildInfo.Package '\lib\*.dll')) {
        if (Enable-Metadata $buildInfo.ReleaseManifest -PropertyName RequiredAssemblies) {
            Update-Metadata $buildInfo.ReleaseManifest -PropertyName RequiredAssemblies -Value (
                (Get-Item (Join-Path $buildInfo.Package 'lib\*.dll')).Name | ForEach-Object {
                    Join-Path 'lib' $_
                }
            )
        }
    }

    # FormatsToProcess
    if (Test-Path (Join-Path $buildInfo.Package '*.Format.ps1xml')) {
        if (Enable-Metadata $buildInfo.ReleaseManifest -PropertyName FormatsToProcess) {
            Update-Metadata $buildInfo.ReleaseManifest -PropertyName FormatsToProcess -Value (Join-Path $buildInfo.Package '*.Format.ps1xml').Name
        }
    }

    # LicenseUri (assume MIT)
    if (Test-Path (Join-Path $buildInfo.Package 'LICENSE')) {
        if (Enable-Metadata $buildInfo.ReleaseManifest -PropertyName LicenseUri) {
            Update-Metadata $buildInfo.ReleaseManifest -PropertyName LicenseUri -Value 'https://opensource.org/licenses/MIT'
        }
    }

    # ProjectUri
    if (Enable-Metadata $buildInfo.ReleaseManifest -PropertyName ProjectUri) {
        # Attempt to parse the project URI from the list of upstream repositories
        [String]$pushOrigin = (git remote -v) -like 'origin*(push)'
        if ($pushOrigin -match 'origin\s+(?<ProjectUri>\S+).git') {
            Update-Metadata $buildInfo.ReleaseManifest -PropertyName ProjectUri -Value $matches.ProjectUri
        }
    }
}

function VSUnitTest {
    if (Test-Path 'source\classes\*.sln') {
        $path = 'source\classes\packages\NUnit.ConsoleRunner.*\tools\nunit3-console.exe'
        if (Test-Path $path) {
            $nunitConsole = (Resolve-Path $path).Path
            Get-ChildItem 'source\classes' -Filter *tests.dll -Recurse | Where-Object FullName -like '*bin*' | ForEach-Object {
                & $nunitConsole $_.FullName --result ('{0}\{1}.xml' -f $buildInfo.Output.FullName, ($_.Name -replace '\.tests'))

                if ($lastexitcode -ne 0) {
                    throw 'VS unit tests failed'
                }
            }
        }
    }
}

function PSUnitTest {
    # Execute unit tests
    # Note: These tests are being executed against the Packaged module, not the code in the repository.

    if (-not (Get-ChildItem 'test' -Filter *.tests.ps1 -Recurse -File)) {
        throw 'The PS project must have tests!'    
    }

    Import-Module $buildInfo.ReleaseManifest -ErrorAction Stop
    $params = @{
        Script       = 'test'
        CodeCoverage = $buildInfo.ReleaseRootModule
        OutputFile   = Join-Path $buildInfo.Output ('{0}.xml' -f $buildInfo.ModuleName)
        PassThru     = $true
    }
    $pester = Invoke-Pester @params

    if ($pester.FailedCount -gt 0) {
        throw 'PS unit tests failed'
    }

    [Double]$codeCoverage = $pester.CodeCoverage.NumberOfCommandsExecuted / $pester.CodeCoverage.NumberOfCommandsAnalyzed
    $pester.CodeCoverage.MissedCommands | Export-Csv (Join-Path $buildInfo.Output 'CodeCoverage.csv') -NoTypeInformation

    if ($codecoverage -lt $buildInfo.CodeCoverageThreshold) {
        $message = 'Code coverage ({0:P}) is below threshold {1:P}.' -f $codeCoverage, $buildInfo.CodeCoverageThreshold 
        throw $message
    }
}

function UpdateVersion {
    $sourceManifest = [System.IO.Path]::Combine($buildInfo.Source, 'Source', ('{0}.psd1' -f $buildInfo.ModuleName))
    Update-Metadata $sourceManifest -PropertyName ModuleVersion -Value $buildInfo.Version
}

# Run the build

try {
    Push-Location $psscriptroot

    # Expand steps
    $Steps = $Steps | ForEach-Object { & $_ }
    $buildInfo = New-Object BuildInfo($Steps, $ReleaseType)
    if ($GetBuildInfo) {
        return $buildInfo
    } else {
        $Script:Quiet = $Quiet.ToBool()

        Write-Message ('Building {0} ({1})' -f $buildInfo.ModuleName, $buildInfo.Version)
        
        foreach ($step in $steps) {
            $stepInfo = New-Object PSObject
            Invoke-Step $step -StepInfo ([Ref]$stepInfo)

            if ($PassThru) {
                $stepInfo
            }

            if ($stepInfo.Result -ne 'Success') {
                throw $stepinfo.Errors
            }
        }

        Write-Message "Build succeeded!" -ForegroundColor Green

        $lastexitcode = 0
    }
} catch {
    Write-Message 'Build Failed!' -ForegroundColor Red

    $lastexitcode = 1

    # Catches unexpected errors, rethrows errors raised while executing steps.
    throw
} finally {
    Pop-Location
}