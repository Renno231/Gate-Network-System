# Gate Network System (GNS)

GNS dials Just Stargate Mod (JSG) gates in OpenComputers from a tablet or a computer. Every gate
has a computer next to it running the GNS gate server; players carry the GNS client on a tablet
(or run it on a computer) and talk to the gates within wireless range. Gates and devices prove
who they are with keys, so a gate can belong to its owner and the players they grant, and an
address shared between players cannot be altered on the way.

- [What you need](#what-you-need)
- [Install](#install): from the internet in one line, from a floppy, or hands-off on empty computers
- [Set up a gate](#set-up-a-gate)
- [Start dialing](#start-dialing)
- [Who owns a gate](#who-owns-a-gate)
- [Sharing with other players](#sharing-with-other-players)
- [Travelling](#travelling)
- [Commands](#commands)
- [Update and uninstall](#update-and-uninstall)
- [What it does](#what-it-does), in full

## What you need

**Mods:** OpenComputers and Just Stargate Mod.

**Every computer and tablet** runs [QuickOS](https://github.com/Renno231/QuickOS) (GNS uses its
`tnet`, `api` and `disco` libraries) and has a **tier-2 wireless network card** (range 400; a
tier-1 card's 16 blocks is too short to use). The installer brings the `ecc` and `loom` libraries
from [Renno-Programs](https://github.com/Renno231/Renno-Programs) with it.

**A gate computer:** a computer case touching the stargate's base block, so the gate is its
`stargate` component, and the DHD touching the computer case for fast dials. A redstone card is
optional: it lets the DHD's redstone wake a sleeping gate and drives the off-world alarm's
redstone.

**A tablet** (the usual client): a tier-2 tablet case with two 512 KB memory sticks (1 MB), a
tier-2 or tier-3 graphics card, the wireless card and a hard drive. It gets the compact layout
for its 80×25 screen. **A computer** with a tier-3 screen and graphics card (160×50) and 2 MB of
memory gets the wide layout with the big drawn gate.

## Install

### From the internet (a computer or tablet with an internet card)

1. Start with OpenOS installed on the computer's or tablet's hard drive and an internet card in
   it. Install QuickOS, then follow its install wizard:

   ```
   pastebin run id5ZWJp8
   ```

2. Install GNS with one line:

   ```
   wget -f https://raw.githubusercontent.com/Renno231/Gate-Network-System/main/install.lua /tmp/gns-install.lua && /tmp/gns-install.lua
   ```

   On a gate computer, add `gate` at the end: it leaves out the client and its drawing library.

   Typing a long line in OC is no fun: copy it here, then press **Insert** (or click the middle
   mouse button) on the OC screen to paste it.

3. Start GNS at boot, then start it now:

   ```
   gns autorun on
   gns
   ```

`gns update` later fetches only the files that changed and keeps the install's kind (gate or
full). Nothing is replaced until every changed file has arrived, so a dropped connection leaves
the old install whole.

### From a floppy (no internet card)

On a computer that has GNS, write it to a floppy (about 150 KB with the client, 45 KB with
`--gate` or from a gate computer):

```
gns floppy /mnt/abc
```

The floppy gets GNS and its libraries, never that computer's vault, address book, backups,
settings, gate state or gate log. On the other QuickOS computer:

```
bundle unpack /mnt/xyz/gns.bundle
gns autorun on
```

### Hands-off on empty computers (an installer floppy)

For a computer with an empty hard drive, make an installer floppy with QuickOS and GNS on it
(under 460 KB of the floppy's 512; about 310 KB with `--gate`):

```
gns floppy /mnt/abc --os --gate --own --name=gate-%02d --auto=5
```

Boot the empty computer with the floppy in its drive: after 5 s it installs QuickOS and GNS on
its own as gate-01, gate-02, ... (a gate takes its name from the hostname), and once the floppy
is out it reboots into QuickOS and starts GNS. Without `--name` it asks for a hostname. Who owns
the gates it installs depends on the floppy (see [Who owns a gate](#who-owns-a-gate)):

| Floppy made with | The gates it installs |
|---|---|
| (neither) | public: anyone may use them, nobody can claim them |
| `--own` | yours from the start: it asks for your vault password and your player name |
| `--own --silent` | yours, and silent: they answer only you and players with access |
| `--unregistered` | the first player whose device runs SET UP on one owns it |

A tablet has no disk drive. To make an `--own` floppy for your tablet's key, put the tablet in a
charger connected to a computer case with a disk drive, boot from the tablet's hard drive, and
make the floppy there.

`--os=required,qos,sys` packs only those parts of QuickOS, `--skip=PATH,...` leaves paths out,
and `--first` and `--label` go to QuickOS's `mkinstaller`.

## Set up a gate

1. Place the gate computer touching the stargate's base, and the DHD touching the computer.
2. In the gate's own screen (right-click the base), set the **iris mode to OC**. JSG starts it at
   OPENED, where no computer can move the iris; until you change it GNS dials and lets wormholes
   in with the iris left as it is, and its status says so.
3. **Chunk-load** the gate computer's chunk together with the gate's. OC stops a computer whose
   chunk unloads, and a computer in an unloaded chunk next to a loaded gate stops when the gate's
   ticks load it.
4. Install GNS with `gate` (or from an installer floppy), and run `gns autorun on`. `gns` starts
   the gate server; its console prompt is `gate>` and `help` lists its commands.

The gate names itself after the computer's hostname (up to 32 bytes); `name <name>` at its
console renames it. Once someone owns it, a gate sleeps after 5 idle minutes; the owner's and
grant holders' devices wake it with its wake key, or a redstone signal from the DHD does.

## Start dialing

1. Run `gns` on your tablet. The first run asks for a password: it locks your **vault**, which
   holds your device's key, your address book and your grants.
2. **SCAN** finds the gates in range. Each one sends its own signed entry, so its name and
   address go into your address book.
3. Pick the gate to dial **from** among the gates in range and the **destination** in your
   address book, and press **DIAL**. Picking the destination shows what the dial costs and how
   long the wormhole can stay open on the power stored.
4. **DISENGAGE** closes the wormhole you opened; **IRIS** opens or shuts the iris.

Everything also works from the command bar: press `;`, then for example `d 5` (dial gate 5 from
the nearest gate) or `d abydos chulak 1234` (dial Chulak from Abydos and send IDC 1234 once it
opens). The client's **Guide** screen explains every screen and command.

To add a gate you have not scanned, type its address on the GATES screen (EDIT ADDRESS, glyph by
glyph), or let GNS work out all three addresses from its location (GENERATE). `import ags` adds
the gates of an AGS address book.

## Who owns a gate

A gate starts in one of three ways:

- **Public, the default.** A plain install belongs to everyone: anyone in range may use it, and
  nobody can claim it. On a server with many players and gates, this keeps gates from being
  taken by whoever reaches them first.
- **Yours from the start**, installed from a floppy made with `--own`.
- **Unregistered**, installed from a floppy made with `--unregistered`. The first player whose
  device runs **SET UP** on it owns it. On a tablet, the Dial screen offers that in one tap when
  such a gate is picked in range.

Owning a gate makes your player its computer's OC user (nobody else can type at it) and gives
your device its wake key. An owned gate is private: only you and the players you grant can use
it. At its console (or from your device with `ssh <gate>`), you decide:

```
allow                        who may use each control now
allow dial anyone            let anyone in range dial (the iris stays yours and your players')
allow iris admins            only you and your admins move the iris
allow close owner            only you close its wormholes
silent on                    answer only you and players with access: to anyone else it is no gate at all
owner public                 give the gate away to the public: nobody owns it or can claim it again
```

Each control (`dial`, `close`, `iris`) takes `anyone`, `users` (anyone you granted; the
default), `admins` or `owner`.

**Network profiles** on your device hold these settings for a whole network of gates (Settings,
PROFILES, or `profile silent <name> on`). A gate takes its profile's settings when you set it up
and keeps its own after. When a gate you own differs from its profile, picking it on the Dial
screen offers to APPLY the profile in one tap.

## Sharing with other players

- **Grants.** INVITE (ACCESS screen) offers players nearby a grant: the role (user, or admin
  from the owner) and which gates it covers (one, or every gate you own). They press JOIN.
  Users dial and work the controls the gate allows; admins also run its console, read its log,
  schedule dials and push updates, and become its computer's OC users. Admins can grant users.
  Grants do not expire.
- **Cutting off.** CUT OFF ends a grant you issued; each gate it covers learns it the next time
  your device opens that gate. Cutting off an admin cuts off the users they granted too.
- **Sharing addresses.** On the CHAT screen, FIND looks for GNS devices in range; SHARE offers
  them gates, with or without their IDCs. Shared gates wait for the other player to ACCEPT.
  Each entry is signed by its gate, so nobody can alter an address on the way.

## Travelling

- **Incoming wormholes.** The gate closes its iris for every incoming wormhole and opens it only
  for a known IDC or a signed pass, answering the traveller either way. Until then its
  off-world alarm is up: the gate computer sounds it, and with `alarm <side>` it drives redstone
  out to the base's lights or doors. `idc add <code> <name>` at the console adds a code.
- **GDO.** Through an open wormhole, GDO sends your signed pass to a GNS gate that knows you, or
  an IDC to any gate.
- **Dial-back.** Dial a gate and type `back`: once the wormhole is open the far gate dials you
  back, paying for the trip. `route <gate> <gate> ...` chains this through several gates.
  Modem messages cross an open wormhole, so the far gate hears you however far away it is; its
  answers reach you within about 10 blocks of your own gate.
- **Home.** `home set <gate>` marks your home gate; `home` dials it with its IDC in one step.
- **Hand dials.** When a player dials by hand at a gate's DHD, the gate keeps the address, and
  `save` (or one tap on a tablet) adds it to your address book.

## Commands

At the shell:

```
gns                 with a stargate: the gate server in the background, then the client (the
                    gate's console where the client is not installed); else the client
gns gate            the gate server's console (on the running gate, or it starts the gate)
gns client          only the client, even on a gate computer
gns passwd          change the vault's password
gns autorun on|off  start gns when the computer boots
gns update          install the newest GNS from GitHub
gns uninstall       remove GNS; the vault, settings and gate state stay (--all removes them)
gns floppy DEST     GNS on a floppy, for bundle unpack on another computer
gns floppy DEST --os  an installer floppy with QuickOS and GNS for empty computers
gns floppy ... --gate  only the gate server
gns floppy ... --own [--silent] | --unregistered   who owns the gates it installs
gns help            this list
```

At a gate's console (`gate>`; the owner and admins also run them remotely with `ssh <gate>` or
CONSOLE on Dial, all but `room`, `clear`, `quit` and `stop`):

```
status              state, iris, owner and who may use what, port, wake key, sleep, alarm
name <name>         rename the gate
dim <number>        the dimension in the gate's entry
close               stop the dial or close the outgoing wormhole
iris [open|close]   open or close the iris
log                 recent dialing, iris, IDC and route events
history [n]         who did what here, newest first
idc                 the IDCs that open the iris; idc add <code> <name>; idc remove <code>
kawoosh on|off      close the iris while the wormhole forms
allow [dial|close|iris] [anyone|users|admins|owner]
silent on|off       answer only the owner and players with access
owner public        give the gate to the public (the owner only)
local on|off        take commands only from the client on this computer
port <number>       the modem port of this gate's network (restart gns after)
sleep <minutes>|off shut down when idle; the wake key or the DHD wakes it
wake new            a new wake key (grant holders get it when they next open the gate)
redstone <level>|off  the DHD redstone level that wakes the gate
alarm <side>|all|off  redstone out on an off-world activation
schedule            scheduled dials; schedule remove <n>
users, cut          the computer's OC users; how many grants it has cut off
room [on|off]       gate room mode: the screen shows the dialing room
clear               clear the screen
quit                leave the console; the gate runs on (where gns gate started it: stop it)
stop                stop the gate
```

The client's commands (`;` then `help`) are listed on its Guide screen.

## Update and uninstall

- `gns update` (internet card) installs the newest GNS. A gate with an internet card also
  updates itself from GitHub every 2 hours. A gate without one gets new code from an admin's
  device: `update <gate>` in the client.
- Either way a gate restarts once it is idle, never mid-wormhole.
- `gns uninstall` removes GNS and keeps the vault, address book backups, settings, gate state
  and gate log for a reinstall; `gns uninstall --all` deletes them too. Both leave the loom and
  ecc libraries.

## What it does

- **Dialing.** The gate dials the shortest address that works, continues glyphs already
  engaged, can press its DHD for a fast dial, closes its iris while the wormhole forms and sends
  your IDC once it is open. The client shows the state, energy and server TPS of the gate you
  use, and a drawn stargate that follows the real gate: its chevrons lock, the event horizon
  bursts open and ripples, and the iris blades or the shield close over it.
- **Keyboard and touch.** Arrows, Tab and Enter move between and press every control; 1-6 open
  the screens; touch and the mouse work too. Several commands go on one line, separated by `;`.
- **Shields.** A shield iris needs power to stay shut: JSG opens it once the gate's store falls
  below its draw (500 RF/t by default), asleep or not. When the iris cannot move (its mode is
  not OC, or a shield has no power), the traveller is told so, not "Gate is open!".
- **Energy.** `energy` shows what a dial costs and how long the wormhole can stay open; each
  dial logs it too.
- **Address book.** Each gate signs its own entry; scanning copies the signed entries into your
  vault, and a changed copy is refused. A gate or device reinstalled with a new key is refused
  until you `trust` it. A setting hides addresses and IDCs, as a client on a gate's own
  computer (a kiosk) does: there they cannot be edited or shared either. Backups of the address
  book: `backup`, `backups`, `restore <n>`.
- **Sleeping gates.** An owned gate sleeps when idle and wakes on its own wake key or the DHD's
  redstone. A sleeping gate with IDCs shuts its iris before it sleeps, so nothing gets through
  before it wakes.
- **Remote console and update.** The owner and admins run a gate's console from the client, to
  set up a gate nobody sits at, and push new GNS code to a gate without an internet card. The
  gate logs each command with the player's name. Admins can schedule a dial to repeat.
- **Gate room mode.** The gate computer's screen becomes the dialing room display: the gate with
  its chevrons locking, the wormhole's time left and the traveller log.
- **A client on the gate's computer** reaches its gate like any other (it shows as "this
  computer"). `local on` makes it the only device that controls the gate; travellers still get
  through the iris with an IDC or a GDO pass. While a client runs there, the gate does not sleep.
