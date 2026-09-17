# INSTALL
# https://help.splunk.com/en/splunk-cloud-platform/forward-and-process-data/universal-forwarder-manual/9.1/install-the-universal-forwarder/install-a-nix-universal-forwarder#bfa92018_7238_476c_8351_2dd1ee65ef8c--en__Install_the_universal_forwarder_on_Linux

sudo useradd -m splunkfwd
sudo groupadd splunkfwd


export SPLUNK_HOME="/opt/splunkforwarder"
mkdir $SPLUNK_HOME

cd $SPLUNK_HOME

# DOWNLOAD
# https://www.splunk.com/en_us/download/universal-forwarder.html
wget -O splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz "https://download.splunk.com/products/universalforwarder/releases/10.4.3/linux/splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz"

tar xvzf splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz

chown -R splunkfwd:splunkfwd $SPLUNK_HOME

sudo /opt/splunkforwarder/bin/splunk start --accept-license

# CONFIG
# https://help.splunk.com/en/splunk-cloud-platform/forward-and-process-data/universal-forwarder-manual/10.4/configure-the-universal-forwarder/configure-the-universal-forwarder-using-configuration-files

# Navigate to outputs.conf in $SPLUNK_HOME/etc/system/local/ to locate your Universal Forwarder configuration files.
# Key configuration files:

## inputs.conf controls how the forwarder collects data.
## outputs.conf controls how the forwarder sends data to an indexer or other forwarder.
## server.conf for connection and performance tuning.
## deploymentclient.conf for connecting to a deployment server.

sudo $SPLUNK_HOME/bin/splunk add forward-server localhost:9997

# From a shell or command prompt on the forwarder, run the command that enables that data input. 
# For example, to monitor the /var/log directory on the host with the universal forwarder installed, type in:


### CORRECOES:

##### USUARIO E SENHA 

[ec2-user@vm-fiap splunk]$ ls
README.md                config_node_otel.sh                  debug_config_docker_otel.sh  run-demo-bank.sh
SIGNALFLOW-DASHBOARD.md  config_smartagent_docker.sh          diagnostico-otel.sh          splunkforwarder
carga-locust.sh          dashboard_FIAP_Bank_Containers.json  docker-run-demo-bank.sh      splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz
config_docker_otel.sh    dashboard_FIAP_v2.json               old_config_docker_otel.sh
config_log_splunkfwd.sh  dashboard_TESTE_minimo.json          remove-demo.sh
[ec2-user@vm-fiap splunk]$ ./splunkforwarder/bin/splunk  start --accept-license
Warning: Attempting to revert the SPLUNK_HOME ownership
Warning: Executing "chown -R ec2-user:ec2-user /home/ec2-user/splunk/splunkforwarder"

This appears to be your first time running this version of Splunk.

Splunk software must create an administrator account during startup. Otherwise, you cannot log in.
Create credentials for the administrator account.
Characters do not appear on the screen when you type in credentials.

Please enter an administrator username: admin
Password must contain at least:
   * 8 total printable ASCII character(s).
Please enter a new password: 
Please confirm new password: 
Creating unit file...
Current splunk is running as non root, which cannot operate systemd unit files.
Please create it manually by 'sudo splunk enable boot-start' later.
Failed to create the unit file. Please do it manually later.


Splunk> CSI: Logfiles.

Checking prerequisites...
        Checking mgmt port [8089]: open
                Creating: /home/ec2-user/splunk/splunkforwarder/var/lib/splunk
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/appserver/i18n
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/appserver/modules/static/css
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/upload
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/search_telemetry
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/search_log
                Creating: /home/ec2-user/splunk/splunkforwarder/var/spool/splunk
                Creating: /home/ec2-user/splunk/splunkforwarder/var/spool/dirmoncache
                Creating: /home/ec2-user/splunk/splunkforwarder/var/lib/splunk/authDb
                Creating: /home/ec2-user/splunk/splunkforwarder/var/lib/splunk/hashDb
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/collect
                Creating: /home/ec2-user/splunk/splunkforwarder/var/run/splunk/sessions
New certs have been generated in '/home/ec2-user/splunk/splunkforwarder/etc/auth'.
New certs have been generated in '/home/ec2-user/splunk/splunkforwarder/etc/auth'.
        Checking conf files for problems...
        Done
        Checking default conf files for edits...
        Validating installed files against hashes from '/home/ec2-user/splunk/splunkforwarder/splunkforwarder-10.4.3-4174a2deda5d-linux-amd64-manifest'
        All installed files intact.
        Done
All preliminary checks passed.

Starting splunk server daemon (splunkd)...  
Done
                                   

sudo $SPLUNK_HOME/bin/splunk add monitor /var/log

# The forwarder asks you to authenticate and begins monitoring the specified directory immediately after you log in.





########## CONFIGURAR LOGIN E SENHA AQUI TB


[ec2-user@vm-fiap splunk]$ ./splunkforwarder/bin/splunk  add forward-server localhost:9997
Warning: Attempting to revert the SPLUNK_HOME ownership
Warning: Executing "chown -R ec2-user:ec2-user /home/ec2-user/splunk/splunkforwarder"
Splunk username: admin
Password: 
Added forwarding to: localhost:9997.
[ec2-user@vm-fiap splunk]$ 


########## AQUI FOI


[ec2-user@vm-fiap splunk]$ ./splunkforwarder/bin/splunk add monitor /var/log
Warning: Attempting to revert the SPLUNK_HOME ownership
Warning: Executing "chown -R ec2-user:ec2-user /home/ec2-user/splunk/splunkforwarder"
Added monitor of '/var/log'.
[ec2-user@vm-fiap splunk]$ 
