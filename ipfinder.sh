#!/usr/bin/env sh

# Sometimes, when there is no Internet connection, curl will continue to retry. If the total time is longer than MAX_TIME we want to abort.
MAX_TIME=10 # seconds
# The time we want to wait before we check for any network changes.
before_network_check=2 # seconds
last_network_change=0 # seconds

DEFAULT_CHECK_ANYWAY=10 # seconds
check_anyway=$DEFAULT_CHECK_ANYWAY # seconds

# Icons
VPN_UP=""
VPN_DOWN=""
INTERNET_DOWN=""

# In case we get throttled anyway, try with a different service.
throttled() {
    response=$(curl -m "$MAX_TIME" -sf -H "Accept: application/json" trackip.net/ip?json)
    ip=$(echo "$response" | jq -r '.IP' 2>/dev/null)
    country=$(echo "$response" | jq -r '.Country' 2>/dev/null)

    if  [ -z "$ip" ] || echo "$ip" | grep -iq null; then
        return 1
    fi

    return 0
}

connected() {
    if ! ip route | grep '^default' | grep -qo '[^ ]*$'; then
        echo 1; 
        return 1; 
    fi

    echo 0;
}

# If a change happens to quickly and the resulting list of states is similar, no change will be detected. Therefore, this check only, of interface states, won't suffice. Alternatively, we may want we check the entire output of `ip link show up` instead.
interface_state() {
    ip link show up | grep -oE 'state (UP|DOWN|UNKNOWN)' | awk '{print $2}' | tr '[:space:]' ' '
}

# Each time a tunnel is created, it is given a unique id. If this instantiation happens too quickly and results in the same state as previously, interface_state won't mark any changes. Uplinks checks all the interfaces numbers.
uplinks() {
    ip link show up | awk -F: '/^[0-9]+/ {print $1}'
}

while :; do

    # We do not want to exceed the limit of API requests, so we check if there is actually any changes.
    current_interface_state="$(interface_state)"
    current_uplinks=$(uplinks)
    current_connection_status=$(connected)
    if [ "$current_interface_state" = "$previous_interface_state" ] &&  [ "$current_uplinks" = "$previous_uplinks" ] && [ "$current_connection_status" = "$previous_connection_status" ]; then
        sleep $before_network_check
        last_network_change=$((last_network_change + before_network_check))
        if [ "$last_network_change" -le "$check_anyway" ]; then
            continue;
        else
            check_anyway=$((check_anyway + 2 * (RANDOM % 10)))

        fi
    else
        check_anyway=$DEFAULT_CHECK_ANYWAY
    fi

    last_network_change=0

    status=$VPN_DOWN
    # If a VPN connection is established, a tunnel is created.
    if ip tuntap | grep -iEq '(proton|tun)[0-9]+|nordlynx' || ip link | grep -iEq 'mullvad|wgpia[0-9]+'; then
        status=$VPN_UP
    fi

    response=$(curl -m "$MAX_TIME" -sf -H "Accept: application/json" ipinfo.io/json)
    if [ -n "$response" ] && ! echo "$response" | jq -r '.ip' | grep -iq null; then

        ip=$(echo "$response" | jq -r '.ip')
        country=$(echo "$response" | jq -r '.country')
    else

        if ! throttled; then

            default_interface=$(ip route | awk '/^default/ { print $5 ; exit }')
            # If there is no default interface, Internet is down.
            if [ -z "$default_interface" ]; then

                status=$INTERNET_DOWN
                ip="127.0.0.1"
            else

                ip=$(ip addr show "$default_interface" | awk '/scope global/ {print $2; exit}' | cut -d/ -f1)
            fi

            country="local"
        fi
    fi

    printf "%-23s\n" "$(echo $status $ip [$country])"
    previous_interface_state="$(interface_state)"
    previous_uplinks=$(uplinks)
    previous_connection_status=$(connected)
done
