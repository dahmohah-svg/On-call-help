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

## Rota and teams
One board holds the whole department. Under **Rota & teams**:
- **All staff:** everyone, once, with their grade (3rd, 2nd, 1st on-call) and whether they usually cover Obs & Gyne.
- **Teams:** the usual group for a night, with coordinator, list prep and Obs & Gyne marked.
- **Rota:** which team is on each date. *Fill rota* rotates the teams in order for 1–8 weeks.
- **Shift times:** weekday 18:00–07:30, holiday 08:00–08:00. Weekend days and public holiday dates use the holiday shift.

The app always opens on the shift running now (at 03:00 that is the shift that started at 18:00 the evening before). Use ‹ › to look at other nights.

**Swaps:** on the Board a second on-call taps *Swap* on a doctor and picks who covers. Their tasks and roles move across, and every change is logged on that shift.
**Handover:** the next shift shows a banner to carry over anything unfinished from the previous one.

## Roles
Each phone chooses **who you are** (button at the top). The app then adapts:
- **Third on-call:** read-only overview of the whole shift, including help requests.
- **Second on-call:** assigns any task to a doctor from the task card, and posts each first on-call *Inside OT* (any or a named theatre) or *Outside OT*.
- **First on-call:** *My work* shows their own cases and duties. They post what they receive and mark each one To do, In progress, Done or Need help. Help requests appear at the top of everyone's board, and anyone can tap *I'll go*.

## Shared team board
In **Team & shift → Share with the team**, one doctor taps **Create team board** and sends the link to the team chat. Everyone who opens the link sees the same board, and changes appear on other phones within a few seconds. Edits made at the same time on different phones are merged, and the app keeps working offline and syncs when signal returns.

The board is stored in Supabase (table `oncall_boards`, see `supabase/oncall_boards.sql`). Anyone with the link or code can see and edit that board, so keep it inside the team and use ward/bed, never patient names or record numbers.
