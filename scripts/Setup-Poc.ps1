#Requires -Version 7.0
<#
.SYNOPSIS
    Configura la PoC ado-aw in un'organizzazione Azure DevOps esistente (un solo comando).

.DESCRIPTION
    1. verifica la GitHub App (installata sull'organizzazione GitHub, permesso "Copilot Requests")
    2. crea (se mancano) i repository 'engineering-standards' e 'ado-aw-poc-app' e vi carica i contenuti di esempio
       (se 'engineering-standards' esiste già con contenuti, NON viene toccato: l'agente leggerà i tuoi file Markdown)
    3. compila il workflow agentico con ado-aw (scaricato e verificato con checksum se non presente)
    4. crea la pipeline, salva la chiave privata come variabile segreta e imposta la Build Validation sul ramo main

    GitHub Enterprise Cloud con data residency (GHE.com, utenti EMU): aggiungi -GitHubHost <tenant>.ghe.com.
    Lo script punta API e Copilot CLI al tenant (api.<tenant>.ghe.com, COPILOT_GH_HOST), consente nel firewall della
    pipeline solo i domini del tenant e sceglie un modello disponibile nelle regioni con data residency (US e UE).
    Con -StrictResidency blocca nel firewall anche gli endpoint pubblici GitHub/Copilot.

    Piano B se la preview "Copilot da GitHub App" non è disponibile sul tenant: -AuthMode Pat con il PAT di un utente di
    servizio che ha una licenza Copilot (fine-grained, permesso "Copilot Requests"); i costi sono addebitati a quell'utente
    e quindi all'Enterprise, non a chi fa il commit.

.EXAMPLE
    ./Setup-Poc.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project Demo `
        -GitHubOrg contoso-gh -GitHubAppId 1234567 -PrivateKeyPath ./ado-aw-copilot.pem

.EXAMPLE
    # GHE.com con data residency (EMU)
    ./Setup-Poc.ps1 -OrganizationUrl https://dev.azure.com/contoso -Project Demo -GitHubHost contoso.ghe.com `
        -GitHubOrg contoso-org -GitHubAppId 1234567 -PrivateKeyPath ./ado-aw-copilot.pem
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OrganizationUrl,
    [Parameter(Mandatory)][string]$Project,
    [Parameter(Mandatory)][string]$GitHubOrg,
    [string]$GitHubAppId,
    [string]$PrivateKeyPath,
    [string]$AppRepo = 'ado-aw-poc-app',
    [string]$StandardsRepo = 'engineering-standards',
    [string]$StandardsProject,
    [string]$Model,
    [string]$Pat,
    [string]$GitHubHost,
    [string]$GitHubApiUrl,   # solo per proxy/test: override dell'API usata dal preflight; la pipeline usa sempre https://api.<tenant>.ghe.com
    [ValidateSet('App', 'Pat')][string]$AuthMode = 'App',
    [string]$GitHubPat,
    [switch]$StrictResidency,
    [string]$AdoAwVersion = '0.54.0',
    [switch]$SkipGitHubCheck,
    [switch]$SkipBuildPolicy
)

. "$PSScriptRoot/PocCommon.ps1"
$pocRoot = Split-Path $PSScriptRoot -Parent

function Get-AdoAwBinary([string]$Version) {
    $onPath = Get-Command ado-aw -ErrorAction SilentlyContinue
    if ($onPath) {
        $found = (& $onPath.Source --version 2>$null) -join ' '
        if ($found -match [regex]::Escape($Version)) { return $onPath.Source }
        Write-Note "ado-aw nel PATH è '$found': uso la $Version, la stessa versione scaricata dalla pipeline"
    }
    $asset = if ($IsWindows) { 'ado-aw-windows-x64.exe' } elseif ($IsMacOS) { 'ado-aw-darwin-arm64' } else { 'ado-aw-linux-x64' }
    $dir = Join-Path ([IO.Path]::GetTempPath()) "ado-aw-poc/v$Version"
    $exe = Join-Path $dir $(if ($IsWindows) { 'ado-aw.exe' } else { 'ado-aw' })
    if (Test-Path $exe) {
        $cached = try { (& $exe --version 2>$null) -join ' ' } catch { '' }   # un exe troncato/corrotto fa lanciare un errore, non restituisce un codice
        if ($cached -match [regex]::Escape($Version)) { return $exe }
        Remove-Item $exe -Force   # download incompleto o corrotto: riscarico
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $base = "https://github.com/githubnext/ado-aw/releases/download/v$Version"
    Invoke-WebRequest "$base/$asset" -OutFile $exe
    $sumsRaw = (Invoke-WebRequest "$base/checksums.txt").Content
    # GitHub serve gli asset come application/octet-stream: in quel caso Content è byte[] e non una stringa
    $sums = $(if ($sumsRaw -is [byte[]]) { [Text.Encoding]::UTF8.GetString($sumsRaw) } else { [string]$sumsRaw }) -split "`n"
    $line = $sums | Where-Object { $_ -match "\s$([regex]::Escape($asset))\s*$" } | Select-Object -First 1
    if (-not $line) { throw "Checksum di $asset non trovato in checksums.txt" }
    $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
    if ((Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        Remove-Item $exe -Force
        throw "Checksum SHA-256 di $asset non valido: download scartato."
    }
    if (-not $IsWindows) { chmod +x $exe }
    return $exe
}

# ------------------------------------------------------------------ 0. input e autenticazione
Write-Step 'Verifica input e accesso ad Azure DevOps'
$target = Get-GitHubTarget $GitHubHost $GitHubApiUrl
$api = $target.ApiUrl
if (-not $Model) {
    $verifiedModel = Get-VerifiedModel $target $GitHubOrg
    if ($verifiedModel) { $Model = $verifiedModel; Write-Ok "Modello verificato dallo smoke test: $Model" } else { $Model = Get-DefaultModel $target.IsGhe }
}
if ($StrictResidency -and -not $target.IsGhe) { throw '-StrictResidency ha senso solo con GHE.com: aggiungi -GitHubHost <tenant>.ghe.com.' }
if ($target.IsGhe) { Write-Ok "GitHub Enterprise Cloud con data residency: tenant $($target.Host) (API $api) · modello $Model" }
$pem = $null
$githubPat = if ($GitHubPat) { $GitHubPat } else { $env:POC_GITHUB_PAT }
if ($AuthMode -eq 'App') {
    if (-not $GitHubAppId -or -not $PrivateKeyPath) { throw 'Con -AuthMode App servono -GitHubAppId e -PrivateKeyPath.' }
    if (-not (Test-Path $PrivateKeyPath)) { throw "File della chiave privata non trovato: $PrivateKeyPath" }
    $pem = (Get-Content $PrivateKeyPath -Raw).Trim()
    if ($pem -notmatch '-----BEGIN (RSA )?PRIVATE KEY-----') { throw "'$PrivateKeyPath' non è una chiave privata PEM (-----BEGIN RSA PRIVATE KEY-----)." }
} elseif (-not $githubPat) {
    throw "Con -AuthMode Pat serve il PAT dell'utente di servizio: -GitHubPat oppure la variabile d'ambiente POC_GITHUB_PAT."
}
$standardsProject = if ($StandardsProject) { $StandardsProject } else { $Project }
$ctx = @{ OrganizationUrl = $OrganizationUrl.TrimEnd('/'); Project = $Project; Headers = (Get-AdoHeaders $Pat) }
$projectInfo = Invoke-Ado -Method GET -Url "$($ctx.OrganizationUrl)/_apis/projects/$([uri]::EscapeDataString($Project))" -Headers $ctx.Headers
Write-Ok "Progetto '$($projectInfo.name)' raggiunto"
$projBase = Get-ProjectBaseUrl $ctx.OrganizationUrl $Project

# ------------------------------------------------------------------ 1. GitHub App (oppure PAT dell'utente di servizio)
$appSlug = $null
$appClientId = $null
$patLogin = $null
if ($SkipGitHubCheck) {
    Write-Warn 'Verifica GitHub App saltata (-SkipGitHubCheck)'
} elseif ($AuthMode -eq 'App') {
    Write-Step "Verifica della GitHub App sull'organizzazione '$GitHubOrg'"
    $found = Get-AppInstallation $api $GitHubAppId $pem $GitHubOrg
    if (-not $found) {
        throw "La GitHub App '$GitHubAppId' non risulta installata sull'organizzazione '$GitHubOrg'. Installala (Settings > Developer settings > GitHub Apps > <app> > Install App)."
    }
    $installation = $found.Installation
    $appSlug = Get-Prop $installation 'app_slug'
    Write-Ok "App '$appSlug' installata sull'organizzazione (installation $($installation.id))"
    try { $appClientId = Get-Prop (Invoke-GitHub -Url "$api/app" -Token $found.Jwt) 'client_id' } catch { Write-Note 'Client ID dell''App non recuperabile (non blocca la PoC)' }
    $minted = New-AppInstallationToken $api $found.Jwt $installation.id
    $granted = Get-Prop (Get-Prop $minted 'permissions') 'organization_copilot_requests'
    if ($granted) { Write-Ok "Permesso 'Copilot Requests' presente ($granted): i costi andranno all'organizzazione '$GitHubOrg'" }
    else {
        Write-Warn "Il token di installazione non riporta il permesso 'Copilot Requests' (organizzazione): aggiungilo all'App e riapprova l'installazione."
        if ($target.IsGhe) { Write-Warn 'Se la voce non compare tra i permessi dell''App, la preview potrebbe non essere ancora disponibile sul tenant: usa Test-CopilotAccess.ps1 o il Piano B (-AuthMode Pat).' }
    }
    Remove-AppInstallationToken $api $minted.token
} else {
    Write-Step "Verifica del PAT dell'utente di servizio su $($target.WebUrl)"
    $me = Invoke-GitHub -Url "$api/user" -Token $githubPat
    $patLogin = Get-Prop $me 'login'
    Write-Ok "PAT valido: utente di servizio '$patLogin' (gli AI Credits delle esecuzioni saranno addebitati a questo utente, quindi all'Enterprise)"
    Write-Note 'Licenza Copilot e permesso "Copilot Requests" del PAT: verificali con Test-CopilotAccess.ps1 -AuthMode Pat'
}

# ------------------------------------------------------------------ 2. ado-aw
Write-Step "Compilatore ado-aw v$AdoAwVersion"
$adoaw = Get-AdoAwBinary $AdoAwVersion
Write-Ok "Uso $adoaw"

# ------------------------------------------------------------------ 3. repository
Write-Step "Repository '$StandardsRepo' (standard) e '$AppRepo' (applicazione)"
$stdCtx = @{} + $ctx; $stdCtx.Project = $standardsProject
$standards = Get-AdoRepository $ctx $StandardsRepo $standardsProject
if (-not $standards) {
    if ($standardsProject -ne $Project) { throw "Repository '$standardsProject/$StandardsRepo' non trovato." }
    $standards = Invoke-Ado -Method POST -Url "$projBase/_apis/git/repositories" -Headers $ctx.Headers -Body @{ name = $StandardsRepo }
    Write-Ok "Creato il repository '$StandardsRepo'"
}
if (-not ((Get-Prop $standards 'defaultBranch') -or (Get-BranchHead $stdCtx $standards.id 'main'))) {
    if ($standardsProject -ne $Project) { throw "Il repository '$standardsProject/$StandardsRepo' è vuoto o non ha il ramo main." }
    $files = @(Get-LocalFiles (Join-Path $pocRoot 'standards-repo'))
    [void](Send-AdoPush $ctx $standards.id 'main' 'Standard di ingegneria (PoC ado-aw)' $files $null $null)
    [void](Invoke-Ado -Method PATCH -Url "$projBase/_apis/git/repositories/$($standards.id)" -Headers $ctx.Headers -Body @{ defaultBranch = 'refs/heads/main' })
    Write-Ok "Caricati $($files.Count) documenti di standard di esempio"
} else {
    Write-Note "'$StandardsRepo' ha già contenuti: non lo modifico (l'agente leggerà i tuoi file Markdown)"
}

$app = Get-AdoRepository $ctx $AppRepo
if (-not $app) {
    $app = Invoke-Ado -Method POST -Url "$projBase/_apis/git/repositories" -Headers $ctx.Headers -Body @{ name = $AppRepo }
    Write-Ok "Creato il repository '$AppRepo'"
}

# ------------------------------------------------------------------ 4. compilazione del workflow
Write-Step 'Compilazione del workflow agentico (Markdown -> pipeline)'
$work = Join-Path ([IO.Path]::GetTempPath()) ('ado-aw-poc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$agentsDir = Join-Path $work 'agents'
New-Item -ItemType Directory -Force -Path $agentsDir | Out-Null
$template = [IO.File]::ReadAllText((Join-Path $pocRoot 'agents/standards-compliance-review.md'))
$flags = @{ ghe = $target.IsGhe; strict = ($target.IsGhe -and [bool]$StrictResidency); 'app-auth' = ($AuthMode -eq 'App'); 'pat-auth' = ($AuthMode -eq 'Pat') }
$markdown = (Resolve-TemplateMarkers $template $flags).Replace('__MODEL__', $Model).Replace('__GITHUB_APP_ID__', "$GitHubAppId").Replace('__GITHUB_ORG__', $GitHubOrg).
    Replace('__STANDARDS_PROJECT__', $standardsProject).Replace('__STANDARDS_REPO__', $StandardsRepo)
if ($target.IsGhe) { $markdown = $markdown.Replace('__GITHUB_HOST__', $target.Host).Replace('__GITHUB_API_URL__', "https://api.$($target.Host)") }
if ($markdown -match '__[A-Z][A-Z_]*__') { throw "Segnaposto non risolto nel workflow: $($Matches[0])" }
[IO.File]::WriteAllText((Join-Path $agentsDir 'standards-compliance-review.md'), $markdown, [Text.UTF8Encoding]::new($false))
$remoteProjBase = $projBase
if (([uri]$ctx.OrganizationUrl).Host -match '^(?<o>[^.]+)\.visualstudio\.com$') {
    # ado-aw riconosce solo il formato https://dev.azure.com/<org>/<progetto>/_git/<repo>
    $remoteProjBase = "https://dev.azure.com/$($Matches.o)/$([uri]::EscapeDataString($Project))"
}
$env:ADO_AW_COMPILE_REMOTE_URL = "$remoteProjBase/_git/$([uri]::EscapeDataString($AppRepo))"
Push-Location $work
try {
    & $adoaw compile 'agents/standards-compliance-review.md' 2>&1 | ForEach-Object { Write-Note "$_" }
    if ($LASTEXITCODE -ne 0) { throw 'ado-aw compile è fallito (vedi messaggi sopra).' }
} finally {
    Pop-Location
    Remove-Item Env:\ADO_AW_COMPILE_REMOTE_URL -ErrorAction SilentlyContinue
}
$lock = [IO.File]::ReadAllText((Join-Path $agentsDir 'standards-compliance-review.lock.yml'))
Write-Ok "Generata la pipeline standards-compliance-review.lock.yml ($([math]::Round($lock.Length / 1KB)) KB)"

# ------------------------------------------------------------------ 5. contenuti del repository applicativo
Write-Step "Caricamento nel repository '$AppRepo'"
$appFiles = @(Get-LocalFiles (Join-Path $pocRoot 'sample-app'))
$appFiles += [pscustomobject]@{ Path = '/agents/standards-compliance-review.md'; Content = $markdown }
$appFiles += [pscustomobject]@{ Path = '/agents/standards-compliance-review.lock.yml'; Content = $lock }
$gitattributes = Join-Path $work '.gitattributes'
if (Test-Path $gitattributes) { $appFiles += [pscustomobject]@{ Path = '/.gitattributes'; Content = [IO.File]::ReadAllText($gitattributes) } }
$existing = if (Get-BranchHead $ctx $app.id 'main') { Get-RepoFiles $ctx $app.id 'main' -WithContent } else { $null }
$push = Send-AdoPush $ctx $app.id 'main' 'PoC ado-aw: applicazione di esempio e workflow agentico' $appFiles $existing $null
if ($push) {
    [void](Invoke-Ado -Method PATCH -Url "$projBase/_apis/git/repositories/$($app.id)" -Headers $ctx.Headers -Body @{ defaultBranch = 'refs/heads/main' })
    Write-Ok "Caricati i file nel ramo main (commit $($push.commits[0].commitId.Substring(0, 8)))"
} else {
    Write-Note 'Il ramo main è già aggiornato: nessun nuovo commit'
}
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ 6. pipeline, segreto, policy
Write-Step 'Pipeline, chiave privata e Build Validation'
$pipelines = Invoke-Ado -Method GET -Url "$projBase/_apis/pipelines" -Headers $ctx.Headers
$pipeline = @($pipelines.value) | Where-Object { $_.name -eq $script:PipelineName } | Select-Object -First 1
if (-not $pipeline) {
    $pipeline = Invoke-Ado -Method POST -Url "$projBase/_apis/pipelines" -Headers $ctx.Headers -Body @{
        name = $script:PipelineName; folder = '\'
        configuration = @{ type = 'yaml'; path = '/agents/standards-compliance-review.lock.yml'; repository = @{ id = $app.id; name = $AppRepo; type = 'azureReposGit' } }
    }
    Write-Ok "Creata la pipeline '$($script:PipelineName)' (id $($pipeline.id))"
} else {
    Write-Note "Pipeline già presente (id $($pipeline.id))"
}

$definition = Invoke-Ado -Method GET -Url "$projBase/_apis/build/definitions/$($pipeline.id)" -Headers $ctx.Headers
if ($null -eq (Get-Prop $definition 'variables')) { $definition | Add-Member -NotePropertyName variables -NotePropertyValue ([pscustomobject]@{}) -Force }
if ($AuthMode -eq 'App') {
    $secretName = 'GITHUB_APP_PRIVATE_KEY'
    $secretValue = ($pem -replace "`r", '') -replace "`n", '\n'
} else {
    $secretName = 'GITHUB_TOKEN'
    $secretValue = $githubPat
}
$definition.variables | Add-Member -NotePropertyName $secretName -Force `
    -NotePropertyValue ([pscustomobject]@{ value = $secretValue; isSecret = $true; allowOverride = $false })
[void](Invoke-Ado -Method PUT -Url "$projBase/_apis/build/definitions/$($pipeline.id)" -Headers $ctx.Headers -Body $definition)
Write-Ok "Credenziale GitHub salvata come variabile SEGRETA $secretName"

if ($SkipBuildPolicy) {
    Write-Warn 'Build Validation saltata: crea tu la policy sul ramo main (vedi guida) oppure le PR non avvieranno la pipeline.'
} else {
    $policyUrl = "$projBase/_apis/git/policy/configurations?repositoryId=$($app.id)&refName=refs/heads/main&policyType=$script:BuildPolicyTypeId"
    $policies = Invoke-Ado -Method GET -Url $policyUrl -Headers $ctx.Headers
    $already = @($policies.value) | Where-Object { (-not (Get-Prop $_ 'isDeleted')) -and ($_.settings.buildDefinitionId -eq $pipeline.id) }
    if ($already) {
        Write-Note 'Build Validation già configurata sul ramo main'
    } else {
        [void](Invoke-Ado -Method POST -Url "$projBase/_apis/policy/configurations" -Headers $ctx.Headers -Body @{
            isEnabled = $true; isBlocking = $false
            type = @{ id = $script:BuildPolicyTypeId }
            settings = @{
                buildDefinitionId = $pipeline.id; displayName = 'ado-aw Standards Compliance Review'
                manualQueueOnly = $false; queueOnSourceUpdateOnly = $true; validDuration = 0
                scope = @(@{ repositoryId = $app.id; refName = 'refs/heads/main'; matchKind = 'Exact' })
            }
        })
        Write-Ok 'Build Validation (non bloccante) attiva sulle PR verso main'
    }
}

# ------------------------------------------------------------------ 7. stato e prossimi passi
Save-PocState ([ordered]@{
    organizationUrl = $ctx.OrganizationUrl; project = $Project; appRepo = $AppRepo; appRepoId = $app.id
    standardsProject = $standardsProject; standardsRepo = $StandardsRepo
    pipelineId = $pipeline.id; pipelineName = $script:PipelineName
    githubOrg = $GitHubOrg; githubAppId = $GitHubAppId; githubAppClientId = $appClientId; githubAppSlug = $appSlug; githubApiUrl = $api
    githubHost = $target.Host; githubEnterprise = $target.Enterprise; authMode = $AuthMode; githubPatLogin = $patLogin; strictResidency = [bool]($target.IsGhe -and $StrictResidency)
    model = $Model; adoAwVersion = $AdoAwVersion; createdUtc = (Get-Date).ToUniversalTime().ToString('o')
})

Write-Host "`nPoC pronta." -ForegroundColor Green
Write-Host "  Repo applicativo : $projBase/_git/$AppRepo"
Write-Host "  Pipeline         : $projBase/_build?definitionId=$($pipeline.id)"
$identity = if ($AuthMode -eq 'App') { "App $(if ($appSlug) { $appSlug } else { $GitHubAppId })" } else { "utente di servizio $patLogin" }
Write-Host "  Modello / auth   : $Model / $identity (org GitHub: $GitHubOrg)"
if ($target.IsGhe) {
    Write-Host "  Data residency   : tenant $($target.Host) · firewall della pipeline: solo $($target.Host) e *.$($target.Host)$(if ($StrictResidency) { ' (endpoint pubblici GitHub/Copilot bloccati)' })"
}
Write-Host "`nProssimo passo:" -ForegroundColor Cyan
Write-Host '  ./New-DemoPullRequests.ps1 -Count 5 -Wait     # crea 5 PR, attende le esecuzioni, mostra i Task e il comando per i crediti'
Write-Host '  ./Get-AiCredits.ps1 -GitHubOrg <org> ...      # AI Credits della GitHub App (il comando completo lo stampa New-DemoPullRequests.ps1)'
if ($target.IsGhe) { Write-Host '  ./Get-ResidencyEvidence.ps1                   # prova: la pipeline ha contattato solo il tenant GHE.com' }
