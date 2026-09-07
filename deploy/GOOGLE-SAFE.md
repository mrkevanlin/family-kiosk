# Keeping Google homework safe

Homework is his Google login (Classroom, Docs, Drive, Search). Explicit results
are locked down in layers — no single switch is perfect.

## What this project enforces on the G10

Chromium **managed policies** (installed by `deploy/install-chromium-policies.sh`):

| Policy | Effect |
|--------|--------|
| `ForceGoogleSafeSearch` | SafeSearch stays on for Google Search **and** Google Images; he cannot turn it off in settings |
| `ForceYouTubeRestrict` = Strict | YouTube Restricted Mode (strict) |
| `SafeSitesFilterBehavior` | Chromium blocks sites Google classifies as adult |
| Incognito / guest disabled | Harder to open an unfiltered profile |
| Default search forced to SafeSearch URLs | Address-bar searches stay filtered |
| Blocklist of other search engines + `safe=off` Google URLs | Reduces easy SafeSearch bypass |

After install, verify on the kid account: open `chrome://policy` and confirm those
policies show as **Mandatory**.

## What you should also do in Google (strongly recommended)

Chromium policies only cover **this computer**. For his Google account:

1. If it is a **personal child account**, use [Google Family Link](https://families.google.com/familylink):
   - Filter explicit results (locks SafeSearch on his account)
   - Limit YouTube / apps as you prefer
2. If it is a **school Workspace** account, ask the school admin whether SafeSearch /
   YouTube Restricted Mode are already forced — many districts already do this.

Account-level locks apply even if he somehow uses another browser later.

## Homework allowlist

With general internet **off**, the allowlist proxy still permits Google / GSuite
domains listed in `always_allow_domains` so login and Classroom work. Edit
`/etc/family-kiosk/config.yaml` if a school tool is missing.

## Limits

- Determined kids can find workarounds (VPN apps, alternate browsers if installed).
  Keep the kid account without sudo and do not install other browsers.
- Image search SafeSearch is good but not perfect; combine with Family Link.
- Approved **Web** sessions also inherit these Chromium policies on this machine.
