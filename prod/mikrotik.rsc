# MikroTik / RouterOS — publish the ZuloOne tenant VM to Cloudflare only.
#
# Import with:
#   /import file-name=mikrotik.rsc
# or paste section by section. READ THE TWO VARIABLES BELOW FIRST — nothing
# works until they match your network.
#
# What this achieves: port 80/443 on the public IP is forwarded to the tenant VM
# ONLY when the source is a Cloudflare edge address. Everything else is dropped
# before it reaches the VM.
#
# Why that matters, concretely: the tenant runs with
# ZuloOne__BehindReverseProxy=true, which enables forwarded headers with
# KnownNetworks and KnownProxies CLEARED — Core trusts X-Forwarded-For from
# whoever connects to it. Correct behind a proxy, dangerous in front of one.
# If anyone can reach the VM directly they can forge client IPs and bypass every
# Cloudflare rule you write. This file is what makes the assumption true.

# ---------------------------------------------------------------------------
# 1. SET THESE
# ---------------------------------------------------------------------------
# Two things must match your network before importing:
#
#   1. The tenant VM address. This file uses 10.10.1.220 (zo-app-1 from
#      ARCHITECTURE.md §3) in sections 3, 4 and 6.
#   2. The WAN interface list used in section 3.
#
# If you do not already have a WAN interface list, either create one
#   /interface list add name=WAN
#   /interface list member add list=WAN interface=ether1
# or replace `in-interface-list=WAN` below with `in-interface=ether1`.

# ---------------------------------------------------------------------------
# 2. Cloudflare edge ranges (IPv4)
# ---------------------------------------------------------------------------
# Captured from https://www.cloudflare.com/ips-v4 on 2026-09-06 — 15 prefixes.
# Cloudflare changes this list on a scale of years and announces it in advance,
# so a static list is more dependable than a parser that can fail quietly.
# Section 7 has a refresh script that validates before it swaps.
#
# IPv6 is deliberately absent: Cloudflare reaches the origin over whatever
# record you publish, and section 4 of the runbook publishes an A record only.
# Add https://www.cloudflare.com/ips-v6 to this list if you ever add AAAA.

/ip firewall address-list
add list=cloudflare comment="Cloudflare edge" address=173.245.48.0/20
add list=cloudflare comment="Cloudflare edge" address=103.21.244.0/22
add list=cloudflare comment="Cloudflare edge" address=103.22.200.0/22
add list=cloudflare comment="Cloudflare edge" address=103.31.4.0/22
add list=cloudflare comment="Cloudflare edge" address=141.101.64.0/18
add list=cloudflare comment="Cloudflare edge" address=108.162.192.0/18
add list=cloudflare comment="Cloudflare edge" address=190.93.240.0/20
add list=cloudflare comment="Cloudflare edge" address=188.114.96.0/20
add list=cloudflare comment="Cloudflare edge" address=197.234.240.0/22
add list=cloudflare comment="Cloudflare edge" address=198.41.128.0/17
add list=cloudflare comment="Cloudflare edge" address=162.158.0.0/15
add list=cloudflare comment="Cloudflare edge" address=104.16.0.0/13
add list=cloudflare comment="Cloudflare edge" address=104.24.0.0/14
add list=cloudflare comment="Cloudflare edge" address=172.64.0.0/13
add list=cloudflare comment="Cloudflare edge" address=131.0.72.0/22

# ---------------------------------------------------------------------------
# 3. Destination NAT — Cloudflare only
# ---------------------------------------------------------------------------
# src-address-list=cloudflare is the whole security control: a packet from any
# other source never gets translated, so it never reaches the VM.
# Address below is zo-app-1 from ARCHITECTURE.md §3. Change it only if
# your inventory differs.

/ip firewall nat
add chain=dstnat action=dst-nat protocol=tcp dst-port=80 \
    in-interface-list=WAN src-address-list=cloudflare \
    to-addresses=10.10.1.220 to-ports=80 \
    comment="ZuloOne tenant HTTP (Cloudflare only)"
add chain=dstnat action=dst-nat protocol=tcp dst-port=443 \
    in-interface-list=WAN src-address-list=cloudflare \
    to-addresses=10.10.1.220 to-ports=443 \
    comment="ZuloOne tenant HTTPS (Cloudflare only)"

# ---------------------------------------------------------------------------
# 4. Forward filter — belt and braces
# ---------------------------------------------------------------------------
# The NAT rules above already gate on source, so this is redundant by design.
# It exists because a future NAT rule added for some other purpose could
# accidentally expose the same host, and this rule would still catch it.
#
# ORDER MATTERS. RouterOS evaluates filter rules top to bottom, so this must sit
# ABOVE any broad accept in the forward chain. Check with `/ip firewall filter
# print` and move it if needed:
#   /ip firewall filter move [find comment~"ZuloOne guard"] destination=0

/ip firewall filter
add chain=forward action=drop protocol=tcp \
    dst-address=10.10.1.220 dst-port=80,443 \
    src-address-list=!cloudflare \
    comment="ZuloOne guard: tenant reachable only via Cloudflare"

# ---------------------------------------------------------------------------
# 5. Inter-subnet policy — default deny between tiers
# ---------------------------------------------------------------------------
# The rule that matters: nothing from the internet ever reaches either database
# node. If a tenant container is compromised, the attacker meets port 5432 with a
# role scoped to one database, not a shell on the box holding every tenant's data.
#
# Note the asymmetry: zo-pg-2 (10.10.2.210) is in the data subnet and everything
# reaching it crosses this router. zo-pg-1 (10.10.1.210) — the PRIMARY — sits in
# the app subnet, so traffic from zo-app-1 to it is switched and never arrives here
# at all. For that path, pg_hba.conf and container-egress.sh are the controls;
# these rules cannot help. The CI runner is deliberately NOT on that segment — it
# is in core, so it reaches the database only through the rules below.
# See ARCHITECTURE.md §1.
#
# ORDER MATTERS. These must sit above any broad forward accept. Check with
# `/ip firewall filter print` and move them if needed.
# Full matrix in ARCHITECTURE.md §9.

/ip firewall filter
# Return traffic first, or every allow below needs a mirror rule.
add chain=forward action=accept connection-state=established,related \
    comment="ZuloOne tiers: established"

# app -> the STANDBY only. The primary (zo-pg-1, 10.10.1.210) sits in the app
# subnet itself, so that traffic is switched and never arrives here — pg_hba.conf
# and container-egress.sh are what gate it. This rule exists so a tenant can
# follow a failover onto the standby.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.1.0/24 dst-address=10.10.2.210 dst-port=5432 \
    comment="ZuloOne tiers: app -> postgres standby"

# Streaming replication between the two data nodes, BOTH directions: after a
# failover the roles swap, and the direction with them.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.1.210 dst-address=10.10.2.210 dst-port=5432 \
    comment="ZuloOne patroni: replication pg-1 -> pg-2"
add chain=forward action=accept protocol=tcp \
    src-address=10.10.2.210 dst-address=10.10.1.210 dst-port=5432 \
    comment="ZuloOne patroni: replication pg-2 -> pg-1"

# pgBackRest moves WAL segments and backup files between the two data nodes over
# SSH, so port 22 has to be open BETWEEN them — the "admin SSH" rule below only
# covers core -> everywhere and does not help here.
#
# Both directions, for the same reason as replication: the repository lives on
# zo-pg-2, the leader pushes to it, and which node leads changes. Whichever one is
# elected needs to reach the other.
#
# Leave this out and `archive_command` starts failing the moment these rules are
# imported. WAL then piles up in pg_wal until archive-push-queue-max, after which
# archiving is skipped silently and PITR is gone. check-cluster.sh catches it
# within five minutes; nothing else will.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.1.210 dst-address=10.10.2.210 dst-port=22 \
    comment="ZuloOne pgbackrest: SSH pg-1 -> pg-2"
add chain=forward action=accept protocol=tcp \
    src-address=10.10.2.210 dst-address=10.10.1.210 dst-port=22 \
    comment="ZuloOne pgbackrest: SSH pg-2 -> pg-1"

# etcd holds the Patroni leader key. All three nodes sit in DIFFERENT subnets, so
# every quorum message crosses this router: 2380 between peers, 2379 for clients.
#
# Without these the etcd cluster never forms, Patroni never starts, and the
# database never comes up at all. If they are lost later, Patroni REFUSES to
# promote anyone — it cannot prove the old leader is gone. That is an outage
# rather than a split brain, and it is the system working correctly.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.1.210,10.10.2.210,10.10.0.220 \
    dst-address=10.10.1.210,10.10.2.210,10.10.0.220 dst-port=2379,2380 \
    comment="ZuloOne etcd: peer + client"

# Patroni's REST API — used by patronictl and for health checks between members.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.0/24,10.10.1.0/24,10.10.2.0/24 \
    dst-address=10.10.1.210,10.10.2.210 dst-port=8008 \
    comment="ZuloOne patroni: REST API"

# DNS. The resolver (10.10.2.10) is pre-existing infrastructure that happens to
# live in the data subnet, so every other tier reaches it across this router —
# and the default-deny below would otherwise swallow it. Without these two rules
# nothing resolves anywhere except on zo-pg-2, and the symptom is `apt-get update`
# hanging rather than anything that points at DNS.
#
# Scoped to the one resolver on the two DNS ports, not opened to the subnet.
add chain=forward action=accept protocol=udp \
    src-address=10.10.0.0/24,10.10.1.0/24 dst-address=10.10.2.10 dst-port=53 \
    comment="ZuloOne tiers: DNS (udp)"
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.0/24,10.10.1.0/24 dst-address=10.10.2.10 dst-port=53 \
    comment="ZuloOne tiers: DNS (tcp, large answers and zone transfers)"

# core -> everything, administration.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.0/24 dst-address=10.10.1.0/24,10.10.2.0/24 dst-port=22 \
    comment="ZuloOne tiers: admin SSH"

# app -> the image registry on zo-ci-1. The registry lives in the CORE subnet
# because that is where images are built, so every pull crosses this router.
# Without this rule the tenant container cannot start and the only symptom is a
# pull timeout that looks like a broken registry rather than a firewall.
#
# Narrow on purpose: one source host to one destination host on one port. Plain
# HTTP is tolerable only because of that narrowness — widen it and it stops being.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.1.220 dst-address=10.10.0.210 dst-port=5000 \
    comment="ZuloOne tiers: app -> image registry"

# --- control plane (zo-cp-1, 10.10.0.200) -----------------------------------
# Add these only when the control plane is actually deployed. Until then they
# widen the core tier for a host that does not exist.
#
# 2375 is the docker-socket-PROXY on zo-app-1, never the raw daemon: the Docker
# API is unauthenticated, so whatever reaches it is root on that host.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.200 dst-address=10.10.1.220 dst-port=2375 \
    comment="ZuloOne cp: docker socket proxy"
# Admin connection — creates and drops tenant databases and roles, and holds the
# control plane's own registry database.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.200 dst-address=10.10.1.210,10.10.2.210 dst-port=5432 \
    comment="ZuloOne cp: postgres admin (both nodes)"
# Health probes and admin seeding, addressed to Traefik with a Host header.
# Keeping it on the LAN avoids hairpinning out through public DNS and back in
# through Cloudflare, which is fragile and often silently broken.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.200 dst-address=10.10.1.220 dst-port=443 \
    comment="ZuloOne cp: tenant health + setup"

# Everything else between tiers is denied. Note this does NOT block outbound to
# the internet (that is srcnat/WAN, not inter-subnet), which app needs for image
# pulls and data needs for package mirrors and the off-site WAL archive.
add chain=forward action=drop \
    src-address=10.10.1.0/24 dst-address=10.10.2.0/24 \
    comment="ZuloOne tiers: deny app -> data (except 5432 above; core is a separate rule)"
add chain=forward action=drop \
    src-address=10.10.2.0/24 dst-address=10.10.1.0/24,10.10.0.0/24 \
    comment="ZuloOne tiers: data never initiates inbound (replication accepted above)"

# ---------------------------------------------------------------------------
# 6. Optional — hairpin NAT
# ---------------------------------------------------------------------------
# Without this, a browser INSIDE the LAN resolving t1.zulo.one gets the public
# IP and the connection dies at the router. Two ways out: a DNS override so LAN
# clients resolve the name straight to the VM (simpler, preferred), or hairpin
# NAT. The DNS route also skips a pointless trip through Cloudflare.
#
# /ip dns static
# add name=t1.zulo.one address=10.10.1.220 comment="LAN shortcut, bypasses Cloudflare"
#
# Note the tradeoff: a LAN client using this override reaches Traefik directly,
# so it presents the Cloudflare Origin certificate, which no LAN browser trusts.
# Expect a certificate warning. That is correct and not worth "fixing" with a
# second certificate.

# ---------------------------------------------------------------------------
# 7. Optional — refresh the Cloudflare list
# ---------------------------------------------------------------------------
# Builds into a temporary list, refuses to swap unless the result looks sane,
# and only then replaces the live one. A truncated download or a DNS hijack
# would otherwise produce a list that locks Cloudflare out — i.e. a self-inflicted
# outage — which is exactly what the count check prevents.

/system script
add name=cf-refresh policy=read,write,test,policy dont-require-permissions=no source={
    :do { /ip firewall address-list remove [find list="cloudflare-new"] } on-error={}
    /tool fetch url="https://www.cloudflare.com/ips-v4" mode=https dst-path="cf-ips-v4.txt"
    :delay 3s
    :local content [/file get [/file find name="cf-ips-v4.txt"] contents]
    :local start 0
    :local end 0
    :while ($start < [:len $content]) do={
        :set end [:find $content "\n" $start]
        :if ([:typeof $end] = "nil") do={ :set end [:len $content] }
        :local line [:pick $content $start $end]
        :if ([:len $line] > 8) do={
            :do { /ip firewall address-list add list="cloudflare-new" address=$line } on-error={}
        }
        :set start ($end + 1)
    }
    :local n [:len [/ip firewall address-list find list="cloudflare-new"]]
    :if ($n >= 10) do={
        /ip firewall address-list remove [find list="cloudflare"]
        :foreach i in=[/ip firewall address-list find list="cloudflare-new"] do={
            /ip firewall address-list set $i list="cloudflare"
        }
        :log info "cf-refresh: cloudflare list updated, $n prefixes"
    } else={
        /ip firewall address-list remove [find list="cloudflare-new"]
        :log error "cf-refresh: got only $n prefixes, refusing to swap"
    }
}

# Monthly is plenty for a list that changes every few years.
# /system scheduler
# add name=cf-refresh interval=30d on-event="/system script run cf-refresh" \
#     comment="Refresh Cloudflare edge ranges"

# ---------------------------------------------------------------------------
# 8. Verify
# ---------------------------------------------------------------------------
# Count the prefixes (expect 15):
#   :put [:len [/ip firewall address-list find list="cloudflare"]]
#
# Watch translations arrive while you load the site:
#   /ip firewall connection print where dst-address~":443"
#
# Then, from any machine OUTSIDE Cloudflare, prove the origin is closed:
#   curl -m 5 -sk https://<public-ip>/health     # must TIME OUT
# If that answers, X-Forwarded-For is forgeable and the lockdown has failed.
#
# --- and prove you did not break the database while closing things down ------
# Section 5 turns a fully open network into a default-deny one, so the risk is
# the mirror image of the usual: not that something is still reachable, but that
# something you depend on quietly is not. Run this on either data node:
#
#   sudo /usr/local/bin/check-cluster.sh
#
# Everything must stay green. The two that fail first if a rule is missing:
#   * "pgbackrest check FAILED"      -> SSH between the data nodes is blocked
#   * "zo-pg-N: state ... not streaming" or "etcd: only N/3 healthy"
#                                    -> replication or the etcd quorum is blocked
#
# Then force the cluster to use the paths a steady state never exercises:
#   sudo -u postgres patronictl -c /etc/patroni/config.yml switchover zuloone --force
#   sudo /usr/local/bin/check-cluster.sh      # on BOTH nodes, still green?
#
# A switchover is the only way to test the reverse-direction rules. Skip it and
# you find out during a real failover instead.
