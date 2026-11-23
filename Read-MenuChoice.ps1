function Write-Menu([string[]] $items, [string] $current, [hashtable] $notes = @{}) {
    $width = ($items | Measure-Object -Property Length -Maximum).Maximum

    for ($i = 0; $i -lt $items.Count; $i++) {
        $isCurrent = $items[$i] -eq $current
        $color = $isCurrent ? @{ ForegroundColor = 'Green' } : @{}
        Write-Host ('  {0} {1,2}  ' -f ($isCurrent ? '*' : ' '), ($i + 1)) -ForegroundColor DarkGray -NoNewline
        Write-Host $items[$i].PadRight($width) -NoNewline @color
        Write-Host "  $($notes[$items[$i]])" -ForegroundColor DarkGray
    }
}

function Read-Choice([string] $prompt, [string[]] $options, [string] $current) {
    while ($true) {
        Write-Host "  ? $prompt " -ForegroundColor Yellow -NoNewline
        $answer = (Read-Host).Trim()

        if (-not $answer) {
            if ($current) { return $current }
            continue
        }

        if (-not $options) { return $answer }

        $index = 0
        if ([int]::TryParse($answer, [ref] $index) -and $index -in 1..$options.Count) {
            return $options[$index - 1]
        }

        # An exact name wins over partial matches, or `edgraph` could never be picked next to `edgraph-jobs`.
        $found = @($options | Where-Object { $_ -eq $answer })
        if (-not $found) { $found = @($options | Where-Object { $_ -like "*$answer*" }) }
        if ($found.Count -eq 1) { return $found[0] }

        $reason = $found ? "'$answer' matches $($found -join ', ')" : "Nothing matches '$answer'"
        Write-Host "  $reason. Type its number or more of its name." -ForegroundColor DarkGray
    }
}
