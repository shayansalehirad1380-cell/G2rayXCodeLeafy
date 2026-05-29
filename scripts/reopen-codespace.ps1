param(
    [string]$Name,
    [string]$Repo,
    [int]$TimeoutSeconds = 600,
    [switch]$NoOpen
)

$ErrorActionPreference = "Stop"

function Fail($Message, $Code = 1) {
    Write-Error $Message
    exit $Code
}

function CurrentRepoFromGitRemote {
    $remote = (& git config --get remote.origin.url 2>$null)
    if (-not $remote) { return $null }
    if ($remote -match "github\.com[:/](?<repo>[^/]+/[^/.]+)(?:\.git)?$") {
        return $Matches.repo
    }
    return $null
}

function RequireCommand($Command) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        Fail "Missing required command: $Command"
    }
}

RequireCommand gh

& gh auth status -h github.com *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "GitHub CLI is not authenticated. Run: gh auth login"
}

if (-not $Repo) {
    $Repo = CurrentRepoFromGitRemote
}

$listArgs = @("codespace", "list", "--json", "name,state,repository,lastUsedAt,displayName", "--limit", "100")
if ($Repo) {
    $listArgs += @("--repo", $Repo)
}

$rawList = (& gh @listArgs 2>&1)
if ($LASTEXITCODE -ne 0) {
    $text = ($rawList -join "`n")
    if ($text -match "codespace.*scope") {
        Fail "GitHub CLI needs the codespace scope. Run: gh auth refresh -h github.com -s codespace"
    }
    Fail "Could not list Codespaces: $text"
}

$codespaces = @($rawList | ConvertFrom-Json)
if ($codespaces.Count -eq 0) {
    if ($Repo) {
        Fail "No Codespaces found for $Repo."
    }
    Fail "No Codespaces found."
}

if (-not $Name) {
    $selected = $codespaces | Sort-Object lastUsedAt -Descending | Select-Object -First 1
    $Name = $selected.name
}

Write-Host "Codespace : $Name"
if ($Repo) { Write-Host "Repository: $Repo" }

$startOutput = (& gh api --method POST "/user/codespaces/$Name/start" 2>&1)
if ($LASTEXITCODE -ne 0) {
    $text = ($startOutput -join "`n")
    if ($text -match "HTTP 402") {
        Fail "GitHub returned HTTP 402. The Codespace is quota/billing blocked; wait for quota reset or change GitHub billing settings." 2
    }
    if ($text -match "HTTP 409|already.*running|not.*stopped") {
        Write-Host "Start API says the Codespace is already active; continuing."
    } else {
        Write-Warning "Start API did not complete cleanly: $text"
        Write-Warning "Continuing to status wait/open because gh codespace code may still start it interactively."
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$state = "unknown"
do {
    Start-Sleep -Seconds 5
    $viewRaw = (& gh codespace view -c $Name --json state,idleTimeoutMinutes,displayName 2>&1)
    if ($LASTEXITCODE -eq 0) {
        $view = $viewRaw | ConvertFrom-Json
        $state = $view.state
        Write-Host "State     : $state"
        if ($view.idleTimeoutMinutes -and [int]$view.idleTimeoutMinutes -lt 240) {
            Write-Host "Idle time : $($view.idleTimeoutMinutes)m. For fewer sleeps, set GitHub Codespaces Default idle timeout to 240 minutes."
        }
        if ($state -match "Available|Running") { break }
    } else {
        Write-Warning ($viewRaw -join "`n")
    }
} while ((Get-Date) -lt $deadline)

if ($state -notmatch "Available|Running") {
    Fail "Timed out waiting for Codespace $Name to become available. Last state: $state"
}

if (-not $NoOpen) {
    Write-Host "Opening in VS Code..."
    & gh codespace code -c $Name
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not open VS Code automatically. Open this URL instead: https://github.com/codespaces/$Name"
    }
}

Write-Host "Codespace is available. Inside it, postStartCommand should run ./g2ray.sh --silent-start automatically."
