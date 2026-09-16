# ---------------------------------------------------------------------------
# Default-deny firewall for the core router — NOT YET APPLIED
# ---------------------------------------------------------------------------
#
# Derived mechanically from the router's own state on 2026-09-16:
# `/ip firewall nat print detail` (53 rules) and `/ip firewall filter export`.
# Every accept below exists because a dst-nat rule points at it. Nothing was
# added from memory or guessed at.
#
# WHY THIS EXISTS
#
# The live forward chain has no final drop. RouterOS then falls through to the
# chain's default policy, which is ACCEPT — so the three "No direct external"
# drops being `disabled=yes` leaves nothing denying anything. What limits
# exposure today is only which dst-nat rules exist, not any rule that says no.
#
# And the control that was supposed to gate RDP does not:
#
#     accept … chain=forward in-interface-list=WAN protocol=tcp \
#              src-address-list=RDP_ALLOWED src-port=33000-34999
#     drop   … chain=forward in-interface-list=WAN protocol=tcp \
#              src-address-list=!RDP_ALLOWED src-port=33000-34999
#
# It matches `src-port` — the CLIENT's ephemeral port. The filter runs after
# dst-nat, so by then the packet carries dst-port=3389 and a random source
# port. The rule fires only when a client happens to source from 33000-34999,
# which is close to never. The RDP fleet is effectively open to the internet.
# Below, the same intent is expressed as dst-address + dst-port=3389 +
# src-address-list, which is what actually matches.
#
# HOW TO APPLY THIS WITHOUT LOSING THE ROUTER
#
# A default-deny rewrite applied over the link you are using is how routers get
# bricked. Do it with an automatic undo armed BEFORE the change:
#
#   /system backup save name=pre-firewall
#   /system scheduler add name=rollback interval=10m on-event={
#       /system backup load name=pre-firewall password="" }
#   ... paste the rules, verify every path below still works ...
#   /system scheduler remove rollback          # only once you are sure
#
# If anything goes dark, do nothing: in ten minutes the router restores itself.
#
# WHAT TO VERIFY BEFORE REMOVING THE ROLLBACK
#
#   ssh -p 22504 zuloone@162.55.72.116        six ZO hosts: 22499..22504
#   ssh -p 22498 okrasheno@162.55.72.116      outline
#   https://cp.zulo.one/                      panel, via Cloudflare
#   https://rms.zulo.one/health               a tenant, via Cloudflare
#   one RDP session from an allow-listed address
#
# ---------------------------------------------------------------------------

/ip firewall address-list
# Kept as they are today. RDP_ALLOWED becomes load-bearing for the first time:
# until now the rule that referenced it did not match, so its contents never
# decided anything.
# add list=RDP_ALLOWED address=<office>        ;# already populated on the router
# add list=cloudflare  address=<ranges>        ;# already populated on the router
# add list=LAN_NET     address=10.10.0.0/16    ;# already populated on the router

# ---------------------------------------------------------------------------
# input — traffic TO the router
# ---------------------------------------------------------------------------
/ip firewall filter
add chain=input action=drop connection-state=invalid \
    comment="drop invalid"

add chain=input action=accept connection-state=established,related \
    comment="est/rel"

add chain=input action=accept protocol=icmp \
    comment="ICMP to the router"

add chain=input action=accept src-address-list=LAN_NET \
    comment="LAN to the router"

# The router's own SSH. 22400-22499 overlaps the 22498/22499 dst-nat rules, but
# dst-nat runs first, so those two reach their hosts and never arrive here.
add chain=input action=accept protocol=tcp in-interface=bridge_wan dst-port=22400-22499 \
    comment="SSH to the router"

add chain=input action=accept protocol=tcp in-interface=bridge_wan dst-port=40000-40100 \
    comment="GitHub runners"

add chain=input action=accept protocol=tcp in-interface=bridge_wan dst-port=1235 \
    comment="1CServer Mobis"

# 9090 answered HTTP/1.0 200 from the public internet when probed on
# 2026-09-16, and it is the only WAN-facing input accept with no source
# restriction at all. Left commented ON PURPOSE: decide what listens there
# before re-opening it, and give it a source list when you do.
# add chain=input action=accept protocol=tcp in-interface-list=WAN dst-port=9090 \
#     comment="REVIEW: what is this, and who should reach it?"

add chain=input action=drop in-interface-list=WAN \
    comment="default deny from WAN"

# ---------------------------------------------------------------------------
# forward — traffic THROUGH the router. One accept per published service.
# ---------------------------------------------------------------------------
add chain=forward action=accept connection-state=established,related \
    comment="est/rel"

add chain=forward action=drop connection-state=invalid \
    comment="drop invalid"

# --- RDP fleet. Matched on the POST-NAT destination, which is what the filter
#     actually sees, and gated by the allow-list as was always intended.
add chain=forward action=accept protocol=tcp dst-port=3389 src-address-list=RDP_ALLOWED \
    dst-address-list=RDP_HOSTS in-interface-list=WAN \
    comment="RDP from allow-listed sources only"

/ip firewall address-list
# Every dst-nat with to-ports=3389, verbatim from the router.
add list=RDP_HOSTS address=10.10.0.50   comment="GW"
add list=RDP_HOSTS address=10.10.0.99   comment="TPL"
add list=RDP_HOSTS address=10.10.1.75   comment="ERP"
add list=RDP_HOSTS address=10.10.1.112  comment="VM_KS"
add list=RDP_HOSTS address=10.10.1.113  comment="VM_BS"
add list=RDP_HOSTS address=10.10.1.114  comment="VM_UA"
add list=RDP_HOSTS address=10.10.1.119  comment="VM_FE"
add list=RDP_HOSTS address=10.10.1.123  comment="VM_SO"
add list=RDP_HOSTS address=10.10.1.127  comment="VM_SH"
add list=RDP_HOSTS address=10.10.2.10   comment="DC"
add list=RDP_HOSTS address=10.10.2.40   comment="MSDB"
add list=RDP_HOSTS address=10.10.2.50   comment="1CServer"
add list=RDP_HOSTS address=10.10.2.110  comment="VM_PS"
add list=RDP_HOSTS address=10.10.2.111  comment="VM_SS"
add list=RDP_HOSTS address=10.10.2.114  comment="VM_MV"
add list=RDP_HOSTS address=10.10.2.115  comment="VM_MA"
add list=RDP_HOSTS address=10.10.2.116  comment="VM_ZU"

# Every dst-nat with to-ports=22.
add list=SSH_HOSTS address=10.10.0.10   comment="ZULO_EDGE-GW    22422"
add list=SSH_HOSTS address=10.10.0.15   comment="ZULO_WEB        22428"
add list=SSH_HOSTS address=10.10.0.20   comment="ZULO_APP        22423"
add list=SSH_HOSTS address=10.10.0.30   comment="ZULO_PLATFORM   22424"
add list=SSH_HOSTS address=10.10.0.40   comment="ZULO_STAGING    22425"
add list=SSH_HOSTS address=10.10.0.45   comment="OUTLINE         22498"
add list=SSH_HOSTS address=10.10.0.200  comment="ZO_CP_1         22501"
add list=SSH_HOSTS address=10.10.0.210  comment="ZO_CI_1         22504"
add list=SSH_HOSTS address=10.10.0.220  comment="ZO_PGW_1        22499"
add list=SSH_HOSTS address=10.10.1.19   comment="GH_RUNNER_02    40031"
add list=SSH_HOSTS address=10.10.1.20   comment="ZULO_DATA       22426"
add list=SSH_HOSTS address=10.10.1.21   comment="ZULO_OSRM       22429"
add list=SSH_HOSTS address=10.10.1.200  comment="USER_DISKS      40022"
add list=SSH_HOSTS address=10.10.1.210  comment="ZO_PG_1         22500"
add list=SSH_HOSTS address=10.10.1.220  comment="ZO_APP_1        22503"
add list=SSH_HOSTS address=10.10.2.10   comment="ZULO_MAPS       22427"
add list=SSH_HOSTS address=10.10.2.81   comment="GH_RUNNER_03    40032"
add list=SSH_HOSTS address=10.10.2.210  comment="ZO_PG_2         22502"

/ip firewall filter
add chain=forward action=accept protocol=tcp dst-port=22 dst-address-list=SSH_HOSTS \
    in-interface-list=WAN \
    comment="SSH to the published hosts"

# --- ZuloOne, Cloudflare only. Same intent as the two guards live today, but
#     expressed as an accept inside a deny-by-default chain rather than as a
#     narrow drop inside an allow-by-default one.
add chain=forward action=accept protocol=tcp dst-address=10.10.1.220 dst-port=443 \
    src-address-list=cloudflare in-interface-list=WAN \
    comment="ZuloOne tenants (origin 8443)"

add chain=forward action=accept protocol=tcp dst-address=10.10.0.200 dst-port=8443 \
    src-address-list=cloudflare in-interface-list=WAN \
    comment="ZuloOne control plane (origin 8444)"

# --- Named services, one per dst-nat that is not RDP or SSH.
add chain=forward action=accept protocol=tcp dst-address=10.10.2.50 dst-port=1235 \
    comment="1CServer Mobis"
add chain=forward action=accept protocol=udp dst-address=10.10.2.50 dst-port=1235 \
    comment="1CServer Mobis"
add chain=forward action=accept protocol=tcp dst-address=10.10.1.119 dst-port=21115 \
    in-interface-list=WAN comment="VM_FE RustDesk"
add chain=forward action=accept protocol=tcp dst-address=10.10.0.45 dst-port=35156 \
    in-interface-list=WAN comment="Outline management"
add chain=forward action=accept protocol=tcp dst-address=10.10.0.45 dst-port=14886 \
    in-interface-list=WAN comment="Outline access key"
add chain=forward action=accept protocol=udp dst-address=10.10.0.45 dst-port=14886 \
    in-interface-list=WAN comment="Outline access key"

# --- Internal, not from WAN.
add chain=forward action=accept protocol=tcp src-address=10.10.0.200 \
    dst-address=10.10.1.220 dst-port=2375 \
    comment="ZuloOne cp -> docker socket proxy"

add chain=forward action=accept src-address=10.10.0.0/16 \
    in-interface=wg-overlay out-interface-list=WAN \
    comment="overlay out to the internet"

add chain=forward action=accept out-interface=bridge_wan src-address=10.10.0.0/16 \
    comment="LAN out to the internet"

add chain=forward action=accept src-address=10.10.0.0/16 dst-address=10.10.0.0/16 \
    comment="LAN to LAN — tighten per tier once the above is proven"

# --- THE LINE THAT MAKES THIS A DEFAULT-DENY FIREWALL.
#     Everything the chain did not name above stops here.
add chain=forward action=drop \
    comment="default deny"
