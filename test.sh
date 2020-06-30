## run this as follows:
#
# docker run -it -p 5222:5222 --entrypoint sh -v /home/proger/mod_pushoff:/home/ejabberd/mod_pushoff ejabberd/ecs:18.01 mod_pushoff/test.sh
#
set -x -e
mkdir -p .ejabberd-modules/sources
cp -R mod_pushoff .ejabberd-modules/sources
bin/ejabberdctl start
sleep 3
bin/ejabberdctl module_install mod_pushoff
bin/ejabberdctl register testuser1 localhost pass123
bin/ejabberdctl register testuser2 localhost pass123
cp mod_pushoff/ejabberd.yml conf/ejabberd.yml
bin/ejabberdctl reload_config
sh
