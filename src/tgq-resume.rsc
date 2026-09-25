:local conf [:deserialize from=json options=json.no-string-conversion value=[/file get [find where name="tg-queue/config.json"] contents]];
:set ($conf->"enabled") true;
/file set [find where name="tg-queue/config.json"] contents=[:serialize to=json options=json.no-string-conversion value=$conf];
/system scheduler enable [find where name="tgq-tick"];
:log info "TGQ: sender enabled; persisted rate limits remain active";
