# Pipeline compilate di esempio

Sono l'output di `ado-aw compile` (v0.54.0) su `agents/standards-compliance-review.md` con **valori fittizi**
(organizzazione GitHub `contoso-gh`, App ID `1234567`, progetto `ContosoProject`). Servono solo per **leggere** la pipeline
generata (job `Setup → Agent → Detection → SafeOutputs → Conclusion`, passo «Mint GitHub App token», sandbox AWF).
**Non vanno caricate così come sono**: `Setup-Poc.ps1` rigenera la pipeline con i valori reali.

| File | Scenario | Modello |
|---|---|---|
| `standards-compliance-review.lock.yml` | github.com con GitHub App | `gpt-5.6-luna` |
| `standards-compliance-review.ghe.lock.yml` | **GHE.com con data residency** (tenant `contoso.ghe.com`, utenti EMU) con GitHub App | `claude-haiku-5.5` |

## Cosa cambia con GHE.com (circa 20 righe su 1250, per Agent e Detection)

| Dove nella pipeline | github.com | GHE.com (`-GitHubHost contoso.ghe.com`) |
|---|---|---|
| Passo «Mint GitHub App token» | API `https://api.github.com` (default) | `--api-url 'https://api.contoso.ghe.com'` |
| Passo «Revoke GitHub App token» | `API_URL=''` | `API_URL='https://api.contoso.ghe.com'` |
| Ambiente di «Run copilot (AWF network isolated)» | — | `COPILOT_GH_HOST: contoso.ghe.com` (la Copilot CLI instrada su `copilot-api.contoso.ghe.com`) |
| `ALLOWED_DOMAINS` del firewall AWF | github.com, `*.githubcopilot.com`… | in più `contoso.ghe.com` e `*.contoso.ghe.com` |
| `--model` | `gpt-5.6-luna` | `claude-haiku-5.5` (disponibile nelle regioni US e UE) |

Con `-StrictResidency` i domini pubblici GitHub/Copilot vengono anche **rimossi** da `ALLOWED_DOMAINS` (32 domini invece di 39).
Il flag `engine.api-target` di ado-aw **non** si usa: aggiunge `--api-target` alla Copilot CLI, che non lo accetta (1.0.88 e 1.0.114).
