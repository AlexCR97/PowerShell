<#
.SYNOPSIS
    Downloads audio from online media platforms using yt-dlp and converts it to MP3 format.

.DESCRIPTION
    This function downloads audio content from supported online platforms (like YouTube, SoundCloud, etc.)
    using yt-dlp. It automatically converts the downloaded content to MP3 format and organizes it into
    folders based on the source platform and playlist information. If yt-dlp is not installed, it offers
    to install it via winget.

.PARAMETER Url
    The URL of the media content to download. This can be a single video/track or a playlist URL.

.PARAMETER Path
    Optional. The destination path where downloaded files will be saved.
    Defaults to the user's Music folder.

.PARAMETER Browser
    Optional. The browser to extract cookies from for authenticated downloads.
    Defaults to "firefox".

.EXAMPLE
    Save-Audio -Url "https://youtube.com/watch?v=dQw4w9WgXcQ"
    Downloads a single track from YouTube to the default Music folder.

.EXAMPLE
    Save-Audio -Url "https://soundcloud.com/artist/track" -Browser "chrome" -Path "D:\MyMusic"
    Downloads from SoundCloud using Chrome cookies to a custom folder.

.NOTES
    Requires yt-dlp to be installed. The function will offer to install it via winget if not found.
    Downloaded files are organized in the following structure:
    {Path}/{platform}/{playlist_name}/{title}.mp3

.LINK
    https://github.com/yt-dlp/yt-dlp
#>
function Save-Audio {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string] $Url,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $Path = [System.IO.Path]::Combine([System.Environment]::GetFolderPath('MyMusic')),
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string] $Browser = "firefox"
    )

    if (!(Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
        Write-Host "yt-dlp is not installed. Would you like to install it? (Y/N)" -ForegroundColor Yellow
        $response = Read-Host
        if ($response -eq 'Y' -or $response -eq 'y') {
            winget install yt-dlp

            if (!(Get-Command yt-dlp -ErrorAction SilentlyContinue)) {
                Write-Host "Installation failed. Please install yt-dlp manually." -ForegroundColor Red
                return
            }
        }
        else {
            Write-Host "Operation cancelled. Please install yt-dlp to use this function." -ForegroundColor Red
            return
        }
    }

    yt-dlp $Url --paths $Path -f ba -x --audio-format mp3 --cookies-from-browser $Browser --output '%(extractor)s\%(playlist)s\%(title)s.%(ext)s' --embed-metadata --extractor-args youtube:player-client=default, android_music
}
