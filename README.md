# PowerShell

My personal PowerShell 7 profile shared between my machines.

## Functions

| Function                 | Description                                                                                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `Get-PublicIP`           | Prints the machine's public IP address, with a spinner while it is fetched.                                                                                  |
| `Reset-DockerData`       | Wizard that deletes Docker Desktop's WSL 2 data disk to reclaim its space, wiping every image, container, volume and build cache. Confirms before each step. |
| `Save-Audio`             | Downloads audio from a URL as MP3 with `yt-dlp`, organized by platform and playlist. Offers to install `yt-dlp` via winget when missing.                     |
| `Show-Spinner`           | Runs a script block as a background job behind a spinner and returns its output. Helper for `Get-PublicIP`.                                                  |
| `Use-Temporal <profile>` | Points the `temporal` CLI at one profile of `Use-Temporal.local.json` for the current session. Tab-completes profile names.                                  |
| `Clear-Temporal`         | Clears the `temporal` CLI environment set by `Use-Temporal`.                                                                                                 |

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
