#!/usr/bin/env nix-shell
#! nix-shell -i python -p python python2Packages.sleekxmpp
import logging
import sys
import base64

from sleekxmpp import ClientXMPP
from sleekxmpp.xmlstream.stanzabase import ET

def hextobase64(s):
    bytes = ''.join([chr(int(''.join(t), 16)) for t in zip(*[iter(s)]*2)])
    return base64.encodestring(bytes).strip()

class Jabber(ClientXMPP):
    def __init__(self, jid, password):
        ClientXMPP.__init__(self, jid, password)

        self.use_message_ids = True

        self.__server = jid.split('@')[-1]

        self.add_event_handler("session_start", self.session_start)
        self.add_event_handler("message", self.message)

        self.register_plugin('xep_0050')

    def session_start(self, event):
        self.send_presence()
        self.f(*self.fargs)

    def message(self, msg):
        print 'incoming:', msg

    def text(self, to, msg):
        self.send_message(mto=to, mbody=msg)
        self.disconnect(wait=True)

    def register_push_apns(self, token):
        self['xep_0050'].start_command(jid=self.__server,
                                       node='register-push-apns',
                                       session={
                                           'next': self._command_next,
                                           'error': self._command_error,
                                           'id': 'execute',
                                           'payload': [ET.fromstring("""
                                           <x xmlns='jabber:x:data' type='submit'>
                                           <field var='token'> <value>%s</value> </field>
                                           </x>""" % hextobase64(token))]
                                       })

    def register_push_fcm(self, token):
        self['xep_0050'].start_command(jid=self.__server,
                                       node='register-push-fcm',
                                       session={
                                           'next': self._command_next,
                                           'error': self._command_error,
                                           'id': 'execute',
                                           'payload': [ET.fromstring("""
                                           <x xmlns='jabber:x:data' type='submit'>
                                           <field var='token'> <value>%s</value> </field>
                                           </x>""" % token)]
                                       })

    def list_push_registrations(self):
        self['xep_0050'].start_command(jid=self.__server,
                                       node='list-push-registrations',
                                       session={
                                           'error': self._command_error,
                                           'next': self._command_next,
                                           'id': 'execute'
                                       })

    def unregister_push(self):
        self['xep_0050'].start_command(jid=self.__server,
                                       node='unregister-push',
                                       session={
                                           'error': self._command_error,
                                           'next': self._command_next,
                                           'id': 'execute'
                                       })

    def _command_next(self, iq, session):
        print iq
        self.disconnect()

    def _command_error(self, iq, session):
        logging.error("COMMAND: %s %s" % (iq['error']['condition'],
                                          iq['error']['text']))
        self['xep_0050'].terminate_command(session)
        self.disconnect()

def usage():
    print >>sys.stderr, 'usage: client.py jid password text jid msg'
    print >>sys.stderr, 'usage: client.py jid password register-push-apns token'
    print >>sys.stderr, 'usage: client.py jid password register-push-fcm token'
    print >>sys.stderr, 'usage: client.py jid password list-push-registrations'
    print >>sys.stderr, 'usage: client.py jid password unregister-push'
    sys.exit(1)

if __name__ == '__main__':
    logging.basicConfig(level=logging.WARNING,
                        format='%(levelname)-8s %(message)s')

    try:
        user = sys.argv[1]
        password = sys.argv[2]
        cmd = sys.argv[3].replace('-', '_')
        args = sys.argv[4:]
    except IndexError:
        usage()

    xmpp = Jabber(user, password)
    xmpp.use_ipv6 = False
    xmpp.auto_reconnect = False

    try:
        xmpp.f = getattr(xmpp, cmd)
        xmpp.fargs = args
    except AttributeError:
        usage()

    xmpp.connect(reattempt=False, use_ssl=False, use_tls=False)
    try:
        xmpp.process(block=True, send_close=False)
    except KeyboardInterrupt:
        sys.exit(1)
