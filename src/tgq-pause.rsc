:local conf [:deserialize from=json options=json.no-string-conversion value=[/file get [find where name="tg-queue/config.json"] contents]];
:set ($conf->"enabled") false;
/file set [find where name="tg-queue/config.json"] contents=[:serialize to=json options=json.no-string-conversion value=$conf];
/system scheduler disable [find where name="tgq-tick"];
:log info "TGQ: sender paused; event capture remains available";
