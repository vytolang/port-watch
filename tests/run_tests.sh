#!/bin/sh
# port-watch test suite.
#
# Everything here runs against REAL sockets that the suite itself creates and
# owns, on high ports unlikely to collide. Nothing touches a socket the suite
# did not bind, and no test kills anything it did not start — a test suite for
# a tool that terminates processes has to be held to that.
#
# Needs python3 for the fixture servers. Skips the cases that need it rather
# than failing, so a machine without it still runs the parsing tests.

set -u

BIN="${BIN:-./port-watch}"
PASS=0
FAIL=0
SKIP=0
TMP="tests/tmp"
PIDS=""

mkdir -p "$TMP"

# Ports the suite binds. High, and checked for being free before use.
P_BASIC=45911
P_STUBBORN=45912
P_FORK=45913
P_UDP=45914

cleanup() {
    for p in $PIDS; do kill -9 "$p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT INT TERM

ok()   { PASS=$((PASS+1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip  %s (%s)\n' "$1" "$2"; }

have_python() { command -v python3 >/dev/null 2>&1; }

port_free() { ! ss -ltnu 2>/dev/null | grep -q ":$1 "; }

# Wait for a port to appear, up to ~3s. Polling beats a fixed sleep: the
# fixture servers start in tens of milliseconds and a sleep long enough to be
# safe would dominate the suite's runtime.
wait_port() {
    _i=0
    while [ $_i -lt 60 ]; do
        ss -ltnu 2>/dev/null | grep -q ":$1 " && return 0
        sleep 0.05
        _i=$((_i+1))
    done
    return 1
}

echo "port-watch tests"
echo

# ---- 1. it builds and answers at all ------------------------------------

if [ ! -x "$BIN" ]; then
    echo "  FAIL  $BIN is not executable — run make first"
    exit 1
fi

"$BIN" --version >/dev/null 2>&1 \
    && ok "--version" || bad "--version"

"$BIN" --help 2>&1 | grep -q "what is holding this port" \
    && ok "--help shows the summary" || bad "--help shows the summary"

# ---- 2. agreement with ss -----------------------------------------------
#
# The real correctness check: every TCP listener ss reports must appear, with
# the same port. A hex-parsing bug (the easiest mistake in this tool) shows up
# here as a mismatched or missing port, not as a crash.

if command -v ss >/dev/null 2>&1; then
    ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un > "$TMP/ss.ports"
    "$BIN" --json 2>/dev/null | grep -o '"port": [0-9]*' | awk '{print $2}' | sort -un > "$TMP/pw.ports"
    if diff -q "$TMP/ss.ports" "$TMP/pw.ports" >/dev/null 2>&1; then
        ok "TCP listener set matches ss exactly"
    else
        bad "TCP listener set matches ss exactly" "$(diff "$TMP/ss.ports" "$TMP/pw.ports" | head -5 | tr '\n' ' ')"
    fi
else
    skip "TCP listener set matches ss" "no ss"
fi

# ---- 3. json is json ----------------------------------------------------

if command -v python3 >/dev/null 2>&1; then
    if "$BIN" --json 2>/dev/null | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        ok "--json emits parseable JSON"
    else
        bad "--json emits parseable JSON"
    fi
else
    skip "--json emits parseable JSON" "no python3"
fi

# ---- 4. a socket we own, found and attributed ---------------------------

if have_python && port_free "$P_BASIC"; then
    python3 -m http.server "$P_BASIC" --bind 127.0.0.1 >/dev/null 2>&1 &
    PIDS="$PIDS $!"
    SERVER_PID=$!
    if wait_port "$P_BASIC"; then
        out=$("$BIN" "$P_BASIC" 2>&1)
        echo "$out" | grep -q "$P_BASIC" \
            && ok "finds a socket we just bound" || bad "finds a socket we just bound" "$out"
        echo "$out" | grep -q "$SERVER_PID" \
            && ok "attributes it to the right pid" || bad "attributes it to the right pid" "$out"
        echo "$out" | grep -q "python" \
            && ok "resolves the command name" || bad "resolves the command name" "$out"
        # The address column must be the loopback we asked for, not 0.0.0.0:
        # an endianness bug renders 127.0.0.1 as 1.0.0.127 and this catches it.
        echo "$out" | grep -q "127.0.0.1" \
            && ok "renders the bound address correctly" || bad "renders the bound address correctly" "$out"
    else
        skip "finds a socket we just bound" "fixture did not start"
    fi
else
    skip "socket attribution tests" "no python3 or port busy"
fi

# ---- 5. absent port: exit 1, and says so plainly ------------------------

if port_free 45999; then
    out=$("$BIN" 45999 2>&1); rc=$?
    [ "$rc" = "1" ] \
        && ok "absent port exits 1" || bad "absent port exits 1" "got $rc"
    echo "$out" | grep -qi "nothing is listening" \
        && ok "absent port says nothing is listening" || bad "absent port says nothing is listening" "$out"
fi

# ---- 6. kill, and the confirmation that it worked -----------------------

if have_python && [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    out=$("$BIN" -k "$P_BASIC" 2>&1); rc=$?
    [ "$rc" = "0" ] \
        && ok "kill exits 0" || bad "kill exits 0" "got $rc: $out"
    echo "$out" | grep -q "is free" \
        && ok "kill confirms the port is free" || bad "kill confirms the port is free" "$out"
    sleep 0.3
    port_free "$P_BASIC" \
        && ok "port really is free after kill" || bad "port really is free after kill"
else
    skip "kill tests" "no fixture server"
fi

# ---- 7. a process that IGNORES SIGTERM must not be reported as killed ---
#
# The important one. An exit-status-only check passes here even when the tool
# lies, so this asserts the REASON: it must say the signal was ignored and
# must exit non-zero while the port is still held.

if have_python && port_free "$P_STUBBORN"; then
    cat > "$TMP/stubborn.py" <<PYEOF
import signal, socket, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", $P_STUBBORN)); s.listen(5)
while True: time.sleep(1)
PYEOF
    python3 "$TMP/stubborn.py" >/dev/null 2>&1 &
    PIDS="$PIDS $!"
    STUB_PID=$!
    if wait_port "$P_STUBBORN"; then
        out=$("$BIN" -k "$P_STUBBORN" 2>&1); rc=$?
        [ "$rc" != "0" ] \
            && ok "ignored SIGTERM exits non-zero" || bad "ignored SIGTERM exits non-zero" "reported success falsely"
        echo "$out" | grep -qi "ignored SIGTERM" \
            && ok "ignored SIGTERM says so" || bad "ignored SIGTERM says so" "$out"
        kill -0 "$STUB_PID" 2>/dev/null \
            && ok "ignored SIGTERM left the process alive" || bad "ignored SIGTERM left the process alive"

        # -K must then actually finish the job.
        out=$("$BIN" -k -K "$P_STUBBORN" 2>&1); rc=$?
        [ "$rc" = "0" ] \
            && ok "--force kills what SIGTERM could not" || bad "--force kills what SIGTERM could not" "$out"
        sleep 0.3
        port_free "$P_STUBBORN" \
            && ok "port free after --force" || bad "port free after --force"
    else
        skip "SIGTERM-ignoring tests" "fixture did not start"
    fi
else
    skip "SIGTERM-ignoring tests" "no python3 or port busy"
fi

# ---- 8. a pre-forked socket must REFUSE, not kill one worker ------------
#
# One listening inode shared by four processes. Killing any single one leaves
# the port held, so reporting success would be the worst possible outcome —
# this asserts the refusal and that every holder is named.

if have_python && port_free "$P_FORK"; then
    cat > "$TMP/prefork.py" <<PYEOF
import socket, os, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", $P_FORK)); s.listen(5)
for _ in range(3):
    if os.fork() == 0:
        while True: time.sleep(1)
while True: time.sleep(1)
PYEOF
    python3 "$TMP/prefork.py" >/dev/null 2>&1 &
    PIDS="$PIDS $!"
    if wait_port "$P_FORK"; then
        sleep 0.2
        view=$("$BIN" "$P_FORK" 2>&1)
        echo "$view" | grep -q "more)" \
            && ok "table flags a multi-holder socket" || bad "table flags a multi-holder socket" "$view"

        out=$("$BIN" -k "$P_FORK" 2>&1); rc=$?
        [ "$rc" != "0" ] \
            && ok "multi-holder kill exits non-zero" || bad "multi-holder kill exits non-zero" "killed one and claimed success"
        echo "$out" | grep -qi "refusing to guess" \
            && ok "multi-holder kill refuses explicitly" || bad "multi-holder kill refuses explicitly" "$out"
        echo "$out" | grep -qi "held by 4 processes" \
            && ok "multi-holder kill counts every holder" || bad "multi-holder kill counts every holder" "$out"
        sleep 0.2
        ! port_free "$P_FORK" \
            && ok "multi-holder refusal left the port held" || bad "multi-holder refusal left the port held"
        # Clean up the whole group ourselves.
        pkill -9 -f "$TMP/prefork.py" 2>/dev/null
    else
        skip "pre-fork tests" "fixture did not start"
    fi
else
    skip "pre-fork tests" "no python3 or port busy"
fi

# ---- 9. udp is off by default, on with -u -------------------------------

if have_python && port_free "$P_UDP"; then
    cat > "$TMP/udp.py" <<PYEOF
import socket, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(("127.0.0.1", $P_UDP))
while True: time.sleep(1)
PYEOF
    python3 "$TMP/udp.py" >/dev/null 2>&1 &
    PIDS="$PIDS $!"
    sleep 0.4
    # Match the PROTO column, not the bare port number: the "nothing is
    # listening on port 45914" message contains the port too, so a plain
    # grep for it passes whether the socket was listed or not.
    if "$BIN" "$P_UDP" 2>&1 | grep -qE "^ *$P_UDP +udp"; then
        bad "udp hidden without -u" "showed a UDP socket by default"
    else
        ok "udp hidden without -u"
    fi
    "$BIN" -u "$P_UDP" 2>&1 | grep -qE "^ *$P_UDP +udp" \
        && ok "udp shown with -u" || bad "udp shown with -u"
else
    skip "udp tests" "no python3 or port busy"
fi

# ---- 10. watch draws immediately, even when redirected ------------------
#
# stdout is block-buffered off a terminal, and a watch is ended by a signal
# that discards the buffer — so without an explicit flush this produces an
# empty file rather than a table, and only when piped. Asserting on bytes
# written catches exactly that.

out_file="$TMP/watch.out"
timeout 2 "$BIN" -w > "$out_file" 2>&1
if [ -s "$out_file" ]; then
    ok "watch writes without waiting for the buffer"
else
    bad "watch writes without waiting for the buffer" "produced no output when redirected"
fi
grep -q "PORT" "$out_file" \
    && ok "watch draws the table" || bad "watch draws the table"

# ---- 11. bad input is rejected, not guessed -----------------------------

"$BIN" notaport >/dev/null 2>&1
[ $? = 2 ] && ok "non-numeric port exits 2" || bad "non-numeric port exits 2"

"$BIN" 99999 >/dev/null 2>&1
[ $? = 2 ] && ok "out-of-range port exits 2" || bad "out-of-range port exits 2"

"$BIN" --kill >/dev/null 2>&1
[ $? = 2 ] && ok "--kill without a port exits 2" || bad "--kill without a port exits 2"

echo
echo "  $PASS passed, $FAIL failed, $SKIP skipped"
echo
[ "$FAIL" = "0" ]
