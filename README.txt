PEERMON - NEIGHBOR HEALTH MONITOR FOR THE RESILIENCY POC
=========================================================

Two Ubuntu VMs, one per site, each running the same FastAPI app. Each VM
checks its neighbor every few seconds and keeps a local history. A client
outside both sites polls each VM for its latest view of the neighbor.

Only the environment file differs between the two VMs.


HOW IT WORKS
------------
- A background task inside the app calls the neighbor's /health endpoint
  every 5 seconds, with a 2-second timeout.
- Every check opens a fresh TCP connection (no keep-alive), the way a real
  client would.
- Each result is written to a small SQLite file on the VM.
- After 3 consecutive failures (about 15 seconds) the neighbor is declared
  DOWN. The first successful check after that declares it UP again.
- History is kept for 72 hours by default, then purged automatically.


WHAT EACH CHECK RECORDS
-----------------------
  seq            sequence number
  ts_utc         time the check was sent (UTC)
  ok             1 = neighbor answered correctly, 0 = failed
  latency_ms     round-trip time of the check
  http_status    HTTP status code, if any
  error          type of failure, if any (see below)
  peer_boot_id   neighbor's boot ID; it changes on every restart, so a quick
                 reboot that never trips the failure threshold is still caught
  clock_skew_ms  estimated offset between the two VMs' clocks, so you know
                 whether their timestamps can be compared

Error types:
  timeout        no answer at all - the VM or the network is gone
  refused        VM is up, but the app isn't listening
  connect_error  any other connection failure
  http_error     the app answered with a non-200 status
  wrong_peer     something answered, but it wasn't the expected neighbor


ENDPOINTS
---------
  GET /health
      Identity, boot ID and current time. This is what the neighbor checks.

  GET /neighbor
      Current view of the neighbor: up / down / unknown, since when,
      consecutive failures, last success, last check.
      This is what the client polls.

  GET /history?minutes=30
      Raw checks for the last N minutes, for building the timeline after a
      test. Optional: &limit=5000

  GET /events?minutes=1440
      State changes only: node started, peer down, peer up (with the outage
      duration measured from the first failed check), peer restarted.

Example /events output after the neighbor was stopped and restarted:

  peer_down       from up; connect_error x3; first failed check 00:38:05.333
  peer_restarted  boot_id 1a94... -> e55d...
  peer_up         from down; outage 5.0s since first failed check 00:38:05.333


FILES
-----
  app.py             the application (same on both VMs)
  requirements.txt   Python packages (fastapi, uvicorn, httpx)
  peermon.service    systemd unit
  vm-a.env           settings for VM A (site A, neighbor = vm-b)
  vm-b.env           settings for VM B (site B, neighbor = vm-a)
  peermonctl         command-line wrapper (see PEERMONCTL below)
  peermon-firewall   host firewall for port 8000 (see HOST FIREWALL below)
  peermon-firewall.service   systemd unit that re-applies the firewall at boot
  install.sh         installer (safe to re-run)
  uninstall.sh       uninstaller (safe to re-run)
  README.txt         this file


SETTINGS (env file, installed as /etc/peermon.env)
--------------------------------------------------
  NODE_NAME        this VM's name (vm-a / vm-b)
  SITE             this VM's site (A / B)
  PEER_NAME        neighbor's name; must match the neighbor's NODE_NAME
  PEER_URL         neighbor's address, e.g. http://10.0.2.10:8000
  CHECK_INTERVAL   seconds between checks (default 5)
  CHECK_TIMEOUT    seconds before a check counts as a timeout (default 2)
  FAIL_THRESHOLD   consecutive failures before DOWN (default 3)
  DB_PATH          history file (default /var/lib/peermon/checks.db)
  RETENTION_HOURS  how long history is kept (default 72)
  FIREWALL_ALLOW   extra hosts allowed to reach port 8000 when the host
                   firewall is enabled: space-separated IPs, CIDRs or
                   hostnames, e.g. FIREWALL_ALLOW="10.0.5.20 10.0.6.0/24".
                   The peer is always allowed; leave empty for peer only.


INSTALL
-------
1. Copy all files to each VM (git clone or scp).
2. Edit the env file for that VM:
     vm-a.env:  PEER_URL=http://<vm-b-ip>:8000
     vm-b.env:  PEER_URL=http://<vm-a-ip>:8000
   If you will use the host firewall and want a monitoring host to reach
   port 8000, add it to FIREWALL_ALLOW as well.
3. Run the installer:
     on VM A:   sudo ./install.sh vm-a.env
     on VM B:   sudo ./install.sh vm-b.env
   Add --firewall to also turn on the host firewall:
                sudo ./install.sh --firewall vm-a.env
   The installer installs python3-venv, chrony and nftables, creates a
   "peermon" service user, installs the app under /opt/peermon, installs
   peermonctl and peermon-firewall to /usr/local/bin, and starts peermon
   under systemd.
4. Open TCP port 8000 in the platform firewall (AWS security group, Azure
   NSG, Nutanix Flow or router ACL):
     - between the two VMs (both directions)
     - from wherever the client or a monitoring host will run
5. Check it:
     peermonctl status
     sudo peermon-firewall status

Re-running install.sh is safe: it updates the code and settings in place
and restarts peermon. Use it after a git pull or after editing the env file.


HOST FIREWALL
-------------
Optional, on top of the platform firewall. On AWS the security group is
the main control and this is defense in depth; on Nutanix without Flow it
may be the only control on port 8000.

How it works:
  - A dedicated nftables table (inet peermon) that touches ONLY tcp/8000.
  - Accepts port 8000 from: localhost, the peer (taken from PEER_URL), and
    any FIREWALL_ALLOW hosts. Drops everything else.
  - Dropped, not rejected, to match security-group behavior: a host that
    is not allowed sees a timeout.
  - SSH and all other traffic are untouched, so it cannot lock you out.
  - Covers IPv4 and IPv6. Hostnames are resolved when the rules are applied.
  - A systemd unit (peermon-firewall.service) re-applies the rules at boot.
  - If ufw is active, matching "ufw allow" rules (comment: peermon) are
    added too, because ufw would otherwise block port 8000 on its own.

Commands:
  sudo peermon-firewall enable    apply now and at every boot
  sudo peermon-firewall disable   remove the rules and stop applying at boot
  sudo peermon-firewall reload    re-read /etc/peermon.env and re-apply
  sudo peermon-firewall status    rules, drop counter and boot state

Post-install changes, e.g. adding a monitoring host:
  1. sudo nano /etc/peermon.env      (edit FIREWALL_ALLOW)
  2. sudo peermon-firewall reload
No reinstall or peermon restart is needed.

Example status:
  $ sudo peermon-firewall status
  boot state: enabled
  rules: active
  table inet peermon {
    chain input {
      type filter hook input priority filter - 1; policy accept;
      iif "lo" tcp dport 8000 accept
      tcp dport 8000 ip saddr { 10.0.2.10, 10.0.5.20 } accept
      tcp dport 8000 counter packets 12 bytes 720 drop comment "peermon: not on allow list"
    }
  }
The drop counter shows how many packets from unlisted hosts were blocked.

Note: restarting nftables.service flushes all rules; peermon-firewall
re-applies automatically when that happens. If you flush rules by hand
(nft flush ruleset), run: sudo peermon-firewall reload


UNINSTALL
---------
  sudo ./uninstall.sh            remove peermon, keep the check history
  sudo ./uninstall.sh --purge    also delete the history and the peermon user

Removes: the peermon and peermon-firewall services, the firewall rules
(and any peermon ufw rules), /opt/peermon, /usr/local/bin/peermonctl,
/usr/local/bin/peermon-firewall and /etc/peermon.env.

By default the history in /var/lib/peermon is kept, because it is your
test evidence. Safe to run more than once.


PEERMONCTL - COMMAND-LINE WRAPPER
---------------------------------
Installed to /usr/local/bin/peermonctl. Python standard library only.

By default it queries the PEER named in /etc/peermon.env, so on vm-a it asks
vm-b and on vm-b it asks vm-a. Unlike curl, it never just fails when the
target is down:

  status    one-line summary; if the target is down, also shows this
            node's view of it
  health    target's identity, or a "status: down" record with the reason
  neighbor  target's view of its peer, or a "status: down" record plus
            this node's view of the target ("seen_from")
  events    target's events; if the target is down, falls back to this
            node's events (which show the peer going down) and appends a
            final "peer_down" entry
  history   same, for the raw checks

Down reasons:
  refused       nothing listening - VM up, app down
  timeout       no answer - VM or network down
  unreachable   any other network error
  http_error    app answered with an error

Options:
  --peer            query the peer from /etc/peermon.env (default)
  --local           query this node
  --host URL        query any node, e.g. --host http://10.0.2.10:8000
  --pretty          indented JSON (like jq)
  --table           human-readable table or key/value view
  --json            compact JSON (default, except for status)
  --minutes N       events/history window (default 30)
  --limit N         history row limit (default 5000)
  --last N          show only the last N events/history rows
  --timeout SEC     seconds before the target counts as down (default 3)
  --watch SEC       repeat every SEC seconds until Ctrl-C

Exit code: 0 = target reachable, 1 = target down, 2 = usage error.

Examples:
  peermonctl status
  peermonctl status --watch 5
  peermonctl neighbor --pretty
  peermonctl events --table --minutes 60
  peermonctl history --table --last 20
  peermonctl events --local --pretty

Example with vm-b's app stopped, run on vm-a:

  $ peermonctl status
  vm-b: DOWN  -  refused (nothing listening: VM up, app down)
  vm-a: sees vm-b DOWN since 2026-10-07 00:13:21.317  (5 consecutive failures)

  $ peermonctl events --table
  # node=vm-a  peer=vm-b  source=local fallback: vm-b is down
  id  ts_utc                   event         detail
  --  -----------------------  ------------  ---------------------------------
  1   2026-10-07 00:13:15.219  node_started  boot_id ed85eeff0a34; peer vm-b ...
  2   2026-10-07 00:13:15.312  peer_up       from unknown
  3   2026-10-07 00:13:21.317  peer_down     from up; refused x3; first fai...
  -   2026-10-07 00:13:23.674  peer_down     vm-b unreachable from peermonc...


OPERATING NOTES
---------------
- Run exactly ONE uvicorn worker. Each extra worker would start its own
  checker. The systemd unit already sets --workers 1.
- Keep chrony running on both VMs. You will compare timestamps from two
  machines, so their clocks must agree; clock_skew_ms shows how well they do.
- Pin exact package versions in requirements.txt once tested.
- Useful commands:
    peermonctl status --watch 5
    sudo peermon-firewall status
    systemctl status peermon
    journalctl -u peermon -f
    sudo systemctl restart peermon
