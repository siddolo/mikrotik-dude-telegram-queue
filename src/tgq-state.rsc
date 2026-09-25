# Persistent state, alternating two independently validated JSON files.
:local base $root;
:local operation $action;
:local best;
:local bestGen -1;
:local target "a";
:local readError "";
:foreach slot in={"a";"b"} do={
    :local path ($base . "/state-" . $slot . ".json");
    :onerror e in={
        :local candidate [:deserialize from=json options=json.no-string-conversion value=[/file get [find where name=$path] contents]];
        :local generation [:tonum ($candidate->"generation")];
        :if ([:typeof $generation] != "num") do={ :error "invalid generation"; };
        :if ($generation > $bestGen) do={
            :set best $candidate;
            :set bestGen $generation;
            :set target "a";
            :if ($slot = "a") do={ :set target "b"; };
        };
    } do={ :set readError [:tostr $e]; };
};
:if ($bestGen < 0) do={ :error ("TGQ: both state files unavailable/invalid; sending stopped: " . $readError); };
:if ($operation = "load") do={ :return $best; };
:if ($operation != "save") do={ :error "TGQ: invalid state operation"; };
:local next $value;
:local generation [:tonsec [:timestamp]];
:if ($generation <= $bestGen) do={ :set generation ($bestGen + 1); };
:set ($next->"generation") [:tostr $generation];
:local encoded [:serialize to=json options=json.no-string-conversion value=$next];
:local path ($base . "/state-" . $target . ".json");
/file set [find where name=$path] contents=$encoded;
:if ([/file get [find where name=$path] contents] != $encoded) do={ :error "TGQ: state readback mismatch"; };
:return $next;
