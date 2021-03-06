#! /bin/bash
#
# 'fix-ec2.sh' repairs a cluster when 1 or more ec2 instances have stopped (usually for no
# apparent reason).
# Fixes the following:
#   - restarts the stopped ec2 node(s) and captures their new ip addresses.
#   - updates /etc/hosts on *every* instance, in both the aws and gce cluster, with new ips.
#   - waits for 'gluster peer status' to see the new ips.
#   - remounts the gluster volume on the previously stopped aws instances.
#
# Usage:
#	fix-ec2.sh <instance-filter> [gluster-vol-name]
# Args:
#	<filter> (required) name or pattern uniquely identifying the target instance(s)
#		 across all providers.
#	<vol>    (optional) gluster volume name (no leading "/").
#		 If there is more than one gluster vol then this value must be supplied.
# Example:
#	fix-ec2.sh jcope gv0
# Assumptions:
#	- stopped instances are aws ec2.


# Start aws ec2 instances based on passed-in ids.
function start_aws_instances() {
	local ids="$@"
	local id; local errcnt=0

	echo "*** starting ec2 instances based on ids: $ids..." >&2
	for id in $ids; do
		aws ec2 start-instances --instance-id $id
		if (( $? != 0 )); then
			echo "error: failed to start ec2 instance $id" >&2
			((errcnt++))
		fi
	done
	(( errcnt > 0 )) && return 1
	echo "*** success" >&2; echo >&2
	return 0
}

# Set a global var to a list of aws ec2 external ip addresses.
# Note: despite doc to the contrary, a list of ids cannot be passed to the aws ec2 cmd below.
function get_ec2_ips() {
	local ids="$@"
	local query='Reservations[*].Instances[*].[PublicIpAddress]'

	echo "*** getting new ips for ec2 instances based on ids: $ids..." >&2
	local id; local ip
	for id in $ids; do
		ip="$(aws ec2 --output text describe-instances --instance-ids $id --query $query)"
		if (( $? != 0 )); then
			echo "error: failed to get ec2 instance's external ips for id $id" >&2
			return 1
		fi
		if [[ -z "$ip" ]]; then
			echo "error: ec2 instance's public ip is empty for id $id" >&2
			return 1
		fi
		AWS_NEW_IPS+="$ip "
	done
	echo "*** success" >&2; echo >&2
	return 0
}

# Set global GLUSTER_VOL to the gluster volume name by ssh'ing into the passed-in gce node.
# Note: using 'gluster vol info' since 'vol status' sometimes hangs when instances are up
#   and down frequently.
# Assumptions:
# - there is only 1 gluster volume.
# Args: 1=target gce node, 2=target zone
function get_vol_name() {
	local node="$1"; local zone="$2"
	local cmd="gluster volume info | head -n2 | tail -n1"

	echo "*** getting the gluster volume name..." >&2
	local vol="$(gcloud compute ssh $node --command="$cmd" --zone=$zone)"
	if (( $? != 0 )); then
		echo "error: '$cmd' failed" >&2
		return 1
	fi
	if [[ -z "$vol" ]]; then
		echo "error: 'gluster vol info' output is empty" >&2
		return 1
	fi
	GLUSTER_VOL="${vol#*: }"
	echo "*** success" >&2; echo >&2
	return 0
}

# Sets a global map keyed by an aws ec2 alias name found in /etc/hosts whose value is its new
# ip address (passed-in as arg @). This map is needed to ensure that the pair of alias and ip
# are consistent across all of the providers.
# Note: this func references global vars.
function map_ec2_aliases() {
	local new_ips=($@)
	local ec2_host_alias='aws-node'
	local cmd="grep $ec2_host_alias /etc/hosts"

	echo "*** mapping aws ec2 /etc/hosts aliases to their new ips..." >&2
	# get complete list of aws aliases by ssh'ing to a gce instance and fetching them from
	# that node's /etc/hosts file
	local matches=() # (ip-1 alias-1 ip-2 alias-2...)
	matches=($(gcloud compute ssh $GCE_NODE --command="$cmd" --zone=$GCE_ZONE))
	if (( $? != 0 )); then
		echo "'gcloud compute ssh $GCE_NODE --command=$cmd' error" >&2
		return 1
	fi
	# delete ips, just want alias names
	local aliases=(); local i
	for ((i=1; i<${#matches[@]}; i+=2 )); do # start at 1 and skip one each loop
		aliases+=(${matches[$i]})
	done
	local num_aliases=${#aliases[@]}
	if (( num_aliases == 0 )); then
		echo "error: no aws alias matching $ec2_host_alias found in /etc/hosts on $GCE_NODE" >&2
		return 1
	fi
	if (( num_aliases != ${#new_ips[@]} )); then
		echo "error: num of aws aliases in /etc/hosts ($num_aliases) != num of new ips (${#new_ips[@]})" >&2
		return 1
	fi
	# create alias map
	local key; local ip
	for ((i=0; i<${#aliases[@]}; i++)); do
		ip=${new_ips[$i]}
		key=${aliases[$i]}
		AWS_ALIASES[$key]=$ip
	done
	echo "*** success" >&2; echo >&2
	return 0
}

# Asserts that various global arrays are of the expected and consistent sizes.
function sanity_check() {

	echo "*** internal sanity check on gce and aws variables..." >&2
	# gce arrays:
	local arr1=(${GCE_INFO[NAMES]}); local size1=${#arr1[@]}
	local arr2=(${GCE_INFO[ZONES]}); local size2=${#arr2[@]}
	if (( size1 == 0 )); then
		echo "error: must have at least 1 gce instance" >&2
		return 1
	fi
	if (( size1 != size2 )); then
		echo "error: expect num of gce instances ($size1) to = num of gce zones ($size2)" >&2
		echo "    gce-names: ${arr1[@]}" >&2
		echo "    gce-zones: ${arr2[@]}" >&2
		return 1
	fi

	# aws arrays:
	arr1=(${AWS_INFO[NAMES]}); size1=${#arr1[@]}
	arr2=(${AWS_INFO[IDS]});   size2=${#arr2[@]}
	local arr3=($AWS_NEW_IPS); local size3=${#arr3[@]}
	local size4=${#AWS_ALIASES[@]}
	if (( size1 == 0 )); then
		echo "error: must have at least 1 aws ec2 instance" >&2
		return 1
	fi
	if [[ "${arr1[0]}" == *None* ]]; then # logged out of aws cli seems to cause this...
		echo "error: re-login to AWS CLI -- ec2 instances are not being found" >&2
		exit 1
	fi
	if (( !(size1 == size2 && size2 == size3 && size3 == size4) )); then
		echo "error: expect num of aws instances ($size1), num of aws ids ($size2), num of aws ips ($size3), and num aws /etc/hosts aliases ($size4) to be the same" >&2
		echo "    aws-names  : ${arr1[@]}" >&2
		echo "    aws-ids    : ${arr2[@]}" >&2
		echo "    aws-ips    : ${arr3[@]}" >&2
		echo "    aws-aliases: ${!AWS_ALIASES[@]}" >&2
		return 1
	fi
	echo "*** success" >&2; echo >&2
	return 0
}

# Updates /etc/hosts aws entries with the new ec2 ips. Done on all of the instances.
# References global vars.
# Assumptions:
# 1) the /etc/hosts ec2 entries are aliased as "aws-node1", "aws-node2", etc. This alias is not
#    captured by any aws ec2 attribute AFAIK. The most important thing is to be consistent across
#    all instances by using the same ip with the same host alias.
function update_etc_hosts() {
	local zones=(${GCE_INFO[ZONES]}) # convert to array
	local ec2_host_alias='aws-node'

	# construct sed cmd to update /etc/hosts on gce and aws instances
	local cmd=''; local alias
	for alias in ${!AWS_ALIASES[@]}; do
		cmd+="-e '/$alias/s/^.* /${AWS_ALIASES[$alias]} /' " # alias's new ip
	done
	cmd="sudo sed -i $cmd /etc/hosts"

	echo "*** updating /etc/hosts on gce instances..." >&2
	local i=0; local node; local zone
	for node in ${GCE_INFO[NAMES]}; do
		zone="${zones[$i]}"
		gcloud compute ssh $node --command="$cmd" --zone=$zone
		if (( $? != 0 )); then
			echo "'gcloud compute ssh $node --command=$cmd' error" >&2
			return 1
		fi
		((i++))
	done

	echo "*** updating /etc/hosts on ec2 instances..." >&2
	# note: even though $cmd contains all aws aliases and the aws hosts file should not
	#   contain its own alias name, the sed command does not fail when a '-e alias' name
	#   is not found in /etc/hosts.
	for node in ${AWS_INFO[NAMES]}; do
		ssh -t $AWS_SSH_USER@$node "$cmd"
		if (( $? != 0 )); then
			echo "'ssh -t $AWS_SSH_USER@$node $cmd' error" >&2
			return 1
		fi
	done
	echo "*** success" >&2; echo >&2
	return 0
}

# Waits for 'gluster peer status' to not display "(Disconnected)" for any of the nodes.
# "Disconnected" indicates that a node is not responsive.
# Args: 1=gce node to ssh into, 2=gce zone
function gluster_wait() {
	local node="$1"; local zone="$2"
	local maxTries=5
	local cmd="for (( i=0; i<$maxTries; i++ )); do cnt=\$(gluster peer status|grep -c '(Disconnected)'); (( cnt == 0 )) && break; sleep 3; done; (( i < $maxTries )) && exit 0 || exit 1"

	echo "*** waiting for gluster to reconnect to ec2 instances..." >&2
	gcloud compute ssh $node --command="$cmd" --zone=$zone
	if (( $? != 0 )); then
		echo "'gluster peer status' not showing all nodes connected after $maxTries tries" >&2
		return 1
	fi
	echo "*** success" >&2; echo >&2
	return 0
}

# Mounts the passed-in gluster volume on the aws ec2 instances.
# Assumptions:
# - mount path is hard-coded to "/mnt/vol".
function mount_vol() {
	local vol="$1"
	local mntPath='/mnt/vol'

	echo "*** remounting gluster volume \"$vol\" on ec2 instances..." >&2
	local node; local cmd; local errcnt=0; local err
	for node in ${AWS_INFO[NAMES]}; do
		cmd="sudo mount -t glusterfs $node:/$vol $mntPath"
		ssh -t $AWS_SSH_USER@$node "$cmd"
		err=$?
		if (( err != 0 && err != 32 )); then # 32==already mounted which is ok
			echo "'ssh -t $AWS_SSH_USER@$node $cmd' error" >&2
			((errcnt++))
		fi
	done
	(( errcnt > 0 )) && return 1
	echo "*** success" >&2; echo >&2
	return 0
}


## main ##

cat <<END

   This script attempts to repair AWS EC2 instances which have been stopped. These
   instances are restarted, /etc/hosts on all instances in the cluster is updated to
   reflect the new ips for the started AWS instances, and the gluster volume is 
   remounted on the AWS instances. The gluster volumne name must be specified if there
   is more than one gluster volume in the cluster; otherwise it is optional.

   Usage: $0 <instance-filter> [gluster-vol]  eg. $0 jcope gv0

END

# source util funcs based on provider
ROOT="$(dirname '${BASH_SOURCE}')"
source $ROOT/init.sh || exit 1

AWS_SSH_USER='centos'
FILTER="$1"
if [[ -z "$FILTER" ]]; then
	echo "Missing required instance-filter value" >&2
	exit 1
fi
GLUSTER_VOL="$2" # optional

# get gce instance info
init::load_provider gce || exit 1
info=$(util::get_instance_info $FILTER NAMES ZONES PUBLIC_IPS)
if (( $? != 0 )); then
	echo "failed to get gce instance info" >&2
	exit 1
fi
declare -A GCE_INFO=$info
GCE_NODE="${GCE_INFO[NAMES]%% *}" # first name, used to ssh into a gce instance
GCE_ZONE="${GCE_INFO[ZONES]%% *}" # first zone

# handle omitted gluster vol
if [[ -z "$GLUSTER_VOL" ]]; then
	# get the gluster volume name (as global var). Expect only one volume.
	get_vol_name $GCE_NODE $GCE_ZONE || exit 1
fi

# get aws instance info
init::load_provider aws || exit 1
info=$(util::get_instance_info $FILTER NAMES IDS) # don't get ips since instance may be stopped
if (( $? != 0 )); then
	echo "failed to get aws instance info" >&2
	exit 1
fi
declare -A AWS_INFO=$info

# start ec2 instances
start_aws_instances ${AWS_INFO[IDS]} || exit 1

AWS_NEW_IPS=''
get_ec2_ips ${AWS_INFO[IDS]} || exit 1

# map /etc/hosts aliases for the ec2 instances to their new ips
declare -A AWS_ALIASES=()
map_ec2_aliases $AWS_NEW_IPS || exit 1

# make sure the instance related variables are sane
sanity_check || exit 1

# update /etc/hosts on all instances
update_etc_hosts || exit 1

# wait for peer status to see new ips
gluster_wait $GCE_NODE $GCE_ZONE ${AWS_INFO[PUBLIC_IPS]} || exit 1

# remount gluster volume on aws instances
mount_vol $GLUSTER_VOL || exit 1

exit 0
