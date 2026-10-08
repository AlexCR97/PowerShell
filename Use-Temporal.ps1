# The Key Vaults holding these API keys are reachable only over the VPN, so the keys live in this untracked file.
$script:TemporalProfilesPath = "$PSScriptRoot\Use-Temporal.local.json"

function Use-Temporal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ArgumentCompleter({
                param($commandName, $parameterName, $wordToComplete)
                (Get-TemporalProfileConfig).PSObject.Properties.Name | Where-Object { $_ -like "$wordToComplete*" }
            })]
        [string] $Name
    )

    $profiles = Get-TemporalProfileConfig
    $temporalProfile = $profiles.PSObject.Properties[$Name]

    if (-not $temporalProfile) {
        throw "No profile '$Name' in $script:TemporalProfilesPath. Available: $($profiles.PSObject.Properties.Name -join ', ')."
    }

    Clear-Temporal

    if ($temporalProfile.Value.portForward) {
        Start-TemporalPortForward $temporalProfile.Name $temporalProfile.Value.portForward
    }
    else {
        $env:TEMPORAL_API_KEY = $temporalProfile.Value.apiKey
    }

    $env:TEMPORAL_PROFILE = $temporalProfile.Name
    Write-Host "temporal CLI now targets '$($temporalProfile.Name)'. Try: temporal schedule list" -ForegroundColor Green
}

function Clear-Temporal {
    Stop-TemporalPortForward

    # Any of these left over from another shell or tool would override the profile silently.
    foreach ($variable in 'TEMPORAL_PROFILE', 'TEMPORAL_API_KEY', 'TEMPORAL_ADDRESS', 'TEMPORAL_NAMESPACE', 'TEMPORAL_ENV') {
        Remove-Item "Env:\$variable" -ErrorAction SilentlyContinue
    }
}

function Get-TemporalProfileConfig {
    if (-not (Test-Path -LiteralPath $script:TemporalProfilesPath)) {
        throw "$script:TemporalProfilesPath does not exist. Create it as described in the README."
    }

    Get-Content -Raw -LiteralPath $script:TemporalProfilesPath | ConvertFrom-Json
}

function Start-TemporalPortForward([string] $name, $portForward) {
    $script:TemporalPortForwardJob = Start-Job -Name "temporal-$name-port-forward" -ScriptBlock {
        param($forward)
        $env:AWS_PROFILE = $forward.awsProfile
        # A local `temporal server start-dev` already holds 7233, so localPort must differ.
        kubectl --context $forward.kubeContext -n $forward.namespace port-forward "svc/$($forward.service)" "$($forward.localPort):7233"
    } -ArgumentList $portForward

    $deadline = (Get-Date).AddSeconds(20)

    while ((Get-Date) -lt $deadline) {
        if ($script:TemporalPortForwardJob.State -ne 'Running') {
            $output = Receive-Job $script:TemporalPortForwardJob 2>&1 | Out-String
            Stop-TemporalPortForward
            throw "The port-forward for '$name' exited. Check the AWS credentials of profile '$($portForward.awsProfile)' and your access to cluster '$($portForward.kubeContext)'.`n$output"
        }

        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            if ($client.ConnectAsync('localhost', $portForward.localPort).Wait(500)) { return }
        }
        catch { }
        finally { $client.Dispose() }

        Start-Sleep -Milliseconds 500
    }

    Stop-TemporalPortForward
    throw "The port-forward for '$name' did not open localhost:$($portForward.localPort) within 20 seconds."
}

function Stop-TemporalPortForward {
    if ($script:TemporalPortForwardJob) {
        Stop-Job $script:TemporalPortForwardJob -ErrorAction SilentlyContinue
        Remove-Job $script:TemporalPortForwardJob -Force -ErrorAction SilentlyContinue
        $script:TemporalPortForwardJob = $null
    }
}
