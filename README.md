# Gate Network System (GNS)

GNS dials Just Stargate Mod gates in OpenComputers from a tablet or computer. Every gate runs the
GNS gate server; players run the GNS client and talk to the gates within wireless range. Gates
and devices prove who they are with keys, so a gate can belong to its owner and the players they
grant, and an address shared between players cannot be altered on the way.

## What it does

- **Dialing.** Scan for gates in range and dial any gate in your address book from any of them.
  The gate dials the shortest address that works, continues glyphs already engaged, can press
  its DHD for a fast dial, closes its iris while the wormhole forms and sends your IDC once it
  is open. Disengage and iris control from the client; the state, energy and server TPS of the gate you use,
  and a drawn stargate that follows the real gate: its chevrons lock, the event horizon bursts
  open and ripples like the show's water, and the iris blades or the shield close over it.
- **Command bar.** Press `;` and type: `d 5` dials gate 5 from the nearest gate, `d 1 2` dials
  gate 2 from gate 1, and every screen's actions have a command (`help` lists them). Several
  commands go on one line, separated by `;`.
- **Keyboard and touch.** Arrows, Tab and Enter move between and press every control; 1-6 open
  the screens. Touch and the mouse work too.
- **Incoming wormholes.** The gate closes its iris for every incoming wormhole and opens it only
  for a known IDC or a signed pass, answering the traveller either way. Until then its
  off-world alarm is up: the gate computer sounds it, and it can drive redstone out to the
  base's lights or doors. A sleeping gate with IDCs shuts its iris
  before it sleeps, so nothing gets through before it wakes. A shield iris needs power to stay
  shut: JSG opens it once the gate's store falls below its draw (500 RF/t by default), asleep or
  not. When the iris cannot move (its mode is not OC, or a shield has no power), the traveller
  is told so, not "Gate is open!".
- **GDO.** Through an open wormhole, the client sends your signed pass to a GNS gate that knows
  you (each pass answers a fresh challenge, so it cannot be replayed), or an IDC to any gate. It
  goes to the gate the wormhole reaches, whoever dialed it; HOME's waits for its own wormhole.
- **Dial-back and routes.** Dial a gate and have it dial you back, paying for the trip; or hand
  your gate a route of several gates, each dialing the next once free. OC modem messages cross
  an open wormhole (JSG repeats them from the far gate at 20 blocks' strength), so the far gate
  hears you however far away it is. Its answers reach you reliably within about 10 blocks of
  your own gate: OC's wireless loses more of them through blocks further out. Routes are signed, so no
  gate on the way needs your address book. Admins can schedule a dial to repeat.
- **Home gate, energy check.** Mark one gate home and dial it with its IDC in one step. `energy`
  shows what a dial costs and how long the wormhole can stay open; each dial logs it too.
- **Hand dials.** When a player dials out by hand on a gate's DHD, the gate keeps the address;
  `save` adds it to the address book of any device that opens the gate (a kiosk keeps it
  hidden).
- **Address book.** Each gate signs its own entry; scanning copies the signed entries into your
  vault, and a changed copy is refused. A gate or device reinstalled with a new key is refused
  until you `trust` it. Edit names, types, addresses, locations and IDCs. A setting hides
  addresses and IDCs, as a client on a gate's own computer (a kiosk) does: there they cannot be
  edited or shared either.
- **Owners and grants.** A network is layered: a port; wake keys (gate servers sleep when idle
  and wake on their own key, or on the DHD's redstone); registration (the device that sets a
  gate up owns it, and its player becomes the gate computer's OC user, so nobody else can type
  there); and roles, through grants. The owner signs a grant for a player's key, as user or
  admin, for one gate or every gate they own; admins grant users too. The gate checks the
  signature, so it keeps no member list, and a grant cut off is refused at every gate it covers
  once the owner's or admin's device has opened it. Grants do not expire.
- **Remote gate console and update.** The owner and admins run a gate's console from the client
  (`ssh`, or CONSOLE on Dial), to set up a gate nobody sits at, and push new GNS code to a gate
  without an internet card (`update`); a gate with one updates itself from GitHub. Either way
  the gate restarts once it is idle, never mid-wormhole. The gate logs each command with the
  player's name.
- **Gate room mode.** The gate computer's screen becomes the dialing room display: the gate with
  its chevrons locking, the wormhole's time left and the traveller log.
- **Chat and sharing.** Chat with GNS devices nearby and share gates with them, with or without
  their IDCs; shares wait for you to accept, and devices can be blocked.
- **Vault.** Your device's key, address book and grants are kept encrypted under your
  password.

## Requirements

- OpenComputers with [QuickOS](https://github.com/Renno231/QuickOS) (its `tnet`, `api` and
  `disco` libraries).
- The `ecc` and `loom` libraries from [Renno-Programs](https://github.com/Renno231/Renno-Programs).
- A wireless network card on every computer.
- Client: a tier-3 GPU. The interface has a wide layout for 160×50 and a compact one for 80×25
  (smaller screens and tablets), chosen by the screen size or in Settings. Developed on a tier-3
  computer with 2 MiB of memory.
- Gate server: a computer connected to a JSG stargate, and to its DHD for fast dials. Set the
  gate's iris mode to OC in its screen (JSG starts it at OPENED, where no computer can move the
  iris); until then GNS dials and lets wormholes in with the iris left as it is, and its status
  says so. A DHD without the chevron upgrade takes 7 symbols; the gate engages the rest.
  Chunk-load the gate server's chunk with the gate's: OC stops a computer whose chunk unloads,
  and a computer in an unloaded chunk next to a loaded gate stops when the gate's ticks load it.

## Install

On a QuickOS computer with an internet card:

```
wget -f https://raw.githubusercontent.com/Renno231/Gate-Network-System/main/install.lua /tmp/gns-install.lua
/tmp/gns-install.lua
```

This installs GNS with `ecc` and the parts of `loom` the client uses. On a gate server, run
`/tmp/gns-install.lua gate` instead: it leaves out the client and loom. `gns update` later
fetches only what changed, keeps the install's kind, and removes files GNS no longer has;
nothing is replaced until every changed file has downloaded. The vault, address book backups,
settings, gate state and gate log are written at run time and never touched by an install or
update. `gns uninstall` keeps them
too, for a reinstall; `gns uninstall --all` deletes them. Both leave the loom and ecc libraries.

Without internet, copy GNS onto a floppy from a computer that has it:

```
gns floppy /mnt/abc
```

This writes `gns.bundle` (about 150 KB) with GNS, loom and ecc, never that computer's vault,
address book, backups, settings, gate state or gate log; `--gate` (or any floppy from a gate server) writes only
the gate server (about 45 KB). On the other QuickOS computer, unpack it and start GNS at
boot:

```
bundle unpack /mnt/xyz/gns.bundle
gns autorun on
```

For an empty computer, make an installer floppy with QuickOS and GNS (it uses QuickOS's
`mkinstaller`; together they take under 460 KB of the floppy's 512, about 310 KB with
`--gate`):

```
gns floppy /mnt/abc --os --gate --own --name=gate-%02d --auto=5
```

`--own` registers every gate installed from the floppy to this device: it asks for the vault
password and your player name. Each gate makes its own wake key, which your device learns the
first time it opens the gate. OC adds your player as the gate computer's OC user only while you
are online: if you were away when the gate first started, it adds you when your device opens it.

Boot the empty computer from it: it installs both hands-off after 5 s as gate-01, gate-02, ...
(a gate server takes its gate's name from the hostname, up to 32 bytes) and reboots into QuickOS once the floppy
is out, where GNS starts on its own (the floppy turns `gns autorun` on at the first boot). Without `--name` it asks for a hostname. `--os=required,qos,sys` packs only those parts
of QuickOS and `--skip=PATH,...` leaves paths out; `--first` and `--label` also go to
mkinstaller. GNS runs the same on computers that boot through `qboot`.

## Use

```
gns                 with a stargate: the gate server in the background, then the client (the
                    gate's console instead where the client is not installed); else the client
gns gate            the gate server's console (on the running gate, or it starts the gate)
gns client          run only the client
gns passwd          change the client vault's password
gns autorun on|off  start gns when the computer boots
gns update          install the newest GNS from GitHub
gns uninstall       remove GNS; the vault, settings and gate state stay (--all removes them)
gns floppy DEST     write gns.bundle to DEST, for bundle unpack on another computer
gns floppy DEST --os  make an installer floppy with QuickOS and GNS for an empty computer
gns floppy ... --gate  only the gate server (no client or loom)
gns floppy ... --own   gates installed from it belong to this device
```

The first client run asks for a password and creates the vault. The client's Guide screen
explains every screen and command. The gate server's console takes `help`, `status`, `close`,
`iris`, `log`, `history`, `idc`, `kawoosh`, `name`, `dim`, `public`, `local`, `port`, `sleep`, `wake`, `redstone`,
`alarm`, `schedule`, `users`, `cut`, `room`, `clear`, `quit` and `stop`; all but `room`, `clear`,
`quit` and `stop` also run remotely for the owner and admins. Only the gate computer's OC users (the owner
and admins) can type at it. On a console opened on a gate running in the background, `quit`
leaves the console and the gate runs on; `stop` stops it.

A client on the gate's own computer reaches its gate like any other (the gate shows as "this
computer"). `local on` makes that client the only device that controls the gate; travellers
still get through the iris with an IDC or a GDO pass. While a client runs there, the gate does
not sleep.

## Design

[docs/design/authentication.md](docs/design/authentication.md) describes the identities,
handshake, signed entries and vault; [docs/design/networks.md](docs/design/networks.md) the
layered networks: ports, wake keys, owners, grants, dial-back, passes and the off-world alarm.
