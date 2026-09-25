# MikroTik Dude Telegram Queue

Coda persistente per inoltrare le notifiche di **The Dude** a Telegram tramite script RouterOS.

Separa la raccolta degli eventi dall'invio HTTP, limita la frequenza delle richieste e conserva gli alert durante le interruzioni di rete.

*WARNING: vibe-coded material.*

## Funzionamento

```text
Notifica Dude → file evento → coda persistente → sender unico → Telegram
                                                     ↓
                                           conferma o ritentativo
```

- Il produttore crea un file JSON distinto per ogni evento, con ID univoco.
- Lo scheduler controlla la coda ogni secondo: il primo evento viene normalmente elaborato entro circa un secondo, salvo attese dovute a errori.
- Il sender mantiene almeno **3,1 secondi fra tentativi**, circa **19 messaggi/minuto**.
- Gli eventi già in attesa vengono raggruppati senza una finestra di attesa aggiuntiva, fino a 30 eventi e 3500 byte di testo per messaggio.
- Le transizioni di stato, compresi down e up, rimangono eventi distinti e ordinati.
- Un evento viene rimosso dalla coda solo dopo una risposta Telegram con `ok=true`.

Ogni alert inizia con **⚠️**, seguito da stato, dispositivo, servizio, problema, orario e ID. Il simbolo è codificato esplicitamente in UTF-8 nello script RouterOS.

Per personalizzare il formato del messaggio Telegram, modificare la costruzione della variabile `part` in [`src/tgq-core.rsc`](src/tgq-core.rsc): contiene simbolo, etichette, campi e ordine delle informazioni di ciascun alert. Dopo la modifica, eseguire `make update` per aggiornare lo script sul router.

Il limite predefinito è pensato per un gruppo Telegram. Eventuali altri invii verso lo stesso gruppo devono essere considerati nel budget complessivo del bot.

## Requisiti

### Sul router

- RouterOS 7 con The Dude e supporto a `:serialize`, `:deserialize`, `:parse`, `:tonsec`, `:timestamp`, `:rndstr` e `:onerror` con attributi d'errore.
- Servizi Scheduler e Fetch abilitati nel device mode.
- Accesso HTTPS all'API Telegram e risoluzione DNS funzionante.
- Un percorso persistente per la directory della coda.
- Permessi del sender e dello scheduler: `read,write,test,ftp,sensitive`.

Il codice utilizza funzionalità presenti in RouterOS 7.24.2. Il permesso `sensitive` consente agli script di leggere i contenuti necessari senza mascheramenti che impediscano la deserializzazione. Il produttore funziona anche con `read,write,test,ftp`: usa soltanto metadati dei file e scrittura, così il contesto di esecuzione delle notifiche Dude non deve leggere configurazioni o contenuti protetti.

### Sul computer di gestione

- Python 3, senza dipendenze Python esterne.
- GNU Make per eseguire i comandi del repository.
- Client OpenSSH e `sshpass`.
- Accesso SSH al router e accesso al client Dude per configurare la notifica.
- Token di un bot Telegram e ID della chat destinataria.

## Configurazione

Prima del deployment, configurare la destinazione tramite variabili d'ambiente:

| Parametro | Dove impostarlo |
| --- | --- |
| Utente SSH | `ROUTER_USER`, sostituisce `@@ROUTER_USER@@` |
| Indirizzo IP o hostname del router | `ROUTER_HOST`, sostituisce `@@ROUTER_HOST@@` |
| ID della chat Telegram | `TELEGRAM_CHAT_ID`, sostituisce `@@TELEGRAM_CHAT_ID@@` |
| Password SSH | Variabile d'ambiente `ROUTER_PASSWORD` |
| Token del bot | Variabile d'ambiente `TELEGRAM_TOKEN` |
| Socket opzionale di una connessione SSH già aperta | Variabile d'ambiente `ROUTER_SSH_CONTROL` |

Il sorgente `src/tgq-send.rsc` contiene il segnaposto `@@TOKEN@@`, sostituito durante l'installazione. Il token viene inserito nello script di invio sul router.

```bash
export ROUTER_USER='<utente-ssh>'
export ROUTER_HOST='<ip-o-hostname-router>'
export ROUTER_PASSWORD='<password-router>'
export TELEGRAM_TOKEN='<token-bot>'
export TELEGRAM_CHAT_ID='<id-chat>'
```

Gli helper rifiutano valori mancanti o placeholder non sostituiti per utente, indirizzo e chat ID.

Il percorso predefinito è `tg-queue/`. Sui dispositivi con directory `flash/`, adattare i percorsi degli script e dell'installer a una posizione persistente, ad esempio `flash/tg-queue/`.

## Installazione

Eseguire dalla directory del repository:

```bash
make install
```

Il comando installa gli script, inizializza directory e stato della coda e crea lo scheduler `tgq-tick`. La configurazione iniziale mantiene l'invio in pausa.

### Collegare una notifica Dude

Nel client Dude, aprire o creare una notifica di tipo **execute on server** e impostare il campo **Command** con il contenuto di [`src/dude-command.txt`](src/dude-command.txt):

```routeros
:local enqueue [:parse [/system script get [find where name="tgq-enqueue"] source]]; $enqueue dev=("[Device.Name]") probe=("[Probe.Name]") state=("[Service.Status]") problem=("[Service.ProblemDescription]")
```

Associare la notifica ai dispositivi o servizi desiderati. Il campo Command va configurato dal client Dude, poiché la CLI RouterOS non lo espone.

Il produttore serializza i dati in JSON. L'espansione del template Dude avviene però prima dell'esecuzione dello script: virgolette, backslash e dollari presenti nei valori richiedono escaping anche a livello del template RouterOS.

### Attivare l'invio

Dal terminale RouterOS:

```routeros
/system script run tgq-resume
/system script run tgq-status
```

Verificare un evento Dude controllato: deve entrare in coda, arrivare su Telegram e incrementare `sentEvents`.

### Aggiornare gli script

```bash
make update
```

L'installer aggiorna gli script riconosciuti dal proprio marcatore e conserva la configurazione e lo stato esistenti. `make install` crea anche lo scheduler e rifiuta uno scheduler omonimo già presente. Per modificare la chat di una coda esistente, aggiornare `chatId` nel suo `config.json`.

## Configurazione e limiti della coda

In `tg-queue/config.json`:

| Campo | Significato | Valore predefinito |
| --- | --- | --- |
| `enabled` | Abilita l'invio | `false` alla prima installazione |
| `chatId` | Chat destinataria | Impostato nel deployment |
| `maxBatchEvents` | Eventi massimi per messaggio | `30` |
| `sender` | Script di trasporto | `tgq-send` |
| `managedBy` | Marcatore dell'installer | Gestito automaticamente |

Il limite di 2000 eventi pendenti è definito da `capacity` in `src/tgq-enqueue.rsc`; l'argomento opzionale `limit` del produttore può ridurlo per una chiamata. Ulteriori limiti sono definiti nei sorgenti: 10 MiB per la coda pendente, 50 KB per evento, 3500 byte di testo per messaggio e 2000 record nell'archivio dei messaggi abbreviati. I controlli di capacità precedono la scrittura; produttori concorrenti possono superare marginalmente la soglia durante la verifica simultanea.

A coda piena, il nuovo evento viene rifiutato con un errore esplicito e gli eventi esistenti vengono conservati. L'archivio pieno arresta il sender per consentire la gestione dei record. La directory `failed/` richiede controllo e manutenzione.

Il produttore restituisce l'ID in caso di successo. In caso di errore registra `TGQ: enqueue failed` e restituisce una stringa vuota, contenendo l'eccezione prima di tornare al notificatore Dude. L'opzione `strict=true`, destinata ai test, propaga invece l'errore al chiamante.

## Gestione degli errori

| Errore | Comportamento |
| --- | --- |
| HTTP 429 | Attende `retry_after` disponibile più 1 secondo; fallback di 61 secondi, crescente se manca un'indicazione esplicita |
| DNS, timeout, HTTP 5xx | Ritenta dopo 15, 30, 60, 120 e poi 300 secondi, conservando gli eventi |
| `maximum connection count reached` | Conserva gli eventi e ritenta ogni 60 secondi quando la coda non è vuota |
| HTTP 401 / 403 | Pausa globale di 300 secondi, con eventi conservati |
| Altri HTTP 4xx | Ritenta il batch per singolo evento e sposta quello invalido in `failed/` |
| JSON evento corrotto | Sposta il file in `failed/` e registra l'errore |
| Stato o configurazione indisponibili | Disabilita lo scheduler e registra un errore operativo |

## Persistenza e consegna

```text
tg-queue/
├── config.json
├── state-a.json
├── state-b.json
├── pending/       # eventi da inviare
├── failed/        # eventi invalidi o rifiutati definitivamente
└── archive/       # originali dei messaggi abbreviati
```

Gli eventi vengono scritti come `.tmp`, verificati confrontando la dimensione scritta con quella del JSON e pubblicati come `.ready`. Il sender legge e valida il JSON prima dell'invio. Ogni produttore usa un file distinto, senza variabili globali condivise.

Lo stato viene salvato alternando due copie JSON. Se la copia più recente è corrotta, il lettore utilizza quella precedente valida. La scadenza del limite di invio viene salvata prima della richiesta; la conferma Telegram viene salvata prima della rimozione dei file. Le eliminazioni interrotte vengono completate al ciclo successivo.

La persistenza dipende dal filesystem e dalle sue cache: il readback non equivale a un `fsync` contro una perdita improvvisa di alimentazione. I `.tmp` incompleti compaiono nel contatore `incomplete` e richiedono verifica prima di ripubblicarli.

Se Telegram accetta un messaggio ma la risposta va persa, il ritentativo può duplicarlo. L'ID dell'evento, incluso nel testo, permette di riconoscere i duplicati. I campi troppo lunghi vengono abbreviati su confini UTF-8 validi; l'originale completo viene archiviato prima dell'invio.

## Comandi utili

```routeros
# Stato della coda
/system script run tgq-status

# Pausa dell'invio; l'accodamento rimane disponibile
/system script run tgq-pause

# Ripresa, rispettando le attese gia' memorizzate
/system script run tgq-resume

# Ispezione dei file e dei log
/file print where name~"^tg-queue/pending/"
/file print where name~"^tg-queue/failed/"
/log print where message~"TGQ:"
```

`tgq-status` riporta `pending`, `pendingBytes`, `oldestAgeSeconds`, `failed`, `incomplete`, `sentMessages`, `sentEvents`, `status`, `lastError` e `retryInSeconds`. Stato ed errore descrivono l'ultimo tentativo; con la coda vuota non vengono eseguite sonde continue verso Telegram.

## Struttura del progetto

```text
mikrotik-dude-telegram-queue/
├── .gitignore
├── LICENSE
├── Makefile
├── README.md
├── script/
│   ├── deploy.py
│   ├── router.py
│   ├── test_router.py
│   └── fixtures/
│       └── tgq-test-send.rsc
└── src/
    ├── dude-command.txt
    ├── tgq-classify.rsc
    ├── tgq-core.rsc
    ├── tgq-enqueue.rsc
    ├── tgq-pause.rsc
    ├── tgq-resume.rsc
    ├── tgq-send.rsc
    ├── tgq-state.rsc
    ├── tgq-status.rsc
    └── tgq-worker.rsc
```

| File | Ruolo |
| --- | --- |
| `src/tgq-enqueue.rsc` | Serializzazione e accodamento |
| `src/tgq-state.rsc` | Stato persistente a due copie |
| `src/tgq-classify.rsc` | Interpretazione degli errori e delle attese |
| `src/tgq-send.rsc` | Chiamata Telegram e verifica della risposta |
| `src/tgq-core.rsc` | Raggruppamento, frequenza, conferme e ritentativi |
| `src/tgq-worker.rsc` | Singola istanza e arresto su errore interno |
| `src/tgq-status.rsc` | Stato operativo |
| `src/tgq-pause.rsc`, `src/tgq-resume.rsc` | Controllo dell'invio |
| `src/dude-command.txt` | Template della notifica Dude |
| `script/router.py`, `script/deploy.py` | Connessione SSH e deployment |
| `script/test_router.py` | Test d'integrazione |
| `script/fixtures/tgq-test-send.rsc` | Trasporto simulato per i test |

## Comandi Make

Eseguire dalla root del repository:

| Comando | Funzione |
| --- | --- |
| `make` oppure `make help` | Elenca i comandi disponibili |
| `make install` | Prima installazione di script, directory e scheduler |
| `make update` | Aggiorna gli script sul router |
| `make test` | Esegue i test d'integrazione sul router di prova configurato |
| `make check` | Verifica localmente la sintassi Python |

L'interprete si può scegliere con `PYTHON`, ad esempio `make check PYTHON=python3.12`. Le variabili di connessione e Telegram vengono ereditate dall'ambiente.

## Test

I test richiedono un router di prova con gli script installati e le variabili `ROUTER_USER`, `ROUTER_HOST` e `ROUTER_PASSWORD` impostate. Creano file e script `tgq-test-*` sul dispositivo e usano un trasporto simulato per verificare concorrenza, frequenza, batch, conferme e ritentativi. La suite verifica anche l'accodamento eseguito senza il permesso `sensitive`.

```bash
make test
```

I test lasciano i propri file e script sul router per l'ispezione; vanno rimossi al termine delle verifiche.

## Riferimenti

- [RouterOS Scripting](https://help.mikrotik.com/docs/spaces/ROS/pages/47579229/Scripting)
- [RouterOS Files](https://help.mikrotik.com/docs/spaces/ROS/pages/2555971/Files)
- [RouterOS Fetch](https://help.mikrotik.com/docs/spaces/ROS/pages/8978514/Fetch)
- [Limiti dei bot Telegram](https://core.telegram.org/bots/faq#my-bot-is-hitting-limits-how-do-i-avoid-this)

## Licenza

Il progetto è distribuito con licenza [MIT](LICENSE).
