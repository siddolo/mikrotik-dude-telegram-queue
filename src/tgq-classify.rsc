# Convert transport errors into a bounded retry decision. Never return bot URL/token.
:local code [:tonum $httpCode];
:local message [:tostr $errorText];
:local wait 0;
:local retryKnown false;
:local body $responseData;
:local headers [:tostr $responseHeaders];
:onerror e in={
    :local obj [:deserialize from=json value=$body];
    :local bodyCode [:tonum ($obj->"error_code")];
    :if ([:typeof $bodyCode] = "num") do={ :set code $bodyCode; };
    :local delay [:tonum ($obj->"parameters"->"retry_after")];
    :if (([:typeof $delay] = "num") && ($delay > 0)) do={ :set wait $delay; :set retryKnown true; };
} do={};
:if ($message~"maximum connection count reached") do={
    :return {"ok"=false;"kind"="blocked";"retry"=60;"error"="maximum connection count reached"};
};
:if ($code = 429) do={
    :if ($wait < 1) do={
        :local lower [:convert $headers transform=lc];
        :local pos [:find $lower "retry-after:"];
        :if ([:typeof $pos] = "num") do={
            :local digits "";
            :for n from=($pos + 12) to=([:len $lower] - 1) do={
                :local ch [:pick $lower $n ($n + 1)];
                :if ($ch~"[0-9]") do={ :set digits ($digits . $ch); } else={
                    :if (($ch != " ") || ([:len $digits] > 0)) do={ :break; };
                };
            };
            :if ([:len $digits] > 0) do={ :set wait [:tonum $digits]; :set retryKnown true; };
        };
    };
    :if ($wait < 1) do={ :set wait 60; };
    :return {"ok"=false;"kind"="rate";"retry"=($wait + 1);"retryKnown"=$retryKnown;"error"="Telegram HTTP 429"};
};
:if (($code = 401) || ($code = 403)) do={
    :return {"ok"=false;"kind"="auth";"retry"=300;"error"=("Telegram HTTP " . $code)};
};
:if (([:typeof $code] = "num") && ($code >= 400) && ($code < 500)) do={
    :return {"ok"=false;"kind"="permanent";"retry"=0;"error"=("Telegram HTTP " . $code)};
};
:local reason "network or invalid response";
:if ($message~"resolv") do={ :set reason "DNS resolution failed"; };
:if ($message~"timeout") do={ :set reason "transport timeout"; };
:if (([:typeof $code] = "num") && ($code >= 500)) do={ :set reason ("Telegram HTTP " . $code); };
:return {"ok"=false;"kind"="network";"retry"=15;"error"=$reason};
