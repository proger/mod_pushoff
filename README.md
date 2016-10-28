# mod_push

mod_push implements push for ejabberd.

Currently supporting [APNS (Apple push notification service)](https://developer.apple.com/library/ios/documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/Chapters/ApplePushService.html).

## Prerequisites

* Erlang/OTP 19 or higher
* ejabberd 16.09 or higher

## Installation

```bash
git clone https://github.com/royneary/mod_push.git
# copy the source code folder to the module sources folder of your ejabberd
# installation (substitute ~ for the home directory of the user that runs ejabberd)
sudo cp -R mod_push ~/.ejabberd-modules/sources/
# if done right ejabberdctl will list mod_push as available module
ejabberdctl modules_available
# automatically compile and install mod_push
ejabberdctl module_install mod_push 
```

###XEP-0357 configuration

####User-definable options
There are user-definable config options to specify what contents should be in
a push notification. You can set default values for them in the mod_push
section:
* `include_senders`: include the jids of the last message sender and the last subscription sender (default: false)
* `include_message_count`: include the number of queued messages (default: true)
* `include_subscription_count`: include the number of queued subscription requests (default: true)
* `include_message_bodies`: include the message contents (default: false)

example:
```yaml
mod_push:
  include_senders: true
  include_message_count: true
  include_subscription_count: true
```

A user can obtain the current push configuration (the server's default configuration if he never changed it) by sending a service discovery info request to his bare jid. The response will contain a form of `FORM_TYPE` `urn:xmpp:push:options`.

```xml
<iq from='bill@example.net' to='bill@example.net/Home' id='x13' type='result'>
  <query xmlns='http://jabber.org/protocol/disco#info'>
    <x xmlns='jabber:x:data' type='result'>
      <field type='hidden' var='FORM_TYPE'><value>urn:xmpp:push:options</value></field>
      <field type='boolean' var='include-senders'><value>0</value></field>
      <field type='boolean' var='include-message-count'><value>1</value></field>
      <field type='boolean' var='include-subscription-count'><value>1</value></field>
      <field type='boolean' var='include-message-bodies'><value>0</value></field>
    </x>
    <identity category='account' type='registered'/>
    <feature var='http://jabber.org/protocol/disco#info'/>
    <feature var='urn:xmpp:push:0'/>
  </query>
</iq>
```

A user can change her configuration by including a form of `FORM_TYPE` `urn:xmpp:push:options` into the enable request. Note that this configuration is a per-user configuration that is valid for all resources. To send publish-options which are passed to the pubsub-service when publishing a notification an other form of `FORM_TYPE` `http://jabber.org/protocol/pubsub#publish-options` can be included. In this example it contains a secret a pubsub service might require as credential. mod_push's internal app server does require providing the secret obtained during registration.

```xml
<iq type='set' to='example.net' id='x42'>                                                
  <enable xmlns='urn:xmpp:push:0' jid='push.example.net' node='v9S+H8VTFgEl'>
    <x xmlns='jabber:x:data' type='submit'>
      <field var='FORM_TYPE'><value>urn:xmpp:push:options</value></field>
      <field var='include-senders'><value>0</value></field>
      <field var='include-message-count'><value>1</value></field>
      <field var='include-message-bodies'><value>0</value></field>
      <field var='include-subscription-count'><value>1</value></field>
    </x>
    <x xmlns='jabber:x:data' type='submit'>
      <field var='FORM_TYPE'><value>http://jabber.org/protocol/pubsub#publish-options</value></field>
      <field var='secret'><value>szLo+l17Q0ZQr2dShnyQiYn/stqicShK</value></field>
    </x>
  </enable>                      
</iq>
```

mod_push provides in-band configuration although not recommended by XEP-0357. In order to prevent privilege escalation as mentioned in the XEP subsequent enable requests are only allowed to disable options, not enable them. A fresh configuration is only possible after all push-enabled resources have been disabled.

The response to an enable request with configuration form will include
those values that have been accepted for the new configuration.

####restrict access
The option `access_backends` allows restricting access to the app server backends using ejabberd's acl feature. `access_backends` may be defined in the mod_push section. The default value is `all`. The example configuration only allows local XMPP users to use the app server.

###App server configuration
You can set up multiple app server backends for the different push
notification services. This is not required, your users can use external app
servers too.

####Default options
* `certfile`: the path to a certificate file (pem format, containing both certificate and private key) used as default for all backends

####Common options
* `register_host`: the app server host where users can register. Must be a subdomain of the XMPP server hostname or the XMPP server hostname itself. The advantage of choosing the XMPP server hostname is that clients don't have to guess any subdomain (XEP-0357 does not define service discovery for finding app servers).
* `pubsub_host`: the pubsub_host of the backend
* `type`: apns|gcm|mozilla|ubuntu|wns
* `app_name`: the name of the app the backend is configured for, will be send to the user when service discovery is done on the register_host; the default value is "any", but that's only a valid value for backend types that don't require developer credentials, that is ubuntu and mozilla
* `certfile`: the path to a certificate file (pem format, containing both certificate and private key) the backend will use for TLS

####APNS-specific options
* `certfile`: path to a pem file containing the developer's private key and the certificate obtained from Apple during the provisioning procedure


###Example configuration
```yaml
access:
  local_users:
    local: allow

acl:
  local:
    server: "example.net"

modules:
  mod_push:
    include_senders: true
    access_backends: local_users
    certfile: "/etc/ssl/private/example.pem"
    backends:
      -
        type: apns
        app_name: "chatninja"
        register_host: "example.net"
        pubsub_host: "push.example.net"
        certfile: "/etc/ssl/private/apns_example_app.pem"  
```

## App server usage

Clients can communicate with the app server by sending adhoc requests containing an XEP-0004 data form:
These are the available adhoc commands:
* `register-push-apns`: register at an APNS backend
* `list-push-registrations`: request a list of all registrations of the requesting user
* `unregister-push`: delete the user's registrations (all of them or those matching a given list of node names)

Example:
```xml
<iq type='set' to='example.net' id='exec1'>
  <command xmlns='http://jabber.org/protocol/commands'
           node='register-push-apns'
           action='execute'>
    <x xmlns='jabber:x:data' type='submit'>
      <field
      var='token'>
        <value>r3qpHKmzZHjYKYbG7yI4fhY+DWKqFZE5ZJEM8P+lDDo=</value>
      </field>
      <field var='device-name'><value>Home</value></field>
    </x>
  </command>
</iq>
```
There are common fields which a client has to include for every backend type and there are backend-specific fields.

### Common fields for the register commands
* `token`: the device identifier the client obtained from the push service
* `device-id`: a device identifier a client can define explicitly (the jid's resource part will be used otherwise)
* `device-name`: an optional name that will be included in the response to the list-push-registrations command

### register-push-apns fields
* `token`: the base64-encoded binary token obtained from APNS

###unregister-push fields
* `device-id`: Either device ID or a list of node IDs must be given. If none of these are in the payload, the resource of the from jid will be interpreted as device ID. If both device ID and node list are given, the device ID will be ignored and only registrations matching a node ID in the given list will be removed.
* `nodes`: a list of node names; registrations mathing one of them will be removed

### register command response
The app server returns the jid of the pubsub host a pubsub node name and a secret. The client can pass those to its XMPP server in the XEP-0357 enable request.
Example:
```xml
<iq from='example.net' to='steve@example.net/home' id='exec1' type='result'>
  <command xmlns='http://jabber.org/protocol/commands' sessionid='2015-06-15T01:05:03.380703Z' node='register-push-apns' status='completed'>
    <x xmlns='jabber:x:data' type='result'>
      <field var='jid'>
        <value>push.example.net</value>
      </field>
      <field var='node'>
        <value>2100994384</value>
      </field>
      <field var='secret'>
        <value>C46JMRFNEixmP1c5lXEUaIGKGVy-sv81</value>
      </field>
    </x>
  </command>
</iq>
```

###unregister command response
When a list of nodes was given in the request, the response contains the list of nodes of the deleted registrations.
Example:
```xml
<iq from='example.net' to='steve@example.net/home' id='exec1' type='result'>
  <command xmlns='http://jabber.org/protocol/commands' sessionid='2015-06-15T01:23:12.836386Z' node='unregister-push' status='completed'>
    <x xmlns='jabber:x:data' type='result'>
      <field type='list-multi' var='nodes'>
        <value>2100994384</value>
      </field>
    </x>
  </command>
</iq>
```

###list registrations
A list of a user's push-enabled clients can be obtained using the `list-push-registrations` command. This might be important if a push client shall be unregistered without having access to the device anymore. If a client provided a `device-name` value during registration it is included in the response along with the node name.
```xml
<iq from='example.net' to='bill@example.net/home' id='exec1' type='result'>
  <command xmlns='http://jabber.org/protocol/commands' sessionid='2015-08-13T16:10:02.489807Z' node='list-push-registrations' status='completed'>
    <x xmlns='jabber:x:data' type='result'>
      <item>
        <field var='device-name'><value>iOS device</value></field>
        <field var='node'><value>2269691389</value></field>
      </item>
      <item>
        <field var='device-name'><value>Ubuntu device</value></field>
        <field var='node'><value>2393247634</value></field>
      </item>
    </x>
  </command>
</iq>

```
