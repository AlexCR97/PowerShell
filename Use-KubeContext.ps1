function Use-KubeContext {
    [CmdletBinding()]
    param()

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
