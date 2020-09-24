# mod_pushoff

mod_pushoff sends empty push notifications for messages in ejabberd's offline queue.

Supported backends:
- `mod_pushoff_apns_h2`: [Apple APNs over http/2](https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/sending_notification_requests_to_apns)
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
        type: mod_pushoff_apns # deprecated
        # make sure this pem file contains only one(!) certificate + key pair
        certfile: "/etc/ssl/private/apns_example_app.pem"
        gateway: "gateway.push.apple.com"
      -
        type: mod_pushoff_apns_h2
        # you can add more backends of each type by specifying backend_ref with unique names
        backend_ref: "sandbox"
        # make sure this pem file contains only one(!) certificate + key pair
        certfile: "/etc/ssl/private/apns_example_app_sandbox.pem"
        gateway: "gateway.sandbox.push.apple.com"
        topic: "com.acme.your.app" # this should be your bundle id
      -
        type: mod_pushoff_fcm
        gateway: "https://fcm.googleapis.com/fcm/send"
        api_key: "API_KEY"
      -
        type: mod_pushoff_fcm
        # you can add more backends of each type by specifying backend_ref with unique names
        backend_ref: "fcm2"
        gateway: "https://fcm.googleapis.com/fcm/send"
        api_key: "API_KEY_2"
```

## Client Applications

Clients can register for push notifications by sending XEP-0004 adhoc requests.

These are the available adhoc commands:

* `register-push-apns`: register with APNS
* `register-push-apns-h2`: register with APNS/h2
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
      <field var='token'>
        <value>urq6urq6urq6urq6urq6urq6urq6urq6urq6urq6uro=</value>
      </field>
    </x>
  </command>
</iq>
```

You need to specify a `backend_ref` field to route your subscription to a particular backend (this is always the case for `mod_pushoff_apns_h2`):

```xml
<iq type='set' to='localhost' id='randomrandomrequestid2'>
  <command xmlns='http://jabber.org/protocol/commands'
           node='register-push-apns'
           action='execute'>
    <x xmlns='jabber:x:data' type='submit'>
      <field var='backend_ref'>
        <value>sandbox</value>
      </field>
      <field var='token'>
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
