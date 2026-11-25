#Requires -Version 7.0
<#
.SYNOPSIS
    Crea N Pull Request di demo (alcune conformi, altre no) e, con -Wait, attende le esecuzioni agentiche.

.DESCRIPTION
    Ogni PR parte da 'main' e applica uno degli scenari in ../scenarios (a rotazione).
    La Build Validation avvia la pipeline 'ado-aw Standards Compliance Review' a ogni PR:
    se l'agente trova violazioni degli standard crea un Task, altrimenti non crea nulla.
    Alla fine stampa il comando Get-AiCredits.ps1 già compilato con i valori di questa PoC (periodo = giorno di oggi).

.EXAMPLE
    ./New-DemoPullRequests.ps1 -Count 5 -Wait
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)][int]$Count = 5,
    [switch]$Wait,
    [int]$TimeoutMinutes = 90,
    [string]$Pat
)

. "$PSScriptRoot/PocCommon.ps1"
$pocRoot = Split-Path $PSScriptRoot -Parent
$state = Read-PocState
if (-not $state) { throw 'Stato della PoC non trovato (.poc-state.json): esegui prima Setup-Poc.ps1.' }

$ctx = @{ OrganizationUrl = $state.organizationUrl; Project = $state.project; Headers = (Get-AdoHeaders $Pat) }
$projBase = Get-ProjectBaseUrl $ctx.OrganizationUrl $ctx.Project
$repoId = $state.appRepoId

function Write-CreditsHint([datetime]$FromUtc) {
    $hint = "./poc/scripts/Get-AiCredits.ps1 -GitHubOrg $($state.githubOrg)"
    if (Get-StateValue $state 'githubHost') { $hint += " -GitHubHost $($state.githubHost)" }
    if (Get-StateValue $state 'githubAppClientId') { $hint += " -AppClientId $($state.githubAppClientId)" }
    $hint += " -From $($FromUtc.ToString('yyyy-MM-dd'))"
    Write-Host "`nAI Credits consumati (token di lettura della fatturazione: GH_TOKEN, -GitHubToken o -BillingAppId):" -ForegroundColor Cyan
    Write-Host "  $hint" -ForegroundColor Cyan
}

# ------------------------------------------------------------------ creazione delle PR
Write-Step "Creazione di $Count Pull Request di demo"
$scenarios = @(Get-ChildItem (Join-Path $pocRoot 'scenarios') -Directory | Sort-Object Name)
$expected = Get-Content (Join-Path $pocRoot 'scenarios/expected.json') -Raw | ConvertFrom-Json
$mainSha = Get-BranchHead $ctx $repoId 'main'
if (-not $mainSha) { throw "Il ramo main del repository '$($state.appRepo)' non esiste: riesegui Setup-Poc.ps1." }
$mainFiles = Get-RepoFiles $ctx $repoId 'main'
$startUtc = (Get-Date).ToUniversalTime()
$created = @()

for ($i = 1; $i -le $Count; $i++) {
    $dir = $scenarios[($i - 1) % $scenarios.Count]
    $info = $expected.($dir.Name)
    $branch = "demo/ado-aw-$($startUtc.ToString('yyyyMMdd-HHmmss'))-$i-$($dir.Name)"
    $files = @(Get-LocalFiles $dir.FullName)
    [void](Send-AdoPush $ctx $repoId $branch "Demo ado-aw: $($info.titolo)" $files $mainFiles $mainSha)
    $rules = if ($info.regole.Count) { ($info.regole -join ', ') } else { 'nessuna' }
    $description = @"
PR di demo generata da ``New-DemoPullRequests.ps1`` (scenario ``$($dir.Name)``).

- **Violazioni attese**: $rules
- **Task atteso**: $(if ($info.taskAtteso) { 'sì' } else { 'no (codice conforme)' })
"@
    $pr = Invoke-Ado -Method POST -Url "$projBase/_apis/git/repositories/$repoId/pullrequests" -Headers $ctx.Headers -Body @{
        sourceRefName = "refs/heads/$branch"; targetRefName = 'refs/heads/main'
        title = "[ado-aw demo] $($info.titolo)"; description = $description
    }
    $created += [pscustomobject]@{
        Pr = $pr.pullRequestId; Scenario = $dir.Name; TaskAtteso = [bool]$info.taskAtteso
        Url = "$projBase/_git/$([uri]::EscapeDataString($state.appRepo))/pullrequest/$($pr.pullRequestId)"
    }
    Write-Ok "PR #$($pr.pullRequestId)  $($dir.Name)"
    Start-Sleep -Seconds 2
}

$created | Format-Table Pr, Scenario, TaskAtteso, Url -AutoSize | Out-Host
Write-Host "Le $Count esecuzioni partono in automatico (Build Validation). Pipeline: $projBase/_build?definitionId=$($state.pipelineId)" -ForegroundColor Cyan

if (-not $Wait) {
    Write-CreditsHint $startUtc
    return
}

# ------------------------------------------------------------------ attesa e verifica dei Task
Write-Step "Attendo il completamento delle $Count esecuzioni (timeout $TimeoutMinutes min)"
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$noRunDeadline = (Get-Date).AddMinutes(6)
$mine = @()
$lastAuth = Get-Date
do {
    Start-Sleep -Seconds 30
    # Il token di Azure CLI dura circa un'ora: con attese lunghe va rinnovato (con -Pat non serve).
    if (-not $Pat -and ((Get-Date) - $lastAuth).TotalMinutes -ge 10) { $ctx.Headers = Get-AdoHeaders $Pat; $lastAuth = Get-Date }
    $runs = Invoke-Ado -Method GET -Url "$projBase/_apis/pipelines/$($state.pipelineId)/runs" -Headers $ctx.Headers
    $mine = @($runs.value) | Where-Object { (ConvertTo-UtcDateTime $_.createdDate) -ge $startUtc.AddMinutes(-1) }
    $done = @($mine | Where-Object { $_.state -eq 'completed' })
    Write-Host ("  esecuzioni completate: {0}/{1} (avviate: {2})" -f $done.Count, $Count, @($mine).Count)
    if (@($mine).Count -eq 0 -and (Get-Date) -gt $noRunDeadline) {
        Write-Warn 'Nessuna esecuzione avviata dopo 6 minuti: verifica la Build Validation sul ramo main (Repos > Branches > Branch policies) e il parallelismo degli agent.'
        break
    }
} while ($done.Count -lt $Count -and (Get-Date) -lt $deadline)

$since = $startUtc.AddMinutes(-1).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
$wiql = @{ query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Tags] CONTAINS 'ado-aw' AND [System.CreatedDate] >= '$since' ORDER BY [System.CreatedDate] ASC" }
$found = Invoke-Ado -Method POST -Url "$projBase/_apis/wit/wiql?timePrecision=true" -Headers $ctx.Headers -Body $wiql
$tasks = @()
$ids = @($found.workItems) | ForEach-Object { $_.id }
if ($ids) {
    $details = Invoke-Ado -Method GET -Url "$projBase/_apis/wit/workitems?ids=$($ids -join ',')&fields=System.Id,System.Title,System.WorkItemType" -Headers $ctx.Headers
    $tasks = @($details.value)
}

Write-Step 'Esito'
$rows = foreach ($c in $created) {
    $task = $tasks | Where-Object { $_.fields.'System.Title' -match "PR #$($c.Pr)\b" } | Select-Object -First 1
    [pscustomobject]@{
        PR       = "#$($c.Pr)"
        Scenario = $c.Scenario
        Atteso   = if ($c.TaskAtteso) { 'Task' } else { 'nessun Task' }
        Ottenuto = if ($task) { "Task $($task.id)" } else { 'nessun Task' }
        Esito    = if ([bool]$task -eq $c.TaskAtteso) { 'OK' } else { 'DIVERSO' }
    }
}
$rows | Format-Table -AutoSize | Out-Host
$completed = @($mine | Where-Object { $_.state -eq 'completed' })
$failed = @($completed | Where-Object { $_.result -ne 'succeeded' })
Write-Host ("Esecuzioni completate: {0}/{1} · non riuscite: {2} · Task creati: {3}" -f $completed.Count, $Count, $failed.Count, $tasks.Count) -ForegroundColor Green
foreach ($t in $tasks) { Write-Host "  $projBase/_workitems/edit/$($t.id)  $($t.fields.'System.Title')" }
Write-CreditsHint $startUtc
