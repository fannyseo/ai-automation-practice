# Inspect an existing project. Does not execute recordings, install tools, or read secrets.
# Run in Windows PowerShell 5.1 or later.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path
$scriptPath = Join-Path $Root 'process-recordings.ps1'
if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw 'process-recordings.ps1 was not found. Select the EXISTING project folder.'
}

$folders = @('inbox','notes','tools','models','logs','config','app','data')
$folderStatus = @($folders | ForEach-Object {
    [pscustomobject]@{name=$_; exists=(Test-Path -LiteralPath (Join-Path $Root $_) -PathType Container)}
})
$models = @()
$modelDir = Join-Path $Root 'models'
if (Test-Path -LiteralPath $modelDir -PathType Container) {
    $models = @(Get-ChildItem -LiteralPath $modelDir -File -Filter '*.bin' |
        Select-Object Name,Length,LastWriteTime)
}
$toolFiles = @()
$toolDir = Join-Path $Root 'tools'
if (Test-Path -LiteralPath $toolDir -PathType Container) {
    $toolFiles = @(Get-ChildItem -LiteralPath $toolDir -File -Recurse |
        Where-Object { $_.Name -in @('whisper-cli.exe','main.exe','whisper.exe','ffmpeg.exe') } |
        Select-Object Name,FullName,Length)
}
$commands = @('codex','python','py','ffmpeg') | ForEach-Object {
    $cmd = Get-Command $_ -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{name=$_; found=($null -ne $cmd); path=if ($cmd) {$cmd.Source} else {$null}}
}

# Parse source without running it. Never include source text in the report.
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath, [ref]$tokens, [ref]$parseErrors)
$source = [System.IO.File]::ReadAllText($scriptPath)
$modelMentions = @([regex]::Matches($source, '(?i)ggml-[a-z0-9._-]+\.bin') |
    ForEach-Object { $_.Value } | Select-Object -Unique)
$sourceChecks = [pscustomobject]@{
    parseErrorCount = @($parseErrors).Count
    modelFilenameMentions = $modelMentions
    mentionsCodex = [bool]($source -match '(?i)\bcodex\b')
    mentionsFfmpeg = [bool]($source -match '(?i)ffmpeg')
    mentionsNotify = [bool]($source -match '(?i)notify\.py|NotifyEnabled')
    mentionsDatabase = [bool]($source -match '(?i)db\.py|status\.db')
    note = 'Text mentions are clues only; they do not prove execution or success.'
}

$taskStatus = @()
$taskQueryError = $null
try {
    $tasks = @(Get-ScheduledTask | Where-Object {
        @($_.Actions | Where-Object {
            $_.Arguments -like '*process-recordings.ps1*'
        }).Count -gt 0
    })
    $taskStatus = @($tasks | ForEach-Object {
        $task = $_
        $info = $task | Get-ScheduledTaskInfo
        [pscustomobject]@{
            name = $task.TaskName
            taskPath = $task.TaskPath
            state = [string]$task.State
            lastRunTime = $info.LastRunTime
            nextRunTime = $info.NextRunTime
            lastTaskResult = $info.LastTaskResult
            actions = @($task.Actions | ForEach-Object {
                [pscustomobject]@{
                    executable = $_.Execute
                    usesHiddenFlag = [bool]($_.Arguments -match '(?i)-WindowStyle\s+Hidden')
                    referencesThisScript = [bool]($_.Arguments -like ('*' + $scriptPath + '*'))
                }
            })
            triggers = @($task.Triggers | ForEach-Object {
                [pscustomobject]@{
                    type = $_.CimClass.CimClassName
                    enabled = $_.Enabled
                    startBoundary = $_.StartBoundary
                    interval = $_.Repetition.Interval
                    duration = $_.Repetition.Duration
                }
            })
        }
    })
} catch {
    $taskQueryError = 'Task query failed. Inspect Task Scheduler locally; do not assume no task exists.'
}

$files = @('01_','02_','03_','04_','05_')
$notesStatus = @()
$notesDir = Join-Path $Root 'notes'
if (Test-Path -LiteralPath $notesDir -PathType Container) {
    $notesStatus = @(Get-ChildItem -LiteralPath $notesDir -Directory |
        Where-Object { $_.Name -notlike '_*' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20 |
        ForEach-Object {
            $dir = $_
            $md = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.md')
            $present = @($files | ForEach-Object {
                $prefix = $_
                [pscustomobject]@{
                    prefix = $prefix
                    nonemptyFileExists = @($md | Where-Object {
                        $_.Name -like ($prefix + '*.md') -and $_.Length -gt 0
                    }).Count -gt 0
                }
            })
            [pscustomobject]@{
                folder = $dir.Name
                updated = $dir.LastWriteTime
                documents = $present
                allFiveNonempty = @($present | Where-Object { -not $_.nonemptyFileExists }).Count -eq 0
            }
        })
}
$configStatus = @('telegram_token.txt','telegram_chat_id.txt') | ForEach-Object {
    $p = Join-Path (Join-Path $Root 'config') $_
    $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
    [pscustomobject]@{name=$_; exists=($null -ne $item); nonempty=($null -ne $item -and $item.Length -gt 0)}
}
$appStatus = @('app\notify.py','app\db.py','app\main.py','data\status.db','logs\run.log') |
    ForEach-Object {
        [pscustomobject]@{path=$_; exists=(Test-Path -LiteralPath (Join-Path $Root $_) -PathType Leaf)}
    }

$report = [ordered]@{
    inspectedAt = (Get-Date).ToString('o')
    root = $Root
    scope = 'Metadata only. No audio, transcript, log contents, config contents, or task arguments exported.'
    folders = $folderStatus
    models = $models
    tools = $toolFiles
    commandDiscovery = @($commands)
    scriptClues = $sourceChecks
    scheduledTasks = $taskStatus
    taskQueryError = $taskQueryError
    recentNotes = $notesStatus
    telegramConfigMetadata = @($configStatus)
    applicationFiles = @($appStatus)
    notVerified = @(
        'Executable health, Codex authentication, and actual model selected at runtime',
        'Five-minute end-to-end processing and document accuracy',
        'Telegram delivery and dashboard/reprocessing behavior'
    )
}
$logDir = Join-Path $Root 'logs'
$null = New-Item -ItemType Directory -Path $logDir -Force
$out = Join-Path $logDir 'inspection-report.json'
$json = $report | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($out, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('Report saved: ' + $out)
Write-Output 'Existing project files were preserved. Only this metadata report was written.'
