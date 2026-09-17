# INSTALL

sudo useradd -m splunkfwd
sudo groupadd splunkfwd


export SPLUNK_HOME="/opt/splunkforwarder"
mkdir $SPLUNK_HOME

cd $SPLUNK_HOME

# https://www.splunk.com/en_us/download/universal-forwarder.html
wget -O splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz "https://download.splunk.com/products/universalforwarder/releases/10.4.3/linux/splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz"

tar xvzf splunkforwarder-10.4.3-4174a2deda5d-linux-amd64.tgz

chown -R splunkfwd:splunkfwd $SPLUNK_HOME

sudo $SPLUNK_HOME/bin/splunk start --accept-license

# CONFIG

# Navigate to outputs.conf in $SPLUNK_HOME/etc/system/local/ to locate your Universal Forwarder configuration files.
# Key configuration files:

## inputs.conf controls how the forwarder collects data.
## outputs.conf controls how the forwarder sends data to an indexer or other forwarder.
## server.conf for connection and performance tuning.
## deploymentclient.conf for connecting to a deployment server.

sudo $SPLUNK_HOME/bin/splunk add forward-server localhost:9997

# From a shell or command prompt on the forwarder, run the command that enables that data input. 
# For example, to monitor the /var/log directory on the host with the universal forwarder installed, type in:

sudo $SPLUNK_HOME/bin/splunk add monitor /var/log

# The forwarder asks you to authenticate and begins monitoring the specified directory immediately after you log in.
