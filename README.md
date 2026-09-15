# port-watch

What is holding this port, and kill it.

```sh
port-watch                 # everything that is listening
port-watch 3000            # just that port
port-watch -k 3000         # terminate whatever holds it
```

No `lsof | awk`, no `netstat -tulpn | grep`, no remembering which of the two
is installed. One binary, no runtime, nothing to configure.

```
 PORT  PROTO    PID  USER             ADDRESS     COMMAND
   53  tcp        ?  systemd-resolve  127.0.0.53  ?
  631  tcp        ?  root             127.0.0.1   ?
 3306  tcp        ?  mysql            127.0.0.1   ?
 5432  tcp        ?  postgres         127.0.0.1   ?
 3000  tcp    84213  jdoe             *           node
 8080  tcp6   84990  jdoe             *           java
 9229  tcp    84213  jdoe             127.0.0.1   node

4 sockets owned by another user — run with sudo to resolve
```

That is the unprivileged view: your own processes are named, other users' are
`?`. Under `sudo` every row is filled in.

## Install

### A prebuilt binary

```sh
curl -LO https://github.com/vytolang/port-watch/releases/latest/download/port-watch-linux-x86_64.tar.gz
tar xzf port-watch-linux-x86_64.tar.gz
cd port-watch-*-linux-x86_64
sudo install -m 755 port-watch /usr/local/bin/
```

No setcap, no daemon, no service file. Reading `/proc` needs no privilege —
`sudo` only ever buys you the names of *other users'* processes.

### From source

Needs the [Vyto compiler](https://github.com/vytolang/vyto). Vyto compiles to
C and shells out to a host C compiler, so there is no other toolchain.

```sh
git clone https://github.com/vytolang/port-watch
cd port-watch
make && make install          # -> ~/.local/bin
```

`make` finds `vytoc` on your `PATH`, or via `$VYTO_HOME`, or you can point at
a checkout: `make VYTO_ROOT=/path/to/vyto`. `PREFIX` and `DESTDIR` work as
usual.

**A package root contains packages**, so this has to sit inside one — `make`
derives the root as the parent directory. Cloning into `~/src/port-watch`
makes `~/src` the root, which is what you want.

## Use

### See what is listening

```sh
port-watch                 # every TCP listener
port-watch -u              # include bound UDP sockets
port-watch 8080            # one port
port-watch --full          # whole command line, not just the program name
port-watch --json          # machine-readable
```

Exit status is `1` when the port you asked about has nothing on it, so a
script can branch without parsing the text:

```sh
if ! port-watch 5432 >/dev/null; then echo "postgres is down"; fi
```

### Free a port

```sh
port-watch -k 3000         # SIGTERM
port-watch -k -K 3000      # SIGKILL
```

`-k` **confirms the process actually died** before reporting success. A
SIGTERM that the process ignores — normal for several databases — is reported
as a failure with the force flag to use next, not as a success you discover
was a lie when the port is still busy:

```
port-watch: 4417 (postgres) ignored SIGTERM after 2s — still holding port 5432
Force it with: port-watch -k -K 5432
```

### Watch

```sh
port-watch -w              # redraw when the set of listeners changes
port-watch -w 3000         # watch one port
```

It redraws on *change*, not on a timer, so a quiet machine costs one
`/proc/net` read per interval and prints nothing. A restart shows up as the
row changing, because the socket inode is part of what it compares.

## Two things it refuses to do

**It will not kill one of several processes sharing a port.** A pre-forking
server binds once and forks; every worker holds the same listening socket.
Killing one frees nothing and the supervisor respawns it, so `-k` stops and
tells you what is there:

```
port 8080 is held by 4 processes:
  9912  gunicorn
  9913  gunicorn
  9914  gunicorn
  9915  gunicorn

Refusing to guess which one to kill. This is usually a pre-forking
server: killing a worker just makes the supervisor respawn it.
Kill the supervisor by pid instead.
```

The table flags it too, as `gunicorn (+3 more)`, so the refusal is never a
surprise.

**It will not show a blank owner.** A socket it could not attribute renders
as `?` with a footer saying why — almost always that the process belongs to
another user:

```
7 sockets owned by another user — run with sudo to resolve
```

A blank cell would read as "nothing holds this port", which is never true.

## How it works

`/proc/net/{tcp,tcp6,udp,udp6}` gives each socket an **inode**;
`/proc/<pid>/fd/<n>` is a symlink reading `socket:[<inode>]`. That is the only
path from a port to a pid on Linux.

The walk is the entire cost, so the set of inodes worth looking for is built
first — a few dozen — and the descriptor scan matches against it in C,
returning only hits. The thousands of pipes and regular files never cross the
FFI boundary. A full scan of a desktop takes about 25 ms.

Two details that are easy to get wrong and are tested:

- A **zombie still answers `kill(pid, 0)`**, because the pid is allocated
  until its parent reaps it — though it has already released the port. Using
  that as the liveness probe reports a successful kill as "ignored the
  signal" whenever the caller is a script that has not reaped. Liveness comes
  from the process state in `/proc/<pid>/stat` instead.
- **`/proc/<pid>/cmdline` is not always NUL-separated.** Chromium and anything
  else that rewrites its argv to set a process title produces one flat
  space-separated string, so `argv[0]` has to end at the first NUL *or* the
  first space.

## Tests

```sh
make test
```

28 checks against real sockets the suite binds itself, including the three
that matter: a process that ignores SIGTERM must not be reported as killed, a
pre-forked socket must be refused rather than half-killed, and the listener
set must match `ss` exactly. Each was fault-injected to confirm it fails when
the logic is broken.

The suite never signals a process it did not start.

## Platform

Linux only, and deliberately: it is built on `/proc`, which is where the
port-to-pid mapping lives. macOS would need an entirely different backend
(`libproc`), and BSD another (`kvm`). Both are possible behind the same
interface; neither is written.

## Licence

MIT.
