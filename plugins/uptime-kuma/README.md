# Uptime Kuma

Your [Uptime Kuma](https://github.com/louislam/uptime-kuma) monitors in
Beacle: an **Uptime Kuma** tab with a tile per monitor (up, down, pending or
in maintenance) and its response time over the last day, an alert while a
watched monitor is down — with your notifications — and a card on the
Overview then. It runs in the panel only; nothing is installed on servers.

## Setting it up

Install it from **Settings → Plugins → Marketplace**; its setup screen opens
by itself (later: **Configure** on its card).

1. **Uptime Kuma address** — where it answers, e.g. `http://192.168.1.10:3001`.
2. **Read from**
   - **metrics** — every monitor, with response times. Needs an API key:
     Uptime Kuma → *Settings → API Keys → Generate*.
   - **status page** — the monitors on one public status page, by its slug
     (the end of its address, `/status/<slug>`). No key.
3. **Connect** — the monitors it finds are listed. Tick the ones to watch;
   none ticked watches all of them.

Then how often to read (15 s to 5 min) and whether a monitor that is down
raises an alert.

## What the install dialog says

It reaches nothing but the address you type in its settings, so the dialog
lists no network permission. The API key stays on this computer.

## Notes

- Uptime Kuma itself decides when a monitor is down (its retries,
  intervals). Beacle passes that on; when it cannot read Uptime Kuma at all
  it says so in the tab and raises nothing — Kuma being out of reach says
  nothing about your services.
- A monitor taken off the list, or removed in Uptime Kuma, has its alert
  resolved.
