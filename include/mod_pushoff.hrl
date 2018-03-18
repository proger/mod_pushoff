-type bare_jid() :: {binary(), binary()}.
-type backend_type() :: apns | fcm.
-type backend_id() :: {binary(), backend_type()}.

-record(pushoff_registration, {bare_jid :: bare_jid(),
                               token :: binary(),
                               backend_id :: backend_id(),
                               timestamp :: erlang:timestamp()}).

-type pushoff_registration() :: #pushoff_registration{}.
