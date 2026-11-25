# Engineering Standards

Pratiche di ingegneria adottate dai team. Ogni regola ha un **ID**, una **severità** e un criterio di verifica.
Il workflow agentico `Standards Compliance Review` legge questi file a ogni Pull Request e apre un Task
con le evidenze quando il codice modificato non li rispetta.

| File | Regole | Argomento |
|---|---|---|
| [security.md](security.md) | SEC-001, SEC-002 | Segreti e accesso ai dati |
| [error-handling.md](error-handling.md) | ERR-001, ERR-002 | Gestione degli errori e chiamate esterne |
| [logging.md](logging.md) | LOG-001, LOG-002 | Logging e dati personali |
| [testing.md](testing.md) | TST-001 | Test automatici |
| [validation.md](validation.md) | VAL-001 | Validazione degli input |

## Severità

| Severità | Significato | Azione attesa |
|---|---|---|
| **Alta** | Rischio di sicurezza o perdita di dati | Correggere prima del merge |
| **Media** | Difetto di affidabilità o manutenibilità | Correggere nello stesso sprint |
| **Bassa** | Miglioria di qualità | Correggere quando si tocca il codice |

## Come si applicano

- Le regole valgono per il codice **aggiunto o modificato** da una Pull Request, non per il debito storico.
- Un'eccezione è ammessa solo se motivata in un commento `# standards-exception: <ID> <motivo>` nel punto interessato.
- Per aggiungere o cambiare una regola, aprire una Pull Request su questo repository: il workflow usa sempre l'ultima versione del branch `main`.
