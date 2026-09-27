# MikroTik Dude Telegram Queue

Coda persistente per inviare a Telegram le notifiche di **The Dude**, con raggruppamento degli eventi, limiti di frequenza e ritentativi in caso di errore.

```text
The Dude → tgq-enqueue → file .tmp → verifica → file .ready → tgq-worker → Telegram
```

`tgq-enqueue` scrive gli eventi in coda; il worker li invia. Ogni notifica contiene stato, dispositivo, servizio, problema, orario e ID: **✅ per `up`**, **⚠️ per `down` e gli altri stati**.

## Requisiti

- RouterOS 7 con The Dude e supporto a `:serialize`, `:deserialize`, `:parse`, `:tonsec`, `:timestamp`, `:rndstr` e `:onerror` con attributi d'errore.
- Scheduler e Fetch abilitati nel device mode, DNS funzionante e accesso HTTPS all'API Telegram.
- Spazio persistente per `tg-queue/`. Sui dispositivi che richiedono `flash/`, adattare i percorsi nei sorgenti e nell'installer.
- Permessi `read,write,test,ftp,sensitive` per gli script di invio e lo scheduler. Il contesto della notifica Dude può usare `read,write,test,ftp`, senza `sensitive`.
- Sul computer di gestione: Python 3, GNU Make, OpenSSH e `sshpass`. Non servono pacchetti Python aggiuntivi.
- Accesso SSH al router, accesso al client Dude, token del bot e ID della chat Telegram.

## Installazione

### 1. Impostare le credenziali

Nel terminale del computer di gestione, dalla directory del repository:

```bash
export ROUTER_USER='<utente-ssh>'
export ROUTER_HOST='<ip-o-hostname-router>'
export ROUTER_PASSWORD='<password-router>'
export TELEGRAM_TOKEN='<token-bot>'
export TELEGRAM_CHAT_ID='<id-chat>'
make install
```

Il comando installa gli script, crea la coda e lo scheduler `tgq-tick` con intervallo di un secondo. **L'invio parte in pausa**. Il token sostituisce `@@TOKEN@@` nello script `tgq-send` sul router.

### 2. Collegare The Dude

Nel client Dude creare una notifica di tipo **execute on server**. Copiare nel campo **Command** il contenuto di [`src/dude-command.txt`](src/dude-command.txt) e associare la notifica ai dispositivi o servizi desiderati, per le transizioni up e down.

I valori del template vengono espansi da Dude prima dell'esecuzione: virgolette, backslash e dollari nei nomi o nelle descrizioni richiedono escaping nel template RouterOS.

### 3. Attivare e verificare

Nel terminale RouterOS:

```routeros
/system script run tgq-resume
/system script run tgq-status
```

Generare un evento Dude controllato e verificare che arrivi su Telegram e che `sentEvents` aumenti. Lo stato `ready`, da solo, non conferma la connettività: a coda vuota non vengono eseguiti invii di prova.

## Aggiornamento

Con le cinque variabili d'ambiente impostate:

```bash
make update
```

L'aggiornamento conserva configurazione e stato della coda, sostituisce gli script riconosciuti dal marcatore di gestione e **usa `TELEGRAM_TOKEN` per riscrivere il token di invio**. Per mantenere lo stesso bot, fornire il token attualmente in uso. `TELEGRAM_CHAT_ID` è richiesto dall'installer, ma una coda esistente mantiene il `chatId` del proprio `config.json`.

Usare `make install` soltanto per la prima installazione: rifiuta uno scheduler `tgq-tick` già presente. `make update` non crea lo scheduler.

Il formato delle notifiche si modifica nelle variabili `icon` e `part` di [`src/tgq-core.rsc`](src/tgq-core.rsc).

## Uso quotidiano

Comandi da eseguire sul router:

```routeros
/system script run tgq-status
/system script run tgq-pause
/system script run tgq-resume
```

`tgq-pause` disabilita lo scheduler e l'invio; Dude può continuare ad accodare eventi. Un invio già in corso può terminare. `tgq-resume` riabilita entrambi, rispettando le attese già memorizzate.

### Leggere lo stato

| Campo di `tgq-status` | Significato |
| --- | --- |
| `enabled` | Invio abilitato nella configurazione; controllare anche lo scheduler |
| `pending` | Numero di file **`.ready`**, pronti all'invio |
| `incomplete` | Numero di file **`.tmp`**, esclusi dall'invio |
| `pendingBytes`, `oldestAgeSeconds` | Dimensione totale ed età dell'evento `.ready` più vecchio |
| `failed` | Eventi spostati in `failed/` perché invalidi o rifiutati definitivamente |
| `sentEvents`, `sentMessages` | Eventi e messaggi confermati da Telegram; un messaggio può contenere più eventi |
| `status`, `lastError` | Esito ed errore dell'ultimo tentativo |
| `retryInSeconds` | Attesa prima del prossimo tentativo consentito |
| `errors` | Errori di invio accumulati, non necessariamente ancora presenti |

### La cartella `pending/` e i file `.tmp`

**Essere nella cartella `pending/` non basta per essere inviati.**

- **`.tmp`**: file in scrittura o rimasto senza conferma di pubblicazione. Non viene inviato, anche se contiene JSON valido.
- **`.ready`**: evento verificato e disponibile per l'invio automatico.

Lo script di accodamento crea il `.tmp`, ne verifica la dimensione e lo rinomina in `.ready`. Aggiorna i metadati e ritenta verifica e rinomina fino a 21 volte, con pause di 100 ms: al massimo 2 secondi complessivi di attesa, oltre al tempo delle operazioni. Se fallisce, lascia il `.tmp` e registra `TGQ: enqueue failed`.

Per ispezionare file e problemi:

```routeros
/file print where name~"^tg-queue/pending/"
/file print where name~"^tg-queue/failed/"
/system scheduler print detail where name="tgq-tick"
/log print where topics~"script" && message~"^TGQ"
```

Un `.tmp` appena comparso può essere ancora in scrittura. Per uno rimasto bloccato, leggere il contenuto, verificare il JSON e la corrispondenza fra il campo `id` e il nome del file. Per recuperare un evento valido, sostituire `<id>` con il suo identificativo:

```routeros
/file get [find where name="tg-queue/pending/<id>.tmp"] contents
/file set [find where name="tg-queue/pending/<id>.tmp"] name="tg-queue/pending/<id>.ready"
```

La rinomina rende l'evento disponibile per l'invio, anche se storico. Un evento obsoleto può invece essere eliminato selezionando il suo file. I `.tmp` non vengono recuperati né eliminati automaticamente; dopo un recupero o una pulizia, controllare che `incomplete` non torni a crescere.

## Configurazione e comportamento

Il file `tg-queue/config.json` contiene:

| Campo | Funzione | Valore iniziale |
| --- | --- | --- |
| `enabled` | Abilita l'invio | `false` |
| `chatId` | Chat destinataria | `TELEGRAM_CHAT_ID` |
| `maxBatchEvents` | Massimo di eventi per messaggio | `30` |
| `sender` | Script di trasporto | `tgq-send` |
| `managedBy` | Marcatore verificato dall'installer | Gestito automaticamente |

- **Frequenza:** almeno 3,1 secondi tra tentativi, circa 19 messaggi/minuto. Eventuali altri invii allo stesso gruppo condividono il limite Telegram.
- **Raggruppamento:** fino a `maxBatchEvents` e 3500 byte di testo per messaggio. Up e down restano eventi distinti, ordinati per ID.
- **Capienza:** fino a 2000 file `.ready` e 10 MiB di dati `.ready`; massimo 50.000 byte per evento JSON. I controlli precedono la scrittura: accodamenti concorrenti possono superare la soglia. I `.tmp` non rientrano in questi limiti.
- **Testi lunghi:** campi abbreviati su confini UTF-8; originali salvati in `archive/`, fino a 2000 file. Un archivio pieno arresta il worker.
- **Consegna:** i file vengono rimossi dopo `ok=true` da Telegram. Se la risposta va persa dopo l'accettazione, un ritentativo può duplicare il messaggio; l'ID permette di riconoscerlo.
- **Stato persistente:** `state-a.json` e `state-b.json` conservano contatori, attese e conferme, alternando le scritture. La persistenza fisica dipende dal filesystem e dalle sue cache.

### Errori e ritentativi

| Errore | Comportamento |
| --- | --- |
| HTTP 429 | Attesa indicata da Telegram più 1 secondo; altrimenti 61 secondi, crescente fino a 600 nei tentativi successivi senza indicazione esplicita |
| DNS, timeout, HTTP 5xx | Attese di 15, 30, 60, 120 e poi 300 secondi |
| `maximum connection count reached` | Ritenta dopo 60 secondi |
| HTTP 401 / 403 | Attende 300 secondi; controllare token e accesso del bot alla chat |
| Altri HTTP 4xx | Riprova gli eventi singolarmente; sposta quelli rifiutati in `failed/` |
| JSON evento invalido | Sposta il file in `failed/` |
| Errore interno, stato o configurazione illeggibili | Arresta il worker e disabilita lo scheduler |

Dopo aver risolto un errore che ha disabilitato lo scheduler, eseguire `tgq-resume` e controllare stato e log.

## Sviluppo e test

| Comando locale | Effetto |
| --- | --- |
| `make` | Mostra i comandi disponibili |
| `make check` | Controlla la sintassi Python, senza collegarsi al router |
| `make test` | Esegue i test d'integrazione sul router configurato |

L'interprete è selezionabile, ad esempio con `make check PYTHON=python3.12`. `ROUTER_SSH_CONTROL` può indicare il socket di una connessione SSH multiplexata già aperta, utile per le prove concorrenti.

Per `make test` usare un **router di prova con gli script aggiornati** e impostare `ROUTER_USER`, `ROUTER_HOST` e `ROUTER_PASSWORD`. La suite usa la coda `tgq-test-20260925/`, ne azzera i dati tra i casi e simula il trasporto: non invia messaggi Telegram. Verifica accodamento, Unicode, permessi ridotti, concorrenza, ritentativi di pubblicazione, raggruppamento, frequenza e gestione degli errori.

Le prove di errore generano intenzionalmente log, fra cui due `TGQ TEST: enqueue failed` per dimensioni non corrispondenti. Il relativo script temporaneo viene rimosso; gli altri file e script `tgq-test-*` restano sul router per l'ispezione e possono essere rimossi dopo i test.

### Mappa dei sorgenti

| File | Responsabilità |
| --- | --- |
| `src/dude-command.txt` | Comando da copiare nella notifica Dude |
| `src/tgq-enqueue.rsc` | Creazione e pubblicazione degli eventi |
| `src/tgq-worker.rsc`, `src/tgq-core.rsc` | Singola istanza, raggruppamento, invio e ritentativi |
| `src/tgq-send.rsc`, `src/tgq-classify.rsc` | API Telegram e interpretazione degli errori |
| `src/tgq-state.rsc` | Lettura e salvataggio dello stato |
| `src/tgq-status.rsc`, `src/tgq-pause.rsc`, `src/tgq-resume.rsc` | Comandi operativi |
| `script/deploy.py`, `script/router.py` | Installazione e connessione SSH |
| `script/test_router.py`, `script/fixtures/tgq-test-send.rsc` | Test e trasporto simulato |

## Riferimenti e licenza

- [RouterOS Scripting](https://help.mikrotik.com/docs/spaces/ROS/pages/47579229/Scripting)
- [RouterOS Files](https://help.mikrotik.com/docs/spaces/ROS/pages/2555971/Files)
- [RouterOS Fetch](https://help.mikrotik.com/docs/spaces/ROS/pages/8978514/Fetch)
- [Limiti dei bot Telegram](https://core.telegram.org/bots/faq#my-bot-is-hitting-limits-how-do-i-avoid-this)

Licenza [MIT](LICENSE).
