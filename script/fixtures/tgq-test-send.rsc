# Test transport; this source is installed only for isolated contract tests.
:local startedNs [:tostr [:tonsec [:timestamp]]];
:local path ($root . "/trace-" . $startedNs . ".json");
:local entry {"ns"=$startedNs;"payload"=$data};
/file add name=$path type=file contents=[:serialize to=json options=json.no-string-conversion value=$entry];
:local response [:deserialize from=json value=[/file get [find where name=($root . "/reply.json")] contents]];
:set ($response->"startedNs") $startedNs;
:return $response;
