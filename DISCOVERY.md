-module(mod_push_SAMPLE).
-behaviour(gen_mod).

start(Host, _Opts) ->
    ejabberd_hooks:add(mgmt_queue_add_hook, Host, ?MODULE, on_store_stanza, 50),
    ok.

%% called on hook mgmt_queue_add_hook
on_store_stanza(RerouteFlag, To, Stanza) ->
    ?DEBUG("++++++++++++ Stored Stanza for ~p: ~p", [To, Stanza]),
    F = fun() -> dispatch([{now(), Stanza}], To, false) end,
    mnesia:transaction(F).

dispatch() ->
    do_dispatch().

notify_previous_users() ->
    do_dispatch().

incoming_notification() ->
    X = fun() do_dispatch_local() end.

do_dispatch({local_reg,_,_},_,_,_) ->
    do_dispatch_local().

do_dispatch_local() ->
    cast({dispatch, XXX}).


<iq type='set' to='localhost' id='execute'>
   <command xmlns='http://jabber.org/protocol/commands' node='register-push-apns' action='execute'>
   <x xmlns='jabber:x:data' type='submit'>
   <field var='token'>
   <value>r3qpHKmzZHjYKYbG7yI4fhY+DWKqFZE5ZJEM8P+lDDo=</value>
   </field>
   <field var='device-name'><value>Home</value></field>
   </x>
   </command>
</iq>

```erlang
ejabberd_config:get_myhosts().
ejabberd_config:get_option({modules, <<"localhost">>}, fun(F) -> F end).
rp(ets:tab2list(hooks)).
code:add_patha("/Users/vladki/src/recon/ebin"),

recon_trace:calls({mod_push, on_offline_message, '_'}, 100).
```
