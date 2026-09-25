# Called as a function, using local parameters: dev, probe, state, problem.
:local completedId "";
:local enqueueError "";
# Contain runtime errors before returning to Dude's notification runner.
:onerror enqueueFailure in={
:local base $root;
:if ([:typeof $base] != "str") do={ :set base "tg-queue"; };
# Dude's execution context may not have 'sensitive': use metadata, not file contents.
:local capacity 2000;
:local requestedLimit [:tonum $limit];
:if (([:typeof $requestedLimit] = "num") && ($requestedLimit > 0) && ($requestedLimit < $capacity)) do={ :set capacity $requestedLimit; };
:local pendingRegex ("^" . $base . "/pending/.*[.]ready\$");
:if ([:len [/file find where name~$pendingRegex]] >= $capacity) do={
    :error "TGQ: queue full";
};
:local eventId ([:tostr [:tonsec [:timestamp]]] . "-" . [:rndstr from="0123456789abcdef" length=16]);
:local stamp ([/system clock get date] . " " . [/system clock get time]);
:local record {"version"=1;"id"=$eventId;"time"=$stamp;"device"=[:tostr $dev];"probe"=[:tostr $probe];"status"=[:tostr $state];"problem"=[:tostr $problem]};
:local encoded [:serialize to=json options=json.no-string-conversion value=$record];
:if ([:len $encoded] > 50000) do={ :error "TGQ: event exceeds 50KB"; };
:local pendingBytes 0;
:foreach item in=[/file print as-value proplist=size where name~$pendingRegex] do={ :set pendingBytes ($pendingBytes + ($item->"size")); };
:if (($pendingBytes + [:len $encoded]) > 10485760) do={ :error "TGQ: queue byte limit (10MiB)"; };
:local tmp ($base . "/pending/" . $eventId . ".tmp");
:local ready ($base . "/pending/" . $eventId . ".ready");
/file add name=$tmp type=file contents=$encoded;
:if ([/file get [find where name=$tmp] size] != [:len $encoded]) do={ :error "TGQ: event size mismatch"; };
/file set [find where name=$tmp] name=$ready;
:set completedId $eventId;
} do={ :set enqueueError [:tostr $enqueueFailure]; };
:if ([:len $enqueueError] > 0) do={
    :log error ("TGQ: enqueue failed: " . $enqueueError);
    :if ($strict = true) do={ :error $enqueueError; };
    :return "";
};
:return $completedId;
