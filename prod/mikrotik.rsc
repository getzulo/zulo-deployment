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
# 1.1 WHICH ROUTER — this is not one device
# ---------------------------------------------------------------------------
# Measured from the hosts on 2026-09-08 (traceroute + an egress-IP probe from
# each VM), NOT assumed:
#
#   subnet            gateway     egresses as        role
#   core 10.10.0.0/24 10.10.0.1   162.55.72.116      hub, transit 10.255.0.1
#   app  10.10.1.0/24 10.10.1.1   46.225.194.115     spoke
#   data 10.10.2.0/24 10.10.2.1   162.55.72.114      spoke, transit 10.255.0.3
#
#   app -> data traverses THREE routers: 10.10.1.1, 10.255.0.1, 10.255.0.3.
#
# Two consequences, and neither is obvious from the rules themselves:
#
#   * Sections 3, 4 and 6 (dst-nat, the return path and the tenant guard) belong
#     ONLY on the CORE router — 162.55.72.116 is the chosen entry point, and
#     section 3 explains why that choice needs a src-nat rule the app router
#     must NOT have. Importing them anywhere else creates rules that can never
#     match, and a rule that never matches looks exactly like one that works.
#
#   * Section 5 (the inter-tier matrix) is written as if one device sees all
#     inter-subnet traffic. It does not. A packet from app to data passes three
#     routers, so a `drop` on any ONE of them stops it while the other two show
#     nothing. Import section 5 on all three, or the deny is partial in a way
#     that is very hard to see; verify with the checks in section 8 rather than
#     by reading the rule lists.
#
# Confirm the WAN address on the core router before pointing DNS at it. The
# figures above are what each subnet NATs OUT to; inbound normally arrives on
# the same address, but that is a property of your router config, not a law.

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
#
# CHOSEN ENTRY POINT: 162.55.72.116, the CORE router — the same address as
# gw.okrasheno.com.ua. That is a deliberate decision to have one front door,
# and it is NOT the app router's own address.
#
# ### Why this needs a second NAT rule, and what breaks without it
#
# The tenant lives at 10.10.1.220, behind a DIFFERENT router. Measured on the
# host: `ip route get 1.1.1.1` on zo-app-1 answers `via 10.10.1.1` — it sends
# every reply through the APP router, which masquerades to 46.225.194.115.
#
# So with dst-nat alone:
#
#   request   Cloudflare -> 162.55.72.116 (core) -> dst-nat -> zo-app-1
#   reply     zo-app-1 -> 10.10.1.1 (app) -> src-nat -> 46.225.194.115 -> Cloudflare
#
# Cloudflare opened the connection to .116 and the answer arrives from .115, so
# it discards it. Every request times out, both routers show traffic, and
# nothing anywhere logs an error. Asymmetric routing, and it is the single most
# expensive way to get this wrong.
#
# The src-nat rule below fixes it by making the reply come back the way the
# request went: the tenant then sees the connection as coming from the core
# router and answers to it, so both directions traverse the same device.
#
# What that costs: the tenant no longer sees Cloudflare's address. It does not
# matter — Cloudflare puts the real client in CF-Connecting-IP and
# X-Forwarded-For, which is what Core reads either way. But it DOES mean the
# guard in section 4 has to live on core, where the true source is still
# visible. See the warning there.
#
# ### The alternative, for the record
#
# Point the wildcard at 46.225.194.115 instead — the app router's own WAN — and
# both rules below collapse into the dst-nat alone, with no src-nat, no
# asymmetry and the real source address preserved all the way to the tenant.
# It is the simpler design; it was not chosen because it means a second public
# entry point to keep track of.

# --- on the CORE router (10.10.0.1, WAN 162.55.72.116) ---------------------
#
# ### The external port is 8443, not 443
#
# 80 and 443 on this router are already forwarded elsewhere. Cloudflare's
# **Origin Rules -> Destination Port** (available on the Free plan) sends the
# origin connection to a port of your choosing while the client still uses 443,
# so the public address stays `https://rms.zulo.one` with no port in it.
#
#   browser :443 -> Cloudflare edge -> 162.55.72.116:8443 -> 10.10.1.220:443
#
# Note the asymmetry in the rule below: `dst-port=8443` is what arrives from
# Cloudflare, `to-ports=443` is what Traefik listens on. Traefik knows nothing
# about 8443 and needs no change.
#
# There is deliberately NO port 80 rule. **SSL/TLS -> Edge Certificates ->
# Always Use HTTPS** makes Cloudflare answer plain HTTP with a 301 at the edge,
# so it never reaches the origin at all. Traefik's own web->websecure redirect
# stays configured and simply never fires — harmless, and worth keeping for the
# day something reaches it directly.

/ip firewall nat
add chain=dstnat action=dst-nat protocol=tcp dst-port=8443 \
    in-interface-list=WAN src-address-list=cloudflare \
    to-addresses=10.10.1.220 to-ports=443 \
    comment="ZuloOne tenant HTTPS (Cloudflare only, origin port 8443)"

# Return path. Masquerade picks whichever address core uses toward the app
# subnet, so this needs no editing if the transit addressing changes.
# It matches only the connections dst-nat just rewrote — src-address-list is
# still `cloudflare` at this point, because dst-nat changes the destination and
# leaves the source alone. dst-port is 443 here: this rule runs AFTER the
# translation above.
add chain=srcnat action=masquerade protocol=tcp \
    dst-address=10.10.1.220 dst-port=443 src-address-list=cloudflare \
    comment="ZuloOne tenant: return path (see section 3)"

# ---------------------------------------------------------------------------
# 4. Forward filter — belt and braces
# ---------------------------------------------------------------------------
# The NAT rule above already gates on source, so this is redundant by design.
# It exists because a future NAT rule added for some other purpose could
# accidentally expose the same host, and this rule would still catch it.
#
# `dst-port=443`, not 8443: the forward chain sees the packet after dst-nat has
# rewritten it, so by this point it is addressed to 10.10.1.220:443.
#
# ON THE CORE ROUTER ONLY. After the src-nat above, traffic arriving at the app
# router carries core's address, not Cloudflare's — so this same rule installed
# there would match EVERY legitimate request and drop the lot, which reads as
# "the tenant is down" rather than "the firewall is wrong". Here on core it sits
# before the translation and still sees the true source.
#
# ORDER MATTERS. RouterOS evaluates filter rules top to bottom, so this must sit
# ABOVE any broad accept in the forward chain. Check with `/ip firewall filter
# print` and move it if needed:
#   /ip firewall filter move [find comment~"ZuloOne guard"] destination=0

/ip firewall filter
add chain=forward action=drop protocol=tcp \
    dst-address=10.10.1.220 dst-port=443 \
    src-address-list=!cloudflare \
    comment="ZuloOne guard: tenant reachable only via Cloudflare"

# ---------------------------------------------------------------------------
# 4.1 The control plane — a SECOND entry point, on its own port
# ---------------------------------------------------------------------------
# ON THE CORE ROUTER, like section 3. `cp.zulo.one` gets its own Cloudflare
# Origin Rule pointing at port 8444, and that is dst-nat'd straight to zo-cp-1.
#
# Why not route it through Traefik with the tenants: zo-cp-1 is in the CORE
# subnet, the same side of this router as its own gateway, so the reply is
# symmetric and needs no src-nat — unlike the tenant path (see section 3). Sending
# it through zo-app-1 instead would mean the operator's bearer token crossing the
# router in clear on the way to 10.10.0.200, and would put the panel's traffic on
# the same host as customer databases, which §12 of the design doc asks it not to
# be.
#
# The control plane serves TLS itself, using the same Cloudflare Origin CA
# certificate, so there is no second Traefik here and Full (strict) is satisfied.
#
# Cloudflare Access sits in front of cp.zulo.one. That is what authenticates
# operators on this path; the panel additionally verifies the assertion
# cryptographically and checks the address against its own allowlist.

/ip firewall nat
add chain=dstnat action=dst-nat protocol=tcp dst-port=8444 \
    in-interface-list=WAN src-address-list=cloudflare \
    to-addresses=10.10.0.200 to-ports=8443 \
    comment="ZuloOne control plane (Cloudflare only, origin port 8444)"

# Guard, as for the tenants. Worth MORE here than there: with no src-nat on this
# path the true source is still visible at the forward chain, so this rule does
# what it says rather than matching an address of our own.
/ip firewall filter
add chain=forward action=drop protocol=tcp \
    dst-address=10.10.0.200 dst-port=8443 \
    src-address-list=!cloudflare \
    comment="ZuloOne guard: control plane reachable only via Cloudflare"

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
# Farm journal — one mongod on zo-app-1. The control plane provisions
# logs_<slug> and reads the fleet viewer over this path. Tenant containers
# reach the same daemon on the host bridge / hairpin, not through this rule.
add chain=forward action=accept protocol=tcp \
    src-address=10.10.0.200 dst-address=10.10.1.220 dst-port=27017 \
    comment="ZuloOne cp: farm mongo"

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
# 8. Verify — and how to read a failure
# ---------------------------------------------------------------------------
# Count the prefixes (expect 15). An EMPTY list is the most common reason
# nothing works: src-address-list=cloudflare then matches nothing, dst-nat never
# fires, the packet is dropped, and Cloudflare reports 522:
#   :put [:len [/ip firewall address-list find list="cloudflare"]]
#
# Does the rule actually match? A zero packet counter means it never fired, and
# that is a different problem from a rule that fired and failed:
#   /ip firewall nat print stats where comment~"ZuloOne"
#   /ip firewall filter print stats where comment~"ZuloOne"
#
# Does the interface list exist? `in-interface-list=WAN` silently matches nothing
# if it does not:
#   /interface list member print
#
# Watch translations arrive while you load the site:
#   /ip firewall connection print where dst-address~":443"
#
# ### Reading Cloudflare's error codes — each one points somewhere different
#
#   521  the origin REFUSED the connection. Cloudflare reached the address and
#        something sent RST. Usually: no dst-nat rule for that port at all.
#   522  Cloudflare sent SYN and got silence. Usually: the rule exists but does
#        not match (empty address list, wrong interface list, wrong router), or
#        the return path is missing — see section 3.
#   525  TLS handshake failed. The port is reaching something that does not
#        speak TLS, e.g. dst-nat pointed at 80 instead of 443.
#   526  the origin certificate is not trusted. Under Full (strict) this is the
#        placeholder cert still in place, or one whose SAN omits the hostname.
#
# Then, from any machine OUTSIDE Cloudflare, prove the origin is closed:
#   curl -m 5 -sk https://162.55.72.116:8443/health   # must TIME OUT
#   curl -m 5 -sk https://46.225.194.115/health       # must TIME OUT — the app
#                                                     # router's WAN is not the
#                                                     # entry point
# If either answers, X-Forwarded-For is forgeable and the lockdown has failed.
#
# Then prove the return path, which dst-nat alone would leave broken:
#   curl -sv https://t1.zulo.one/health 2>&1 | grep -i 'connected to'
# A 522 while the dst-nat counter is climbing is the asymmetric-routing failure
# from section 3 — the src-nat rule is missing.
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
