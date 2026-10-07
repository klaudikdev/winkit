function Write-WKLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Step')]
        [string]$Level = 'Info'
    )

    $entry = [pscustomobject]@{
        Time    = Get-Date
        Level   = $Level
        Message = $Message
    }

    if (-not $WK) { return }

    # The UI drains this queue on its own thread.
    $WK.LogQueue.Enqueue($entry)

    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1,-7}] {2}' -f $entry.Time, $Level.ToUpperInvariant(), $Message
    [System.Threading.Monitor]::Enter($WK.LogLock)
    try {
        [System.IO.File]::AppendAllText($WK.LogFile, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
    }
    catch {
        # Logging must never break the operation being logged.
    }
    finally {
        [System.Threading.Monitor]::Exit($WK.LogLock)
    }
}

function Write-WKConsole {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Entry)

    $color = switch ($Entry.Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        'Step'    { 'Cyan' }
        default   { 'Gray' }
    }
    try { Write-Host ('{0:HH:mm:ss}  {1}' -f $Entry.Time, $Entry.Message) -ForegroundColor $color } catch { }
}
