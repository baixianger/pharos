# Remote Mac: keychain unlock for spawned sessions

When you passive-join a **remote Mac** (recipe B2 in `passive-join.md`), the spawned
claude lands in a **non-GUI security session** whose login keychain is **locked**. This
doc is the model + the self-contained recipes to unlock it. No external skill needed.

## The model (empirically established on macOS 26)

- **Keychain lock state is per security session, not global per user.** The GUI login
  session gets it unlocked at login; **every fresh SSH connection sees it locked** —
  always, regardless of GUI state.
- **A GUI login does NOT fix ssh/tmux-spawned sessions.** It unlocks the *GUI* security
  session only; an SSH-spawned tmux server still sees the keychain locked. (Screen
  Sharing changes nothing — unlock happens at fresh login, and re-attaching doesn't
  re-login.) This corrects an old, wrong "one GUI login fixes SSH too" note — that was a
  false positive from a passphrase-less ssh key.
- **A tmux server and all its panes/sessions share ONE security session.** Unlock there
  and every current *and future* pane sees it unlocked — **until the server exits**. A
  helper that spins up its own throwaway server, unlocks, and kills its last session
  gains nothing: the unlock dies with the server.
- **So the order matters:**
  1. create a session so the server stays alive (the claude session itself, before
     claude launches — or a `kc-hold` session),
  2. unlock **into that server** (a throwaway pane on the *same* server joins its session),
  3. launch claude under the same server.
- **claude login itself survives a locked keychain** — claude v2.1.x persists
  `~/.claude/.credentials.json` after its first logged-in boot, so it boots straight to
  the prompt even locked. The unlock still matters for **ssh keys** (`UseKeychain`),
  **`security` reads**, git `credential-osxkeychain`, and Macs where claude is
  keychain-only.

**Probe the RIGHT session** — plain `ssh … security …` measures the wrong (fresh-ssh)
session and always reads locked. Probe *inside the server*, capturing to a file (piping
`tmux run-shell`/new-window straight into grep can drop the output):

```sh
RT=/opt/homebrew/bin/tmux
ssh $HOST "printf '%s\n' 'security show-keychain-info ~/Library/Keychains/login.keychain-db > /tmp/kcv.out 2>&1' > /tmp/kcv.sh && chmod +x /tmp/kcv.sh
  $RT new-window -t $NICK -n kcv /tmp/kcv.sh; sleep 2; $RT kill-window -t $NICK:kcv 2>/dev/null; cat /tmp/kcv.out; rm -f /tmp/kcv.sh /tmp/kcv.out"
# locked  → "User interaction is not allowed"
# unlocked→ 'Keychain "…/login.keychain-db" no-timeout'
```

## Zero-touch model: store each peer's password in the local keychain

Each of your Macs holds the *other* Mac's login password as a keychain item named after
the target: **`host-<alias>`** (e.g. `host-mac-mini`). Unlocking a peer is then
unattended — the password flows **keychain → pipe → tmux buffer**, never argv/ps/chat.
The item lives on the machine that **does the unlocking** (the one running the unlock
command), and its login keychain must itself be unlocked (a normal GUI login covers the
machine you drive from).

### One-time seed (per direction) — the agent never sees the password

Discover what already exists (metadata read, works even when locked):

```sh
security dump-keychain ~/Library/Keychains/login.keychain-db 2>/dev/null | grep -o '"host-[^"]*"' | sort -u
```

**Path A — agent-assisted editor handoff (used & validated 2026-07-11).** The agent
prepares a `chmod 600` template in a **session-scoped temp dir outside any git repo**
(the Claude Code scratchpad — never a working tree, never `~`), opens it in a
**plain-text** editor, and the human types the password and saves:

```sh
F="$SCRATCH/hostpw.env"
printf 'HOST_PW_<ALIAS>=\n' > "$F" && chmod 600 "$F"      # <ALIAS> uppercased, - → _
open -a Zed "$F" 2>/dev/null || open -a "Visual Studio Code" "$F" 2>/dev/null || open -e "$F"
# open -e (TextEdit) is last resort — first turn OFF smart quotes/dashes or it mangles the password
```

Human fills in the value after `=`, saves, pings the agent. The agent then seeds the
item and shreds the file — the secret goes **file → command-substitution → `security`
stdin**, never printed, never in the agent's context (`$(…)` also strips the trailing
newline). Seed on the machine that will DO the unlocking:

```sh
printf '%s' "$(grep '^HOST_PW_<ALIAS>=' "$F" | cut -d= -f2-)" | \
  security add-generic-password -U -a "$USER" -s host-<alias> -w -   # `-w -` reads the secret from stdin
rm -P "$F"   # TRANSIT file — shred right after seeding; the encrypted keychain is the durable home
```

**Path B — human-driven, in a real Terminal** (no transit file at all):

```sh
security add-generic-password -U -a "$USER" -s host-<target> -w      # prompts for <target>'s password
```

`-U` = update-in-place everywhere, so re-seeding rotates a changed password. CLI-created
items **pre-authorize the `security` binary**, so reads never pop an "Always Allow"
dialog (GUI/Keychain-Access-created items do — a human must click it once).

### Zero-touch unlock into a live server

Precondition: `host-<alias>` seeded locally, and the remote claude tmux server **alive**
(the claude session keeps it alive; the unlock dies with the server). Drive the unlock in
a throwaway pane on that **same** server so it lands in the right security session:

```sh
NICK=orbidash-mac ; HOST=mac-mini ; RT=/opt/homebrew/bin/tmux
# 1) throwaway session on the SAME default server (shares its security session):
ssh $HOST "$RT new-session -d -s kc-$NICK"
ssh $HOST "$RT send-keys -t kc-$NICK -l 'security unlock-keychain ~/Library/Keychains/login.keychain-db'; $RT send-keys -t kc-$NICK Enter"
until ssh $HOST "$RT capture-pane -t kc-$NICK -p" | grep -qi 'password to unlock'; do sleep 1; done
# 2) local keychain → pipe → ssh stdin → tmux buffer → no-echo prompt; -d self-deletes. No argv/ps/context:
security find-generic-password -s host-$HOST -w | ssh $HOST "$RT load-buffer -b kcpw - && $RT paste-buffer -d -b kcpw -t kc-$NICK"
ssh $HOST "$RT send-keys -t kc-$NICK Enter" ; sleep 2
ssh $HOST "$RT capture-pane -t kc-$NICK -p" | grep -qiE 'not correct|unable to unlock|failed' && echo "UNLOCK FAILED"
ssh $HOST "$RT kill-session -t kc-$NICK"     # the UNLOCK persists on the still-alive $NICK server
```

The `security find-generic-password -s host-$HOST -w` runs **locally** and emits the
password on stdout straight into the pipe — the agent never prints or reads it.

## Gotchas (all learned the hard way)

- **A GUI login does NOT fix ssh/tmux-spawned sessions** (see model above). It only
  helps when the human runs claude themselves in a local GUI Terminal.
- **Claude Code's `!` bash-input has NO interactive TTY.** `read -s` reads empty and
  "succeeds", `security … -w` prompts get no input, `ssh -t` password prompts hang.
  **Never** route interactive password entry through the agent's own bash — real
  Terminal, or the tmux-buffer delivery above.
- **Blind-pasting into a pane is dangerous**: if the prompt hasn't appeared yet, the
  paste lands on the shell prompt and Enter **executes** the password, leaking it into
  history. Always poll `capture-pane` for the prompt text first (the recipes do).
- **Don't pipe `ssh … tmux run-shell`/probe straight into grep** — output can vanish in
  the pipe (a probe once read as "unlocked" wrongly). Capture to a file/var first.
- **zsh remotes expand a leading `=`** (equals expansion): `tmux … -t =name` over ssh
  became "command not found". Single-quote-wrap remote args; these recipes name sessions
  without a leading `=`.
- **The unlock dies with the tmux server.** If the claude server exits, the next one
  starts locked — re-run the zero-touch unlock (or let a spawn helper do it).

## Notes

- Before launching claude on a Darwin remote, export the GUI session's launchd agent
  socket so ssh-agent keys work: `export SSH_AUTH_SOCK=$(find /var/run /private/tmp
  -maxdepth 2 -name Listeners -user "$(whoami)" 2>/dev/null | head -1)`.
- Linux remotes have neither problem — credentials are a plain file
  (`~/.claude/.credentials.json`) and agent/keys work as usual.
