# Oracle TubeRepair test deployment

This deployment keeps the iPhone side unchanged.

Architecture:

```
stock iPhone YouTube.app
        |
        | later, same aydreyoutube2g.duckdns.org endpoint
        v
Modified TubeRepair
        |
        +--> private Invidious Companion (first playback source)
        |
        +--> original upstream yt-dlp fallback
```

For the first test, do **not** change DuckDNS and do **not** change anything
on the iPhone. Test the Oracle VM directly from a modern Mac.

## VM

Recommended Always Free configuration:

- Ubuntu 24.04 aarch64
- VM.Standard.A1.Flex
- 2 OCPUs
- 12 GB memory
- public IPv4 enabled
- IPv6 enabled on the VCN/subnet if available

OCI documents 1,500 A1 OCPU-hours and 9,000 GB-hours per month as Always Free,
equivalent to 2 OCPUs and 12 GB RAM continuously.

Allow inbound TCP 22 for SSH and TCP 10000 temporarily for the direct test.
After validation, expose only 80/443 through a reverse proxy.

## Install

Clone the `youtube-2g-server` branch, then:

```bash
cd world-wide-web/youtube-2g/oracle
bash setup-oracle.sh
```

For initial playback testing, Google OAuth variables may remain blank.

## Test from Mac

Replace `ORACLE_IP` with the VM public IPv4:

```bash
curl -s http://ORACLE_IP:10000/healthz
```

Then test the first two bytes of a real video:

```bash
curl -sS -D - \
  --range 0-1 \
  -o /dev/null \
  'http://ORACLE_IP:10000/getvideo/jNQXAC9IVRw'
```

Success is HTTP 200 or 206 with a video content type, not HTML.

Only after that succeeds should the DuckDNS hostname be moved from Render to
the Oracle VM.

## IPv6

OCI allows up to 32 secondary IPv6 addresses on a VNIC. Oracle-controlled
address assignment means Invidious Companion cannot safely assume that every
address in the subnet /64 can be used. Start with the VM's assigned IPv6
address. If YouTube later blocks it, additional OCI-assigned IPv6 addresses
can be added and rotated without changing the iPhone.
