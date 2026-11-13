function Use-KubeContext {
    [CmdletBinding()]
    param()

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

    $config = (kubectl config view -o json) -join "`n" | ConvertFrom-Json
    $contexts = @($config.contexts ?? @())

    if (-not $contexts) {
        Write-Host '  ⚠ Your kubeconfig has no contexts.' -ForegroundColor Yellow
        return
    }

    $currentContext = $config.'current-context'
    $contextNames = @($contexts.name | Sort-Object)
    $namespaceOf = @{}
    foreach ($entry in $contexts) { $namespaceOf[$entry.name] = $entry.context.namespace ?? 'default' }

    Write-Host "`n  Contexts (* is current)`n" -ForegroundColor Blue
    Write-Menu $contextNames $currentContext $namespaceOf
    Write-Host ''
    $context = Read-Choice 'Context number or part of its name (Enter keeps current):' $contextNames $currentContext
    $currentNamespace = $namespaceOf[$context]

    Write-Host "`n  Fetching the namespaces of $context..." -ForegroundColor DarkGray
    $output = kubectl --context $context get namespaces -o name --request-timeout 10s 2>&1
    $lines, $errors = $output.Where({ $_ -is [string] }, 'Split')

    if ($LASTEXITCODE -eq 0) {
        $namespaces = @($lines -replace '^namespace/')
        Write-Host "`n  Namespaces (* is current)`n" -ForegroundColor Blue
        Write-Menu $namespaces $currentNamespace
        Write-Host ''
        $namespace = Read-Choice "Namespace number or part of its name (Enter keeps $currentNamespace):" $namespaces $currentNamespace
    }
    else {
        Write-Host '  ⚠ Could not list them:' -ForegroundColor Yellow
        # kubectl logs the same failure once per API discovery retry before printing its own summary.
        $errors |
        ForEach-Object { "$_" } |
        Where-Object { $_ -and $_ -notmatch '^E\d{4} ' } |
        Select-Object -Unique |
        ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        Write-Host ''
        $namespace = Read-Choice "Namespace name (Enter keeps $currentNamespace):" @() $currentNamespace
    }

    if ($context -eq $currentContext -and $namespace -eq $currentNamespace) {
        Write-Host "`n  Nothing changed: still on $context, namespace $namespace`n" -ForegroundColor DarkGray
        return
    }

    if ($namespace -ne $currentNamespace) {
        $null = kubectl config set-context $context --namespace $namespace
        if ($LASTEXITCODE -ne 0) { throw "Could not set namespace '$namespace' on context '$context'." }
    }

    if ($context -ne $currentContext) {
        $null = kubectl config use-context $context
        if ($LASTEXITCODE -ne 0) { throw "Could not switch to context '$context'." }
    }

    Write-Host "`n  ✓ kubectl now targets $context, namespace $namespace`n" -ForegroundColor Green
}
