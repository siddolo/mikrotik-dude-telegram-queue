# Shared drain engine. Production entrypoint provides the single-instance guard.
:local base $root;
:local stateFn [:parse [/system script get [find where name="tgq-state"] source]];
:local st [$stateFn root=$base action="load"];
:local start [:tonsec [:timestamp]];
:local pendingRegex ("^" . $base . "/pending/.*[.]ready\$");
:local limitNs 3100000000;
:local exactFile do={
    :local wantedPath $entry;
    :local matches [/file find where name=$wantedPath];
    :if ([:len $matches] != 1) do={ :error "TGQ: expected exactly one file"; };
    :return [:pick $matches 0];
};
# Byte-safe prefix for UTF-8. RouterOS string indexes count bytes.
:local short do={
    :local s [:tostr $text];
    :local n $maxBytes;
    :if ([:len $s] <= $n) do={ :return $s; };
    :while ($n > 0) do={
        :local hex [:convert [:pick $s $n ($n + 1)] from=raw to=hex];
        :if ($hex~"^[89aAbB]") do={ :set n ($n - 1); } else={ :break; };
    };
    :return ([:pick $s 0 $n] . " ...");
};
# Complete acknowledged deletions after an interrupted previous run.
:foreach entryPath in=($st->"acked") do={
    :if ([:pick $entryPath 0 ([:len $base] + 9)] != ($base . "/pending/")) do={ :error "TGQ: invalid acknowledged path"; };
    :local ids [/file find where name=$entryPath];
    :if ([:len $ids] > 0) do={ /file remove [$exactFile entry=$entryPath]; };
};
:set ($st->"acked") [:toarray ""];
:while (([:tonsec [:timestamp]] - $start) < 45000000000) do={
    :local conf [:deserialize from=json options=json.no-string-conversion value=[/file get [find where name=($base . "/config.json")] contents]];
    :if (($conf->"enabled") != true) do={ :return "paused"; };
    :local now [:tonsec [:timestamp]];
    :local wait ([:tonum ($st->"notBeforeNs")] - $now);
    :if ($wait > 0) do={
        :if ($wait > $limitNs) do={ :return "cooldown"; };
        :while ($wait > 0) do={
            :delay [:totime ($wait . "ns")];
            :set wait ([:tonum ($st->"notBeforeNs")] - [:tonsec [:timestamp]]);
        };
    };
    :local ordered [:toarray ""];
    :foreach row in=[/file print as-value proplist=name where name~$pendingRegex] do={
        :set ($ordered->($row->"name")) true;
    };
    :if ([:len $ordered] = 0) do={ :return "empty"; };
    :local selected [:toarray ""];
    :local message "";
    :local maxBatch [:tonum ($conf->"maxBatchEvents")];
    :if (($st->"single") = true) do={ :set maxBatch 1; };
    :foreach entryPath,unused in=$ordered do={
        :if ([:len $selected] >= $maxBatch) do={ :break; };
        :local event;
        :local bad false;
        :onerror e in={
            :set event [:deserialize from=json options=json.no-string-conversion value=[/file get [$exactFile entry=$entryPath] contents]];
            :if (([:typeof ($event->"id")] != "str") || ([:typeof ($event->"device")] != "str") || ([:typeof ($event->"status")] != "str")) do={ :error "invalid event"; };
        } do={ :set bad true; };
        :if ($bad) do={
            :local leaf [:pick $entryPath ([:len $base] + 9) [:len $entryPath]];
            /file set [$exactFile entry=$entryPath] name=($base . "/failed/" . $leaf);
            :set ($st->"failedEvents") ([:tonum ($st->"failedEvents")] + 1);
            :set ($st->"lastError") "invalid queued JSON";
            :set st [$stateFn root=$base action="save" value=$st];
            :log error "TGQ: invalid event moved to failed";
            :continue;
        };
        # Preserve full originals whenever Telegram's compact rendering is shortened.
        :if (([:len ($event->"device")] > 200) || ([:len ($event->"probe")] > 120) || ([:len ($event->"status")] > 40) || ([:len ($event->"problem")] > 1800)) do={
            :local archivePath ($base . "/archive/" . [:pick $entryPath ([:len $base] + 9) [:len $entryPath]]);
            :if ([:len [/file find where name=$archivePath]] = 0) do={
                :local archiveRegex ("^" . $base . "/archive/");
                :if ([:len [/file find where name~$archiveRegex]] >= 2000) do={ :error "TGQ: archive full; inspect archived long events"; };
                /file add name=$archivePath type=file contents=[/file get [$exactFile entry=$entryPath] contents];
            };
        };
        :local icon "\E2\9A\A0\EF\B8\8F";
        :if (($event->"status") = "up") do={ :set icon "\E2\9C\85"; };
        :local part ($icon . " [" . [$short text=($event->"status") maxBytes=40] . "] " . [$short text=($event->"device") maxBytes=200] . "\nServizio: " . [$short text=($event->"probe") maxBytes=120] . "\nProblema: " . [$short text=($event->"problem") maxBytes=1800] . "\nOra: " . ($event->"time") . "\nID: " . ($event->"id"));
        :if (([:len $message] + [:len $part] + 2) > 3500) do={ :break; };
        :if ([:len $selected] > 0) do={ :set message ($message . "\n\n"); };
        :set message ($message . $part);
        :set selected ($selected , $entryPath);
    };
    :if ([:len $selected] = 0) do={ :return "no valid events"; };
    :local payload [:serialize to=json options=json.no-string-conversion value={"chat_id"=($conf->"chatId");"text"=$message}];
    # Persist spacing BEFORE sending. Crash/restart must not bypass the limit.
    :set now [:tonsec [:timestamp]];
    :set ($st->"lastAttemptNs") [:tostr $now];
    :set ($st->"notBeforeNs") [:tostr ($now + $limitNs)];
    :set ($st->"status") "sending";
    :set st [$stateFn root=$base action="save" value=$st];
    :local sendFn [:parse [/system script get [find where name=($conf->"sender")] source]];
    :local reply;
    :onerror err in={ :set reply [$sendFn root=$base data=$payload]; } do={
        :set reply {"ok"=false;"kind"="network";"retry"=15;"error"="sender script exception"};
    };
    # Anchor spacing to transport entry, including variable state-write overhead.
    :local actualStart [:tonum ($reply->"startedNs")];
    :if (([:typeof $actualStart] = "num") && ($actualStart >= $now)) do={
        :set ($st->"lastAttemptNs") [:tostr $actualStart];
        :set ($st->"notBeforeNs") [:tostr ($actualStart + $limitNs)];
    };
    :if (($reply->"ok") = true) do={
        :set ($st->"sentMessages") ([:tonum ($st->"sentMessages")] + 1);
        :set ($st->"sentEvents") ([:tonum ($st->"sentEvents")] + [:len $selected]);
        :set ($st->"lastSuccessNs") [:tostr [:tonsec [:timestamp]]];
        :set ($st->"lastError") "";
        :set ($st->"status") "ready";
        :set ($st->"consecutive") 0;
        :set ($st->"single") false;
        :set ($st->"acked") $selected;
        :set st [$stateFn root=$base action="save" value=$st];
        :foreach entryPath in=$selected do={ /file remove [$exactFile entry=$entryPath]; };
        :set ($st->"acked") [:toarray ""];
    } else={
        :local kind ($reply->"kind");
        :local failures ([:tonum ($st->"consecutive")] + 1);
        :set ($st->"consecutive") $failures;
        :set ($st->"errors") ([:tonum ($st->"errors")] + 1);
        :set ($st->"lastError") ($reply->"error");
        :set ($st->"status") $kind;
        :local pause [:tonum ($reply->"retry")];
        :if ([:typeof $pause] != "num") do={ :set pause 60; };
        :if ($kind = "network") do={
            :local delays {15;30;60;120;300};
            :local index ($failures - 1);
            :if ($index > 4) do={ :set index 4; };
            :set pause [:pick $delays $index];
        };
        :if (($kind = "rate") && ($failures > 1) && (($reply->"retryKnown") != true)) do={
            :local fallback (60 * $failures);
            :if ($fallback > 600) do={ :set fallback 600; };
            :if ($pause < $fallback) do={ :set pause $fallback; };
        };
        :if ($kind = "permanent") do={
            :if ([:len $selected] > 1) do={
                :set ($st->"single") true;
            } else={
                :local entryPath [:pick $selected 0];
                :local leaf [:pick $entryPath ([:len $base] + 9) [:len $entryPath]];
                /file set [$exactFile entry=$entryPath] name=($base . "/failed/" . $leaf);
                :set ($st->"failedEvents") ([:tonum ($st->"failedEvents")] + 1);
                :set ($st->"consecutive") 0;
                :set ($st->"single") false;
            };
        };
        :local until ([:tonsec [:timestamp]] + ($pause * 1000000000));
        :if ($until > [:tonum ($st->"notBeforeNs")]) do={ :set ($st->"notBeforeNs") [:tostr $until]; };
        :set st [$stateFn root=$base action="save" value=$st];
        :if (($failures = 1) || (($failures % 10) = 0)) do={
            :log warning ("TGQ: " . ($reply->"error") . "; events retained; retry in " . $pause . "s");
        };
        :return $kind;
    };
};
:return "timeslice";
