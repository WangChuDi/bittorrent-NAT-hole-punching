#!/bin/sh

script=$(readlink -f "$0")
script_dir=$(dirname "$script")

# natmap
public_addr=$1
public_port=$2
ip4p=$3
private_port=$4
protocol=$5

port=$public_port

echo
echo "External IP - $public_addr:$public_port, bind port $private_port, $protocol"
echo

# Transmission

interface="ppp+"
host="192.168.0.74"
web_port="9091"
username="admin"
password="12345"
forward_ipv6=1

# script begins

retry_interval=57
retry_times=2880

rsf="$script_dir/trs_running"
rs=0
rs_b=0
wait_to_exit=$(($retry_interval + 30))

if [ -f "$rsf" ]; then
  rs=$(cat "$rsf")
  if ! [ "$rs" -ge 0 ]; then
    if ! [[ $(wc -c <"$rsf") -le 4 ]]; then
      echo "$rsf : unexpected value"
      echo "An error occurred."
      echo "Place this script on other folder to suppress the error."
      exit 99
    fi
    rs=0
  fi

  rs=$(($rs + 1))
  echo "$rs" >"$rsf"
  sleep $wait_to_exit

  if ! [ -f "$rsf" ]; then
    exit 100
  fi

  rs_b=$(cat "$rsf")
  if ! [ "$rs" = "$rs_b" ]; then
    exit 200
  fi

  echo "0" >"$rsf"
else
  echo "0" >"$rsf"
fi

# delete previous iptables rule
tdrsh="$script_dir/trs_tdr"

if [ -f "$tdrsh" ]; then
  sh "$tdrsh"
  rm -f "$tdrsh"
fi

x=1
ut_token=nul

# If bittorrent client isn't online, try 57 seconds later.
# ( Loop last 48 hours unless this script is invoked again or app is online. )
while [ $x -le $retry_times ]; do
  if ! [ -f "$rsf" ]; then
    exit 101
  fi

  rs=$(cat "$rsf")
  if ! [ "$rs" = "0" ]; then
    echo "Another running script detected, exit."
    exit 102
  fi

  tr_header=$(curl -m 3 -s -u $username:$password http://$host:$web_port/transmission/rpc | grep -o '<code.*code>' | grep -o '>.*<' | sed -e 's/>\(.*\)</\1/')
  if [[ $(expr match "$tr_header" 'X.\+Id...') -gt 27 ]]; then
    echo "Update Transmission listen port to $public_port"
    curl -m 3 -s -u $username:$password -X POST -H "$tr_header" -d '{"method":"session-set","arguments":{"peer-port":'$port'}}' "http://$host:$web_port/transmission/rpc" &>/dev/null
	if [ $? != '0' ]; then
      sleep 5
      echo "Retrying.."
      curl -m 3 -s -u $username:$password -X POST -H "$tr_header" -d '{"method":"session-set","arguments":{"peer-port":'$port'}}' "http://$host:$web_port/transmission/rpc" &>/dev/null
    fi
    break
  fi

  x=$(($x + 1))
  sleep $retry_interval
done

if ! [ $x -le $retry_times ]; then
  exit 103
fi

# iptables

echo "Add rule"

retry_on_fail() {
  $1
  if [ $? != '0' ]; then
    sleep 1
    $1
    if [ $? != '0' ]; then
      sleep 2
      $1
    fi
  fi
}

d_rule="iptables -t nat -D PREROUTING -i $interface -p $protocol --dport $private_port -j DNAT --to-destination $host:$port"
d_rule2=""
d_rule3=""
d_rule4="iptables -t nat -D POSTROUTING -p tcp --dport $private_port -j ACCEPT" #delete SNAT rule to show real ip in Transmission

retry_on_fail "iptables -t nat -I PREROUTING -i $interface -p $protocol --dport $private_port -j DNAT --to-destination $host:$port"
retry_on_fail "iptables -t nat -I POSTROUTING -p tcp --dport $private_port -j ACCEPT"

if [ $forward_ipv6 -eq 1 ]; then
  retry_on_fail "ip6tables -t filter -I FORWARD -i $interface -p udp --dport $port -j ACCEPT"
  retry_on_fail "ip6tables -t filter -I FORWARD -i $interface -p tcp --dport $port -j ACCEPT"
  d_rule2="ip6tables -t filter -D FORWARD -i $interface -p udp --dport $port -j ACCEPT"
  d_rule3="ip6tables -t filter -D FORWARD -i $interface -p tcp --dport $port -j ACCEPT"
fi

echo "#!/bin/sh
# External IP - $public_addr:$public_port, bind port $private_port, $protocol
echo 'Delete rule'
retry_on_fail() {
  \$1
  if [ \$? != '0' ]; then
    sleep 1
    \$1
    if [ \$? != '0' ]; then
      sleep 2
      \$1
    fi
  fi
}
retry_on_fail \"$d_rule\"
retry_on_fail \"$d_rule2\"
retry_on_fail \"$d_rule3\"
retry_on_fail \"$d_rule4\"
" >"$tdrsh"

rm -f "$rsf"

echo Fin
exit 0
