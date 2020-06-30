-type bare_jid() :: {binary(), binary()}.
-type backend_ref() :: apns | fcm | {apns, binary()} | {fcm, binary()}.
-type backend_id() :: {binary(), backend_ref()}.

-record(pushoff_registration, {bare_jid :: bare_jid(),
                               token :: binary(),
                               backend_id :: backend_id(),
                               timestamp :: erlang:timestamp()}).

-type pushoff_registration() :: #pushoff_registration{}.
