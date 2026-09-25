# This named entrypoint is the only scheduled sender.
:if ([/system script job print count-only as-value where script="tgq-worker"] > 1) do={ :return ""; };
:onerror err in={
    :local drain [:parse [/system script get [find where name="tgq-core"] source]];
    $drain root="tg-queue";
} do={
    /system scheduler disable [find where name="tgq-tick"];
    :log error ("TGQ: worker stopped; check queue state/configuration: " . $err);
};
