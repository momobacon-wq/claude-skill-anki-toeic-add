# Add-AnkiCard.ps1 — push a vocab note to user's Anki TOEIC deck via AnkiConnect
# Dot-source before calling:
#   . "$env:USERPROFILE\.claude\skills\anki-toeic-add\scripts\Add-AnkiCard.ps1"

function Add-AnkiCard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Chinese,
        [Parameter(Mandatory)][string]$English,
        [Parameter(Mandatory)][string]$KK,
        [Parameter(Mandatory)][string]$PartOfSpeech,
        [Parameter(Mandatory)][string]$Etymology,
        [Parameter(Mandatory)][string]$Examples,
        [string]$PronunNote = '',
        [string]$Deck = 'TOEIC',
        [string]$Model = '英文單字',
        [string[]]$Tags = @(),
        [string]$Uri = 'http://127.0.0.1:8765'
    )

    $payload = @{
        action  = 'addNote'
        version = 6
        params  = @{
            note = @{
                deckName  = $Deck
                modelName = $Model
                fields    = @{
                    '中文'     = $Chinese
                    'English'  = $English
                    'KK音標'   = $KK
                    '發音說明' = $PronunNote
                    '詞性'     = $PartOfSpeech
                    '解說'     = $Etymology
                    '例句'     = $Examples
                }
                tags    = $Tags
                options = @{ allowDuplicate = $false }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $r = Invoke-RestMethod -Uri $Uri -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 10
    } catch {
        return [PSCustomObject]@{
            word    = $English
            status  = 'connection_error'
            noteId  = $null
            error   = $_.Exception.Message
        }
    }

    if ($r.error) {
        $status = if ($r.error -match 'duplicate') { 'duplicate' } else { 'api_error' }
        return [PSCustomObject]@{
            word   = $English
            status = $status
            noteId = $null
            error  = $r.error
        }
    }

    [PSCustomObject]@{
        word   = $English
        status = 'ok'
        noteId = $r.result
        error  = $null
    }
}

function Test-AnkiCardExists {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$English,
        [string]$Deck = 'TOEIC',
        [string]$Uri = 'http://127.0.0.1:8765'
    )
    $q = "deck:$Deck English:`"$English`""
    $payload = @{ action='findNotes'; version=6; params=@{ query=$q } } | ConvertTo-Json -Depth 4 -Compress
    try {
        $r = Invoke-RestMethod -Uri $Uri -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 10
    } catch {
        return $null  # connection error — caller should handle
    }
    return ($r.result.Count -gt 0)
}

function Test-AnkiConnect {
    [CmdletBinding()]
    param([string]$Uri = 'http://127.0.0.1:8765')
    try {
        $r = Invoke-RestMethod -Uri $Uri -Method Post `
            -Body '{"action":"version","version":6}' `
            -ContentType 'application/json' -TimeoutSec 3
        return [PSCustomObject]@{ ok = $true; version = $r.result }
    } catch {
        return [PSCustomObject]@{ ok = $false; error = $_.Exception.Message }
    }
}
