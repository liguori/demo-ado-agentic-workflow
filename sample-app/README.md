# Orders — applicazione di esempio per la PoC ado-aw

Piccolo servizio Python (solo libreria standard) usato come **codice di partenza conforme** agli
standard del repository `engineering-standards`.

```bash
# esegue i test
PYTHONPATH=src python -m unittest discover -s tests -v
```

Le Pull Request di demo (`New-DemoPullRequests.ps1`) aggiungono o modificano file in `src/` e `tests/`,
alcune rispettando gli standard e altre no.

- `src/orders/config.py` — configurazione da variabili d'ambiente
- `src/orders/service.py` — creazione e lettura ordini (SQL parametrizzato, validazione, logging)
- `tests/test_service.py` — test automatici
- `agents/` — workflow agentico `Standards Compliance Review` (sorgente `.md` + pipeline compilata `.lock.yml`)
