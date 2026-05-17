# Add-AnkiCard.ps1 — push a vocab note to user's Anki TOEIC deck via AnkiConnect,
# with auto-generated audio via edge-tts (Azure Neural Voice "Ava").
#
# Dot-source before calling:
#   . "$env:USERPROFILE\.claude\skills\anki-toeic-add\scripts\Add-AnkiCard.ps1"

function New-AnkiTtsAudio {
    <#
    Generates an mp3 of the given English word using edge-tts (AvaNeural),
    uploads it to Anki's media library via AnkiConnect storeMediaFile, and
    returns the [sound:filename] tag suitable for an Audio field.
    Returns $null on failure.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Word,
        [string]$Voice = 'en-US-AvaNeural',
        [string]$Uri = 'http://127.0.0.1:8765'
    )

    $slug = ($Word.ToLower() -replace '[^a-z0-9]', '_').Trim('_')
    if (-not $slug) { Write-Error "Cannot derive slug from word '$Word'"; return $null }
    $filename = "anki_toeic_$slug.mp3"

    $workDir = Join-Path $env:TEMP 'anki_toeic_audio'
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    $mp3Path = Join-Path $workDir $filename

    # Generate mp3 via edge-tts (run as ephemeral uvx tool — no permanent Python install needed)
    $null = uvx --quiet --from edge-tts edge-tts `
        --voice $Voice `
        --text $Word `
        --write-media $mp3Path 2>&1

    if (-not (Test-Path $mp3Path)) {
        Write-Error "edge-tts failed to produce $mp3Path for word '$Word'"
        return $null
    }

    # Upload to Anki's media collection
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($mp3Path))
    $payload = @{
        action  = 'storeMediaFile'
        version = 6
        params  = @{ filename = $filename; data = $b64 }
    } | ConvertTo-Json -Depth 4 -Compress

    try {
        $r = Invoke-RestMethod -Uri $Uri -Method Post -Body $payload `
            -ContentType 'application/json' -TimeoutSec 15
    } catch {
        Write-Error "AnkiConnect storeMediaFile failed: $($_.Exception.Message)"
        return $null
    }
    if ($r.error) {
        Write-Error "AnkiConnect storeMediaFile error: $($r.error)"
        return $null
    }

    return "[sound:$filename]"
}

function Add-AnkiCard {
    <#
    Adds a vocab note to the user's Anki TOEIC deck via AnkiConnect.
    Auto-generates an audio mp3 of the English word (en-US-AvaNeural) unless
    -SkipAudio is set or a non-empty -AudioTag is supplied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Chinese,
        [Parameter(Mandatory)][string]$English,
        [Parameter(Mandatory)][string]$KK,
        [Parameter(Mandatory)][string]$PartOfSpeech,
        [Parameter(Mandatory)][string]$Etymology,
        [Parameter(Mandatory)][string]$Examples,
        [string]$PronunNote = '',
        [string]$AudioTag = '',    # pre-built [sound:...] tag if you have one; empty = auto-generate
        [switch]$SkipAudio,         # skip audio generation entirely (Audio field will be empty)
        [string]$Deck = 'TOEIC',
        [string]$Model = '英文單字',
        [string[]]$Tags = @(),
        [string]$Uri = 'http://127.0.0.1:8765'
    )

    # Generate audio if not provided and not skipped
    if (-not $SkipAudio -and -not $AudioTag) {
        # Strip HTML from English to get the bare word for TTS
        $cleanWord = ($English -replace '<[^>]+>', '').Trim()
        $AudioTag = New-AnkiTtsAudio -Word $cleanWord -Uri $Uri
        if (-not $AudioTag) {
            Write-Warning "Audio generation failed for '$cleanWord'; note will be added without audio."
            $AudioTag = ''
        }
    }

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
                    'Audio'    = $AudioTag
                }
                tags    = $Tags
                options = @{ allowDuplicate = $false }
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress

    try {
        $r = Invoke-RestMethod -Uri $Uri -Method Post -Body $payload `
            -ContentType 'application/json' -TimeoutSec 15
    } catch {
        return [PSCustomObject]@{
            word = $English; status = 'connection_error'; noteId = $null; error = $_.Exception.Message
        }
    }

    if ($r.error) {
        $status = if ($r.error -match 'duplicate') { 'duplicate' } else { 'api_error' }
        return [PSCustomObject]@{
            word = $English; status = $status; noteId = $null; error = $r.error
        }
    }

    [PSCustomObject]@{
        word   = $English
        status = 'ok'
        noteId = $r.result
        audio  = $AudioTag
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
    $payload = @{ action = 'findNotes'; version = 6; params = @{ query = $q } } | ConvertTo-Json -Depth 4 -Compress
    try {
        $r = Invoke-RestMethod -Uri $Uri -Method Post -Body $payload `
            -ContentType 'application/json' -TimeoutSec 10
    } catch { return $null }
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
