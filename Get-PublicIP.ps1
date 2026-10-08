function Get-PublicIP {
    Show-Spinner -function {
        try {
            $response = Invoke-RestMethod -Uri "https://api.ipify.org?format=json"
            if ($response -and $response.ip) {
                Write-Output "`rYour public IP address is: $($response.ip)"
            }
            else {
                Write-Output "`rUnable to determine public IP address."
            }
        }
        catch {
            Write-Output "`rAn error occurred: $_"
        }
    } -Label "Fetching public IP..."
}
