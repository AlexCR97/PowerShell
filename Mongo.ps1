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

function Get-MongoProfileConfig {
    if (-not (Test-Path -LiteralPath $script:MongoProfilesPath)) {
        throw "$script:MongoProfilesPath does not exist. Create it as described in the README."
    }

    Get-Content -Raw -LiteralPath $script:MongoProfilesPath | ConvertFrom-Json
}

function Resolve-MongoUri([string] $name, [string] $database) {
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

    $uri = $mongoProfile.Value.uri
    $database = $database ? $database : $mongoProfile.Value.database

    if (-not $database) { return $uri }

    $parts = Split-MongoUri $uri
    "$($parts.Prefix)/$database$($parts.Query)"
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
