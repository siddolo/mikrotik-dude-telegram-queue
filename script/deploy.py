import argparse
import json
import os
from router import SRC, command, configured, install_script, quote

MARKER = "TGQ managed v1 2026-09-25"


def initial_state():
    return {"generation": "0", "notBeforeNs": "0", "lastAttemptNs": "0", "lastSuccessNs": "0",
            "sentMessages": 0, "sentEvents": 0, "failedEvents": 0, "errors": 0,
            "consecutive": 0, "single": False, "status": "ready", "lastError": "", "acked": []}


def write_json(path, obj):
    encoded = json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
    return command(f':local ids [/file find where name={quote(path)}]; :if ([:len $ids] = 0) do={{/file add name={quote(path)} type=file contents={quote(encoded)}}} else={{/file set $ids contents={quote(encoded)}}}')


def initialize(base, *, test=False):
    chat_id = "-100TEST" if test else configured("TELEGRAM_CHAT_ID", "@@TELEGRAM_CHAT_ID@@")
    conf = {"managedBy": MARKER, "enabled": bool(test), "chatId": chat_id,
            "maxBatchEvents": 30,
            "sender": "tgq-test-send" if test else "tgq-send"}
    exists = command(f':put [:len [/file find where name={quote(base)}]]')
    if exists != "0":
        existing = json.loads(command(f':put [/file get [find where name={quote(base + "/config.json")}] contents]'))
        if existing.get("managedBy") != MARKER:
            raise RuntimeError("Unmanaged queue directory collision")
        print(base + " already initialized; existing state preserved")
        return
    for path in (base, base + "/pending", base + "/failed", base + "/archive"):
        command(f'/file add name={quote(path)} type=directory')
    write_json(base + "/config.json", conf)
    for slot in "ab":
        write_json(base + "/state-" + slot + ".json", initial_state())
    print(base + " initialized")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--production", action="store_true")
    parser.add_argument("--enable-scheduler", action="store_true")
    args = parser.parse_args()
    if args.production:
        configured("TELEGRAM_CHAT_ID", "@@TELEGRAM_CHAT_ID@@")
    for name in ("tgq-state", "tgq-enqueue", "tgq-classify", "tgq-send", "tgq-core", "tgq-worker", "tgq-status", "tgq-pause", "tgq-resume"):
        source = (SRC / (name + ".rsc")).read_text()
        if name == "tgq-send":
            source = source.replace("@@TOKEN@@", os.environ["TELEGRAM_TOKEN"])
        print(install_script(name, source))
    if args.production:
        initialize("tg-queue")
    if args.enable_scheduler:
        command(':if ([:len [/system scheduler find where name="tgq-tick"]] > 0) do={:error "scheduler already exists"}; '
                '/system scheduler add name="tgq-tick" comment="TGQ managed v1 2026-09-25" interval=1s '
                'start-time=startup on-event="/system script run tgq-worker" policy=read,write,test,ftp,sensitive disabled=no')
        print("tgq-tick installed; sender remains controlled by config.enabled")


if __name__ == "__main__":
    main()
