"""Contract tests on isolated queue storage; mocked transport never contacts Telegram."""
from concurrent.futures import ThreadPoolExecutor
import json
import time
from router import FIXTURES, SRC, command, function, install_script, quote
from deploy import MARKER, initialize, initial_state, write_json

BASE = "tgq-test-20260925"


def read_json(path):
    return json.loads(command(f':put [/file get [find where name={quote(path)}] contents]'))


def paths(pattern):
    output = command(f':put [:serialize to=json value=[/file print as-value proplist=name where name~{quote(pattern)}]]')
    return [item["name"] for item in json.loads(output)]


def state():
    return json.loads(command(':local f [:parse [/system script get [find where name="tgq-state"] source]]; '
                              f':put [:serialize to=json options=json.no-string-conversion value=[$f root={quote(BASE)} action="load"]]'))


def reset(max_batch=30):
    command(f'/file remove [find where name~{quote("^" + BASE + "/(pending/|failed/|archive/|trace-)")}]')
    for slot in "ab":
        write_json(BASE + "/state-" + slot + ".json", initial_state())
    write_json(BASE + "/config.json", {"managedBy": MARKER, "enabled": True, "chatId": "-100TEST",
                                      "maxBatchEvents": max_batch, "sender": "tgq-test-send"})
    write_json(BASE + "/reply.json", {"ok": True, "messageId": 1})


def enqueue(i=0, dev=None, limit=2000):
    return command(function("tgq-enqueue", f'root={quote(BASE)} strict=true limit={limit} dev=({quote(dev or f"TEST-{i}")}) probe="ping" state="down" problem="timeout"'))


def drain():
    return command(function("tgq-core", f'root={quote(BASE)}'), timeout=75)


def clear_cooldown():
    command(':local f [:parse [/system script get [find where name="tgq-state"] source]]; '
            f':local s [$f root={quote(BASE)} action="load"]; :set ($s->"notBeforeNs") "0"; '
            f':local saved [$f root={quote(BASE)} action="save" value=$s]')


def check(label, condition):
    if not condition:
        raise AssertionError(label)
    print("PASS " + label, flush=True)


def test_publication_retries():
    """Inject metadata faults into a test copy of the installed producer."""
    source = command(':put [/system script get [find where name="tgq-enqueue"] source]')
    source = source.replace("TGQ: enqueue failed:", "TGQ TEST: enqueue failed:")
    metadata = ':local matches [/file print as-value proplist=name,size where name=$tmp];'
    item = ':local item [:pick $matches 0];'
    assert source.count(metadata) == source.count(item) == 1, "Install the current tgq-enqueue before testing"
    name = "tgq-test-enqueue-retry"
    args = f'root={quote(BASE)} dev=("TEST-RETRY") probe="ping" state="up" problem=""'
    reset()
    try:
        transient = source.replace(metadata, metadata + '\n'
                                   '        :if ($attempt < 3) do={ :set matches [:toarray ""]; };')
        print(install_script(name, transient))
        identifier = command(function(name, args + ' strict=true'))
        event = read_json(BASE + "/pending/" + identifier + ".ready")
        check("transient missing metadata retried and published", event["id"] == identifier and event["status"] == "up")
        check("retry does not duplicate or leave unfinished events", len(paths("^" + BASE + "/pending/")) == 1)
        check("producer retries never use the transport", not paths("^" + BASE + "/trace-"))

        reset()
        mismatch = source.replace(item, item + '\n        :set ($item->"size") -1;')
        print(install_script(name, mismatch))
        print("Expect two TGQ TEST error logs from persistent-mismatch checks", flush=True)
        started = time.monotonic()
        rejected = False
        try:
            command(function(name, args + ' strict=true'))
        except RuntimeError as error:
            rejected = "event publication timed out: event size mismatch" in str(error)
        check("persistent mismatch fails after retries", rejected and time.monotonic() - started >= 2)
        check("mismatched event stays unpublished", len(paths("^" + BASE + "/pending/.*[.]tmp$")) == 1
              and not paths("^" + BASE + "/pending/.*[.]ready$"))
        result = command(function(name, args))
        check("publication failure is contained for Dude", result == ""
              and len(paths("^" + BASE + "/pending/.*[.]tmp$")) == 2
              and not paths("^" + BASE + "/pending/.*[.]ready$"))
    finally:
        command(f'/system script remove [find where name={quote(name)}]')


def main():
    initialize(BASE, test=True)
    print(install_script("tgq-test-send", (FIXTURES / "tgq-test-send.rsc").read_text()))
    reset()
    special = 'TEST "quote" \\ slash $ variable\nUnicode: è ⚠'
    identifier = enqueue(dev=special)
    event = read_json(BASE + "/pending/" + identifier + ".ready")
    check("JSON preserves quotes, backslashes, dollars, newlines and UTF-8", event["device"] == special)
    check("producer publishes one complete event", len(paths("^" + BASE + "/pending/.*[.]ready$")) == 1)
    check("no unfinished producer file", not paths("^" + BASE + "/pending/.*[.]tmp$"))
    check("no transport used by producer", not paths("^" + BASE + "/trace-"))
    check("successful delivery", drain() == "empty")
    check("acknowledged event removed", not paths("^" + BASE + "/pending/"))
    rendered = json.loads(read_json(paths("^" + BASE + "/trace-")[0])["payload"])["text"]
    check("warning emoji is preserved as UTF-8", rendered.startswith("⚠️ [down] "))

    reset()
    restricted_source = ':local f [:parse [/system script get [find where name="tgq-enqueue"] source]]; '
    restricted_source += ':put [$f root=' + quote(BASE) + ' dev="TEST-RESTRICTED" probe="ping" state="down" problem="timeout"]'
    print(install_script("tgq-test-restricted", restricted_source))
    command('/system script set [find where name="tgq-test-restricted"] policy=read,write,test,ftp')
    identifier = command('/system script run tgq-test-restricted use-script-permissions')
    check("producer works without sensitive permission", read_json(BASE + "/pending/" + identifier + ".ready")["device"] == "TEST-RESTRICTED")
    drain()

    reset(max_batch=1)
    for i in range(4):
        enqueue(i)
    check("drain four messages", drain() == "empty")
    traces = [read_json(path) for path in sorted(paths("^" + BASE + "/trace-"))]
    gaps = [(int(b["ns"]) - int(a["ns"])) / 1e9 for a, b in zip(traces, traces[1:])]
    check("one send per event with batch size 1", len(traces) == 4)
    check("minimum 3.1 second spacing", all(gap >= 3.1 for gap in gaps))
    print("Measured gaps:", gaps, flush=True)
    check("success counters persisted", state()["sentMessages"] == 4 and state()["sentEvents"] == 4)

    reset()
    with ThreadPoolExecutor(max_workers=5) as pool:
        identifiers = list(pool.map(enqueue, range(20)))
    check("concurrent producers retain all events", len(set(identifiers)) == 20 and len(paths("^" + BASE + "/pending/")) == 20)
    check("concurrent producers publish every event", len(paths("^" + BASE + "/pending/.*[.]ready$")) == 20
          and not paths("^" + BASE + "/pending/.*[.]tmp$"))
    drain()
    traces = [read_json(path) for path in paths("^" + BASE + "/trace-")]
    check("batching reduces sends", 0 < len(traces) < 20)
    check("batch payloads valid and under 3500 bytes", all(len(json.loads(t["payload"])["text"].encode()) <= 3500 for t in traces))
    check("all batched events acknowledged", state()["sentEvents"] == 20)

    test_publication_retries()

    reset()
    enqueue()
    write_json(BASE + "/reply.json", {"ok": False, "kind": "blocked", "retry": 60, "error": "maximum connection count reached"})
    check("blocked Fetch classified", drain() == "blocked")
    check("blocked Fetch preserves event", len(paths("^" + BASE + "/pending/")) == 1)
    check("blocked Fetch observes cooldown", drain() == "cooldown" and len(paths("^" + BASE + "/trace-")) == 1)
    check("circuit state persisted", state()["status"] == "blocked" and state()["errors"] == 1)

    reset()
    enqueue()
    write_json(BASE + "/reply.json", {"ok": False, "kind": "network", "retry": 15, "error": "transport timeout"})
    check("network error retained", drain() == "network" and len(paths("^" + BASE + "/pending/")) == 1)
    first = state()
    clear_cooldown()
    drain()
    second = state()
    check("network exponential backoff", int(second["notBeforeNs"]) - int(second["lastAttemptNs"]) >= 30_000_000_000 and second["consecutive"] == 2)

    reset()
    enqueue(1)
    enqueue(2)
    write_json(BASE + "/reply.json", {"ok": False, "kind": "permanent", "retry": 0, "error": "Telegram HTTP 400"})
    check("permanent batch error triggers single-event isolation", drain() == "permanent" and state()["single"])
    clear_cooldown()
    drain()
    check("permanent event quarantined", len(paths("^" + BASE + "/failed/")) == 1 and len(paths("^" + BASE + "/pending/")) == 1)

    reset()
    command(f'/file add name={quote(BASE + "/pending/broken.ready")} type=file contents="not-json"')
    drain()
    check("corrupt event quarantined", len(paths("^" + BASE + "/failed/")) == 1)

    reset()
    enqueue(limit=1)
    rejected = False
    try:
        enqueue(2, limit=1)
    except RuntimeError as error:
        rejected = "queue full" in str(error)
    check("capacity enforced without deleting existing event", rejected and len(paths("^" + BASE + "/pending/")) == 1)
    result = command(function("tgq-enqueue", f'root={quote(BASE)} limit=1 dev="TEST-OVERFLOW" probe="ping" state="down" problem="timeout"'))
    check("producer contains errors before returning to Dude", result == "" and len(paths("^" + BASE + "/pending/")) == 1)

    reset()
    code = (SRC / "tgq-worker.rsc").read_text().replace('script="tgq-worker"', 'script="tgq-test-worker"').replace('root="tg-queue"', 'root=' + quote(BASE))
    code = code.replace('/system scheduler disable [find where name="tgq-tick"];', '')
    print(install_script("tgq-test-worker", code))
    reset(max_batch=1)
    enqueue(1)
    enqueue(2)
    before_errors = json.loads(command(':put [:serialize to=json value=[/log print as-value proplist=message where topics~"error"]]'))
    before_ids = {row[".id"] for row in before_errors}
    command(':execute {/system script run tgq-test-worker}; :delay 200ms; :execute {/system script run tgq-test-worker}; :delay 8s')
    check("overlapping workers do not duplicate sends", len(paths("^" + BASE + "/trace-")) == 2 and state()["sentEvents"] == 2)
    after_errors = json.loads(command(':put [:serialize to=json value=[/log print as-value proplist=message where topics~"error"]]'))
    new_errors = [row for row in after_errors if row[".id"] not in before_ids]
    check("overlapping workers exit without script errors", not new_errors)

    for code, body, headers, expected, retry in [
        (429, '{"parameters":{"retry_after":12}}', "", "rate", 13),
        (429, "", "Retry-After: 9\r\nContent-Type: application/json", "rate", 10),
        (429, "", "", "rate", 61),
        (401, "", "", "auth", 300),
        (400, "", "", "permanent", 0),
        (503, "", "", "network", 15),
    ]:
        args = f'httpCode={code} errorText="" responseData=({quote(body)}) responseHeaders=({quote(headers)})'
        result = json.loads(command(':local f [:parse [/system script get [find where name="tgq-classify"] source]]; '
                                    ':put [:serialize to=json value=[$f ' + args + ']]'))
        check(f"HTTP {code} classification and retry {retry}s", result["kind"] == expected and result["retry"] == retry)
    print("ALL CONTRACT TESTS PASSED", flush=True)


if __name__ == "__main__":
    main()
