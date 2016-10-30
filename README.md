# mod_pushoff

mod_pushoff relays offline messages as push notifications.

Currently supporting [Legacy APNS Binary Provider API](https://developer.apple.com/library/content/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/BinaryProviderAPI.html#//apple_ref/doc/uid/TP40008194-CH13-SW1)

## Prerequisites

* Erlang/OTP 19 or higher
* ejabberd 16.09 or higher

## Installation

```bash
git clone https://github.com/proger/mod_pushoff.git
# copy the source code folder to the module sources folder of your ejabberd
# installation (substitute ~ for the home directory of the user that runs ejabberd)
sudo cp -R mod_pushoff ~/.ejabberd-modules/sources/
# if done right ejabberdctl will list mod_pushoff as available module
ejabberdctl modules_available
# automatically compile and install mod_pushoff
ejabberdctl module_install mod_pushoff
```

## Example configuration

```yaml
modules:
  mod_offline: {}
  mod_pushoff:
    backends:
      -
        type: apns
        register_host: "localhost"
        # make sure this pem file contains only one(!) certificate + key pair
        certfile: "/etc/ssl/private/apns_example_app.pem"
        # sandbox is for testing
        gateway: "gateway.push.apple.com"
        #gateway: "gateway.sandbox.push.apple.com"
```

## Usage

Clients can register for push notifications by sending XEP-0004 adhoc requests.

These are the available adhoc commands:

* `register-push-apns`: register at an APNS backend
* `list-push-registrations`: request a list of all registrations of the requesting user
* `unregister-push`: delete the user's registrations

Example:
```xml
<iq type='set' to='localhost' id='execute'>
  <command xmlns='http://jabber.org/protocol/commands'
           node='register-push-apns'
           action='execute'>
    <x xmlns='jabber:x:data' type='submit'>
      <field
      var='token'>
        <value>r3qpHKmzZHjYKYbG7yI4fhY+DWKqFZE5ZJEM8P+lDDo=</value>
      </field>
    </x>
  </command>
</iq>
```

See [client.py](client.py) for a reference client.

## History

This module is based on [mod_push](https://github.com/royneary/mod_push).
