function Show-Spinner {
    param(
        [scriptblock] $function,
        [string] $Label
    )

    $job = Start-Job -ScriptBlock $function

    $symbols = @("⣾⣿", "⣽⣿", "⣻⣿", "⢿⣿", "⡿⣿", "⣟⣿", "⣯⣿", "⣷⣿",
        "⣿⣾", "⣿⣽", "⣿⣻", "⣿⢿", "⣿⡿", "⣿⣟", "⣿⣯", "⣿⣷")
    $i = 0
    while ($job.State -eq "Running") {
        $symbol = $symbols[$i]
        Write-Host -NoNewLine "`r$symbol $Label" -ForegroundColor Green
        Start-Sleep -Milliseconds 100
        $i++
        if ($i -eq $symbols.Count) {
            $i = 0
        }
    }
    Write-Host -NoNewLine "`r"
    Receive-Job -Job $job
    Remove-Job -Job $job
}
