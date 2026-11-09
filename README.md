# Gate Network System (GNS)

GNS dials Just Stargate Mod gates in OpenComputers from a tablet or computer. Every gate runs the
GNS gate server; players run the GNS client and talk to the gates within wireless range. Gates
and devices prove who they are with keys, so a gate can be kept private to a network of players,
and an address shared between players cannot be altered on the way.

## What it does

- **Dialing.** Scan for gates in range and dial any gate in your address book from any of them.
  The gate dials the shortest address that works, continues glyphs already engaged, can press
  its DHD for a fast dial, closes its iris while the wormhole forms and sends your IDC once it
  is open. Disengage and iris control from the client; live gate state, energy and server TPS,
  and a drawn stargate that follows the real gate: its chevrons lock, the event horizon bursts
  open and ripples like the show's water, and the iris blades or the shield close over it.
- **Command bar.** Press `;` and type: `d 5` dials gate 5 from the nearest gate, `d 1 2` dials
  gate 2 from gate 1, and every screen's actions have a command (`help` lists them). Several
  commands go on one line, separated by `;`.
- **Keyboard and touch.** Arrows, Tab and Enter move between and press every control; 1-6 open
  the screens. Touch and the mouse work too.
- **Incoming wormholes.** The gate closes its iris for every incoming wormhole and opens it only
  for a known IDC, answering the traveller either way.
- **Address book.** Each gate signs its own entry; scanning copies the signed entries into your
  vault, and a changed copy is refused. Edit names, types, addresses, locations and IDCs.
- **Private networks.** A founder creates a network, invites members by fingerprint as user,
  moderator or admin, and adds gates. A private gate serves only members; revoking a member cuts
  them off at every gate.
- **Remote gate console.** An admin of a gate's network runs that gate's console from the client
  (`ssh`, or CONSOLE on Dial), to set up a gate nobody sits at: rename it, set its IDCs, read its
  log, sync its address book. The gate logs each command with the admin's fingerprint.
- **Chat and sharing.** Chat with GNS devices nearby and share gates with them, with or without
  their IDCs; shares wait for you to accept, and devices can be blocked.
- **Vault.** Your device's key, address book and memberships are kept encrypted under your
  password.

## Requirements

- OpenComputers with [QuickOS](https://github.com/Renno231/QuickOS) (its `tnet`, `api` and
  `disco` libraries).
- The `ecc` and `loom` libraries from [Renno-Programs](https://github.com/Renno231/Renno-Programs).
- A wireless network card on every computer.
- Client: a tier-3 GPU. The interface has a wide layout for 160×50 and a compact one for 80×25
  (smaller screens and tablets), chosen by the screen size or in Settings. Developed on a tier-3
  computer with 2 MiB of memory.
- Gate server: a computer connected to a JSG stargate, and to its DHD for fast dials.

## Install

On a QuickOS computer with an internet card:

```
wget -f https://raw.githubusercontent.com/Renno231/Gate-Network-System/main/install.lua /tmp/gns-install.lua
/tmp/gns-install.lua
```

This installs GNS with the `loom` and `ecc` libraries. `gns update` later fetches only what
changed; nothing is replaced until every changed file has downloaded. The vault, settings and
gate state are written at run time and never touched by an install or update.

Without internet, copy GNS onto a floppy from a computer that has it:

```
gns floppy /mnt/abc
```

This writes `gns.bundle` (about 190 KB) with GNS, loom and ecc, never that computer's vault,
address book, settings or gate state. On the other QuickOS computer, unpack it and start GNS at
boot:

```
bundle unpack /mnt/xyz/gns.bundle
gns autorun on
```

For an empty computer, make an installer floppy with QuickOS and GNS (it uses QuickOS's
`mkinstaller`; together they take about 460 KB of the floppy's 512):

```
gns floppy /mnt/abc --os --name=gate-%02d --auto=5
```

Boot the empty computer from it: it installs both hands-off after 5 s as gate-01, gate-02, ...
(a gate server takes its gate's name from the hostname) and reboots into QuickOS once the floppy
is out. Without `--name` it asks for a hostname. `--os=required,qos,sys` packs only those parts
of QuickOS and `--skip=PATH,...` leaves paths out; `--first` and `--label` also go to
mkinstaller. GNS runs the same on computers that boot through `qboot`.

## Use

```
gns                 run the gate server (with a stargate) or the client
gns client          run the client
gns passwd          change the client vault's password
gns autorun on|off  start gns when the computer boots
gns update          install the newest GNS from GitHub
gns floppy DEST     write gns.bundle to DEST, for bundle unpack on another computer
gns floppy DEST --os  make an installer floppy with QuickOS and GNS for an empty computer
```

The first client run asks for a password and creates the vault. The client's Guide screen
explains every screen and command. The gate server's console takes `help`, `status`, `close`,
`iris`, `log`, `idc`, `kawoosh`, `name`, `dim`, `book`, `sync`, `trust`, `clear` and `quit`; all but
`clear` and `quit` also run remotely for admins.

## Design

[docs/design/authentication.md](docs/design/authentication.md) describes the identities,
handshake, signed entries, networks and vault.
