-- Guide screen: how to use GNS. Up and Down (or the mouse wheel) scroll it.
local _, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C

local TEXT = [[
#GATE NETWORK SYSTEM
GNS dials stargates from a tablet or computer. Each gate runs the GNS gate server; your device runs this client and talks to the gates within wireless range.

#MOVING AROUND
Arrows move to the nearest control in that direction, Tab to the next one (Shift+Tab back). Enter or Space presses the control with the white [ ] brackets. 1 to 6 open the screens, L the whole activity log, Q quits, Escape leaves a text field. Touch and the mouse work too.

#THE COMMAND BAR
Press ; to type commands in the bar at the bottom; Enter runs them and Up and Down bring back earlier ones. Several commands go on one line separated by ; such as: d 3 ; iris
Gates are their number in the address book or their name (the start of it is enough; _ stands for a space).
d 5             dial gate 5 from the nearest gate in range
d 1 2           dial gate 2 from gate 1 (a gate in range)
d 1 2 1234      the same, sending IDC 1234 once it opens
d 1 2 30s       the same, closing the wormhole 30 s after it opens
d               dial the chosen destination from the chosen gate
close / x       stop the dial or close the outgoing wormhole
iris / i [open|close]  open or close the iris (alone: the other way)
scan            wake your gates and look for gates in range
from <gate>     choose the gate to dial from; from alone lists them
energy [gate]   what a dial costs and how long the wormhole can stay open
glyphs          the dialing gate's glyphs as buttons, to dial or save an address by touch
gdo [idc]       through the open wormhole: your signed pass, or an IDC
back [s]        once the wormhole is open, the far gate dials you back
route <gate> <gate>…           each gate dials the next once it is free
home [back], home set <gate>   dial the home gate (back: it dials you back)
schedule <min> <gate>          the gate dials that gate every so often (admins)
setup [gate]    make an unregistered gate yours
update [gate]   push your GNS gate files to a gate (admins)
ssh [gate]      the gate's console (owner and admins)
gatelog [gate]  what happened at a gate, newest first (admins)
save [name]     add the address last dialed by hand at the gate's DHD
new <name> [MW|PG|UN]          add a gate
add <gate> <MW|PG|UN> <glyph>…  set an address (Canis_Minor, or the start of a name)
idc <gate> 1234,5678 | none    its IDCs
loc <gate> <dim> [x y z]       where it is
gen <gate> [dim x y z]         work out its addresses from where it is
rn <gate> <name>, del <gate>, swap <a> <b>, mv <gate> <n>
edit <gate> [MW|PG|UN|idc|loc]  put the command that sets it in the bar, to change
import ags [path]              add the gates of AGS's address book
backup, backups, restore <n>   copies of the address book (the newest 10 are kept)
profile [new <name> <port> | use <name>|all | add|remove <name> <gate>… | delete <name>]  network profiles
trust <name>    accept the new key of a reinstalled gate or device
find, say <text>, share <gate>… [idc] [@device], block <device>, accept [n], refuse [n]
grants, invite, join, cut <name>
set fast|learn|take|codes on|off, set speed <s>, set sleep <minutes>|off, set scan <s>, set range <blocks>, set port <n>, set layout auto|compact|wide
get range|speed|sleep|scan|port|layout|energy|memory|fingerprint|entries|entry <gate>
go <screen>, log, clear, help [command], quit

#YOUR DEVICE
Your device has a key pair kept in a password-protected vault with your address book and grants. Its fingerprint (bottom right, Settings) is how gates and other devices know you. PASSWORD on Settings changes the password (or gns passwd in the shell).

#DIAL
SCAN wakes the gates you hold wake keys for, then finds the gates in range and opens each one; Settings can rescan on its own. FROM is the gate that dials: ◀ ▶ choose among the gates in range, CLOSE drops one. Choose the destination in the address book and press DIAL; energy shows what the dial costs and how long the wormhole can stay open, and the destination keeps it. A gate tells the client nothing until you use it. Over your own open wormhole DIAL closes it and dials (to the gate it is already open to, it leaves it open); while the gate has an incoming wormhole, another dial in progress or a wormhole closing, the dial waits and goes out once the gate is idle (within five minutes).
The gate dials the shortest address that works, continues glyphs already engaged, closes its iris while the wormhole forms and sends the destination's first IDC once it is open. The stargate on screen follows the real gate: chevrons light as glyphs engage, the wormhole shimmers, a closed iris shows.
DISENGAGE stops the dial or closes the outgoing wormhole (your own dial; admins any). IRIS opens or closes it (yours, an admin's or a user's with a grant; on a public gate not the public's); the gate's iris mode must be OC, set in the gate's screen, or FROM shows why it cannot. GDO sends your signed pass through the open wormhole to a GNS gate that knows you, or an IDC to any gate; it goes to the gate the wormhole reaches, whoever dialed it, not the gate chosen since. Fast dial (Settings) presses the gate's DHD instead of spinning the ring. Dial time (Settings, set speed) spreads a whole dial over that many seconds; from 25 s the ring spins.
Dial-back: dial a gate and type back. Once the wormhole is open, the far gate is told to dial yours, your side closes, and it dials you back, paying for the trip. A route chains this through several gates. Modem messages cross an open wormhole, so the far gate hears you however far it is; its answers reach you within about 10 blocks of your own gate.

#GATES
Your address book. NEW adds a gate, DELETE removes one, ▲ ▼ reorder, HOME marks your home gate. For the chosen gate: RENAME, its galaxy, LOCATION (dimension and x y z), EDIT ADDRESS (glyph by glyph), GENERATE (all three addresses worked out from the location, as JSG does, shown in the address dialog: SAVE keeps them) and its IDCs. Gates learned from scans are signed by the gate itself, so a changed copy from someone else is refused.
Settings can hide addresses and IDCs on this device; a client on a gate's own computer hides them unless its owner or an admin shows them.

#CHAT
FIND looks for GNS devices in range. Messages go to every device found, or to the one chosen in the list. SHARE offers gates to a device; switch on "Send their IDCs too" to send their IDCs.
Gates shared with you wait under Shared With You: ACCEPT adds them, REFUSE drops them and BLOCK SENDER ignores that device from then on. Settings lists blocked devices and can take shared gates without asking.

#ACCESS
A gate belongs to the device that sets it up: SET UP on an unregistered gate in range makes you its owner, your player its OC user (nobody else can type at it), and gives this device its wake key. A registered gate is private: only you and the players you grant can use it (public on, at its console, lets anyone dial it; its iris stays yours and your grant holders').
INVITE hands players nearby a grant: the role (user, or admin from the owner) and the gates it covers (one, or every gate you own). They choose JOIN. Admins can grant users too. A grant holder's device gets the gates' wake keys, and an admin becomes an OC user of the gate computer.
CUT OFF ends a grant you issued: each gate it covers learns it when your device next opens that gate. Cutting off an admin also cuts off the users they granted. Grants do not expire.
An unscheduled incoming wormhole raises the gate's off-world alarm: the iris closes, the gate computer sounds it and drives its alarm redstone. Your signed pass or a known IDC opens the iris and stands it down.

#THE GATE CONSOLE
On a computer with a stargate, gns starts the gate server. Its console commands, also run by the owner and admins remotely (CONSOLE on Dial, or ssh):
status          state, iris, owner, port, wake, sleep, alarm
close           stop dialing or close the outgoing wormhole
iris [open|close]   open or close the iris
log             recent dialing, iris, IDC, route and console events
history [n]     the gate log: who did what here, newest first
idc             list IDCs; idc add <code> <name>; idc remove <code>
kawoosh on|off  close the iris while the wormhole forms
name <name>     rename the gate (its entry is signed again)
dim <number>    the dimension in the gate's entry
public on|off   let anyone dial this gate (not move its iris)
port <n>        the modem port of this gate's network
sleep <min>|off shut down when idle; the wake key or the DHD wakes it
wake new        a new wake key (grant holders get it on their next open)
redstone <n>|off  the redstone level from the DHD that wakes the gate
alarm <side>|all|off  redstone out on an off-world activation
schedule        scheduled dials; schedule remove <n>
users, cut      the computer's OC users; how many grants it has cut off
room [on|off]   gate room mode (at the gate): the screen shows the dialing room
At the gate itself, gns autorun on starts the gate server when the computer boots.
]]

-- Wrapped to the screen, headings in amber.
local lines = {}
local width = R.w - 6
for line in (TEXT .. "\n"):gmatch("(.-)\n") do
    local heading = line:match("^#(.*)")
    if heading then
        if #lines > 0 then lines[#lines + 1] = {""} end
        lines[#lines + 1] = {"▌ " .. heading, C.amber}
    elseif line:match("^%S+.-   ") or line == "" then
        lines[#lines + 1] = {line, C.dim} -- a command table row
    else
        for _, l in ipairs(ui.wrap(line, width)) do lines[#lines + 1] = {l, C.text} end
    end
end
ui.card(frame, 1, 1, R.w, R.h, "GUIDE", "↑ ↓ scroll")
local list = ui.List(frame, 2, 2, R.w - 2, R.h - 1, {items = lines, scrollOnly = true,
    cells = function(item) return {{2, item[1], item[2]}} end})

return {first = list}
