text:
	python client.py bot@localhost bot text test1@localhost !!!FROM_BOT!!!

reg:
	python client.py bot@localhost bot register-push-apns <token>

list:
	python client.py test2@localhost test2 list-push-registrations

unreg:
	python client.py jid password unregister-push
