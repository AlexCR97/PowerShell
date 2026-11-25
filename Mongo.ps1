# The connection strings carry passwords, so they live in this untracked file.
$script:MongoProfilesPath = "$PSScriptRoot\Mongo.local.json"

function Connect-Mongo {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete)
                (Get-MongoProfileConfig).PSObject.Properties.Name | Where-Object { $_ -like "$wordToComplete*" }
            })]
        [string] $Name,

        [string] $Database,

        [Parameter(ValueFromRemainingArguments)]
        [string[]] $MongoshArgs = @()
    )

    $uri = Resolve-MongoUri $Name $Database
    mongosh $uri @MongoshArgs
}

function Invoke-MongoScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [Parameter(Position = 1)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete)
                (Get-MongoProfileConfig).PSObject.Properties.Name | Where-Object { $_ -like "$wordToComplete*" }
            })]
        [string] $Name,

        [string] $Database
    )

    $script = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $uri = Resolve-MongoUri $Name $Database
    mongosh $uri --quiet --file $script.ProviderPath
}

# Writes <OutPath>\<profile>\<date>_<time>[_<label>]\<database>, one .bson and one .metadata.json per collection.
# The time keeps several dumps taken on the same day side by side.
function Save-MongoDump {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete)
                (Get-MongoProfileConfig).PSObject.Properties.Name | Where-Object { $_ -like "$wordToComplete*" }
            })]
        [string] $Name,

        [string] $Database,

        [ValidateNotNullOrEmpty()]
        [string] $OutPath = '.mongo/dumps',

        [ValidatePattern('^[\w.-]+$')]
        [string] $Label,

        [ValidateNotNullOrEmpty()]
        [string[]] $Collection = @(),

        [ValidateNotNullOrEmpty()]
        [string[]] $ExcludeCollection = @(),

        [switch] $Gzip,

        [ValidateRange(1, 64)]
        [int] $NumParallelCollections = 4
    )

    $ErrorActionPreference = 'Stop'

    if ($Collection -and $ExcludeCollection) {
        throw '-Collection and -ExcludeCollection cannot be combined. Name what to dump, or name what to skip.'
    }

    $mongodump = Get-MongoTool 'mongodump'
    $target = Resolve-MongoTarget $Name $Database

    $folderName = Get-Date -Format 'yyyy-MM-dd_HHmmss'
    if ($Label) { $folderName += "_$Label" }

    $outRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutPath)
    $dumpRoot = Join-Path $outRoot "$($target.Name)\$folderName"
    $databasePath = Join-Path $dumpRoot $target.Database

    # Only reachable when another dump started in this very second, and blending into it is never
    # what the caller wanted.
    $existingFiles = @(Get-ChildItem -LiteralPath $databasePath -File -ErrorAction SilentlyContinue)
    if ($existingFiles) {
        throw "'$databasePath' already holds $($existingFiles.Count) file(s). Re-run to dump into a new timestamped folder."
    }

    if ($PSCmdlet.ShouldProcess($dumpRoot, 'Create dump folder')) {
        New-Item -Path $dumpRoot -ItemType Directory -Force | Out-Null
    }

    $baseArguments = @(
        "--uri=$($target.Uri)"
        "--db=$($target.Database)"
        "--out=$dumpRoot"
        "--numParallelCollections=$NumParallelCollections"
    )

    if ($Gzip) { $baseArguments += '--gzip' }

    foreach ($excluded in $ExcludeCollection) {
        $baseArguments += "--excludeCollection=$excluded"
    }

    # --collection takes a single name, so each named collection is its own mongodump run.
    $jobs = @(
        if ($Collection) {
            foreach ($collectionName in $Collection) {
                [pscustomobject]@{ Name = $collectionName; Arguments = $baseArguments + "--collection=$collectionName" }
            }
        }
        else {
            [pscustomobject]@{ Name = 'all collections'; Arguments = $baseArguments }
        }
    )

    $scope = if ($Collection) { "$($Collection.Count) named collection(s): $($Collection -join ', ')" }
    elseif ($ExcludeCollection) { "all collections except $($ExcludeCollection -join ', ')" }
    else { 'all collections' }

    Write-Host ''
    Write-Host "Source     : $($target.Name) ($($target.Host)) -> $($target.Database)"
    Write-Host "Target     : $databasePath"
    Write-Host "Scope      : $scope"
    Write-Host "Mode       : $(if ($Gzip) { 'bson.gz (restore with -Gzip)' } else { 'bson' })"
    Write-Host ''

    $dumped = [System.Collections.Generic.List[object]]::new()
    $failures = [System.Collections.Generic.List[object]]::new()
    $runTimer = [System.Diagnostics.Stopwatch]::StartNew()

    # mongodump reports each finished collection on stderr as: done dumping <database>.<collection> (<n> documents)
    $donePattern = "done dumping $([regex]::Escape($target.Database))\.(?<collection>.+?) \((?<count>\d+) document"

    foreach ($job in $jobs) {
        if (-not $PSCmdlet.ShouldProcess("$($target.Database) ($($job.Name))", "mongodump to $databasePath")) { continue }

        Write-Progress -Activity "Dumping $($target.Database)" -Status $job.Name

        $result = Invoke-MongoTool $mongodump $job.Arguments {
            param($line)

            if ($line -match $donePattern) {
                $dumped.Add([pscustomobject]@{ Collection = $Matches['collection']; Documents = [int] $Matches['count'] })
                Write-Host ('[{0,4}] {1,-48} {2,9:N0} docs' -f $dumped.Count, $Matches['collection'], [int] $Matches['count'])
            }
        }

        Write-Verbose ($result.Output -join [Environment]::NewLine)

        if ($result.ExitCode -ne 0) {
            $failures.Add([pscustomobject]@{ Label = "$($job.Name) (exit $($result.ExitCode))"; Output = $result.Output })
        }
    }

    Write-Progress -Activity "Dumping $($target.Database)" -Completed
    $runTimer.Stop()

    if ($WhatIfPreference) { return }

    $totalDocuments = ($dumped | Measure-Object -Property Documents -Sum).Sum ?? 0
    $totalBytes = (Get-ChildItem -LiteralPath $databasePath -File -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum ?? 0

    $totalSize = switch ($totalBytes) {
        { $_ -ge 1GB } { '{0:N1} GB' -f ($totalBytes / 1GB); break }
        { $_ -ge 1MB } { '{0:N1} MB' -f ($totalBytes / 1MB); break }
        { $_ -ge 1KB } { '{0:N1} KB' -f ($totalBytes / 1KB); break }
        default { "$totalBytes bytes" }
    }

    Write-Host ''
    Write-Host ('Dumped {0:N0} document(s) from {1} collection(s) into {2} in {3:mm\:ss}.' -f $totalDocuments, $dumped.Count, $totalSize, $runTimer.Elapsed)

    if (-not $failures) {
        if ($dumped) {
            Write-Host ''
            Write-Host "Restore it with: Restore-MongoDump '$databasePath' <profile> -Drop$(if ($Gzip) { ' -Gzip' })" -ForegroundColor DarkGray
        }

        return
    }

    Write-MongoFailures $failures

    if ($failures.Output -match 'server selection error|no reachable servers|connection\(\) error') {
        Write-Host ''
        Write-Host "Could not reach '$($target.Host)'. Check the server is running and reachable, and that the profile '$($target.Name)' carries any required credentials." -ForegroundColor Yellow
    }

    throw "$($failures.Count) mongodump run(s) failed."
}

# Restores a dump folder written by Save-MongoDump. -DumpPath is the folder holding the .bson files, i.e. the <database> level.
function Restore-MongoDump {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $DumpPath,

        [Parameter(Position = 1)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete)
                (Get-MongoProfileConfig).PSObject.Properties.Name | Where-Object { $_ -like "$wordToComplete*" }
            })]
        [string] $Name,

        [string] $Database,

        [switch] $Drop,

        [switch] $Gzip
    )

    $ErrorActionPreference = 'Stop'

    $mongorestore = Get-MongoTool 'mongorestore'
    $dump = Get-Item -LiteralPath $DumpPath
    if (-not $dump.PSIsContainer) { throw "Dump path is not a folder: $($dump.FullName)" }

    $target = Resolve-MongoTarget $Name $Database
    Assert-MongoWritable $target

    Write-Host ''
    Write-Host "Source     : $($dump.FullName)"
    Write-Host "Target     : $($target.Name) ($($target.Host)) -> $($target.Database)"
    Write-Host "Mode       : $(if ($Drop) { 'drop then insert' } else { 'insert (existing documents will conflict)' })"
    Write-Host ''

    if (-not $PSCmdlet.ShouldProcess("$($target.Name) ($($target.Host)) database '$($target.Database)'", "mongorestore $($dump.FullName)$(if ($Drop) { ', dropping each collection first' })")) { return }

    $arguments = @("--uri=$($target.Uri)", "--db=$($target.Database)")
    if ($Drop) { $arguments += '--drop' }
    if ($Gzip) { $arguments += '--gzip' }
    $arguments += $dump.FullName

    $result = Invoke-MongoTool $mongorestore $arguments { param($line) Write-Host $line }

    if ($result.ExitCode -ne 0) { throw "mongorestore failed (exit $($result.ExitCode))." }
}

# Every *.jsonl file in the export folder becomes the collection named after the file, one Extended JSON document per line.
function Import-MongoExport {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string] $ExportPath,

        [Parameter(Position = 1)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete)
                (Get-MongoProfileConfig).PSObject.Properties.Name | Where-Object { $_ -like "$wordToComplete*" }
            })]
        [string] $Name,

        [string] $Database,

        [ValidateNotNullOrEmpty()]
        [string[]] $Include = @('*'),

        [switch] $Drop,

        [ValidateRange(1, 64)]
        [int] $InsertionWorkers = 4
    )

    $ErrorActionPreference = 'Stop'

    $mongoimport = Get-MongoTool 'mongoimport'
    $exportRoot = Get-Item -LiteralPath $ExportPath
    if (-not $exportRoot.PSIsContainer) { throw "Export path is not a folder: $($exportRoot.FullName)" }

    $jsonlFiles = @(Get-ChildItem -LiteralPath $exportRoot.FullName -Filter '*.jsonl' -File)

    # Exports are commonly nested one level deep.
    if (-not $jsonlFiles) {
        $nestedFolders = @(Get-ChildItem -LiteralPath $exportRoot.FullName -Directory |
            Where-Object { Get-ChildItem -LiteralPath $_.FullName -Filter '*.jsonl' -File })

        if ($nestedFolders.Count -ne 1) {
            throw "No .jsonl files found in '$($exportRoot.FullName)' or in a single nested folder."
        }

        $exportRoot = $nestedFolders[0]
        $jsonlFiles = @(Get-ChildItem -LiteralPath $exportRoot.FullName -Filter '*.jsonl' -File)
    }

    $selectedFiles = @($jsonlFiles |
        Where-Object {
            $collectionName = $_.BaseName
            $collectionName -notlike 'system.*' -and ($Include | Where-Object { $collectionName -like $_ })
        } |
        Sort-Object -Property Name)

    if (-not $selectedFiles) {
        throw "No collections in '$($exportRoot.FullName)' matched -Include: $($Include -join ', ')"
    }

    $emptyFiles = @($selectedFiles | Where-Object Length -eq 0)
    $filesToImport = @($selectedFiles | Where-Object Length -gt 0)
    $totalMegabytes = [math]::Round((($filesToImport | Measure-Object -Property Length -Sum).Sum ?? 0) / 1MB, 1)

    $target = Resolve-MongoTarget $Name $Database
    Assert-MongoWritable $target

    Write-Host ''
    Write-Host "Source     : $($exportRoot.FullName)"
    Write-Host "Target     : $($target.Name) ($($target.Host)) -> $($target.Database)"
    Write-Host "Collections: $($filesToImport.Count) ($totalMegabytes MB)$(if ($emptyFiles) { ", $($emptyFiles.Count) empty (skipped)" })"
    Write-Host "Mode       : $(if ($Drop) { 'drop then insert' } else { 'insert (existing documents will conflict)' })"
    Write-Host ''

    if (-not $PSCmdlet.ShouldProcess("$($target.Name) ($($target.Host)) database '$($target.Database)'", "mongoimport $($filesToImport.Count) collection(s)$(if ($Drop) { ', dropping each first' })")) { return }

    $results = [System.Collections.Generic.List[object]]::new()
    $runTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $index = 0

    foreach ($file in $filesToImport) {
        $collectionName = $file.BaseName
        $index++

        Write-Progress -Activity "Importing into $($target.Database)" -Status "$index/$($filesToImport.Count) $collectionName" -PercentComplete (($index / $filesToImport.Count) * 100)

        $arguments = @(
            "--uri=$($target.Uri)"
            "--db=$($target.Database)"
            "--collection=$collectionName"
            "--file=$($file.FullName)"
            '--type=json'
            "--numInsertionWorkers=$InsertionWorkers"
        )

        if ($Drop) { $arguments += '--drop' }

        $collectionTimer = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-MongoTool $mongoimport $arguments
        $collectionTimer.Stop()

        Write-Verbose ($result.Output -join [Environment]::NewLine)

        $imported = 0
        $failed = 0
        $summaryLine = $result.Output | Where-Object { $_ -match 'document\(s\) imported successfully' } | Select-Object -Last 1

        if ($summaryLine -match '(\d+)\s+document\(s\) imported successfully') { $imported = [int] $Matches[1] }
        if ($summaryLine -match '(\d+)\s+document\(s\) failed to import') { $failed = [int] $Matches[1] }

        $isSuccess = ($result.ExitCode -eq 0) -and ($failed -eq 0)

        $results.Add([pscustomobject]@{ Label = $collectionName; Documents = $imported; Success = $isSuccess; Output = $result.Output })

        $progressLabel = '[{0,4}/{1}] {2,-48}' -f $index, $filesToImport.Count, $collectionName

        if ($isSuccess) {
            Write-Host ('{0} {1,9:N0} docs {2,6:N1}s' -f $progressLabel, $imported, $collectionTimer.Elapsed.TotalSeconds)
        }
        else {
            Write-Host ('{0} FAILED (exit {1}, {2:N0} imported, {3:N0} failed)' -f $progressLabel, $result.ExitCode, $imported, $failed) -ForegroundColor Red
        }
    }

    Write-Progress -Activity "Importing into $($target.Database)" -Completed
    $runTimer.Stop()

    $failures = @($results | Where-Object { -not $_.Success })

    Write-Host ''
    Write-Host ('Imported {0:N0} document(s). {1}/{2} collection(s) succeeded in {3:mm\:ss}.' -f
        ($results | Measure-Object -Property Documents -Sum).Sum, ($results.Count - $failures.Count), $results.Count, $runTimer.Elapsed)

    if ($emptyFiles) {
        Write-Host "Skipped $($emptyFiles.Count) empty export file(s): $(($emptyFiles.BaseName | Sort-Object) -join ', ')" -ForegroundColor DarkGray
    }

    if (-not $failures) { return }

    Write-MongoFailures $failures

    if ($failures.Output -match 'E11000') {
        Write-Host ''
        Write-Host 'Duplicate key errors mean the collections already hold these documents. Re-run with -Drop to replace them.' -ForegroundColor Yellow
    }

    throw "$($failures.Count) collection(s) failed to import."
}

function Get-MongoProfileConfig {
    if (-not (Test-Path -LiteralPath $script:MongoProfilesPath)) {
        throw "$script:MongoProfilesPath does not exist. Create it as described in the README."
    }

    Get-Content -Raw -LiteralPath $script:MongoProfilesPath | ConvertFrom-Json
}

function Select-MongoProfile([string] $name) {
    $profiles = Get-MongoProfileConfig
    $names = @($profiles.PSObject.Properties.Name | Sort-Object)

    if (-not $names) {
        throw "$script:MongoProfilesPath has no profiles."
    }

    if (-not $name) {
        $targets = foreach ($entry in $profiles.PSObject.Properties) {
            $parts = Split-MongoUri $entry.Value.uri
            [pscustomobject]@{ Name = $entry.Name; Host = $parts.Host; Database = $entry.Value.database ?? $parts.Database ?? '-' }
        }

        $hostWidth = ($targets.Host | Measure-Object -Property Length -Maximum).Maximum
        $notes = @{}
        foreach ($target in $targets) { $notes[$target.Name] = "$($target.Host.PadRight($hostWidth))  $($target.Database)" }

        Write-Host "`n  MongoDB profiles`n" -ForegroundColor Blue
        Write-Menu $names $null $notes
        Write-Host ''
        $name = Read-Choice 'Profile number or part of its name:' $names $null
    }

    $mongoProfile = $profiles.PSObject.Properties[$name]

    if (-not $mongoProfile) {
        throw "No profile '$name' in $script:MongoProfilesPath. Available: $($names -join ', ')."
    }

    $mongoProfile
}

function Resolve-MongoUri([string] $name, [string] $database) {
    $mongoProfile = Select-MongoProfile $name
    $uri = $mongoProfile.Value.uri
    $database = $database ? $database : $mongoProfile.Value.database

    if (-not $database) { return $uri }

    $parts = Split-MongoUri $uri
    "$($parts.Prefix)/$database$($parts.Query)"
}

# The tools take the database from --db alone, so the URI is returned without one. Only Name and Host are safe to print; Uri holds the password.
function Resolve-MongoTarget([string] $name, [string] $database) {
    $mongoProfile = Select-MongoProfile $name
    $parts = Split-MongoUri $mongoProfile.Value.uri

    [pscustomobject]@{
        Name     = $mongoProfile.Name
        Host     = $parts.Host
        Database = $database ? $database : ($mongoProfile.Value.database ?? $parts.Database ?? 'edgraph')
        Uri      = "$($parts.Prefix)/$($parts.Query)"
    }
}

function Split-MongoUri([string] $uri) {
    if ($uri -notmatch '^(?<prefix>mongodb(\+srv)?://(?:(?<userinfo>[^@/?]*)@)?(?<host>[^/?]+))(?:/(?<database>[^?]*))?(?<query>\?.*)?$') {
        throw "'$uri' is not a mongodb:// or mongodb+srv:// connection string."
    }

    [pscustomobject]@{
        Prefix   = $Matches.prefix
        Host     = $Matches.host
        Database = $Matches.database ? $Matches.database : $null
        Query    = $Matches.query
    }
}

function Assert-MongoWritable($target) {
    # `preprod` is not production, so `prod` has to stand alone between separators.
    if ($target.Name -match '(^|[-_.])prod(uction)?($|[-_.])') {
        throw "'$($target.Name)' is a production profile. Restoring and importing into production is refused."
    }
}

function Get-MongoTool([string] $name) {
    $tool = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1

    if (-not $tool) {
        throw "$name was not found on PATH. Install the MongoDB Database Tools: https://www.mongodb.com/try/download/database-tools"
    }

    $tool.Path
}

# A non-zero exit is returned, not thrown, so one failing run is reported with its output while the others continue.
function Invoke-MongoTool([string] $tool, [string[]] $arguments, [scriptblock] $onLine) {
    $PSNativeCommandUseErrorActionPreference = $false

    $output = @(& $tool @arguments 2>&1 | ForEach-Object {
            $line = [string] $_
            if ($onLine) { & $onLine $line }
            $line
        })

    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Write-MongoFailures($failures) {
    Write-Host ''
    Write-Host "$($failures.Count) run(s) failed:" -ForegroundColor Red

    foreach ($failure in $failures) {
        Write-Host "  $($failure.Label)" -ForegroundColor Red

        $lines = @($failure.Output | Where-Object { $_ -match '\S' })

        if (-not $lines) {
            Write-Host '    (no output -- the tool did not start, was killed, or could not reach the server)' -ForegroundColor DarkGray
            continue
        }

        foreach ($line in $lines | Select-Object -Last 3) {
            Write-Host "    $line" -ForegroundColor DarkGray
        }
    }
}
