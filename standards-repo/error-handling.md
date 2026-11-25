# Gestione degli errori

## ERR-001 — Nessuna eccezione ignorata

- **Severità**: Media
- **Ambito**: tutto il codice applicativo
- **Regola**: è vietato `except:` senza tipo e qualsiasi blocco che intercetta un'eccezione e la ignora (`pass`) senza loggarla o rilanciarla. Si intercettano solo le eccezioni attese, con un'azione esplicita.
- **Come verificare**: `except:` nudo, `except Exception:` seguito solo da `pass`/`continue`/`return`.
- **Conforme**: `except smtplib.SMTPException: logger.exception("invio_fallito"); raise`
- **Non conforme**: `except: pass`

## ERR-002 — Chiamate esterne con timeout

- **Severità**: Media
- **Ambito**: chiamate di rete (HTTP, SMTP, database remoti, code)
- **Regola**: ogni chiamata verso un sistema esterno deve avere un timeout esplicito, per evitare blocchi indefiniti.
- **Come verificare**: `requests.get/post`, `smtplib.SMTP`, `urlopen`, `socket.create_connection` e simili senza parametro `timeout`.
- **Conforme**: `smtplib.SMTP("smtp.contoso.internal", timeout=10)`
- **Non conforme**: `smtplib.SMTP("smtp.contoso.internal")`
