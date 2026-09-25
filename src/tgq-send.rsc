# TOKEN is substituted only during installation, from the process environment.
:local token "@@TOKEN@@";
:local received;
:local failure "";
:local attributes;
:local startedNs [:tostr [:tonsec [:timestamp]]];
:onerror err,attr in={
    :set received [/tool fetch url=("https://api.telegram.org/bot" . $token . "/sendMessage") http-method=post http-header-field="Content-Type:application/json" http-data=$data output=user as-value duration=10s idle-timeout=5s];
} do={ :set failure $err; :set attributes $attr; };
:local body ($received->"data");
:if ([:len $failure] = 0) do={
    :local response;
    :onerror e in={
        :set response [:deserialize from=json value=$body];
    } do={};
    :if (($response->"ok") = true) do={
        :return {"ok"=true;"messageId"=($response->"result"->"message_id");"startedNs"=$startedNs};
    };
};
:if ([:typeof $body] != "str") do={ :set body ($attributes->"data"); };
:local classify [:parse [/system script get [find where name="tgq-classify"] source]];
:local outcome [$classify httpCode=($attributes->"code") errorText=$failure responseData=$body responseHeaders=($attributes->"http-headers")];
:set ($outcome->"startedNs") $startedNs;
:return $outcome;
