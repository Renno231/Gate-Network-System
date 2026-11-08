-- Guide screen: how to use GNS. Up and Down (or the mouse wheel) scroll it.
local _, clientEnv, _, frame, R = ...
local ui = clientEnv.ui
local C = ui.C

local TEXT = [[
#GATE NETWORK SYSTEM
GNS dials stargates from a tablet or computer. Each gate runs the GNS gate server; your device runs this client and talks to the gates within wireless range.

#MOVING AROUND
Arrows move to the nearest control in that direction, Tab to the next one (Shift+Tab back). Enter or Space presses the control with the white [ ] brackets. 1 to 6 open the screens, Q quits, Escape leaves a text field. Touch and the mouse work too.

#THE COMMAND BAR
Press ; to type commands in the bar at the bottom; Enter runs them and Up and Down bring back earlier ones. Several commands go on one line separated by ; such as: d 3 ; iris
Gates are their number in the address book or their name (the start of it is enough; _ stands for a space).
d 5             dial gate 5 from the nearest gate in range
d 1 2           dial gate 2 from gate 1 (a gate in range)
d 1 2 1234      the same, sending IDC 1234 once it opens
d               dial the chosen destination from the chosen gate
close / x       stop the dial or close the outgoing wormhole
iris / i        open or close the iris (moderators and admins)
scan            look for gates in range
from <gate>     choose the gate to dial from; from alone lists them
ssh [gate]      the gate's console, for admins of its network
new <name> [MW|PG|UN]          add a gate
add <gate> <MW|PG|UN> <glyph>…  set an address (Canis_Minor, or the start of a name)
idc <gate> 1234,5678 | none    its IDCs
loc <gate> <dim> [x y z]       where it is
gen <gate> [dim x y z]         work out its addresses from where it is
rn <gate> <name>, del <gate>, swap <a> <b>, mv <gate> <n>
edit <gate> [MW|PG|UN|idc|loc]  put the command that sets it in the bar, to change
find, say <text>, share <gate>… [idc] [@device], block <device>, accept [n], refuse [n]
net [name], push
set fast|learn|take on|off, set scan <s>, set range <blocks>, set layout auto|compact|wide
get range|scan|layout|energy|memory|fingerprint|entries|entry <gate>
go <screen>, clear, help [command], quit

#YOUR DEVICE
Your device has a key pair kept in a password-protected vault with your address book. Its fingerprint (bottom right, Settings) is how gates and other devices know you. PASSWORD on Settings changes the password (or gns passwd in the shell).

#DIAL
SCAN finds the gates in range, opens each one and copies its address book into yours; Settings can rescan on its own. FROM is the gate that dials: ◀ ▶ choose among the gates in range, CLOSE drops one. Choose the destination in the address book and press DIAL.
The gate dials the shortest address that works, continues glyphs already engaged, closes its iris while the wormhole forms and sends the destination's first IDC once it is open. The stargate on screen follows the real gate: chevrons light as glyphs engage, the wormhole shimmers, a closed iris shows.
DISENGAGE stops the dial or closes the outgoing wormhole. IRIS opens or closes it (moderators and admins). Fast dial (Settings) presses the gate's DHD instead of spinning the ring.

#GATES
Your address book. NEW adds a gate, DELETE removes one, ▲ ▼ reorder. For the chosen gate: RENAME, its galaxy, LOCATION (dimension and x y z), EDIT ADDRESS (glyph by glyph), GENERATE (all three addresses worked out from the location, as JSG does) and its IDCs. Gates learned from scans are signed by the gate itself, so a changed copy from someone else is refused.

#CHAT
FIND looks for GNS devices in range. Messages go to every device found, or to the one chosen in the list. SHARE offers gates to a device; switch on "Send their IDCs too" to send their IDCs.
Gates shared with you wait under Shared With You: ACCEPT adds them, REFUSE drops them and BLOCK SENDER ignores that device from then on. Settings lists blocked devices and can take shared gates without asking.

#NETWORKS
Private networks: a founder creates one with NEW, then INVITE lets members nearby JOIN, each with a role (user, moderator, admin). ADD GATE brings a gate in range into the network; its owner first types trust <your fingerprint> at the gate. A gate in a private network serves only its members, and a revoked member is refused by every gate once PUSH has told them.
Admins can run a gate's console from anywhere in range (CONSOLE on Dial, or ssh), to set up a gate nobody sits at.

#THE GATE CONSOLE
On a computer with a stargate, gns starts the gate server. Its console commands, also run by admins remotely:
status          state, iris, last dial, TPS, DHD, network
close           stop dialing or close the outgoing wormhole
iris [open|close]   open or close the iris
log             recent dialing, iris, IDC and console events
idc             list IDCs; idc add <code> <name>; idc remove <code>
kawoosh on|off  close the iris while the wormhole forms
name <name>     rename the gate (its entry is signed again)
dim <number>    the dimension in the gate's entry
book            gates in this gate's address book
sync <modem>    pull another gate's address book
trust <fp>      let this gate join the network founded by that key
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
