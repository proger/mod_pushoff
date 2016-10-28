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


<iq type='set' to='localhost' id='execute'> <command xmlns='http://jabber.org/protocol/commands' node='register-push-apns' action='execute'> <x xmlns='jabber:x:data' type='submit'> <field var='token'> <value>r3qpHKmzZHjYKYbG7yI4fhY+DWKqFZE5ZJEM8P+lDDo=</value> </field> </x> </command> </iq>

```erlang
ejabberd_config:get_myhosts().
ejabberd_config:get_option({modules, <<"localhost">>}, fun(F) -> F end).
rp(ets:tab2list(hooks)).
code:add_patha("/Users/vladki/src/recon/ebin"),
recon_trace:calls({mod_push, on_offline_message, '_'}, 100).
mod_push:make_payload([{now(), {xmlel,<<"message">>, [{<<"xml:lang">>,<<"en">>}, {<<"id">>,<<"prof_msg_7">>}, {<<"to">>,<<"jane@localhost">>}, {<<"type">>,<<"chat">>}], [{xmlel,<<"body">>,[],[{xmlcdata,<<"jane????">>}]}]}}]).
```




+++++ error in on_offline_message: {{case_clause,undefined},[{lists,'-filter/2-lc$^0/1-0-',2,[{file,"lists.erl"},{line,1286}]},{mod_push,make_payload,1,[{file,"src/mod_push.erl"},{line,756}]},{mod_push,dispatch,2,[{file,"src/mod_push.erl"},{line,270}]},{mnesia_tm,apply_fun,3,[{file,"mnesia_tm.erl"},{line,835}]},{mnesia_tm,execute_transaction,5,[{file,"mnesia_tm.erl"},{line,810}]},{mod_push,on_offline_message,3,[{file,"src/mod_push.erl"},{line,252}]},{ejabberd_hooks,safe_apply,3,[{file,"src/ejabberd_hooks.erl"},{line,382}]},{ejabberd_hooks,run1,3,[{file,"src/ejabberd_hooks.erl"},{line,329}]}]}

(ejabberd@localhost)10> mod_push:make_payload([{now(), {xmlel,<<"message">>, [{<<"xml:lang">>,<<"en">>}, {<<"id">>,<<"prof_msg_7">>}, {<<"to">>,<<"jane@localhost">>}, {<<"type">>,<<"chat">>}], [{xmlel,<<"body">>,[],[{xmlcdata,<<"jane????">>}]}]}}]).
** exception error: no case clause matching undefined
     in function  lists:'-filter/2-lc$^0/1-0-'/2 (lists.erl, line 1286)
     in call from mod_push:make_payload/1 (src/mod_push.erl, line 757)


17:43:15.071 [debug] +++++++++ mod_push_apns:init, certfile = <<"/Users/vladki/src/cryptocall/secrets/voip.pem">>
17:43:15.071 [error] gen_server apns_localhost terminated with reason: bad return value: {reply,{error,badarg},{state,<<"/Users/vladki/src/cryptocall/secrets/voip.pem">>,undefined,[],[],[],#Ref<0.0.2.10009>,#Ref<0.0.2.10010>,undefined,undefined,0}}
17:43:15.071 [error] CRASH REPORT Process apns_localhost with 0 neighbours exited with reason: bad return value: {reply,{error,badarg},{state,<<"/Users/vladki/src/cryptocall/secrets/voip.pem">>,undefined,[],[],[],#Ref<0.0.2.10009>,#Ref<0.0.2.10010>,undefined,undefined,0}} in gen_server:terminate/7 line 812
17:43:15.072 [error] Supervisor ejabberd_sup had child apns_localhost started with gen_server:start_link({local,apns_localhost}, mod_push_apns, [undefined,undefined,<<"/Users/vladki/src/cryptocall/secrets/voip.pem">>], []) at <0.424.0> exit with reason bad return value: {reply,{error,badarg},{state,<<"/Users/vladki/src/cryptocall/secrets/voip.pem">>,undefined,[],[],[],#Ref<0.0.2.10009>,#Ref<0.0.2.10010>,undefined,undefined,0}} in context child_terminated
17:43:15.072 [debug] Supervisor ejabberd_sup started gen_server:start_link({local,apns_localhost}, mod_push_apns, [undefined,undefined,<<"/Users/vladki/src/cryptocall/secrets/voip.pem">>], []) at pid <0.432.0>
