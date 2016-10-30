```erlang
ejabberd_config:get_myhosts().
ejabberd_config:get_option({modules, <<"localhost">>}, fun(F) -> F end).
rp(ets:tab2list(hooks)).


code:add_patha("/Users/vladki/src/recon/ebin"),
recon_trace:calls({mod_push, on_offline_message, '_'}, 100).

mod_push:make_payload([{now(), {xmlel,<<"message">>, [{<<"xml:lang">>,<<"en">>}, {<<"id">>,<<"prof_msg_7">>}, {<<"to">>,<<"jane@localhost">>}, {<<"type">>,<<"chat">>}], [{xmlel,<<"body">>,[],[{xmlcdata,<<"jane????">>}]}]}}]).

code:add_patha("/Users/vladki/src/recon/ebin"),
recon_trace:calls({mod_offline, store_packet, '_'}, 100).

code:add_patha("/Users/vladki/src/recon/ebin"),
recon_trace:calls({mod_offline, store_packet, fun(_) -> return_trace() end}, 100).
```
