#! /bin/bash
#
# Script attached to a GoogleComputeEngine addinstance operation
# to customize a mapr cluster node off of a default mapr image.
#
# Starting Conditions  (generated by maprimagerscript if necessary)
#	The image has the correct MapR repository links in place
#	The image has ssh public key functionality enabled
#	The image has ntp installed and running (all cluster nodes see same time)
#	The image has JAVA installed
#	The core mapr software is installed (mapr-core) ... but the script
#		handles the case when it is not
#	The image may have a mapr user already initialized; the launch
#		script can override with a new user if necessary
#			NOTE: the password WILL be updated even if the user already exists !
#
#
# Metadata
#	The metadata passed in includes
#		maprhome : home directory of the software
#		mapruser : local user for mapr services (account may exist)
#		maprgroup : (defaults to "user" if not present)
#		maprpasswd : password for local user
#			NOTE: the baseline image has mapr:hadoop with password MapR
#			those will be the defaults, as with MAPR_HOME=/opt/mapr
#
#		maprimagerscript   : baseline image creation (just in case)
#		maprversion   : Version of MapR software; not used at this point
#		maprpackages  : MapR software packages to be installed
#		maprlicense   : license key (if available)
#		cluster : name of this cluster
#		zknodes : Zookeeper nodes for this cluster
#		cldbnodes : CLDB nodes for this cluster
#			NOTE: The script will exit if rational values of these 
#			are not passed in
#	
#		maprnfsserver : node to use for NFS mounting of cluster
#			Nodes with mapr-nfs as one of the packages to be installed
#			will automatically mount the localhost:/mapr.  Other client
#			nodes should have this parameter passed to set up the remote
#			mount.  This can be a server name or an HA NFS VIP.
#
#		maprmetricsserver : node on which the MySQL database with the
#			metrics instance is configured.  If this script runs on
#		    that node, the MySQL instance will be initialized.
#
#	Additionally, there some values from the Cloud Environment itself
#	that might be usefule
#		image : we could confirm that we're launched with a mapr image 
#
# Logic
#
# To Be Done
#	- Get smarter about the specification MAPR_USER.  We should require at
#	  least MAPR_USER and MAPR_PASSWD ... and not override the password of
#	  an existing account with the our default.
#	  password with a new one
#	- Get smarter about the specification of MAPR_HOME ... could look 
#	  at maprcli link and use that; remember to update conf/env.sh as needed. 
#	- Handle discovery of JAVA_HOME (currently done by prepare-mapr-image.sh
#	  as the mapr instance image is created, but we may want to change that;
#	  again, remember that conf/env.sh would need to be updated.
#	


# SECTION: Initial Sleep
# This instance may have been just started.
# Allow ample time for the network and setup processes to settle.
sleep 3

# Metadata for this installation ... pull out details that we'll need
# Google Compue Engine allows the create-instance operation to pass
# in parameters via this mechanism.
#
# Be sure to use curl -f for parameters that might be missing ... otherwise
# you'll load garbage into the shell variables !!!
# 
murl_top=http://metadata/0.1/meta-data
murl_attr="${murl_top}/attributes"

THIS_FQDN=$(curl $murl_top/hostname)
THIS_HOST=${THIS_FQDN/.*/}

MAPR_HOME=$(curl -f $murl_attr/maprhome)	# software installation directory
MAPR_HOME=${MAPR_HOME:-"/opt/mapr"}
MAPR_USER=$(curl -f $murl_attr/mapruser)
MAPR_USER=${MAPR_USER:-"mapr"}
MAPR_GROUP=$(curl -f $murl_attr/maprgroup)
MAPR_GROUP=${MAPR_GROUP:-"mapr"}
MAPR_PASSWD=$(curl -f $murl_attr/maprpasswd)
MAPR_PASSWD=${MAPR_PASSWD:-"MapR"}

MAPR_IMAGER_SCRIPT=$(curl -f $murl_attr/maprimagerscript)
MAPR_VERSION=$(curl $murl_attr/maprversion)
MAPR_PACKAGES=$(curl -f $murl_attr/maprpackages)
MAPR_LICENSE=$(curl -f $murl_attr/maprlicense)
MAPR_NFS_SERVER=$(curl -f $murl_attr/maprnfsserver)

MAPR_METRICS_DEFAULT=metrics
MAPR_METRICS_SERVER=$(curl -f $murl_attr/maprmetricsserver)
MAPR_METRICS_DB=$(curl -f $murl_attr/maprmetricsdb)
MAPR_METRICS_DB=${MAPR_METRICS_DB:-$MAPR_METRICS_DEFAULT}

MAPR_DISKS=""
MAPR_DISKS_PREREQS="fileserver"
#	if the PREREQ packages (comma-separated list) are installed, 
#	then we MUST find some disks to use and configure them properly 
#	... otherwise this provisioning script will return an error.

cluster=$(curl -f $murl_attr/cluster)
zknodes=$(curl -f $murl_attr/zknodes)  
cldbnodes=$(curl -f $murl_attr/cldbnodes)  

restore_only=$(curl -f $murl_attr/maprrestore)  
restore_only=${restore_only:-false}
restore_hostid=$(curl -f $murl_attr/maprhostid)

LOG=/tmp/configure-mapr-instance.log

# SECTION: Path
# Extend the PATH.  This shouldn't be needed after Compute leaves beta.
PATH=/sbin:/usr/sbin:$PATH

# Identify the install command, since we'll do it a lot.
# If we don't find something rational, bail out
if which dpkg &> /dev/null  ; then
	INSTALL_CMD="apt-get install -y --force-yes"
	UNINSTALL_CMD="apt-get purge -y --force-yes"
elif which rpm &> /dev/null ; then
	INSTALL_CMD="yum install -y"
	UNINSTALL_CMD="yum remove -y"
else
	echo "Unable to identify software installation command" >> $LOG
	echo "Cannot continue" >> $LOG
	exit 1
fi


# Helper utility to log the commands that are being run and
# save any errors to a log file
#	BEWARE : any error forces the script to exit
#		Since there are some some errors that we can live with,
#		this helper script is not used for all operations.
#
#	BE CAREFUL ... this function cannot handle command lines with
#	their own redirection.

c() {
    echo $* >> $LOG
    $* || {
	echo "============== $* failed at "`date` >> $LOG
	exit 1
    }
}

# Helper utility to update ENV settings in env.sh.
# Function is replicated in the prepare-mapr-image.sh script.
# Function WILL NOT override existing settings ... it looks
# for the default "#export <var>=" syntax and substitutes the new value.
# It __could__ override existing settings with a trivial change to 
# the generated awk script.
#	NOTE: I used awk because sed is too painful for substituting paths.
#
MAPR_ENV_FILE=$MAPR_HOME/conf/env.sh
update-env-sh()
{
	[ -z "${1:-}" ] && return 1
	[ -z "${2:-}" ] && return 1

	AWK_FILE=/tmp/ues$$.awk
	cat > $AWK_FILE << EOF_ues
/^#export ${1}=/ {
	getline
	print "export ${1}=$2"
}
{ print }
EOF_ues

	cp -p $MAPR_ENV_FILE ${MAPR_ENV_FILE}.spinup_save
	awk -f $AWK_FILE ${MAPR_ENV_FILE} > ${MAPR_ENV_FILE}.new
	[ $? -eq 0 ] && mv -f ${MAPR_ENV_FILE}.new ${MAPR_ENV_FILE}
}

#
# Again, this function should match that in prepare-mapr-instance.sh
#
function add_mapr_user() {
	echo Adding/configuring mapr user >> $LOG
	id $MAPR_USER &> /dev/null
	[ $? -eq 0 ] && return $? ;

	echo "useradd -u 2000 -c MapR -m -s /bin/bash" >> $LOG
	useradd -u 2000 -c "MapR" -m -s /bin/bash $MAPR_USER 2> /dev/null
	if [ $? -ne 0 ] ; then
			# Assume failure was dup uid; try with default uid assignment
		echo "useradd returned $?; trying auto-generated uid" >> $LOG
		useradd -c "MapR" -m -s /bin/bash $MAPR_USER
	fi

	if [ $? -ne 0 ] ; then
		echo "Failed to create new user $MAPR_USER {error code $?}"
		return 1
	else
		passwd $MAPR_USER << passwdEOF > /dev/null
$MAPR_PASSWD
$MAPR_PASSWD
passwdEOF

	fi

		# Create sshkey for $MAPR_USER (must be done AS MAPR_USER)
	su $MAPR_USER -c "mkdir ~${MAPR_USER}/.ssh ; chmod 700 ~${MAPR_USER}/.ssh"
	su $MAPR_USER -c "ssh-keygen -q -t rsa -f ~${MAPR_USER}/.ssh/id_rsa -P '' "
	su $MAPR_USER -c "cp -p ~${MAPR_USER}/.ssh/id_rsa ~${MAPR_USER}/.ssh/id_launch"
	su $MAPR_USER -c "cp -p ~${MAPR_USER}/.ssh/id_rsa.pub ~${MAPR_USER}/.ssh/authorized_keys"
	su $MAPR_USER -c "chmod 600 ~${MAPR_USER}/.ssh/authorized_keys"
		
		# TBD : copy the key-pair used to launch the instance directly
		# into the mapr account to simplify connection from the
		# launch client.
	MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
#	LAUNCHER_SSH_KEY_FILE=$MAPR_USER_DIR/.ssh/id_launcher.pub
#	curl ${murl_top}/public-keys/0/openssh-key > $LAUNCHER_SSH_KEY_FILE
#	if [ $? -eq 0 ] ; then
#		cat $LAUNCHER_SSH_KEY_FILE >> $MAPR_USER_DIR/.ssh/authorized_keys
#	fi

		# Enhance the login with rational stuff
    cat >> $MAPR_USER_DIR/.bashrc << EOF_bashrc

CDPATH=.:$HOME
export CDPATH

# PATH updates based on settings in MapR env file
MAPR_HOME=${MAPR_HOME:-/opt/mapr}
MAPR_ENV=\${MAPR_HOME}/conf/env.sh
[ -f \${MAPR_ENV} ] && . \${MAPR_ENV} 
[ -n "\${JAVA_HOME}:-" ] && PATH=\$PATH:\$JAVA_HOME/bin
[ -n "\${MAPR_HOME}:-" ] && PATH=\$PATH:\$MAPR_HOME/bin

set -o vi

EOF_bashrc

	return 0
}

# If there's no mapr software installed, use imager script
# to do our initial setup.  Exit on failure
prepare_instance() {
	if [ ! -d ${MAPR_HOME} ] ; then
		if [ -z "${MAPR_IMAGER_SCRIPT}" ] ; then
			echo "ERROR: MapR software not found on image ..." >> $LOG
			echo "        and no imager script was provided.  Exiting !!!" >> $LOG
			exit 1
		fi
	
		echo "Executing imager script;" >> $LOG
		echo "    see /tmp/prepare-mapr-image.log for details" >> $LOG
		MAPR_IMAGER_FILE=/tmp/mapr_imager.sh
		curl $murl_attr/maprimagerscript > $MAPR_IMAGER_FILE
		chmod a+x $MAPR_IMAGER_FILE
		$MAPR_IMAGER_FILE
		return $?
	fi
	
	return 0
}


# Takes the packaged defined by MAPR_PACKAGES and makes sure
# that those (and only those) pieces of MapR software are installed.
# The idea is that a single image with EXTRA packages could still 
# be used, and the extraneous packages would just be removed.
#	NOTE: We expect MAPR_PACKAGES to be short-hand (cldb, nfs, etc.)
#		instead of the full "mapr-cldb" name.  But the logic handles
#		all cases cleanly just in case.
# 	NOTE: We're careful not to remove mapr-core or -internal packages.
#
#	Input: MAPR_PACKAGES  (global)
#
install_mapr_packages() {
	#
	#  If no MapR software packages are specified, BAIL OUT NOW !!!
	#
	if [ -z "${MAPR_PACKAGES:-}" ] ; then
		echo "No MapR software specified ... terminating script" >> $LOG
		return 1
	fi

	if which dpkg &> /dev/null ; then
		MAPR_INSTALLED=`dpkg --list mapr-* | grep ^ii | awk '{print $2}'`
	else
		MAPR_INSTALLED=`rpm -q --all --qf "%{NAME}\n" | grep ^mapr `
	fi
	MAPR_REQUIRED=""
	for pkg in `echo ${MAPR_PACKAGES//,/ }`
	do
		MAPR_REQUIRED="$MAPR_REQUIRED mapr-${pkg#mapr-}"
	done

		# Be careful about removing -core or -internal packages
		# Never remove "core", and remove "-internal" only if we 
		# remove the parent as well (that logic is not yet implemented).
	MAPR_TO_REMOVE=""
	for pkg in $MAPR_INSTALLED
	do
		if [ ${pkg%-core} = $pkg  -a  ${pkg%-internal} = $pkg ] ; then
			echo $MAPR_REQUIRED | grep -q $pkg
			[ $? -ne 0 ] && MAPR_TO_REMOVE="$MAPR_TO_REMOVE $pkg"
		fi
	done

	MAPR_TO_INSTALL=""
	for pkg in $MAPR_REQUIRED
	do
		echo $MAPR_INSTALLED | grep -q $pkg
		[ $? -ne 0 ] && MAPR_TO_INSTALL="$MAPR_TO_INSTALL $pkg"
	done

	if [ -n "${MAPR_TO_REMOVE}" ] ; then
		c $UNINSTALL_CMD $MAPR_TO_REMOVE
	fi

	if [ -n "${MAPR_TO_INSTALL}" ] ; then
		c $INSTALL_CMD $MAPR_TO_INSTALL
	fi

	return 0
}

# Logic to search for unused disks and initialize the MAPR_DISKS
# parameter for use by the disksetup utility.
# As a first approximation, we simply look for any disks without
# a partition table and use them.
# This logic should be fine for any reasonable number of spindles.
#
find_mapr_disks() {
	MAPR_DISKS=""

	for d in `fdisk -l 2>/dev/null | grep -e "^Disk .* bytes$" | awk '{print $2}' `
	do
		dev=${d%:}

		cfdisk -P s $dev &> /dev/null 
        [ $? -eq 0 ] && continue

        mount | grep -q -w $dev
        [ $? -eq 0 ] && continue

        swapon -s | grep -q -w $dev
        [ $? -eq 0 ] && continue

        if which pvdisplay &> /dev/null; then
            pvdisplay $dev &> /dev/null
            [ $? -eq 0 ] && continue
        fi

        disks="$disks $dev"
	done

	MAPR_DISKS="$disks"
	export MAPR_DISKS
}

#
# For most installations, we'll just look for unused disks
# Optionally, the MAPR_DISKS setting can be passed in as 
# meta data to override the search.
#
provision_mapr_disks() {
		# If we're restoring the node, regenerate the disktab
		# if necessary and go on.

	diskfile=/tmp/MapR.disks
	disktab=$MAPR_HOME/conf/disktab
	rm -f $diskfile
	[ -z "${MAPR_DISKS:-}" ] && find_mapr_disks
	if [ -n "$MAPR_DISKS" ] ; then
		for d in $MAPR_DISKS ; do echo $d ; done >> $diskfile
		if [ "${restore_only}" = "true" ] ; then
			if [ ! -f $disktab ] ; then
				echo $MAPR_HOME/server/disksetup -G $diskfile
				$MAPR_HOME/server/disksetup -G $diskfile > $disktab

					# There is a bug in disksetup that does not set
					# the proper permissions on the device files unless
					# "-F" is used; we have to do that by hand here
				chmod g+rw $MAPR_DISKS
				chgrp $MAPR_GROUP $MAPR_DISKS
			fi
		else
			c $MAPR_HOME/server/disksetup -F $diskfile
		fi
	else
		echo "No unused disks found" >> $LOG
		if [ -n "$MAPR_DISKS_PREREQS" ] ; then
			for pkg in `echo ${MAPR_DISKS_PREREQS//,/ }`
			do
				echo $MAPR_PACKAGES | grep -q $pkg
				if [ $? -eq 0 ] ; then 
					echo "MapR package{s} $MAPR_DISKS_PREREQS installed" >> $LOG
					echo "Those packages require physical disks for MFS" >> $LOG
					echo "Exiting startup script" >> $LOG
					exit 1
				fi
			done
		fi
	fi
}


# Several identity files may need to be updated if this
# instance was created from an image file.  Alternatively,
# nodes being redeployed to the same cluster SHOULD NOT 
# rebuild those identity files.
configure_host_identity() {
		#
		# hostid is created when mapr-core is installed, which
		# could have been from the image file used to create
		# this instance.
		#
	if [ "${restore_only}" = "true" ] ; then
		if [ -n "${restore_hostid}" ] ; then
			echo $restore_hostid > $MAPR_HOME/hostid
			chmod 444 $MAPR_HOME/hostid
		fi
	else
		HOSTID=$($MAPR_HOME/server/mruuidgen)
		echo $HOSTID > $MAPR_HOME/hostid
		echo $HOSTID > $MAPR_HOME/conf/hostid.$$
		chmod 444 $MAPR_HOME/hostid
	fi

	HOSTNAME_FILE="$MAPR_HOME/hostname"
	if [ ! -f $HOSTNAME_FILE ]; then
		/bin/hostname --fqdn > $HOSTNAME_FILE
		chown $MAPR_USER:$MAPR_GROUP $HOSTNAME_FILE
		if [ $? -ne 0 ]; then
			rm -f $HOSTNAME_FILE
			echo "Cannot find valid hostname. Please check your DNS settings" >> $LOG
		fi
	fi
}


# Initializes MySQL database if necessary.
#
#	Input: MAPR_METRICS_SERVER  (global)
#			MAPR_METRICS_DB		(global)
#			MAPR_METRICS_DEFAULT	(global)
#			MAPR_PACKAGES		(global)
#
# NOTE: It is simpler to use the hostname for mysql connections
#	even on the host running the mysql instance (probably because 
#	of mysql's strange handling of "localhost" when validating
#	login privileges).
#
# NOTE: The CentOS flavor of mapr-metrics depends on soci-mysql, which
#	is NOT in the base distro.  If the Extra Packages for Enterprise Linux
#	(epel) repository is not configured, we won't waste time with this
#	installation.
#
# TBD : we should support the database files being within MFS, which
#		will make it easier to "migrate" a node.  Won't do that work yet.
#       

configure_mapr_metrics() {
	[ -z "${MAPR_METRICS_SERVER:-}" ] && return 0
	[ -z "${MAPR_METRICS_DB:-}" ] && return 0

	if [ which yum &> /dev/null ] ; then
		yum list soci-mysql > /dev/null 2> /dev/null
		if [ $? -ne 0 ] ; then 
			echo "Skipping metrics configuration; missing dependencies" >> $LOG
			return 0
		fi
	fi

	echo "Configuring task metrics connection" >> $LOG

	# If the metrics server is specified, let's just install
	# the metrics package anyway (even if it wasn't in our list
	echo $MAPR_PACKAGES | grep -q -w metrics 
	if [ $? -ne 0 ] ; then
		$INSTALL_CMD mapr-metrics
	fi

	c $MAPR_HOME/server/configure.sh -R -d ${MAPR_METRICS_SERVER}:3306 \
		-du $MAPR_USER -dp $MAPR_PASSWD -ds $MAPR_METRICS_DB

		# Additional configuration required on WebServer nodes
		# Need to specify the connection metrics in the hibernate CFG file
	echo $MAPR_PACKAGES | grep -q -w webserver 
	if [ $? -eq 0 ] ; then
		HIBCFG=$MAPR_HOME/conf/hibernate.cfg.xml
			# TO BE DONE ... fix database properties
	fi
}


# Simple script to do any config file customization prior to 
# program launch
configure_mapr_services() {
	echo "Updating configuration for MapR services" >> $LOG

# Additional customizations ... to be customized based
# on instane type and other deployment details.   This is only
# necessary if the default configuration files from configure.sh
# are sub-optimal for Cloud deployments.  Some examples might be:
#	
# 	give MFS more memory -- only on slaves, not on masters
#sed -i 's/service.command.mfs.heapsize.percent=.*$/service.command.mfs.heapsize.percent=35/'
#
#	give CLDB more threads 
# sed -i 's/cldb.numthreads=10/cldb.numthreads=40/' $MAPR_HOME/conf/cldb.conf
}

#
#  Wait until DNS can find all the zookeeper nodes
#	TBD: put a timeout ont this ... it's not a good design to wait forever
#
function resolve_zknodes() {
	echo "WAITING FOR DNS RESOLUTION of zookeeper nodes {$zknodes}" >> $LOG
	zkready=0
	while [ $zkready -eq 0 ]
	do
		zkready=1
		echo testing DNS resolution for zknodes
		for i in ${zknodes//,/ }
		do
			[ -z "$(dig -t a +search +short $i)" ] && zkready=0
		done

		echo zkready is $zkready
		[ $zkready -eq 0 ] && sleep 5
	done
	echo "DNS has resolved all zknodes {$zknodes}" >> $LOG
	return 0
}


# Enable NFS mount point for cluster
#	localhost:/mapr for hosts running mapr-nfs service
#	$MAPR_NFS_SERVER:/mapr for other hosts
#
# NOTE: By this time, all necessary NFS packages have been installed !!!
#		  but may need to be restarted (CentOS images have this issue)
# NOTE: we assume that localhost: trumps any MAPR_NFS_SERVER setting
# NOTE: we'll do a cluster-specific mount, since we'll assume we're 
#       provisioning only one cluster.
#

MAPR_FSMOUNT=/mapr
MAPR_FSTAB=$MAPR_HOME/conf/mapr_fstab
SYSTEM_FSTAB=/etc/fstab

configure_mapr_nfs() {
	if [ -f $MAPR_HOME/roles/nfs ] ; then
		MAPR_NFS_SERVER=localhost
		MAPR_NFS_OPTIONS="hard,intr,nolock"
	else
		MAPR_NFS_OPTIONS="hard,intr"
	fi

		# Bail out now if there's not NFS server (either local or remote)
	[ -z "${MAPR_NFS_SERVER:-}" ] && return 0

		# For RedHat distros, we need to start up NFS services
	if which rpm &> /dev/null; then
		/etc/init.d/rpcbind restart
		/etc/init.d/nfslock restart
	fi

	echo "Mounting ${MAPR_NFS_SERVER}:/mapr/$cluster to $MAPR_FSMOUNT" >> $LOG
	mkdir $MAPR_FSMOUNT

		# I need to be smarter here about the "restore_only" case
	if [ $MAPR_NFS_SERVER = "localhost" ] ; then
		echo "${MAPR_NFS_SERVER}:/mapr/$cluster	$MAPR_FSMOUNT	$MAPR_NFS_OPTIONS" >> $MAPR_FSTAB

		$MAPR_HOME/initscripts/mapr-nfsserver restart
	else
		echo "${MAPR_NFS_SERVER}:/mapr/$cluster	$MAPR_FSMOUNT	nfs	$MAPR_NFS_OPTIONS	0	0" >> $SYSTEM_FSTAB
		mount $MAPR_FSMOUNT
	fi
}

#
# Isolate the creation of the metrics database itself until
# LATE in the installation process, so that we can use the
# cluster file system itself if we'd like.  Default to 
# using that resource, and fall back to local storage if
# the creation of the volume fails.
#
#	CAREFUL : this routine uses the MAPR_FSMOUNT variable defined just
#	above ... so don't rearrange this code without moving that as well
#
create_metrics_db() {
	[ $MAPR_METRICS_SERVER != $THIS_HOST ] && return

	echo "Creating MapR metrics database" >> $LOG

		# Install MySQL, update MySQL config and restart the server
	MYSQL_OK=1
	if  which dpkg &> /dev/null ; then
		apt-get install -y mysql-server mysql-client

		MYCNF=/etc/mysql/my.cnf
		sed -e "s/^bind-address.* 127.0.0.1$/bind-address = 0.0.0.0/g" \
			-i".localhost" $MYCNF 

		update-rc.d -f mysql enable
		service mysql stop
		MYSQL_OK=$?
	elif which rpm &> /dev/null  ; then 
		yum install -y mysql-server mysql

		MYCNF=/etc/my.cnf
		sed -e "s/^bind-address.* 127.0.0.1$/bind-address = 0.0.0.0/g" \
			-i".localhost" $MYCNF 

		chkconfig mysqld on
		service mysqld stop
		MYSQL_OK=$?
	fi

	if [ $MYSQL_OK -ne 0 ] ; then
		echo "Failed to install/configure MySQL" >> $LOG
		echo "Unable to create MapR metrics database" >> $LOG
		return 1
	fi

	echo "Initializing metrics database ($MAPR_METRICS_DB)" >> $LOG

		# If we have NFS connectivity to the cluster, then we can
		# create a MapRFS volume for the database and point there.
		# If the NFS mount point isn't visible, just leave the 
		# data directory as is and warn the user.
	if [ -f $MAPR_HOME/roles/nfs  -o  -n "${MAPR_NFS_SERVER}" ] ; then
		MYSQL_DATA_DIR=/var/mapr/mysql

		maprcli volume create -name mapr.mysql -user mysql:fc \
			-path $MYSQL_DATA_DIR -createparent true -topology / 
		maprcli acl edit -type volume -name mapr.mysql -user mysql:fc
		if [ $? -eq 0 ] ; then
				# Now we'll access the DATA_DIR via an NFS mount
			MYSQL_DATA_DIR=${MAPR_FSMOUNT}${MYSQL_DATA_DIR}

				# Short wait for NFS client to see newly created volume
			sleep 5
			find `dirname $MYSQL_DATA_DIR` &> /dev/null
			if [ -d ${MYSQL_DATA_DIR} ] ; then
				chown --reference=/var/lib/mysql $MYSQL_DATA_DIR

			    sedArg="`echo "$MYSQL_DATA_DIR" | sed -e 's/\//\\\\\//g'`"
				sed -e "s/^datadir[ 	=].*$/datadir = ${sedArg}/g" \
					-i".localdata" $MYCNF 

					# On Ubuntu, AppArmor gets in the way of
					# mysqld writing to the NFS directory; We'll 
					# unload the configuration here so we can safely
					# update the aliases file to enable the proper
					# access.  The profile will be reloaded when mysql 
					# is launched below
				if [ -f /etc/apparmor.d/usr.sbin.mysqld ] ; then
					echo "alias /var/lib/mysql/ -> ${MYSQL_DATA_DIR}/," >> \
						/etc/apparmor.d/tunables/alias

					apparmor_parser -R /etc/apparmor.d/usr.sbin.mysqld
				fi

					# Remember to initialize the new data directory !!!
					# If this fails, go back to the default datadir
				mysql_install_db
				if [ $? -ne 0 ] ; then
					echo "Failed to initialize MapRFS datadir ($MYSQL_DATA_DIR}" >> $LOG
					echo "Restoring localdata configuration" >> $LOG
					cp -p ${MYCNF}.localdata ${MYCNF}
				fi
			fi
		fi
	fi

		# Startup MySQL so the rest of this stuff will work
	[ -x /etc/init.d/mysql ]   &&  /etc/init.d/mysql  start
	[ -x /etc/init.d/mysqld ]  &&  /etc/init.d/mysqld start

		# At this point, we can customize the MySQL installation 
		# as needed.   For now, we'll just enable multiple connections
		# and create the database instance we need.
		#	WARNING: don't mess with the single quotes !!!
	mysql << metrics_EOF

create user '$MAPR_USER' identified by '$MAPR_PASSWD' ;
create user '$MAPR_USER'@'localhost' identified by '$MAPR_PASSWD' ;
grant all on $MAPR_METRICS_DB.* to '$MAPR_USER'@'%' ;
grant all on $MAPR_METRICS_DB.* to '$MAPR_USER'@'localhost' ;
quit

metrics_EOF

		# Update setup.sql in place, since we've picked
		# a new metrics db name.
	if [ !  $MAPR_METRICS_DB = $MAPR_METRICS_DEFAULT ] ; then
		sed -e "s/ $MAPR_METRICS_DEFAULT/ $MAPR_METRICS_DB/g" \
			-i".default" $MAPR_HOME/bin/setup.sql 
	fi
	mysql -e "source $MAPR_HOME/bin/setup.sql"
}


function enable_mapr_services() 
{
	echo Enabling  MapR services >> $LOG

	if which update-rc.d &> /dev/null; then
		c update-rc.d -f mapr-warden enable
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c update-rc.d -f mapr-zookeeper enable
	elif which chkconfig &> /dev/null; then
		c chkconfig mapr-warden on
		[ -f $MAPR_HOME/roles/zookeeper ] && \
			c chkconfig mapr-zookeeper on
	fi
}

function start_mapr_services() {
	echo "Starting MapR services" >> $LOG

	if [ -f $MAPR_HOME/roles/zookeeper ] ; then
		if [ "${restore_only}" = "true" ] ; then
			echo "Postponing zookeeper startup until zkdata properly restored" >> $LOG
		else
			c service mapr-zookeeper start
		fi
	fi
	c service mapr-warden start

	#
	# wait till "/" is available (maximum 10 minutes ... then error)
	#
	HDFS_ONLINE=0
	echo "Waiting for hadoop file system to come on line" >> $LOG
	i=0
	while [ $i -lt 600 ] 
	do
		hadoop fs -stat /
		if [ $? -eq 0 ] ; then
			echo " ... success !!!" >> $LOG
			HDFS_ONLINE=1
			i=9999
			break
		fi

		sleep 3
		i=$[i+3]
	done

	if [ ${HDFS_ONLINE} -eq 0 ] ; then
		echo "ERROR: MapR File Services did not come on-line" >> $LOG
		return 1
	else
		return 0
	fi

}

# Enable FullControl for MAPR_USER and install a license (if we have one)
#	Be careful with license installation ... no sense in installing 
#	the license 7 times (and getting an error each time). We only install
#	the license if the installed licenses DO NOT include the hash for
#	this license.
#
# NOTE: we could be smart and only do this for CLDB nodes, since it
#	doesn't make sense at this time to pass the license key in to the
#	slave nodes.
#
# NOTE: This is a race condition (since the script will be running on
#	multiple servers at the same time).  Thus, we can't afford to use
#	the "c" function, which will exit on error (and we'll get an error if
#	we're one millisecond late with the addlicense call).
#
finalize_mapr_cluster() {
	[ "${restore_only}" = "true" ] && return 

		# Allow MAPR_USER to manage cluster
	c maprcli acl edit -type cluster -user ${MAPR_USER}:fc

	if [ ${#MAPR_LICENSE} -gt 0 ] ; then
		MAPR_LICENSE_FILE=/tmp/mapr.license
		echo $MAPR_LICENSE > $MAPR_LICENSE_FILE

		license_installed=0
		for lic in `maprcli license list | grep hash: | cut -d" " -f 2 | tr -d "\""`
		do
			grep -q $lic $MAPR_LICENSE_FILE
			[ $? -eq 0 ] && license_installed=1
		done

		if [ $license_installed -eq 0 ] ; then 
			echo "maprcli license add -license $MAPR_LICENSE_FILE -is_file true" >> $LOG
			maprcli license add -license $MAPR_LICENSE_FILE -is_file true
				# As of now, maprcli does not print an error if
				# the license already exists ... so there won't be any
				# strange messages in $LOG
		fi
	else
		echo $MAPR_PACKAGES | grep -q cldb
		if [ $? -eq 0 ] ; then
			echo "No license provided ... please install one at your earliest convenience" >> $LOG
		fi
	fi

		#
		# Enable centralized logging
		#	need to wait for mapr.logs to exist before we can
		#	create our entry point
		#
	VAR_ONLINE=0
	echo "Waiting for mapr.var volume to come on line" >> $LOG
	i=0
	while [ $i -lt 300 ] 
	do
		maprcli volume info -name mapr.var &> /dev/null
		if [ $? -eq 0 ] ; then
			echo " ... success !!!" >> $LOG
			VAR_ONLINE=1
			i=9999
			break
		fi

		sleep 3
		i=$[i+3]
	done

	if [ ${VAR_ONLINE} -eq 0 ] ; then
		echo "WARNING: mapr.var volume did not come on-line" >> $LOG
	else
			# Probably don't need the "-createparent true" option,
			# since mapr.logs should be mounted to /var/mapr ...
			# but just in case it isn't ...
		echo "Creating volume for centralized logs" >> $LOG
		maprcli volume create -name mapr.logs \
			-path /var/mapr/logs -createparent true -topology / 

			# If the volume exists (either because we created it
			# or another node in the cluster already did it for us,
			# enable access and then execute the link-logs for this node
		maprcli volume info -name mapr.logs &> /dev/null
		if [ $? -eq 0 ] ; then
			maprcli acl edit -type volume -name mapr.logs -user ${MAPR_USER}:fc
			maprcli job linklogs -jobid "job_*" -todir /var/mapr/logs
		fi
	fi
}


function main()
{
	echo "Instance initialization started at "`date` >> $LOG

	prepare_instance
	if [ $? -ne 0 ] ; then
		echo "incomplete system initialization" >> $LOG
		echo "$0 script exiting with error at "`date` >> $LOG
		exit 1
	fi

	#
	# Install the software first ... that will give other nodes
	# the time to come up.
	#
	install_mapr_packages
	[ $? -ne 0 ] && return $?

	#
	#  If no MapR cluster definition is given, exit
	#
	if [ -z "${cluster}" -o  -z "${zknodes}"  -o  -z "${cldbnodes}" ] ; then
		echo "Insufficient specification for MapR cluster ... terminating script" >> $LOG
		exit 1
	fi

	add_mapr_user

	configure_host_identity 

	c $MAPR_HOME/server/configure.sh -N $cluster -C $cldbnodes -Z $zknodes \
		-u $MAPR_USER -g $MAPR_GROUP --isvm 

	configure_mapr_metrics 
	configure_mapr_services

	provision_mapr_disks

	enable_mapr_services

	resolve_zknodes
	if [ $? -eq 0 ] ; then
		start_mapr_services
		[ $? -ne 0 ] && return $?

		finalize_mapr_cluster
		configure_mapr_nfs

		create_metrics_db
	fi

	echo "Instance initialization completed at "`date` >> $LOG
	echo INSTANCE READY >> $LOG
	return 0
}


main
exitCode=$?

# Save of the install log to ~${MAPR_USER}; some cloud images
# use AMI's that automatically clear /tmp with every reboot
MAPR_USER_DIR=`eval "echo ~${MAPR_USER}"`
if [ -n "${MAPR_USER_DIR}"  -a  -d ${MAPR_USER_DIR} ] ; then
		cp $LOG $MAPR_USER_DIR
		chmod a-w ${MAPR_USER_DIR}/`basename $LOG`
		chown ${MAPR_USER}:`id -gn ${MAPR_USER}` \
			${MAPR_USER_DIR}/`basename $LOG`
fi

exit $exitCode

