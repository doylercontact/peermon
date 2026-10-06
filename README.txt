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
  install.sh         installer
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


INSTALL
-------
1. Copy all files to each VM.
2. Edit the env file for that VM and replace the placeholder with the
   neighbor's IP:
     vm-a.env:  PEER_URL=http://<vm-b-ip>:8000
     vm-b.env:  PEER_URL=http://<vm-a-ip>:8000
3. Run the installer:
     on VM A:   sudo ./install.sh vm-a.env
     on VM B:   sudo ./install.sh vm-b.env
   It installs python3-venv and chrony, creates a "peermon" service user,
   installs the app under /opt/peermon, and starts it under systemd.
4. Open TCP port 8000:
     - between the two VMs (both directions)
     - from wherever the client will run
5. Check it:
     curl http://<vm-ip>:8000/neighbor


OPERATING NOTES
---------------
- Run exactly ONE uvicorn worker. Each extra worker would start its own
  checker. The systemd unit already sets --workers 1.
- Keep chrony running on both VMs. You will compare timestamps from two
  machines, so their clocks must agree; clock_skew_ms shows how well they do.
- Pin exact package versions in requirements.txt once tested.
- Useful commands:
    systemctl status peermon
    journalctl -u peermon -f
    sudo systemctl restart peermon
