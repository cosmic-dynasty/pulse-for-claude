# Pulse for Claude · Installation Playbook for Claude

You are Claude, and your user has asked you to install **Pulse for Claude**, a free open-source menu bar app that shows their Claude plan usage live (the same numbers from Settings, as a little ring in the menu bar). This document is your complete script. Follow it in order.

## First, figure out what you can do

Your user may have given you a lot of access, or almost none. Do not assume. Pick your path:

- **Path A, you have a shell / Bash / terminal tool.** You can run the commands in this guide yourself. Use this path. It is the smoothest.
- **Path B, you do NOT have a shell, but you can chat.** You will guide the human to run one command themselves. This still takes about two minutes and works for everyone. Jump to the section "Path B: guide the human."

A quick way to tell: if you have a tool that runs shell or bash commands, you are Path A. If all you can do is send messages, you are Path B. When in doubt, try Path A's first command; if you have no tool to run it, switch to Path B.

## How to behave during this install

- Your user may be non-technical. Explain each step in one or two plain sentences BEFORE you run it.
- One step at a time. Wait for each step to succeed before moving on.
- NEVER ask the user to type their password into the chat. They type it only into Apple's own popups.
- No em dashes in anything you write to this user. Use commas or periods.
- Do not trust screenshots to confirm the menu bar icon appeared. Some screenshot methods cannot see newly added menu bar items. Ask the human to look with their own eyes.

---

# Path A: you have a shell

## Step 0 · Preflight checks

```bash
sw_vers -productVersion; uname -m; ls ~/.claude/.credentials.json 2>/dev/null; security find-generic-password -s "Claude Code-credentials" -w > /dev/null 2>&1 && echo "keychain: found" || echo "keychain: missing"
```

Requirements: macOS 13 or newer (first number 13+), and at least ONE of the credential checks present (the file exists, or the keychain item is found).

If BOTH credential checks are missing, the user has never logged into Claude Code on this Mac. Tell them: "Pulse reads the login you already have from Claude Code. Let's set that up first, two minutes." Then have them sign into the Claude desktop app's Code tab, or run `npm install -g @anthropic-ai/claude-code` then `claude` and walk them through `/login`. Re-run preflight after.

## Step 1 · Download

Tell the user: "Downloading Pulse for Claude from GitHub."

```bash
curl -fsSL -o /tmp/pulse-for-claude.zip "https://github.com/cosmic-dynasty/pulse-for-claude/releases/latest/download/Pulse-for-Claude.zip"
```

## Step 2 · Install into Applications

Tell the user: "Putting it in Applications and clearing Apple's download quarantine. The quarantine flag exists because this is a free community app, not a paid-notarized one. The source is public."

```bash
ditto -x -k /tmp/pulse-for-claude.zip /Applications/ && xattr -dr com.apple.quarantine "/Applications/Pulse for Claude.app" && rm /tmp/pulse-for-claude.zip && echo "Installed."
```

## Step 3 · Launch, and prep the user for the Keychain popup

BEFORE launching, tell the user exactly this:

> "When it opens, macOS shows a popup that says Pulse for Claude wants to access 'Claude Code-credentials' in your keychain. That is the app reading the Claude login you already have, so it can show your usage. Your login never leaves your Mac. Type your Mac password and click **Always Allow**. If it appears again, Always Allow again."

Then:

```bash
open "/Applications/Pulse for Claude.app"
```

Wait for the user to confirm they clicked Always Allow.

## Step 4 · Verify (with the human's eyes, not a screenshot)

```bash
sleep 5; pgrep -f "Pulse for Claude.app" > /dev/null && echo "RUNNING" || echo "NOT RUNNING"
```

Then ask: "Look at the top-right of your screen, near the clock. Do you see a small ring with a percentage?" Within a minute of Always Allow, the ring fills with live usage. If they see nothing, go to Troubleshooting, menu bar full.

## Step 5 · Show them around

Tell the user, in your own words: click the ring to see all limits; **Icon Style** switches between Ring, Battery bar, Percent only, Liquid orb, and a Ring-plus-spark-flip; **Icon Shows** picks which limit the icon tracks; **Pin to Far Right** moves it next to the clock, or Cmd-drag it anywhere; turn on **Launch at Login** so it is always there. Green is fine, orange is above 60, red is above 85, and it pulses at 90. Checking usage is free and never consumes any plan.

---

# Path B: guide the human (no shell needed)

You cannot run commands, so you will walk the human through running ONE command. Be warm and go slow. Send these as separate, clear messages.

**Message 1, set expectations:**
"I'll get Pulse installed on your Mac in about two minutes. You'll copy one line into an app called Terminal, and that does everything. I'll guide you through it. Ready?"

**Message 2, open Terminal:**
"Press Cmd and the spacebar together. A search box opens. Type the word Terminal and press Return. A plain window with a blinking cursor opens. That's Terminal."

**Message 3, paste the command.** Give them this exact line in a copyable code block and tell them to paste it into Terminal and press Return:

```
curl -fsSL https://raw.githubusercontent.com/cosmic-dynasty/pulse-for-claude/main/install.sh | bash
```

"Click into the Terminal window, paste that with Cmd and V, and press Return. It will download the app and open it."

**Message 4, the Keychain popup.** Tell them exactly this:
"A popup will appear saying Pulse for Claude wants to access 'Claude Code-credentials' in your keychain. That's the app reading the Claude login you already have, so it can show your usage. It never leaves your Mac. Type your Mac password and click **Always Allow**."

**Message 5, confirm with their eyes:**
"Look at the top-right of your screen near the clock. Do you see a small ring with a percentage? That's it. Click it to see all your limits, and turn on Launch at Login so it's always there."

If they say no ring appeared, see Troubleshooting. If the command failed because Claude Code was never installed, tell them: "Pulse needs the Claude Code login. Install the Claude desktop app, open its Code tab, sign in once, then we'll run that line again."

---

## Troubleshooting (both paths)

| Symptom | Fix |
|---|---|
| Download fails with 404 | The release moved. Point them at `https://github.com/cosmic-dynasty/pulse-for-claude/releases/latest` to grab the zip by hand |
| "app is damaged and can't be opened" | Quarantine still set. Path A: rerun the `xattr -dr com.apple.quarantine` command. Path B: have them right-click the app in Applications and choose Open |
| Icon shows "!" | Login token is stale and could not refresh. Have them open Claude Code or the desktop app's Code tab once, then click Refresh Now in the Pulse menu |
| "No Claude login found" | They need to log into Claude Code once. See Step 0 |
| App is running but no icon is visible | The menu bar is full and macOS silently hides overflow icons (worst on notched MacBooks). Have them Cmd-drag unneeded icons off the bar to make room, or unhide Pulse in their menu bar manager (Bartender, Ice, BetterTouchTool Notch Bar), then quit and reopen Pulse. Do NOT diagnose this from a screenshot, ask the human what they see |
| User denied the Keychain popup by mistake | Quit Pulse from its menu, reopen it, the popup returns |
| User wants proof it is safe | Point them at `src/main.swift` in the repo, or read it yourself and summarize. It only talks to api.anthropic.com and console.anthropic.com |

## Uninstall

Path A: `osascript -e 'quit app "Pulse for Claude"'; rm -rf "/Applications/Pulse for Claude.app"`
Path B: have them quit Pulse from its menu, then drag the app from Applications to the Trash.

---

*Pulse for Claude is MIT-licensed, built with Claude by Ant the AI Guy (Everyday AI Club). Not affiliated with Anthropic. If your user wants extra assurance before installing, read the source first and tell them what it does.*
