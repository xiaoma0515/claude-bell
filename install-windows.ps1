<#
.SYNOPSIS
    claude-bell, PC half — give "Claude needs you" a sound of its own.

.DESCRIPTION
    install.sh (server half) decides WHICH terminal each alert goes to. It
    cannot decide what that alert sounds like: SSH carries a BEL byte, and a
    byte has no timbre. Windows Terminal plays whatever wav the receiving
    tab's profile maps BEL to — and that mapping is per profile.

    So a second profile is a second sound. This script builds one:

      * synthesizes a short "beep-beep" wav (no download, no dependencies)
      * adds a Windows Terminal profile that plays it on BEL
      * points that profile's command line straight at `bell.sh listen`, so
        opening the tab is the whole setup — nothing to type

    Result: permission prompts and questions beep-beep in the alerts tab,
    while "done" keeps ringing in your session tab with its original sound.
    Close the alerts tab and the server falls back to its two-beep pattern.

    Re-run any time; it updates in place. -Uninstall removes the profile.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
    Auto-detects your SSH profile and reuses its command line. Use this form
    if plain .\install-windows.ps1 reports that running scripts is disabled:
    Windows ships with the Restricted execution policy, and this bypasses it
    for one run without changing any machine setting.

.EXAMPLE
    .\install-windows.ps1 -SshCommand "ssh myserver"
    Spell out the connection yourself.

.EXAMPLE
    .\install-windows.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    # How to reach the box, as you would type it. "-t <bell.sh> listen" is
    # appended. Omit to reuse an existing SSH profile's command line.
    [string]$SshCommand,

    # Where bell.sh lives on the server. Change if CLAUDE_CONFIG_DIR is set.
    [string]$RemoteBellPath = '~/.claude/hooks/bell.sh',

    # Where to write the alert sound.
    [string]$SoundPath = "$env:LOCALAPPDATA\claude-bell\ask-beep.wav",

    [string]$ProfileName = 'Claude alerts',

    # Override settings.json discovery (Store / unpackaged / Preview).
    [string]$SettingsPath,

    # Don't open the alerts tab when finished.
    [switch]$NoLaunch,

    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

# Fixed, so re-running updates the same profile instead of stacking copies.
$PROFILE_GUID = '{b3117a4d-5c0e-4f6a-9d21-c1a0de0be115}'

function Ok   ($m) { Write-Host "  + $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  ! $m" -ForegroundColor Yellow }
function Err  ($m) { Write-Host "  x $m" -ForegroundColor Red }
function Hdr  ($m) { Write-Host ""; Write-Host $m -ForegroundColor White }

# --------------------------------------------------------------- settings.json
function Find-TerminalSettings {
    if ($SettingsPath) {
        if (-not (Test-Path $SettingsPath)) { throw "No settings.json at $SettingsPath" }
        return $SettingsPath
    }
    $candidates = @(
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
        "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
    )
    $found = @($candidates | Where-Object { Test-Path $_ })
    if ($found.Count -eq 0) {
        throw "Couldn't find Windows Terminal's settings.json. Open Terminal once, or pass -SettingsPath."
    }
    if ($found.Count -gt 1) { Warn "several installs found; using $($found[0])" }
    return $found[0]
}

# Windows Terminal writes JSONC — its stock settings.json is full of //
# comments, which ConvertFrom-Json rejects. Strip them, but only outside
# string literals: paths like "C:\\x" are fine, yet a URL in a tab title
# would lose its tail to a naive regex.
function Remove-JsonComments([string]$Text) {
    $sb = New-Object System.Text.StringBuilder
    $inStr = $false; $esc = $false; $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($esc)             { $esc = $false }
            elseif ($c -eq '\')   { $esc = $true }
            elseif ($c -eq '"')   { $inStr = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and ($i + 1) -lt $Text.Length) {
            $n = $Text[$i + 1]
            if ($n -eq '/') {
                while ($i -lt $Text.Length -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
            if ($n -eq '*') {
                $i += 2
                while (($i + 1) -lt $Text.Length -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
                $i += 2; continue
            }
        }
        [void]$sb.Append($c); $i++
    }
    $sb.ToString()
}

function Save-Json($Object, [string]$Path) {
    $json = $Object | ConvertTo-Json -Depth 100
    # No BOM: Terminal copes either way, but its own writes have none.
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# ------------------------------------------------------------------ the sound
# Two clipped high blips. Deliberately dry and short so it reads as an alert
# and never blurs into the longer chime you keep for "done".
function New-AlertWav {
    param([string]$Path, [int]$Freq = 2100, [int]$ToneMs = 70, [int]$GapMs = 60, [double]$Amp = 0.55)

    $rate   = 44100
    $toneN  = [int]($rate * $ToneMs / 1000)
    $gapN   = [int]($rate * $GapMs / 1000)
    $fadeN  = [int]($rate * 0.006)   # kills the click at each edge
    $pcm    = New-Object System.Collections.Generic.List[int16]

    foreach ($blip in 1, 2) {
        for ($i = 0; $i -lt $toneN; $i++) {
            # Not $env — that name collides with the environment provider.
            $gain = 1.0
            if     ($i -lt $fadeN)            { $gain = $i / $fadeN }
            elseif ($i -gt ($toneN - $fadeN)) { $gain = ($toneN - $i) / $fadeN }
            $v = $Amp * $gain * [Math]::Sin(2 * [Math]::PI * $Freq * $i / $rate)
            $pcm.Add([int16][Math]::Round($v * 32767))
        }
        if ($blip -eq 1) { for ($i = 0; $i -lt $gapN; $i++) { $pcm.Add([int16]0) } }
    }

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $bytes = $pcm.Count * 2
    $fs = [System.IO.File]::Create($Path)
    try {
        $bw = New-Object System.IO.BinaryWriter($fs)
        # Pass the byte[] straight to Write(); routing it through a scriptblock
        # or the pipeline turns it into Object[] and overload resolution fails.
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $bw.Write([int32](36 + $bytes))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
        $bw.Write([int32]16)
        $bw.Write([int16]1); $bw.Write([int16]1)              # PCM, mono
        $bw.Write([int32]$rate); $bw.Write([int32]($rate * 2))
        $bw.Write([int16]2); $bw.Write([int16]16)             # block align, bits
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $bw.Write([int32]$bytes)
        foreach ($s in $pcm) { $bw.Write($s) }
        $bw.Flush()
    } finally { $fs.Dispose() }
}

# =========================================================================== go
Hdr "claude-bell — PC half"

$settingsFile = Find-TerminalSettings
Ok "settings.json: $settingsFile"

$raw = Get-Content -Path $settingsFile -Raw -Encoding UTF8
try { $cfg = Remove-JsonComments $raw | ConvertFrom-Json }
catch { throw "settings.json didn't parse, refusing to touch it: $_" }

# Schema has been {profiles:{list:[...]}} for years; the bare array is ancient.
if ($cfg.profiles -is [System.Array]) { $list = @($cfg.profiles); $flat = $true }
else                                  { $list = @($cfg.profiles.list); $flat = $false }

$backup = "$settingsFile.bak.$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item $settingsFile $backup
Ok "backed up to $(Split-Path -Leaf $backup)"

# ------------------------------------------------------------------ uninstall
if ($Uninstall) {
    Hdr "Uninstall"
    $kept = @($list | Where-Object { $_.guid -ne $PROFILE_GUID })
    if ($kept.Count -eq $list.Count) { Warn "no '$ProfileName' profile found" }
    else {
        if ($flat) { $cfg.profiles = $kept } else { $cfg.profiles.list = $kept }
        Save-Json $cfg $settingsFile
        Ok "removed the alerts profile"
    }
    if (Test-Path $SoundPath) { Remove-Item $SoundPath -Force; Ok "removed $SoundPath" }
    Write-Host ""
    Write-Host "Done. Alerts fall back to the two-beep pattern in your session tab."
    return
}

# ------------------------------------------------------- how to reach the box
if (-not $SshCommand) {
    $sshProfiles = @($list | Where-Object {
        $_.guid -ne $PROFILE_GUID -and $_.commandline -and $_.commandline -match '\bssh(\.exe)?\b'
    })
    if ($sshProfiles.Count -eq 1) {
        $SshCommand = $sshProfiles[0].commandline
        Ok "reusing SSH profile '$($sshProfiles[0].name)'"
    }
    elseif ($sshProfiles.Count -gt 1) {
        Hdr "Which connection should the alerts tab use?"
        for ($i = 0; $i -lt $sshProfiles.Count; $i++) {
            Write-Host ("  {0}. {1}  —  {2}" -f ($i + 1), $sshProfiles[$i].name, $sshProfiles[$i].commandline)
        }
        $pick = Read-Host "number"
        $idx = 0
        if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $sshProfiles.Count) {
            throw "Not a listed number. Re-run with -SshCommand ""ssh yourhost""."
        }
        $SshCommand = $sshProfiles[$idx - 1].commandline
    }
    else {
        # Plenty of people never make an SSH profile - they open a normal
        # shell tab and type ssh. Ask instead of dead-ending on an error.
        Hdr "No SSH profile found in Windows Terminal"
        Write-Host "  How do you reach the box? e.g.  you@203.0.113.9   or   ssh myserver -p 2222"
        $answer = Read-Host "  ssh target"
        if (-not $answer -or -not $answer.Trim()) {
            throw "Nothing entered. Re-run with -SshCommand ""ssh yourhost""."
        }
        $SshCommand = $answer
    }
}

# Accept a bare target ("user@host") as readily as a full command line.
$SshCommand = $SshCommand.Trim()
if ($SshCommand -notmatch '\bssh(\.exe)?\b') { $SshCommand = "ssh $SshCommand" }

# -t is not optional: listen mode refuses to run without a real tty, and
# `ssh host <cmd>` doesn't allocate one.
$cmdline = '{0} -t "{1} listen"' -f $SshCommand, $RemoteBellPath

# ------------------------------------------------------------------- the wav
Hdr "Alert sound"
New-AlertWav -Path $SoundPath
Ok "wrote $SoundPath (200 ms, beep-beep)"
try {
    $player = New-Object System.Media.SoundPlayer $SoundPath
    $player.PlaySync()
    Ok "played it once — that is what 'Claude needs you' will sound like"
} catch { Warn "couldn't preview it here, but the file is written" }

# --------------------------------------------------------------- the profile
Hdr "Terminal profile"
$alerts = [ordered]@{
    guid                     = $PROFILE_GUID
    name                     = $ProfileName
    commandline              = $cmdline
    tabTitle                 = $ProfileName
    suppressApplicationTitle = $true
    bellStyle                = 'audible'
    bellSound                = $SoundPath
    hidden                   = $false
}

$existing = @($list | Where-Object { $_.guid -eq $PROFILE_GUID })
if ($existing.Count -gt 0) {
    foreach ($k in $alerts.Keys) {
        $existing[0] | Add-Member -NotePropertyName $k -NotePropertyValue $alerts[$k] -Force
    }
    Ok "updated the existing '$ProfileName' profile"
    $newList = $list
} else {
    $newList = $list + [pscustomobject]$alerts
    Ok "added profile '$ProfileName'"
}

if ($flat) { $cfg.profiles = $newList } else { $cfg.profiles.list = $newList }
Save-Json $cfg $settingsFile
Ok "saved settings.json (comments in it are not preserved — see the backup)"

Write-Host ""
Write-Host "Connection : $cmdline"
Write-Host "Sound      : $SoundPath"
Write-Host ""
Write-Host "Open the '$ProfileName' tab from the Terminal dropdown and leave it open."
Write-Host "Permission prompts and questions beep there; 'done' stays in your session tab."
Write-Host "Closing the tab is the off switch — nothing to undo on the server."

if (-not $NoLaunch) {
    $wt = Get-Command wt.exe -ErrorAction SilentlyContinue
    if ($wt) {
        Hdr "Opening it now"
        # One pre-quoted string: an -ArgumentList array is joined with plain
        # spaces, which splits a profile name like "Claude alerts" in two.
        Start-Process wt.exe -ArgumentList "-w 0 nt -p `"$ProfileName`""
        Ok "launched — bell.sh prints a test beep when it connects"
    } else {
        Warn "wt.exe not on PATH; open the tab from the dropdown yourself"
    }
}
