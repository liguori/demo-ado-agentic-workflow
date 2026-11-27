# PoC ado-aw su Azure DevOps — guida step by step

**Cosa fa la PoC**

1. **Controllo delle Pull Request.** Una *build validation* (non bloccante) sul ramo `main` avvia, a ogni Pull Request, una pipeline che esegue un agente Copilot usando gli Agentic Workflows. L'agente legge la patch (`git diff`) e la confronta con gli **standard aziendali scritti in Markdown** (sicurezza, gestione degli errori, logging, validazione, test), conservati in **un altro repository** (`engineering-standards`, con contenuto di esempio in `standards-repo/`), con regole identificate da ID e severità.
2. **Segnalazione delle violazioni.** Per ogni PR che viola le regole l'agente crea un **Task** in Azure DevOps con le evidenze (file, righe, regola violata, segreti oscurati). Per una PR conforme non crea nulla.
3. **Autenticazione tramite GitHub App.** La pipeline non usa il PAT di una persona: ottiene un token di installazione da una **GitHub App** con il solo permesso *Copilot Requests*. Le richieste a Copilot sono quindi attribuite all'**organizzazione GitHub** (e al suo Enterprise), non a chi ha fatto commit.
4. **Dati di prova.** `Setup-Poc.ps1` prepara l'ambiente (repository `engineering-standards` e `ado-aw-poc-app`, workflow compilato, pipeline, policy, variabile segreta con la chiave dell'App) e `New-DemoPullRequests.ps1` apre le PR di esempio (`scenarios/`, fino a 5) con casi diversi: segreti e SQL, errori e log, assenza di test e validazione, codice conforme, modifica di un file esistente. Il risultato atteso di ogni scenario è in `scenarios/expected.json`.
5. **Verifica dei consumi.** `Get-AiCredits.ps1` legge i report di utilizzo di GitHub e mostra gli **AI Credits** consumati dall'App dopo le esecuzioni, con il CSV scaricabile dal sito come alternativa se l'endpoint non è disponibile. Per GHE.com, `Test-CopilotAccess.ps1` verifica prima che Copilot funzioni sul tenant e `Get-ResidencyEvidence.ps1` dimostra dai log del firewall che il traffico resta sul tenant.

Funziona con **github.com** e con **GHE.com** (data residency, utenti EMU). I passi che riguardano solo GHE.com sono marcati **`[solo GHE.com]`**: con github.com saltali.

## Cosa serve

- [ ] Organizzazione e progetto **Azure DevOps Services** esistenti; sei *Project Administrator*
- [ ] Organizzazione **GitHub** con **Copilot** attivo, abilitata alle richieste Copilot da **GitHub App** (public preview: se non lo è, la run fallisce con `403 … not enabled` → account team GitHub/Microsoft); un **owner** per creare l'App
- [ ] **PowerShell 7+** (`pwsh`) e **Azure CLI** (`az`) sul tuo PC
- [ ] `[solo GHE.com]` tenant `<tenant>.ghe.com` in regione **US o UE** e, nelle policy Copilot dell'Enterprise, **«Restrict Copilot to data residency compliant models»** attiva


## Passo 1 — Crea la GitHub App (5 minuti, una volta)

`[solo GHE.com]` falla **sul tenant** (`https://<tenant>.ghe.com`), come owner dell'organizzazione.

GitHub → organizzazione → **Settings → Developer settings → GitHub Apps → New GitHub App**:

1. Nome `ado-aw-copilot-<org>` · Homepage `https://github.com/githubnext/ado-aw` · **Webhook: disattiva**.
2. **Organization permissions → Copilot Requests → Read-only** (nessun altro permesso).
3. *Where can this GitHub App be installed?* → *Only on this account* → **Create GitHub App**.
4. Copia l'**App ID** → Spostarsi in  **Credentials - > Key Pairs - > New Key** → e salvare il `.pem` (va tenuto al sicuro in KeyVault).
5. **Install App** → installala sull'**organizzazione**.

Risultato: hai un **App ID** e il file `app.pem`.

## Passo 2 — Imposta i valori (1 minuto)

Apri PowerShell 7 nella cartella che contiene `poc/` e incolla, **modificando solo i valori**:

```powershell
$ado    = 'https://dev.azure.com/<org>'   # la tua organizzazione Azure DevOps
$prj    = '<progetto>'                    # progetto dove creare la demo
$org    = '<org-github>'                  # organizzazione GitHub che paga (su GHE.com: quella del tenant)
$appId  = 1234567                         # App ID del passo 1
$clientId = 'Iv23…'                       # Client ID (non l'App ID) della stessa App, dalla sua pagina su GitHub
$key    = './app.pem'                     # chiave privata del passo 1
$tenant = ''                              # github.com: lascia vuoto · GHE.com: 'contoso.ghe.com'
$enterprise = ''                          # solo github.com (passo 6): slug dell'Enterprise · GHE.com: lascia vuoto
# --- solo passo 6 (consumi) ---
$from   = '2026-11-24'                    # primo giorno (UTC) da includere: il giorno in cui lanci le PR
$to     = '2026-11-25'                    # ultimo giorno (UTC) da includere
$ghToken = '<ghp_…>'                      # A) PAT classic, scope manage_billing:enterprise
$billingAppId = 0                         # B) App ID della GitHub App di fatturazione (se usi B)
$billingKey = './billing-app.pem'         # B) chiave privata di quella App
$pipelineId = 0                           # facoltativo: id della pipeline (lo stampa il setup), per contare le esecuzioni
$ghe    = if ($tenant) { @{ GitHubHost = $tenant; StrictResidency = $true } } else { @{} }   # non modificare
```

## Passo 3 — `[solo GHE.com]` Verifica che Copilot funzioni sul tenant (2 minuti)

```powershell
./poc/scripts/Test-CopilotAccess.ps1 -GitHubHost $tenant -GitHubOrg $org -GitHubAppId $appId -PrivateKeyPath $key
```

Genera il token dell'App e chiede a Copilot di rispondere «OK» (meno di 1 AI Credit), controllando che parli solo con il tenant. Non usa Azure DevOps.

- **Tutte le righe ✔ e «Via libera»** → vai al passo 4.
- **Il modello predefinito (`claude-haiku-5.5`) non è abilitato** per la tua organizzazione → non devi fare nulla: lo script prova da solo altri modelli, **sceglie il primo che funziona e lo salva**; il setup (passo 4) lo userà in automatico. Se preferisci Haiku, abilitalo nelle policy Copilot dell'organizzazione/Enterprise e rilancia questo passo.


*Facoltativo, per dimostrare la residenza:* aggiungi `-NegativeModel gpt-5.6-luna` (in UE usa `gpt-4o`). Lo script chiede a Copilot un modello **non disponibile nella tua regione**: con la policy di residenza attiva Copilot lo **deve rifiutare**; se lo accetta, la policy non è attiva. 

## Passo 4 — Setup in Azure DevOps

```powershell
az login
./poc/scripts/Setup-Poc.ps1 -OrganizationUrl $ado -Project $prj -GitHubOrg $org -GitHubAppId $appId -PrivateKeyPath $key @ghe
```

Crea nel progetto: il repository **`engineering-standards`** (le regole), il repository **`ado-aw-poc-app`** (l'applicazione di esempio con il workflow), la pipeline **`ado-aw Standards Compliance Review`** e la Build Validation su `main`. Si può rilanciare senza danni. Al termine stampa **«PoC pronta.»** con i link.

`[solo GHE.com]` `@ghe` aggiunge `-GitHubHost` e `-StrictResidency`: la pipeline parla con il tenant e il suo firewall blocca gli endpoint pubblici GitHub/Copilot.

## Passo 5 — Lancia N esecuzioni (circa 8 minuti a PR, in sequenza)

```powershell
./poc/scripts/New-DemoPullRequests.ps1 -Count 5 -Wait
```

Crea 5 Pull Request (4 con violazioni, 1 conforme); ognuna avvia la pipeline. Alla fine mostra una tabella *atteso / ottenuto* e i link ai **Task** creati (Boards, tag `ado-aw`). Le run vanno in sequenza: **lancialo prima dell'incontro**.

## Passo 6 — Leggi il consumo: «N esecuzioni → X AI Credits»

Lo script è **autonomo** (nessun file di stato). Legge via REST il report «AI usage» dell'Enterprise e somma **solo le righe della tua GitHub App** nel periodo indicato. Per leggere la fatturazione serve un'identità **diversa da quella della pipeline**: scegli **A** (PAT) oppure **B** (GitHub App). Comune a entrambi: `$clientId` è il *Client ID* (`Iv23…`) dell'App del passo 1; `$from`/`$to` sono giorni UTC inclusi. Tutte le variabili sono nel passo 2; `$tenant` e `$enterprise` come indicato lì. `New-DemoPullRequests.ps1` stampa alla fine il comando già compilato.

**A) PAT classic**

- Utente: enterprise admin o billing manager (su GHE.com, l'utente EMU sul tenant).
- Scope: `manage_billing:enterprise` (`admin:enterprise` lo include ma dà molti più poteri). Deve essere *classic* (Settings → Developer settings → Personal access tokens → Tokens (classic)): i fine-grained non sono supportati.

```powershell
./poc/scripts/Get-AiCredits.ps1 -GitHubOrg $org -AppClientId $clientId -GitHubHost $tenant -GitHubEnterprise $enterprise -From $from -To $to `
    -GitHubToken $ghToken
```

**B) GitHub App di sola lettura** (diversa da quella con «Copilot Requests»)

- Permesso: Enterprise permissions → **Enterprise billing = Read-only**. Nessun altro permesso («Read and write» serve solo per budget e cost center).
- Installata sull'**Enterprise** da un enterprise owner (non solo su un'organizzazione). Lo script genera il token di installazione e lo revoca a fine esecuzione.

```powershell
./poc/scripts/Get-AiCredits.ps1 -GitHubOrg $org -AppClientId $clientId -GitHubHost $tenant -GitHubEnterprise $enterprise -From $from -To $to `
    -BillingAppId $billingAppId -BillingPrivateKeyPath $billingKey
```

Facoltativo, per mostrare anche «N esecuzioni» (esecuzioni e Task `ado-aw` creati nel periodo; usa `az login` o `-Pat`): aggiungi `-AdoOrganizationUrl $ado -AdoProject $prj -PipelineId $pipelineId` (l'id lo stampa il setup).

```
═══ AI Credits attribuiti alla GitHub App (report REST) ═══
  Organizzazione GitHub (fatturata) : <org-github>
  App (client id)                   : Iv23…
  Periodo                           : 2026-11-24 → 2026-11-25 (UTC, giorni inclusi)
  Righe attribuite                  : 2
  Esecuzioni ado-aw nel periodo     : 5 avviate, 5 completate · Task creati: 4     (solo con i parametri -Ado…)
  AI Credits consumati              : X  (≈ $X×0,01)
  Media per esecuzione              : X/5 AI Credits
  Righe con username                : 0  → nessun utente addebitato
```

- Lo script crea il report (`POST …/settings/billing/reports`, tipo `ai_credit`), attende, scarica e filtra: nessuna azione manuale. Granularità giornaliera: altre prove con la stessa App nello stesso giorno sono incluse.
- **Se l'endpoint dei report non esiste sul tenant** (HTTP 404: oggi è così sul tenant GHE.com provato) lo script lo dichiara e **ripiega sul consumo aggregato dell'organizzazione** nel periodo (tutti gli utenti e tutte le App: stima valida se nessun altro usa Copilot). Per il dato esatto per App scarica il CSV dal sito: `Get-AiCredits.ps1 -GitHubOrg <org> -AppClientId <id> -UsageCsv <file>`.
- Se mostra 0, attendi qualche minuto (il dato arriva in ritardo).
- **Prova che non paga chi ha fatto commit**: righe dell'App con `app_client_id` valorizzato e `username` **vuoto** («Righe con username: 0»).
- `[solo GHE.com]` con la policy di residenza i crediti sono **+10%**.

## Passo 7 — `[solo GHE.com]` Prova della data residency

```powershell
./poc/scripts/Get-ResidencyEvidence.ps1
```

Legge i log del firewall delle run e mostra con quali host ha parlato l'agente. Risultato atteso: solo host `*.<tenant>.ghe.com` (in particolare `copilot-api.<tenant>.ghe.com`) e la riga **«Endpoint pubblici GitHub/Copilot: nessuno contattato ✔»**; `api.github.com` compare tra i «Tentativi BLOCCATI dal firewall»: è il firewall che funziona (verificato su un tenant GHE.com: 16 richieste consentite verso `copilot-api.<tenant>` in 5 run e `api.github.com` negato con 403).

## Per la demo

1. Una PR **con violazioni** → la pipeline parte → **Task** con regola, file e righe, evidenze.
2. La PR **conforme** → run verde, nessun Task.
3. **Chi paga**: l'App (nessuna licenza ai committer) → `Get-AiCredits.ps1` e il CSV.
4. `[solo GHE.com]` **Residenza**: policy Enterprise attiva → `Get-ResidencyEvidence.ps1`.


