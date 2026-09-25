"""Local deployment/test helper. Credentials are read from the environment."""
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
FIXTURES = ROOT / "script" / "fixtures"


def configured(name, placeholder):
    value = os.environ.get(name, placeholder)
    if not value or value == placeholder:
        raise ValueError(f"Set {name} to replace {placeholder}")
    return value


def quote(value):
    value = str(value)
    escapes = {92: "\\\\", 34: '\\"', 36: "\\$", 10: "\\n", 13: "\\r", 9: "\\t"}
    return '"' + ''.join(escapes.get(b, chr(b) if 32 <= b < 127 else f"\\{b:02X}") for b in value.encode("utf-8")) + '"'


def command(script, timeout=90):
    router_user = configured("ROUTER_USER", "@@ROUTER_USER@@")
    router_host = configured("ROUTER_HOST", "@@ROUTER_HOST@@")
    env = dict(os.environ, SSHPASS=os.environ["ROUTER_PASSWORD"])
    arguments = [
        "sshpass", "-e", "ssh", "-o", "ConnectTimeout=15",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "ServerAliveInterval=15", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=/dev/null", "-o", "PreferredAuthentications=password,keyboard-interactive",
        "-o", "PubkeyAuthentication=no", f"{router_user}@{router_host}",
        ':onerror topError in={' + script + '; :put "__TGQ_OK__"} do={:put ("__TGQ_ERROR__".$topError)}',
    ]
    if control_path := os.environ.get("ROUTER_SSH_CONTROL"):
        arguments[3:3] = ["-o", "ControlPath=" + control_path]
    for attempt in range(3):
        result = subprocess.run(arguments, capture_output=True, text=True, env=env, timeout=timeout)
        # Retry only a rejected authentication: the remote command has not run.
        # Never replay a command after an ambiguous disconnect or partial output.
        rejected_login = result.returncode in (5, 255) and not result.stdout.strip() and "Permission denied" in result.stderr
        if not rejected_login or attempt == 2:
            break
        time.sleep(attempt + 1)
    output = result.stdout.replace("\r", "")
    if result.returncode or "__TGQ_OK__" not in output or "__TGQ_ERROR__" in output:
        safe = re.sub(r"[0-9]{6,}:[A-Za-z0-9_-]{20,}", "<TOKEN_REDACTED>", output + result.stderr)
        raise RuntimeError(safe)
    return output.replace("__TGQ_OK__", "").strip()


def install_script(name, source):
    # Existing tgq scripts must carry our marker before updating them.
    marker = "TGQ managed v1 2026-09-25"
    script = f':local old [/system script find where name={quote(name)}]; '
    script += f':if ([:len $old] > 0) do={{:if ([/system script get $old comment] != {quote(marker)}) do={{:error "unmanaged script name collision"}}; '
    script += f'/system script set $old source={quote(source)} policy=read,write,test,ftp,sensitive; '
    script += f'}} else={{/system script add name={quote(name)} comment={quote(marker)} policy=read,write,test,ftp,sensitive source={quote(source)}}}; '
    script += f':local parsed [:parse [/system script get [find where name={quote(name)}] source]]; :put {quote(name + " parsed")}'
    return command(script)


def function(name, arguments=""):
    return f':local f [:parse [/system script get [find where name={quote(name)}] source]]; :put [$f {arguments}]'
