#Requires -Version 5.1
<#
.SYNOPSIS
    Windows traffic generator for Zscaler lab environments.

.DESCRIPTION
    Simulates realistic web traffic for different user personas. Designed to run
    via Windows Task Scheduler on a schedule matching the persona's work pattern.
    Requires the Zscaler root CA installed in the Windows Trusted Root CA store
    so that TLS-inspected traffic is not blocked by certificate errors.

.PARAMETER Profile
    Traffic persona: office-worker, sales, developer, executive, threat

.PARAMETER DurationMinutes
    How long to run before exiting cleanly. Default: 30.

.EXAMPLE
    .\win-traffic.ps1 -Profile office-worker -DurationMinutes 55
    .\win-traffic.ps1 -Profile threat -DurationMinutes 10
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("office-worker", "sales", "developer", "executive", "threat")]
    [string]$Profile,

    [Parameter(Mandatory = $false)]
    [int]$DurationMinutes = 30
)

$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

$LOG_DIR  = "C:\ProgramData\proxmox-lab"
$LOG_FILE = "$LOG_DIR\traffic-gen.log"

if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}

function Write-TrafficLog {
    param([string]$Message, [string]$Level = "INFO")
    $ts   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Profile] [$Level] $Message"
    Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------

$SCRIPT_START = Get-Date
$END_TIME     = $SCRIPT_START.AddMinutes($DurationMinutes)

function Test-TimeRemaining { return (Get-Date) -lt $END_TIME }

function Start-RandomDelay {
    param([int]$Min = 5, [int]$Max = 45)
    if (-not (Test-TimeRemaining)) { return }
    Start-Sleep -Seconds (Get-Random -Minimum $Min -Maximum ($Max + 1))
}

# ---------------------------------------------------------------------------
# User agents
# ---------------------------------------------------------------------------

$UA_WINDOWS = @(
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0"
)

$UA_MAC = @(
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_1) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

$UA_DEV_BROWSER = @(
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

$UA_DEV_TOOL = @(
    "git/2.47.1",
    "npm/10.9.2 node/v22.12.0 win32 x64",
    "python-requests/2.32.3",
    "Docker/27.4.0 go/go1.23.3 git-commit/6b50c08 kernel/10.0.26100.2454 os/windows arch/amd64"
)

# ---------------------------------------------------------------------------
# Core HTTP helper
# ---------------------------------------------------------------------------

function Invoke-Traffic {
    param(
        [string]   $Uri,
        [string]   $UserAgent,
        [string]   $Method      = "GET",
        [hashtable]$Headers     = @{},
        [string]   $Body,
        [string]   $ContentType
    )

    if (-not (Test-TimeRemaining)) { return }

    try {
        $params = @{
            Uri             = $Uri
            UserAgent       = $UserAgent
            Method          = $Method
            TimeoutSec      = 20
            UseBasicParsing = $true
        }
        if ($Headers.Count -gt 0) { $params.Headers     = $Headers }
        if ($Body)                 { $params.Body        = $Body }
        if ($ContentType)          { $params.ContentType = $ContentType }

        $response = Invoke-WebRequest @params
        Write-TrafficLog "$Method $Uri $($response.StatusCode)"
    }
    catch [System.Net.WebException] {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { "TIMEOUT" }
        Write-TrafficLog "$Method $Uri $code"
    }
    catch {
        $msg = ($_.Exception.Message -replace '\r?\n', ' ').Substring(0, [Math]::Min(80, $_.Exception.Message.Length))
        Write-TrafficLog "$Method $Uri ERR ($msg)"
    }
}

# ---------------------------------------------------------------------------
# Profile: office-worker
#   Microsoft 365 productivity, SaaS collaboration, lunch/personal browsing
#   UA: Windows Chrome/Edge/Firefox pool  -  pick one per session
# ---------------------------------------------------------------------------

function Invoke-OfficeWorkerSession {
    $ua = $UA_WINDOWS | Get-Random
    Write-TrafficLog "--- session start (ua: $($ua.Split('/')[0]))"

    # Microsoft 365 productivity
    $m365 = @(
        "https://outlook.office.com",
        "https://teams.microsoft.com",
        "https://www.office.com",
        "https://sharepoint.com",
        "https://onedrive.live.com"
    )
    foreach ($url in ($m365 | Get-Random -Count (Get-Random -Minimum 2 -Maximum 4))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 8 -Max 25
    }

    # SaaS / collaboration
    $saas = @(
        "https://www.salesforce.com",
        "https://slack.com",
        "https://workspace.google.com",
        "https://zoom.us",
        "https://www.atlassian.com",
        "https://servicenow.com",
        "https://www.workday.com"
    )
    foreach ($url in ($saas | Get-Random -Count (Get-Random -Minimum 2 -Maximum 4))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 8 -Max 25
    }

    # Lunch / personal browsing
    $personal = @(
        "https://www.bbc.com",
        "https://www.cnn.com",
        "https://www.reddit.com",
        "https://www.amazon.com",
        "https://www.linkedin.com",
        "https://news.google.com",
        "https://www.espn.com",
        "https://www.weather.com"
    )
    foreach ($url in ($personal | Get-Random -Count (Get-Random -Minimum 2 -Maximum 3))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 5 -Max 20
    }
}

# ---------------------------------------------------------------------------
# Profile: sales
#   CRM, prospecting, travel, GenAI for pitch prep
#   UA: Mac Safari/Chrome pool  -  pick one per session
# ---------------------------------------------------------------------------

function Invoke-SalesSession {
    $ua = $UA_MAC | Get-Random
    Write-TrafficLog "--- session start (ua: $($ua.Split('/')[0]))"

    # CRM and prospecting
    $crm = @(
        "https://www.salesforce.com",
        "https://www.linkedin.com",
        "https://app.hubspot.com",
        "https://www.outreach.io",
        "https://zoom.us",
        "https://teams.microsoft.com"
    )
    foreach ($url in ($crm | Get-Random -Count (Get-Random -Minimum 2 -Maximum 4))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 8 -Max 25
    }

    # Analyst / competitive research
    $research = @(
        "https://www.gartner.com",
        "https://www.forrester.com",
        "https://www.crunchbase.com",
        "https://www.g2.com",
        "https://www.zdnet.com"
    )
    foreach ($url in ($research | Get-Random -Count (Get-Random -Minimum 1 -Maximum 3))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 5 -Max 15
    }

    # Travel / expenses
    $travel = @(
        "https://www.expedia.com",
        "https://www.hotels.com",
        "https://www.concur.com",
        "https://www.tripadvisor.com"
    )
    foreach ($url in ($travel | Get-Random -Count (Get-Random -Minimum 1 -Maximum 2))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 5 -Max 15
    }

    # GenAI browsing
    $genai = @(
        "https://chatgpt.com",
        "https://claude.ai",
        "https://gemini.google.com",
        "https://huggingface.co",
        "https://www.perplexity.ai"
    )
    foreach ($url in ($genai | Get-Random -Count (Get-Random -Minimum 1 -Maximum 2))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 5 -Max 15
    }

    # GenAI API call (business prompt  -  inspected by Zscaler regardless of response)
    $prompt = @(
        "Draft a follow-up email to prospect Jane Doe at Acme Corp after our Q1 pricing call.",
        "Summarize our top 3 competitive advantages against CrowdStrike for a healthcare pitch.",
        "Write a 3-sentence value proposition for our cloud security platform targeting retail."
    ) | Get-Random
    $payload = @{ inputs = $prompt } | ConvertTo-Json
    Invoke-Traffic -Uri "https://api-inference.huggingface.co/models/distilgpt2" `
        -Method "POST" -Body $payload -ContentType "application/json" -UserAgent $ua
}

# ---------------------------------------------------------------------------
# Profile: developer
#   Package registries (tool UAs), code/docs (browser UA), cloud consoles, GenAI
#   UA: rotates between browser and tool UAs within session
# ---------------------------------------------------------------------------

function Invoke-DeveloperSession {
    $browserUa = $UA_DEV_BROWSER | Get-Random
    $toolUa    = $UA_DEV_TOOL    | Get-Random
    Write-TrafficLog "--- session start (browser: $($browserUa.Split('/')[0]), tool: $($toolUa.Split('/')[0]))"

    # Package registries  -  tool UA simulates actual package manager traffic
    $registries = @(
        "https://registry.npmjs.org",
        "https://pypi.org/simple/",
        "https://hub.docker.com",
        "https://pkg.go.dev",
        "https://crates.io"
    )
    foreach ($url in ($registries | Get-Random -Count (Get-Random -Minimum 1 -Maximum 3))) {
        Invoke-Traffic -Uri $url -UserAgent $toolUa
        Start-RandomDelay -Min 3 -Max 10
    }

    # Code, docs, community  -  browser UA
    $devSites = @(
        "https://github.com",
        "https://gitlab.com",
        "https://stackoverflow.com",
        "https://developer.mozilla.org",
        "https://docs.aws.amazon.com",
        "https://learn.microsoft.com",
        "https://docs.docker.com",
        "https://kubernetes.io/docs/"
    )
    foreach ($url in ($devSites | Get-Random -Count (Get-Random -Minimum 2 -Maximum 4))) {
        Invoke-Traffic -Uri $url -UserAgent $browserUa
        Start-RandomDelay -Min 8 -Max 25
    }

    # Cloud console
    $cloud = @(
        "https://console.aws.amazon.com",
        "https://portal.azure.com",
        "https://console.cloud.google.com"
    )
    Invoke-Traffic -Uri ($cloud | Get-Random) -UserAgent $browserUa
    Start-RandomDelay -Min 5 -Max 15

    # GenAI for coding assistance
    $genai = @(
        "https://chatgpt.com",
        "https://claude.ai",
        "https://github.com/features/copilot",
        "https://www.perplexity.ai"
    )
    foreach ($url in ($genai | Get-Random -Count (Get-Random -Minimum 1 -Maximum 2))) {
        Invoke-Traffic -Uri $url -UserAgent $browserUa
        Start-RandomDelay -Min 5 -Max 15
    }

    # GenAI API call (code question)
    $prompt = @(
        "Explain this Python traceback: AttributeError: 'NoneType' object has no attribute 'split'",
        "Write a Terraform module for an AWS S3 bucket with versioning and lifecycle rules.",
        "Why is this SQL query slow: SELECT * FROM orders JOIN customers ON orders.cid = customers.id WHERE status = 'pending'",
        "Convert this bash script to PowerShell: for f in *.log; do grep -c ERROR `$f; done"
    ) | Get-Random
    $payload = @{ inputs = $prompt } | ConvertTo-Json
    Invoke-Traffic -Uri "https://api-inference.huggingface.co/models/distilgpt2" `
        -Method "POST" -Body $payload -ContentType "application/json" -UserAgent $browserUa
}

# ---------------------------------------------------------------------------
# Profile: executive
#   Light O365, business news, GenAI for briefings
#   UA: Mac Safari pool
#   Note: the 10:30 PM scheduled task run generates the UEBA signal  -  the
#   profile itself doesn't need special after-hours logic; timing is in the task
# ---------------------------------------------------------------------------

function Invoke-ExecutiveSession {
    $ua = $UA_MAC | Get-Random
    Write-TrafficLog "--- session start (ua: $($ua.Split('/')[0]))"

    # O365 productivity
    $prod = @(
        "https://outlook.office365.com",
        "https://teams.microsoft.com",
        "https://zoom.us",
        "https://www.office.com"
    )
    foreach ($url in ($prod | Get-Random -Count (Get-Random -Minimum 1 -Maximum 3))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 8 -Max 25
    }

    # Business news and finance
    $news = @(
        "https://www.wsj.com",
        "https://www.bloomberg.com",
        "https://www.reuters.com",
        "https://www.ft.com",
        "https://hbr.org",
        "https://www.linkedin.com",
        "https://www.cnbc.com"
    )
    foreach ($url in ($news | Get-Random -Count (Get-Random -Minimum 2 -Maximum 3))) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 10 -Max 30
    }

    # GenAI  -  executives use it for summaries and comms
    $genai = @("https://chatgpt.com", "https://claude.ai", "https://gemini.google.com")
    Invoke-Traffic -Uri ($genai | Get-Random) -UserAgent $ua
    Start-RandomDelay -Min 5 -Max 15

    $prompt = @(
        "Summarize the key risks in our Q4 earnings report in 3 bullet points.",
        "Draft a one-paragraph board update on our cloud migration progress for the Q1 all-hands.",
        "Write talking points for an investor call about our AI strategy and competitive positioning."
    ) | Get-Random
    $payload = @{ inputs = $prompt } | ConvertTo-Json
    Invoke-Traffic -Uri "https://api-inference.huggingface.co/models/distilgpt2" `
        -Method "POST" -Body $payload -ContentType "application/json" -UserAgent $ua
}

# ---------------------------------------------------------------------------
# Profile: threat
#   Security test events  -  maps to the LXC security-tests/ scripts
#   Runs each test type once per session; scheduled 3x/day
#
#   AV:     EICAR test file download
#   DLP:    POST fake SSN+CCN to public HTTPS endpoint
#   DLP:    POST PII-in-prompt to real AI APIs (OpenAI, Anthropic)
#           No valid key used  -  server returns 401, but Zscaler inspects the
#           outbound request body before the response arrives, triggering DLP
#   Policy: HTTP access to blocked personal cloud storage sites
# ---------------------------------------------------------------------------

function Invoke-ThreatSession {
    $ua = $UA_WINDOWS | Get-Random
    Write-TrafficLog "--- threat session start ---"

    # --- Policy violation: personal cloud storage ---
    Write-TrafficLog "policy-violation: accessing personal cloud storage"
    $policySites = @(
        "https://www.dropbox.com",
        "https://wetransfer.com",
        "https://mega.nz",
        "https://www.box.com",
        "https://www.mediafire.com"
    )
    foreach ($url in $policySites) {
        Invoke-Traffic -Uri $url -UserAgent $ua
        Start-RandomDelay -Min 3 -Max 8
    }

    # --- AV: EICAR test file ---
    Write-TrafficLog "eicar: downloading EICAR test file"
    Invoke-Traffic -Uri "https://www.eicar.org/download/eicar.com.txt" -UserAgent $ua
    Invoke-Traffic -Uri "https://www.eicar.org/download/eicar_com.zip" -UserAgent $ua
    Start-RandomDelay -Min 3 -Max 8

    # --- DLP: POST fake PII to public endpoint ---
    Write-TrafficLog "dlp-network: POST fake SSN/CCN to HTTPS endpoint"
    $body = "firstname=John&lastname=Smith&ssn=123-45-6789&ccn=4111111111111111&amount=9500&account=87654321"
    Invoke-Traffic -Uri "https://httpbin.org/post" `
        -Method "POST" -Body $body -ContentType "application/x-www-form-urlencoded" -UserAgent $ua
    Start-RandomDelay -Min 3 -Max 8

    # Shared PII payload for GenAI DLP tests
    $piiPrompt = @(
        "Summarize this employee record: John Smith, DOB 03/15/1985, SSN 123-45-6789, salary `$92000, perf rating 4.2.",
        "Draft a collections letter to John Smith at 123 Main St Springfield IL 62701, account 87654321, balance `$5,240.",
        "Analyze this patient: Jane Doe, DOB 07/22/1978, MRN 456789, diagnosis hypertension, insurance ID HMO-987654."
    ) | Get-Random

    # --- DLP: GenAI prompt with PII  -  OpenAI ---
    Write-TrafficLog "dlp-genai-prompt: POST PII to OpenAI API"
    $openaiPayload = @{
        model    = "gpt-4"
        messages = @(@{ role = "user"; content = $piiPrompt })
    } | ConvertTo-Json -Depth 3
    Invoke-Traffic -Uri "https://api.openai.com/v1/chat/completions" `
        -Method "POST" -Body $openaiPayload -ContentType "application/json" -UserAgent $ua `
        -Headers @{ Authorization = "Bearer sk-dlp-test-no-valid-key-zscaler-inspection-target" }
    Start-RandomDelay -Min 3 -Max 8

    # --- DLP: GenAI prompt with PII  -  Anthropic ---
    Write-TrafficLog "dlp-genai-prompt: POST PII to Anthropic API"
    $anthropicPayload = @{
        model      = "claude-3-5-sonnet-20241022"
        max_tokens = 256
        messages   = @(@{ role = "user"; content = $piiPrompt })
    } | ConvertTo-Json -Depth 3
    Invoke-Traffic -Uri "https://api.anthropic.com/v1/messages" `
        -Method "POST" -Body $anthropicPayload -ContentType "application/json" -UserAgent $ua `
        -Headers @{
            "x-api-key"         = "sk-ant-dlp-test-no-valid-key-zscaler-inspection-target"
            "anthropic-version" = "2023-06-01"
        }
    Start-RandomDelay -Min 3 -Max 8

    # --- DLP: GenAI prompt with PII  -  Google Gemini ---
    Write-TrafficLog "dlp-genai-prompt: POST PII to Google Gemini API"
    $geminiPayload = @{
        contents = @(@{
            parts = @(@{ text = $piiPrompt })
        })
    } | ConvertTo-Json -Depth 4
    Invoke-Traffic -Uri "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=dlp-test-no-valid-key" `
        -Method "POST" -Body $geminiPayload -ContentType "application/json" -UserAgent $ua
}

# ---------------------------------------------------------------------------
# Main loop  -  runs sessions until DurationMinutes expires
# ---------------------------------------------------------------------------

Write-TrafficLog "=== started | duration=${DurationMinutes}m | end=$($END_TIME.ToString('HH:mm:ss')) ==="

$sessionCount = 0

while (Test-TimeRemaining) {
    $sessionCount++
    Write-TrafficLog "--- session $sessionCount ---"

    switch ($Profile) {
        "office-worker" { Invoke-OfficeWorkerSession }
        "sales"         { Invoke-SalesSession }
        "developer"     { Invoke-DeveloperSession }
        "executive"     { Invoke-ExecutiveSession }
        "threat"        { Invoke-ThreatSession }
    }

    # Pause between sessions (skipped if time already expired)
    if (Test-TimeRemaining) {
        Start-RandomDelay -Min 30 -Max 90
    }
}

$elapsed = [int]((Get-Date) - $SCRIPT_START).TotalMinutes
Write-TrafficLog "=== done | sessions=$sessionCount elapsed=${elapsed}m ==="
