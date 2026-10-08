$script:DockerDataDisk = "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx"

function Reset-DockerData {
    [CmdletBinding()]
    param()

    $totalStages = 0
    # Nested functions get a copy of an outer variable on assignment, so the counter lives in a shared hashtable.
    $progress = @{ Stage = 0 }
    $completed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    function banner([string] $title, [string] $description) {
        Clear-Host
        Write-Host "`n  $title" -ForegroundColor Blue
        Write-Host "  $totalStages stages`n" -ForegroundColor DarkGray
        Write-Host "  $description" -ForegroundColor DarkGray
        Write-Host "  Stop any time with Ctrl-C; nothing changes without your confirmation.`n" -ForegroundColor DarkGray
        pause 'Ready to start?'
    }

    function stage([string] $name) {
        Clear-Host
        $progress.Stage++
        Write-Host "`n▸ Stage $($progress.Stage)/$totalStages · $name" -ForegroundColor Blue
    }

    function say([string] $text) { Write-Host "  $text" }
    function step([string] $text) { Write-Host '  • ' -ForegroundColor Blue -NoNewline; Write-Host $text }
    function note([string] $text) { Write-Host "  $text" -ForegroundColor DarkGray }
    function warn([string] $text) { Write-Host "  ⚠ $text" -ForegroundColor Yellow }
    function done([string] $text) { Write-Host '  ✓ ' -ForegroundColor Green -NoNewline; Write-Host $text }

    function pause([string] $text = 'Press Enter to continue') {
        Write-Host "  $text " -ForegroundColor DarkGray -NoNewline
        $null = Read-Host
    }

    function confirm([string] $question) {
        Write-Host "  ? $question [y/N] " -ForegroundColor Yellow -NoNewline
        (Read-Host) -match '^[Yy]'
    }

    function abort([string] $reason) {
        Write-Host ''
        warn "Stopped: $reason"
        note 'Nothing after this point was changed. Re-run Reset-DockerData when ready.'
        Write-Host ''
    }

    function finish([string] $title) {
        Clear-Host
        Write-Host "`n  ✓ $title" -ForegroundColor Green
        foreach ($item in $completed) { note "- $item" }
        if ($skipped.Count) {
            Write-Host ''
            warn 'still to do by hand:'
            foreach ($item in $skipped) { note "  - $item" }
        }
        Write-Host ''
    }

    function Get-DockerProcesses {
        Get-Process -Name 'Docker Desktop', 'com.docker.*' -ErrorAction SilentlyContinue
    }

    function Get-RunningDistros {
        # wsl.exe writes UTF-16 to pipes unless told otherwise, which PowerShell decodes as text with NULs in between.
        $previous = $env:WSL_UTF8
        $env:WSL_UTF8 = '1'
        $names = wsl --list --running --quiet
        $env:WSL_UTF8 = $previous

        # With nothing running, wsl prints a message instead of names and exits non-zero.
        if ($LASTEXITCODE -ne 0) { return @() }

        @($names | ForEach-Object Trim | Where-Object { $_ })
    }

    function Format-Size([long] $bytes) { '{0:N2} GB' -f ($bytes / 1GB) }

    $totalStages = 5

    banner 'Reset Docker Desktop data' "Deletes $script:DockerDataDisk so Docker Desktop starts from an empty state."

    stage 'Inspect what will be deleted'

    if (-not (Test-Path -LiteralPath $script:DockerDataDisk)) {
        warn "No data disk at $script:DockerDataDisk."
        note 'Docker Desktop may be using a custom disk location (Settings → Resources → Advanced → Disk image location).'
        abort 'nothing to delete'
        return
    }

    $diskSize = (Get-Item -LiteralPath $script:DockerDataDisk).Length
    say "Data disk: $script:DockerDataDisk"
    say "Size on disk: $(Format-Size $diskSize)"
    Write-Host ''

    $null = docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -eq 0) {
        say 'What Docker reports it is storing (the disk file is usually larger, as it never shrinks):'
        docker system df | ForEach-Object { note "  $_" }
    }
    else {
        note 'Docker is not running, so its storage breakdown is unavailable.'
    }

    Write-Host ''
    warn 'Every image, container, volume and build cache will be lost, including any database data in volumes.'
    note 'Docker Desktop settings and your docker login credentials are kept.'
    Write-Host ''
    if (-not (confirm 'Continue?')) { abort 'you chose not to continue'; return }

    stage 'Stop Docker Desktop'

    if (-not (Get-DockerProcesses)) {
        done 'Docker Desktop is not running.'
    }
    else {
        say 'Docker Desktop is running and holds the data disk open.'
        if (-not (confirm 'Stop Docker Desktop now?')) { abort 'Docker Desktop must be stopped first'; return }

        step 'Stopping Docker Desktop (this can take up to a minute)...'
        docker desktop stop --timeout 120 2>&1 | ForEach-Object { note "  $_" }

        if (Get-DockerProcesses) {
            warn 'Docker Desktop did not stop cleanly.'
            if (-not (confirm 'Force it to stop?')) { abort 'Docker Desktop is still running'; return }
            docker desktop stop --force --timeout 60 2>&1 | ForEach-Object { note "  $_" }
        }

        while (Get-DockerProcesses) {
            warn 'Docker processes are still running:'
            Get-DockerProcesses | ForEach-Object { note "  - $($_.ProcessName) ($($_.Id))" }
            step 'Right-click the whale icon in the system tray → Quit Docker Desktop.'
            if (-not (confirm 'Done? Check again?')) { abort 'Docker Desktop is still running'; return }
        }

        done 'Docker Desktop is stopped.'
        $completed.Add('Stopped Docker Desktop')
    }
    pause

    stage 'Shut down WSL'

    say 'wsl --shutdown stops the WSL VM so it releases the data disk.'
    $otherDistros = Get-RunningDistros | Where-Object { $_ -notlike 'docker-desktop*' }
    if ($otherDistros) {
        warn "These distros are running and will be stopped too: $($otherDistros -join ', ')"
        note 'Save any work in them first.'
    }
    else {
        note 'No other WSL distros are running.'
    }
    Write-Host ''
    if (-not (confirm 'Shut down WSL now?')) { abort 'WSL must be shut down first'; return }

    wsl --shutdown
    if ($LASTEXITCODE -ne 0 -or (Get-RunningDistros)) {
        abort 'wsl --shutdown did not stop every distro; run it yourself and re-run Reset-DockerData'
        return
    }

    done 'WSL is shut down.'
    $completed.Add('Shut down WSL')
    pause

    stage 'Delete the data disk'

    say "About to permanently delete $script:DockerDataDisk ($(Format-Size $diskSize))."
    warn 'This cannot be undone. It does not go to the Recycle Bin.'
    Write-Host ''
    Write-Host '  ? Type DELETE to confirm: ' -ForegroundColor Yellow -NoNewline
    if ((Read-Host) -cne 'DELETE') { abort 'confirmation text did not match'; return }

    try {
        Remove-Item -LiteralPath $script:DockerDataDisk -Force -ErrorAction Stop
    }
    catch {
        warn $_.Exception.Message
        abort 'the file is still in use; reboot Windows, then re-run Reset-DockerData before starting Docker Desktop'
        return
    }

    done "Deleted the data disk and freed $(Format-Size $diskSize)."
    $completed.Add("Deleted docker_data.vhdx, freeing $(Format-Size $diskSize)")
    pause

    stage 'Start Docker Desktop with a fresh disk'

    if (-not (confirm 'Start Docker Desktop now?')) {
        $skipped.Add('Start Docker Desktop; it creates a fresh data disk on start')
        finish 'Docker data deleted'
        return
    }

    step 'Starting Docker Desktop (this can take a few minutes)...'
    docker desktop start --timeout 300 2>&1 | ForEach-Object { note "  $_" }

    $null = docker info --format '{{.ServerVersion}}' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $script:DockerDataDisk)) {
        warn 'Docker Desktop did not come up with a new data disk.'
        $skipped.Add('Start Docker Desktop from the Start menu and check it recreates the data disk')
        pause
        finish 'Docker data deleted'
        return
    }

    $newSize = (Get-Item -LiteralPath $script:DockerDataDisk).Length
    done "Docker Desktop is running with a fresh $(Format-Size $newSize) data disk."
    $completed.Add("Started Docker Desktop with a fresh $(Format-Size $newSize) data disk")
    pause

    finish 'Docker Desktop reset to an empty state'
}
