# mod_pushoff

mod_pushoff sends empty push notifications for messages in ejabberd's offline queue.

Supported backends:
- `mod_pushoff_apns`: [Apple Legacy APNS Binary Provider API](https://developer.apple.com/library/content/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/BinaryProviderAPI.html#//apple_ref/doc/uid/TP40008194-CH13-SW1)
- `mod_pushoff_fcm`: [Google Firebase Cloud Messaging HTTP Protocol](https://firebase.google.com/docs/cloud-messaging/http-server-ref)

## Prerequisites

* Erlang/OTP 19 or higher
* ejabberd 18.01

## Installation

```bash
# Substitute ~ for the home directory of the user that runs ejabberd:
cd ~/.ejabberd-modules/sources/
git clone https://github.com/proger/mod_pushoff.git
# ejabberdctl should now list mod_pushoff as available:
ejabberdctl modules_available
# Compile and install mod_pushoff:
ejabberdctl module_install mod_pushoff
```

### Upgrading

```bash
ejabberdctl module_upgrade mod_pushoff # same as uninstall + install
```

`module_upgrade` does not restart modules and thus leaves mod_pushoff stopped.
Kick it manually inside `ejabberdctl debug`:

``` erlang
l(mod_pushoff_apns).
[catch gen_mod:start_module(Host, mod_pushoff) || Host <- ejabberd_config:get_myhosts()].
```

### Operation Notes

``` erlang
% Are hooks installed? Look for mod_pushoff:
mod_pushoff:health().
% What hosts to expect?
ejabberd_config:get_myhosts().
% What is the host configuration?
ejabberd_config:get_option({modules, <<"localhost">>}, fun(F) -> F end).
% Divert logs:
lager:trace_file("/tmp/mod_pushoff.log", [{module, mod_pushoff}], debug).
lager:trace_file("/tmp/mod_pushoff.log", [{module, mod_pushoff_apns}], debug).
% Tracing (install recon first from https://github.com/ferd/recon):
code:add_patha("/Users/vladki/src/recon/ebin"),
recon_trace:calls({mod_pushoff, on_offline_message, '_'}, 100),
recon_trace:calls({jiffy, encode, fun(_) -> return_trace() end}, 100).
```

## Configuration

```yaml
modules:
  # mod_offline is a hard dependency
  mod_offline: {}
  mod_pushoff:
    backends:
      -
        type: apns
        # make sure this pem file contains only one(!) certificate + key pair
        certfile: "/etc/ssl/private/apns_example_app.pem"
        # sandbox is for testing
        gateway: "gateway.push.apple.com"
        #gateway: "gateway.sandbox.push.apple.com"
      -
        type: fcm
        gateway: "https://fcm.googleapis.com/fcm/send"
        api_key: "API_KEY"
```

## Client Applications

Clients can register for push notifications by sending XEP-0004 adhoc requests.

These are the available adhoc commands:

* `register-push-apns`: register with APNS
* `register-push-fcm`: register with Firebase
* `list-push-registrations`: request a list of all registrations
* `unregister-push`: delete all user's registrations

Example (note, `to='localhost'` contain the your user's server name):
```xml
<iq type='set' to='localhost' id='randomrandomrequestid'>
  <command xmlns='http://jabber.org/protocol/commands'
           node='register-push-apns'
           action='execute'>
    <x xmlns='jabber:x:data' type='submit'>
      <field
      var='token'>
        <value>urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6uro=</value>
      </field>
    </x>
  </command>
</iq>
```

See [client.py](client.py) for a reference client.

You can use `babababababababababababababababababababababababababababababababa` (`urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6uro=` in base64) token to test APNS.
`mod_pushoff` does not send messages to devices registered using that token.

## History

This module is based on [mod_push](https://github.com/royneary/mod_push).
