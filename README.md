# On-Call Board

An installable web app for anaesthesia on-call teams. It assigns OT cases, APS reviews, emergency calls, preop assessments and list preparation to second and first on-call doctors, shows the shift as a timeline, and produces handover text to paste into the team chat.

## Deploy on Vercel
1. Go to https://vercel.com/new and import this GitHub repository.
2. Leave the settings as they are (`vercel.json` already sets the build and output folder) and press **Deploy**.
3. Every push to `master` redeploys automatically.

## Install on a phone
Open the Vercel link, then:
- **iPhone (Safari):** Share → *Add to Home Screen*.
- **Android (Chrome):** menu → *Install app*.
It then opens full screen and works without signal.

## Develop
- Edit `src/app.html`, then run `./build.sh` to rebuild `public/index.html`.
- `public/` holds the manifest, service worker (offline support) and icons.

## Shared team board
In **Team & shift → Share with the team**, one doctor taps **Create team board** and sends the link to the team chat. Everyone who opens the link sees the same board, and changes appear on other phones within a few seconds. Edits made at the same time on different phones are merged, and the app keeps working offline and syncs when signal returns.

The board is stored in Supabase (table `oncall_boards`, see `supabase/oncall_boards.sql`). Anyone with the link or code can see and edit that board, so keep it inside the team and use ward/bed, never patient names or record numbers.
