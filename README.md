# PowerShell

My personal PowerShell 7 profile shared between my machines.

## Functions

| Function                                | Description                                                                                                                                                      |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Connect-Mongo [<profile>]`             | Opens `mongosh` on a profile of `Mongo.local.json`, tab-completed or picked from a list. `-Database` overrides its database; other arguments go to `mongosh`.    |
| `Invoke-MongoScript <file> [<profile>]` | Runs a `mongosh` script file against a profile and prints its output, e.g. to redirect into an sdlc artifact capture. Takes `-Database` too.                     |
| `Save-MongoDump [<profile>]`            | Dumps a database of a profile with `mongodump` into `.mongo\dumps\<profile>\<date>_<time>\<database>`. Take a subset with `-Collection` or `-ExcludeCollection`. |
| `Restore-MongoDump <path> [<profile>]`  | Restores a dump folder with `mongorestore` into a profile. `-Drop` replaces existing collections. Asks for confirmation and refuses production.                  |
| `Import-MongoExport <path> [<profile>]` | Imports every `*.jsonl` file of an export folder with `mongoimport`, one collection per file. Asks for confirmation and refuses production.                      |
| `Get-PublicIP`                          | Prints the machine's public IP address, with a spinner while it is fetched.                                                                                      |
| `Write-Menu`, `Read-Choice`             | Print a numbered list and read a pick by number or part of a name. Helpers for `Use-KubeContext` and `Connect-Mongo`.                                            |
| `Reset-DockerData`                      | Wizard that deletes Docker Desktop's WSL 2 data disk to reclaim its space, wiping every image, container, volume and build cache. Confirms before each step.     |
| `Save-Audio`                            | Downloads audio from a URL as MP3 with `yt-dlp`, organized by platform and playlist. Offers to install `yt-dlp` via winget when missing.                         |
| `Show-Spinner`                          | Runs a script block as a background job behind a spinner and returns its output. Helper for `Get-PublicIP`.                                                      |
| `Use-KubeContext`                       | Switches `kubectl` to a context and namespace picked from lists by number or part of the name. Asks for the namespace by name if the cluster is unreachable.     |
| `Use-Temporal <profile>`                | Points the `temporal` CLI at one profile of `Use-Temporal.local.json` for the current session. Tab-completes profile names.                                      |
| `Clear-Temporal`                        | Clears the `temporal` CLI environment set by `Use-Temporal`.                                                                                                     |

## Setup on a new machine

PowerShell 7 already creates `Documents\PowerShell`, so clone into it in place:

```powershell
cd (Split-Path $PROFILE)
git init -b main
git remote add origin git@github.com:AlexCR97/PowerShell.git
git fetch origin
git checkout -f -t origin/main
```

### Temporal profiles

`Use-Temporal` reads its profiles from `Use-Temporal.local.json` in this folder, which is gitignored because it holds API keys. Copy it from another machine or create it. Each name must match a profile in `%AppData%\temporalio\temporal.toml`, which holds the address and namespace. A profile has either an `apiKey` for Temporal Cloud or a `portForward` for a self-hosted Temporal reachable only inside a Kubernetes cluster:

```json
{
  "cloud-profile": {
    "apiKey": "<Temporal Cloud API key>"
  },
  "self-hosted-profile": {
    "portForward": {
      "kubeContext": "<kubectl context>",
      "awsProfile": "<AWS profile kubectl authenticates with>",
      "namespace": "<Kubernetes namespace>",
      "service": "<Temporal frontend service>",
      "localPort": 17233
    }
  }
}
```

### MongoDB profiles

`Connect-Mongo` and `Invoke-MongoScript` read their profiles from `Mongo.local.json` in this folder, which is gitignored because the connection strings hold passwords. Copy it from another machine or create it. Name each profile after its environment, so a capture of an sdlc artifact can be named after it too (`probe.qa.output.txt`). `database` is optional and `-Database` overrides it:

```json
{
  "dev": {
    "uri": "mongodb+srv://<user>:<password>@<dev-cluster>/?authSource=admin",
    "database": "enrollment"
  },
  "qa": {
    "uri": "mongodb+srv://<user>@<qa-cluster>/?authSource=admin"
  },
  "localhost": {
    "uri": "mongodb://localhost:27017"
  }
}
```

The database goes into the URI's path, and a URI without `authSource` authenticates against that database. Set `authSource` explicitly to the database the user was created in, usually `admin`, or switching databases breaks the login. Leave the password out of a URI to have `mongosh` prompt for it.

Arguments after the profile go to `mongosh`, in its `--long` form so PowerShell does not take them as its own:

```powershell
Connect-Mongo qa --eval "db.getCollectionNames()"
Invoke-MongoScript .\probe.js qa > .\probe.qa.output.txt
```

`Save-MongoDump`, `Restore-MongoDump` and `Import-MongoExport` take the same profiles and need the [MongoDB Database Tools](https://www.mongodb.com/try/download/database-tools) on the `PATH`. The database is `-Database`, then the profile's `database`, then `edgraph`. `Save-MongoDump` writes under the current directory (`.mongo\dumps\` by default, or `-OutPath`), and exports are kept in `.mongo\exports\`. `.gitignore` keeps `.mongo\` out of the repo. A restore or import is typically aimed at a `localhost` profile, as above. Both refuse a `prod` or `production` profile, and `-WhatIf` shows what they would do:

```powershell
Save-MongoDump edx-preprod -Label preMigration
Restore-MongoDump .\.mongo\dumps\edx-preprod\2026-08-18_112537_preMigration\edgraph localhost -Drop
Import-MongoExport .\.mongo\exports\dev\2026-07-30_ignoreEdOrgFalse localhost -Include 'identity-svc-*' -Drop
```
